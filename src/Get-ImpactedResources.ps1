<#
.SYNOPSIS
  Lists impacted resources for Azure Service Health tracking IDs (PowerShell 5.1 / 7+).

.DESCRIPTION
  For each tracking ID:
    Step 1 - Service Health impacted resources (Resource Graph: ServiceHealthResources).
    Step 2 - Retirement fallback: Advisor Recommendation Metadata API (filtered by tracking ID)
             -> recommendation type IDs -> Advisor recommendations (Resource Graph: advisorresources).
  With -All (no tracking IDs needed):
    - every ACTIVE Service Health event in scope (add -IncludeResolved for resolved ones too),
    - all Service Health impacted resources for those events (one bulk query),
    - every retirement tracking ID known to Advisor mapped to its affected resources
      (catches retirements that use a different tracking ID per resource type),
    - one 'None' row for each event that has no resource-level data, so every ID is accounted for.

  Only prerequisite: Azure CLI signed in (az login). All calls use REST, so no az.cmd quoting issues.
  -ManagementGroup is optional; when omitted, every subscription your account can read is searched.

  Runbook / unattended use: -UseManagedIdentity gets tokens from the managed identity endpoint
  (Azure Automation, Functions, App Service, VMs and Arc servers) instead of the Azure CLI.
  Add -EmailTo and/or -ActionGroupId (recipients = the action group's email receivers), plus -EmailFrom and
  -AcsEndpoint, to email the CSV through Azure Communication Services Email; the identity needs the
  Contributor role on the Communication Services resource.
  See infra/ and deploy/ for a Bicep deployment of the whole runbook solution.

.EXAMPLE
  .\Get-ImpactedResources.ps1 -TrackingId '8Q2_-MK8','TP__-G1G','1P6D-SGZ'
.EXAMPLE
  .\Get-ImpactedResources.ps1 -TrackingId '8Q2_-MK8' -ManagementGroup 'contoso-mg'
.EXAMPLE
  .\Get-ImpactedResources.ps1 -All
.EXAMPLE
  .\Get-ImpactedResources.ps1 -All -IncludeResolved -ManagementGroup 'contoso-mg' -OutCsv .\all-events.csv
.EXAMPLE
  # As an Azure Automation runbook: managed identity + email the CSV through Azure Communication Services
  .\Get-ImpactedResources.ps1 -All -ManagementGroup 'contoso-mg' -UseManagedIdentity `
      -EmailTo 'ops@contoso.com,cloud@contoso.com' -EmailFrom 'DoNotReply@xxxx.azurecomm.net' `
      -AcsEndpoint 'https://acs-impacted.unitedstates.communication.azure.com'

.NOTES
  SPDX-License-Identifier: MIT

  MIT License

  Copyright (c) 2026 nd4ever

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string[]]$TrackingId,
    [string]$ManagementGroup,
    [Alias('AllRetirements')][switch]$All,
    [switch]$IncludeResolved,
    [string]$OutCsv = ".\impacted-resources-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    # Managed identity (runbooks / unattended). Client ID only for a user-assigned identity.
    [switch]$UseManagedIdentity,
    [string]$ManagedIdentityClientId,

    # Azure Communication Services Email. -EmailTo accepts an array or a comma/semicolon separated string.
    [string[]]$EmailTo,
    # Resource ID of an Azure Monitor action group; its enabled email receivers are added to the recipients.
    [string]$ActionGroupId,
    [string]$EmailFrom,
    [string]$AcsEndpoint,
    [string]$EmailSubject = 'Azure Service Health impacted resources report'
)

$ErrorActionPreference = 'Stop'
if (-not $All -and -not $TrackingId) { throw 'Provide -TrackingId <id1,id2,...> or -All.' }
if ($ManagementGroup -match '[<>]') {
    throw "'$ManagementGroup' looks like a placeholder. Use your management group ID (e.g. -ManagementGroup 'contoso-mg'), or omit -ManagementGroup to search all accessible subscriptions."
}

# Recipients: accept 'a@x.com,b@x.com' (schedules pass strings) as well as arrays
$recipients = @($EmailTo | ForEach-Object { "$_" -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ActionGroupId -and $ActionGroupId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/microsoft\.insights/actionGroups/[^/]+$') {
    throw "-ActionGroupId must be a full action group resource ID (got '$ActionGroupId')."
}
$sendEmail = [bool]($recipients.Count -or $ActionGroupId)
if ($sendEmail) {
    if (-not $EmailFrom -or -not $AcsEndpoint) { throw '-EmailTo / -ActionGroupId require -EmailFrom and -AcsEndpoint (Azure Communication Services endpoint).' }
    if ($AcsEndpoint -notmatch '^https://[^/\s]+/?$') { throw "-AcsEndpoint must look like https://<name>.<geo>.communication.azure.com (got '$AcsEndpoint')." }
    foreach ($a in @($recipients + $EmailFrom)) {
        if ($a -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') { throw "'$a' is not a valid email address." }
    }
}

# In a runbook, write the CSV to the sandbox temp folder unless a path was given
if ($UseManagedIdentity -and -not $PSBoundParameters.ContainsKey('OutCsv')) {
    $OutCsv = Join-Path ([IO.Path]::GetTempPath()) "impacted-resources-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
}
if ($ManagementGroup) { Write-Host "Scope: management group '$ManagementGroup'" } else { Write-Host 'Scope: all subscriptions accessible to the signed-in account' }

function Get-AccessToken([string]$Resource) {
    if (-not $UseManagedIdentity) {
        $t = az account get-access-token --resource $Resource --query accessToken -o tsv
        if (-not $t) { throw "Could not get a token for $Resource. Run 'az login' first." }
        return $t
    }
    $id = ''
    if ($ManagedIdentityClientId) { $id = '&client_id=' + [uri]::EscapeDataString($ManagedIdentityClientId) }
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        # Azure Automation, Functions, App Service, Container Apps
        $uri = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01$id"
        $r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' }
    }
    else {
        # Azure VMs / hybrid runbook workers (IMDS)
        $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$([uri]::EscapeDataString($Resource))$id"
        $r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Metadata = 'true' }
    }
    if (-not $r.access_token) { throw "Managed identity returned no token for $Resource." }
    return $r.access_token
}

function Send-AcsEmail([object[]]$Rows, [string]$CsvPath) {
    $enc  = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $sum  = @($Rows | Group-Object trackingId | Sort-Object Name | ForEach-Object {
        $first = $_.Group[0]
        $res   = @($_.Group | Where-Object { $_.source -ne 'None' }).Count
        $srcs  = (@($_.Group | Select-Object -ExpandProperty source -Unique) -join ', ')
        "<tr><td>$(& $enc $_.Name)</td><td>$(& $enc $first.eventTitle)</td><td>$(& $enc $first.eventType)</td><td style='text-align:right'>$res</td><td>$(& $enc $srcs)</td></tr>"
    })
    $scope = if ($ManagementGroup) { "management group $ManagementGroup" } else { 'all accessible subscriptions' }
    $html  = "<p>Impacted resources report for $(& $enc $scope), generated $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC.</p>" +
             "<p><b>$($Rows.Count)</b> row(s) across <b>$($sum.Count)</b> tracking ID(s). The full list is attached as CSV.</p>" +
             "<table border='1' cellpadding='4' style='border-collapse:collapse;font-family:Segoe UI,Arial;font-size:12px'>" +
             '<tr><th>Tracking ID</th><th>Title</th><th>Type</th><th>Resources</th><th>Source</th></tr>' + ($sum -join '') + '</table>'
    $text  = "Impacted resources report for $scope. $($Rows.Count) row(s) across $($sum.Count) tracking ID(s). The full list is attached as CSV."

    $body = @{
        senderAddress = $EmailFrom
        content       = @{ subject = $EmailSubject; plainText = $text; html = $html }
        recipients    = @{ to = @($recipients | ForEach-Object { @{ address = $_ } }) }
    }
    $bytes = [IO.File]::ReadAllBytes($CsvPath)
    if ($bytes.Length -le 7MB) {      # ACS limit is 10 MB per message after base64 encoding
        $body.attachments = @(@{ name = [IO.Path]::GetFileName($CsvPath); contentType = 'text/csv'; contentInBase64 = [Convert]::ToBase64String($bytes) })
    } else {
        Write-Warning "CSV is $([math]::Round($bytes.Length / 1MB, 1)) MB; too large to attach. Sending the summary only."
        $body.content.plainText += ' (CSV too large to attach.)'
    }
    $acsToken = Get-AccessToken 'https://communication.azure.com'
    $uri = $AcsEndpoint.TrimEnd('/') + '/emails:send?api-version=2023-03-31'
    $r = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' `
         -Headers @{ Authorization = "Bearer $acsToken"; 'repeatability-request-id' = [guid]::NewGuid().ToString(); 'repeatability-first-sent' = (Get-Date).ToUniversalTime().ToString('R') } `
         -Body ($body | ConvertTo-Json -Depth 6)
    Write-Host "Email queued to $($recipients -join ', ') (operation $($r.id), status $($r.status))"
}

$arm   = 'https://management.azure.com'
$token = Get-AccessToken $arm
$headers = @{ Authorization = "Bearer $token" }

if ($ActionGroupId) {
    $ag = Invoke-RestMethod -Method Get -Headers $headers -Uri "$arm$($ActionGroupId)?api-version=2023-01-01"
    $agMails = @($ag.properties.emailReceivers | Where-Object { $_.status -ne 'Disabled' -and $_.emailAddress } | ForEach-Object { $_.emailAddress.Trim() })
    Write-Host "Action group '$($ag.name)': $($agMails.Count) email receiver(s)"
    $recipients = @(@($recipients + $agMails) | Sort-Object -Unique)
    if (-not $recipients.Count) { throw "Action group '$($ag.name)' has no enabled email receivers and no -EmailTo was given." }
}

function Invoke-ArgQuery([string]$Query) {
    # Azure Resource Graph via REST, with paging
    $rows = @(); $skip = $null
    do {
        $options = @{ '$top' = 1000; resultFormat = 'objectArray' }
        if ($skip) { $options['$skipToken'] = $skip }
        $req = @{ query = $Query; options = $options }
        if ($ManagementGroup) { $req.managementGroups = @($ManagementGroup) }   # omitted = all accessible subscriptions
        $body = $req | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body $body `
             -Uri "$arm/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
        $rows += @($r.data)
        $skip = $r.'$skipToken'
    } while ($skip)
    return $rows
}

function Get-AdvisorRecTypes([string]$Filter) {
    $uri = "$arm/providers/Microsoft.Advisor/metadata?api-version=2025-01-01"
    if ($Filter) { $uri += '&$filter=' + [uri]::EscapeDataString($Filter) }
    $meta = Invoke-RestMethod -Method Get -Headers $headers -Uri $uri
    return @(($meta.value | Where-Object { $_.name -eq 'recommendationType' }).properties.supportedValues)
}

function Get-AdvisorResources([string[]]$RecTypeIds) {
    $list = ($RecTypeIds | ForEach-Object { "'$($_.ToLower())'" }) -join ','
    Invoke-ArgQuery @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| extend recTypeId = tolower(tostring(properties.recommendationTypeId))
| where recTypeId in ($list)
| project recTypeId, subscriptionId,
          resourceId = tostring(properties.resourceMetadata.resourceId),
          resourceName = tostring(properties.impactedValue),
          resourceType = tostring(properties.impactedField),
          recommendation = tostring(properties.shortDescription.problem),
          retirementFeature = tostring(properties.extendedProperties.retirementFeatureName),
          retirementDate = tostring(properties.extendedProperties.retirementDate)
"@
}

function Get-AllRetirementAdvisorResources {
    # All retirement-type Advisor recommendations (filtered locally by type ID to avoid huge 'in' lists)
    Invoke-ArgQuery @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| extend ep = properties.extendedProperties
| where tostring(ep.recommendationSubCategory) == 'ServiceUpgradeAndRetirement' or isnotempty(ep.retirementDate)
| project recTypeId = tolower(tostring(properties.recommendationTypeId)), subscriptionId,
          resourceId = tostring(properties.resourceMetadata.resourceId),
          resourceName = tostring(properties.impactedValue),
          resourceType = tostring(properties.impactedField),
          recommendation = tostring(properties.shortDescription.problem),
          retirementFeature = tostring(ep.retirementFeatureName),
          retirementDate = tostring(ep.retirementDate)
"@
}

function New-Row($Tid, $Evt, $Source, $R, $Note) {
    $rg = ''
    if ($R.resourceId -match '/resourcegroups/([^/]+)/') { $rg = $Matches[1] }
    [pscustomobject]@{
        trackingId        = $Tid
        eventTitle        = $Evt.eventTitle
        titleSource       = if ($Evt.titleSource) { $Evt.titleSource } elseif ($Evt.eventTitle) { 'ServiceHealth' } else { '' }
        eventType         = $Evt.eventType
        eventSubType      = $Evt.eventSubType
        eventStatus       = $Evt.eventStatus
        source            = $Source
        subscriptionId    = $R.subscriptionId
        resourceGroup     = $rg
        resourceName      = if ($R.resourceName) { $R.resourceName } elseif ($R.resourceId) { ($R.resourceId -split '/')[-1] } else { '' }
        resourceType      = $R.resourceType
        region            = $R.region
        recommendation    = $R.recommendation
        retirementFeature = $R.retirementFeature
        retirementDate    = $R.retirementDate
        resourceId        = $R.resourceId
        note              = $Note
    }
}

$output = New-Object System.Collections.Generic.List[object]

if ($All) {
    # 1. All Service Health events in scope (one row per tracking ID)
    $events = @(Invoke-ArgQuery @"
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events'
| project trackingId = name, eventTitle = tostring(properties.Title), eventType = tostring(properties.EventType),
          eventSubType = tostring(properties.EventSubType), eventStatus = tostring(properties.Status)
"@)
    $evtMap = @{}
    foreach ($e in $events) {
        if (-not $e.trackingId) { continue }
        if (-not $evtMap.ContainsKey($e.trackingId) -or $e.eventStatus -eq 'Active') { $evtMap[$e.trackingId] = $e }
    }
    $inScope = @{}
    foreach ($k in $evtMap.Keys) { if ($IncludeResolved -or $evtMap[$k].eventStatus -eq 'Active') { $inScope[$k] = $true } }
    Write-Host "Service Health events: $($evtMap.Count) total, $($inScope.Count) in report ($(if ($IncludeResolved) {'active + resolved'} else {'active only'}))"
    $hasRows = @{}

    # 2. Service Health impacted resources for all events (bulk)
    $sh = @(Invoke-ArgQuery @"
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events/impactedresources'
| extend trackingId = tostring(split(split(id, '/events/')[1], '/')[0])
| project trackingId, subscriptionId, resourceId = tostring(properties.targetResourceId),
          resourceType = tostring(properties.targetResourceType), region = tostring(properties.targetRegion)
"@)
    $shCount = 0
    foreach ($r in $sh) {
        if (-not $r.trackingId -or -not $inScope.ContainsKey($r.trackingId)) { continue }
        $output.Add((New-Row $r.trackingId $evtMap[$r.trackingId] 'ServiceHealth' $r '')); $hasRows[$r.trackingId] = $true; $shCount++
    }
    Write-Host "Service Health impacted resources: $shCount"

    # 3. Advisor: every retirement recommendation type -> its tracking IDs -> affected resources
    $types = @(Get-AdvisorRecTypes | Where-Object { $_.sourceProperties.serviceRetirement.serviceHealth.trackingIds })
    $map = @{}; $titleMap = @{}
    foreach ($t in $types) {
        $map[$t.id.ToLower()]      = @($t.sourceProperties.serviceRetirement.serviceHealth.trackingIds)
        $titleMap[$t.id.ToLower()] = $t.displayName
    }
    $advCount = 0
    foreach ($r in (Get-AllRetirementAdvisorResources)) {
        if (-not $r.recTypeId -or -not $map.ContainsKey($r.recTypeId)) { continue }
        foreach ($tid in $map[$r.recTypeId]) {
            if (-not $tid) { continue }
            if ($evtMap.ContainsKey($tid)) { $e = $evtMap[$tid]; $note = '' }
            else {
                $advTitle = if ($titleMap[$r.recTypeId]) { $titleMap[$r.recTypeId] } elseif ($r.recommendation) { $r.recommendation } else { $r.retirementFeature }
                $e = [pscustomobject]@{ eventTitle = $advTitle; titleSource = 'Advisor'; eventType = 'HealthAdvisory'; eventSubType = 'Retirement'; eventStatus = '' }
                $note = 'Advisor-only tracking ID: these resources are affected by the retirement, but this notice ID is not in your Service Health'
            }
            $output.Add((New-Row $tid $e 'Advisor' $r $note)); $hasRows[$tid] = $true; $advCount++
        }
    }
    Write-Host "Advisor retirement resources: $advCount (from $($map.Count) retirement types with tracking IDs)"

    # 4. Account for every in-scope event that has no resource-level data
    $none = 0
    foreach ($tid in $inScope.Keys) {
        if (-not $hasRows.ContainsKey($tid)) {
            $output.Add((New-Row $tid $evtMap[$tid] 'None' ([pscustomobject]@{}) 'No resource-level data published for this event')); $none++
        }
    }
    Write-Host "Events with no resource-level data: $none"
}
else {
    foreach ($tid in $TrackingId) {
        if ($tid -notmatch '^[A-Za-z0-9_\-]+$') { Write-Warning "Skipping invalid tracking ID '$tid'"; continue }
        Write-Host "== $tid =="

        $evt = Invoke-ArgQuery @"
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events' and name =~ '$tid'
| project eventTitle = tostring(properties.Title), eventType = tostring(properties.EventType),
          eventSubType = tostring(properties.EventSubType), eventStatus = tostring(properties.Status)
| take 1
"@ | Select-Object -First 1
        # Advisor mapping for this tracking ID (retirements); also used as title fallback.
        # @() keeps a single result as an array: Windows PowerShell 5.1 has no .Count on a lone object.
        $types = @(Get-AdvisorRecTypes -Filter "trackingIds/any(t: t eq '$tid')")
        if (-not $evt) {
            if ($types.Count) {
                $evt = [pscustomobject]@{ eventTitle = $types[0].displayName; titleSource = 'Advisor'; eventType = 'HealthAdvisory'; eventSubType = 'Retirement'; eventStatus = '' }
            } else {
                $evt = [pscustomobject]@{ eventTitle = '(not visible in this scope)'; titleSource = ''; eventType = ''; eventSubType = ''; eventStatus = '' }
            }
        }

        # Step 1 - Service Health impacted resources
        $sh = @(Invoke-ArgQuery @"
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events/impactedresources'
| where id contains '/events/$tid/'
| project subscriptionId, resourceId = tostring(properties.targetResourceId),
          resourceType = tostring(properties.targetResourceType), region = tostring(properties.targetRegion)
"@)
        Write-Host "  Step 1 (Service Health): $($sh.Count) resource(s)"
        foreach ($r in $sh) { $output.Add((New-Row $tid $evt 'ServiceHealth' $r '')) }

        # Step 2 - Advisor fallback (retirements)
        $adv = @()
        if ($types.Count) { $adv = @(Get-AdvisorResources -RecTypeIds @($types | ForEach-Object { $_.id })) }
        Write-Host "  Step 2 (Advisor): $($types.Count) recommendation type(s), $($adv.Count) resource(s)"
        foreach ($r in $adv) { $output.Add((New-Row $tid $evt 'Advisor' $r '')) }

        if (-not $sh.Count -and -not $adv.Count) {
            $why = if ($types.Count) { 'Advisor mapping exists but no affected resources in scope' }
                   else { 'No resource-level data published (not a retirement, or no Advisor mapping)' }
            $output.Add((New-Row $tid $evt 'None' ([pscustomobject]@{}) $why))
        }
    }
}

$output | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "`nSaved $($output.Count) row(s) to $OutCsv"
if ($sendEmail) { Send-AcsEmail -Rows $output.ToArray() -CsvPath $OutCsv }
$output | Group-Object trackingId, source | Select-Object Count, Name | Format-Table -AutoSize
