<#
.SYNOPSIS
  Deploys the impacted resources report as an Azure Automation runbook that emails the CSV through
  Azure Communication Services (ACS) Email (infra/main.bicep).

.DESCRIPTION
  Interactive by default; every prompt can be answered up front with a parameter.
    1. Checks the Azure CLI sign-in and asks for anything missing (management group, subscription, region, recipients).
    2. Azure Communication Services:
         - lists the ACS resources you can see and lets you pick one (and a sender address on a linked domain), or
         - if you have none (or choose to), offers to create a new ACS + Email service with an Azure-managed domain.
    3. Removes the previous schedule link for the runbook (job schedules cannot be updated in place).
    4. Runs 'az deployment mg create' with infra/main.bicep (use -WhatIf to preview).
    5. Optionally starts the runbook once (-RunNow) so you get the first email straight away.

  Permissions needed by the person deploying: Owner (or Contributor + User Access Administrator) on the
  management group, because the template assigns Reader there and Contributor on the ACS resource.

.EXAMPLE
  .\deploy\Deploy-ImpactedResourcesReport.ps1
.EXAMPLE
  .\deploy\Deploy-ImpactedResourcesReport.ps1 -ManagementGroup contoso-mg -SubscriptionId <sub-id> -Location eastus `
      -EmailTo 'ops@contoso.com,cloud@contoso.com' -AcsMode new -RunNow
.EXAMPLE
  .\deploy\Deploy-ImpactedResourcesReport.ps1 -ManagementGroup contoso-mg -SubscriptionId <sub-id> -Location eastus `
      -ActionGroup NotifyOps -AcsMode existing `
      -ExistingAcsResourceId /subscriptions/<sub>/resourceGroups/rg-comms/providers/Microsoft.Communication/communicationServices/acs-contoso `
      -SenderAddress alerts@contoso.com

.NOTES
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 nd4ever
  Licensed under the MIT License. See the LICENSE file in the project root for the full text.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ManagementGroup,
    [string]$SubscriptionId,
    [string]$Location,
    [string]$ResourceGroupName = 'rg-impacted-resources-report',
    [string]$AutomationAccountName = 'aa-impacted-resources',
    [string]$EmailTo,
    # Action group name or resource ID; its email receivers become recipients (read at each run)
    [string]$ActionGroup,
    [ValidateSet('', 'new', 'existing')][string]$AcsMode = '',
    [string]$ExistingAcsResourceId,
    [string]$SenderAddress,
    [string]$AcsDataLocation = 'United States',
    [ValidateSet('Day', 'Week')][string]$ScheduleFrequency = 'Week',
    [string[]]$ScheduleWeekDays = @('Monday'),
    [ValidatePattern('^\d{2}:\d{2}$')][string]$ScheduleTimeUtc = '13:00',
    [switch]$IncludeResolved,
    [string]$RunbookContentUri,
    [switch]$WhatIf,
    [switch]$RunNow,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repo 'infra/main.bicep'
$arm      = 'https://management.azure.com'
$runbook  = 'Get-ImpactedResources'

function Read-Value([string]$Prompt, [string]$Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $v = Read-Host "$Prompt$suffix"
    if (-not $v) { $v = $Default }
    return $v
}
function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host "$Prompt ($d)"
    if (-not $v) { return $Default }
    return $v -match '^(y|yes)$'
}
# REST through Invoke-RestMethod (avoids az.cmd quoting problems with '&' in URLs on Windows)
function Invoke-Arm([string]$Method, [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "$arm$Path"; Headers = @{ Authorization = "Bearer $script:token" } }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = ($Body | ConvertTo-Json -Depth 10) }
    Invoke-RestMethod @p
}
function Invoke-Arg([string]$Query) {
    $rows = @(); $skip = $null
    do {
        $opt = @{ '$top' = 1000 }; if ($skip) { $opt['$skipToken'] = $skip }
        $r = Invoke-Arm Post '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' @{ query = $Query; options = $opt }
        $rows += @($r.data); $skip = $r.'$skipToken'
    } while ($skip)
    return $rows
}

# ---------------------------------------------------------------- 1. sign-in and basics
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }
Write-Host "Signed in as $($account.user.name) (tenant $($account.tenantId))" -ForegroundColor Cyan
$script:token = az account get-access-token --resource $arm --query accessToken -o tsv
if (-not $script:token) { throw 'Could not get an ARM token from the Azure CLI.' }

if (-not $ManagementGroup) { $ManagementGroup = Read-Value 'Management group ID to report on (Reader is assigned here)' '' }
if (-not $ManagementGroup -or $ManagementGroup -match '[<>]') { throw 'A management group ID is required (e.g. contoso-mg).' }
if (-not $SubscriptionId)  { $SubscriptionId = Read-Value 'Subscription for the Automation account' $account.id }
if (-not $Location)        { $Location = Read-Value 'Region for the Automation account' 'eastus' }
while (-not $EmailTo -and -not $ActionGroup) {
    $v = Read-Value 'Recipients: email addresses (comma separated) or an action group name' ''
    if ($v -match '@') { $EmailTo = $v } else { $ActionGroup = $v }
}
$recipients = @("$EmailTo" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($a in $recipients) { if ($a -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') { throw "'$a' is not a valid email address." } }
$EmailTo = $recipients -join ','

$actionGroupId = ''
if ($ActionGroup) {
    if ($ActionGroup -like '/subscriptions/*') { $agRows = @(Invoke-Arg "resources | where type =~ 'microsoft.insights/actiongroups' and id =~ '$($ActionGroup -replace "'", '')' | project id, name, resourceGroup, subscriptionId, emails = properties.emailReceivers") }
    else { $agRows = @(Invoke-Arg "resources | where type =~ 'microsoft.insights/actiongroups' and name =~ '$($ActionGroup -replace "'", '')' | project id, name, resourceGroup, subscriptionId, emails = properties.emailReceivers") }
    if (-not $agRows.Count) { throw "Action group '$ActionGroup' not found." }
    $ag = $agRows[0]
    if ($agRows.Count -gt 1) {
        Write-Host "`nSeveral action groups named '$ActionGroup':" -ForegroundColor Cyan
        for ($i = 0; $i -lt $agRows.Count; $i++) { Write-Host "  [$($i + 1)] $($agRows[$i].name) (rg $($agRows[$i].resourceGroup), sub $($agRows[$i].subscriptionId))" }
        $pick = Read-Value 'Use which one?' '1'
        if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $agRows.Count) { throw "Invalid choice '$pick'." }
        $ag = $agRows[[int]$pick - 1]
    }
    $agMails = @($ag.emails | Where-Object { $_.status -ne 'Disabled' } | ForEach-Object { $_.emailAddress })
    if (-not $agMails.Count -and -not $EmailTo) { throw "Action group '$($ag.name)' has no enabled email receivers." }
    $actionGroupId = $ag.id
    Write-Host "Action group $($ag.name): $($agMails -join ', ')"
}

# ---------------------------------------------------------------- 2. Azure Communication Services
function Get-AcsSenders([string]$AcsId) {
    $acs = Invoke-Arm Get "$($AcsId)?api-version=2023-04-01"
    $senders = @()
    foreach ($d in @($acs.properties.linkedDomains)) {
        if (-not $d) { continue }
        try {
            $dom   = Invoke-Arm Get "$($d)?api-version=2023-04-01"
            $names = @((Invoke-Arm Get "$d/senderUsernames?api-version=2023-04-01").value | ForEach-Object { $_.properties.username })
            if (-not $names.Count) { $names = @('DoNotReply') }
            foreach ($n in $names) { $senders += "$n@$($dom.properties.mailFromSenderDomain)" }
        } catch { Write-Warning "Could not read linked domain ${d}: $($_.Exception.Message)" }
    }
    return $senders
}

if (-not $AcsMode) {
    $existing = @(Invoke-Arg "resources | where type =~ 'microsoft.communication/communicationservices' | project id, name, resourceGroup, subscriptionId, linked = array_length(properties.linkedDomains) | order by name asc")
    if ($existing.Count) {
        Write-Host "`nAzure Communication Services resources you can access:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $existing.Count; $i++) {
            $e = $existing[$i]
            $mail = if ($e.linked) { "$($e.linked) email domain(s) linked" } else { 'no email domain linked' }
            Write-Host ("  [{0}] {1}  (rg {2}, sub {3}) - {4}" -f ($i + 1), $e.name, $e.resourceGroup, $e.subscriptionId, $mail)
        }
        Write-Host '  [N] Create a new ACS + Email service with an Azure-managed domain'
        $pick = Read-Value 'Use which one?' '1'
        if ($pick -match '^[Nn]') { $AcsMode = 'new' }
        elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $existing.Count) {
            $AcsMode = 'existing'; $ExistingAcsResourceId = $existing[[int]$pick - 1].id
        }
        else { throw "Invalid choice '$pick'." }
    }
    else {
        Write-Host "`nNo Azure Communication Services resource found." -ForegroundColor Yellow
        if (-not (Read-YesNo 'Create a new ACS + Email service with an Azure-managed domain?')) {
            throw 'An ACS resource with an email domain is required. Create one, or rerun and choose to create it.'
        }
        $AcsMode = 'new'
    }
}

if ($AcsMode -eq 'existing') {
    if ($ExistingAcsResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Communication/communicationServices/[^/]+$') {
        throw "-ExistingAcsResourceId must be a full Microsoft.Communication/communicationServices resource ID (got '$ExistingAcsResourceId')."
    }
    if (-not $SenderAddress) {
        $senders = @(Get-AcsSenders $ExistingAcsResourceId)
        if (-not $senders.Count) {
            throw 'That ACS resource has no email domain linked. Link one (ACS > Email > Domains) or rerun with -AcsMode new.'
        }
        Write-Host "`nSender addresses available on that resource:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $senders.Count; $i++) { Write-Host "  [$($i + 1)] $($senders[$i])" }
        $pick = Read-Value 'Send from which address?' '1'
        if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $senders.Count) { throw "Invalid choice '$pick'." }
        $SenderAddress = $senders[[int]$pick - 1]
    }
    if ($SenderAddress -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') { throw "'$SenderAddress' is not a valid sender address." }
}

# ---------------------------------------------------------------- summary
Write-Host "`nDeployment plan" -ForegroundColor Cyan
Write-Host "  Management group : $ManagementGroup (Reader for the runbook identity)"
Write-Host "  Automation       : $AutomationAccountName in $ResourceGroupName / $SubscriptionId ($Location)"
Write-Host "  Schedule         : every $(if ($ScheduleFrequency -eq 'Week') { "week on $($ScheduleWeekDays -join ', ')" } else { 'day' }) at $ScheduleTimeUtc UTC"
Write-Host "  Recipients       : $(@(@($EmailTo) + $(if ($actionGroupId) { "action group $actionGroupId" })) | Where-Object { $_ }) -join ' + ')"
if ($AcsMode -eq 'new') { Write-Host "  ACS              : NEW (Email service + Azure-managed domain, data location $AcsDataLocation)" }
else                    { Write-Host "  ACS              : existing $ExistingAcsResourceId, sender $SenderAddress" }
if (-not $Force -and -not $WhatIf -and -not (Read-YesNo 'Deploy now?')) { Write-Host 'Cancelled.'; return }

# ---------------------------------------------------------------- 3. remove previous schedule links
$aaPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
if (-not $WhatIf) {
    try { $links = @((Invoke-Arm Get "$aaPath/jobSchedules?api-version=2023-11-01").value) } catch { $links = @() }   # 404 on first deployment
    foreach ($l in $links) {
        if ($l.properties.runbook.name -eq $runbook) {
            Write-Host "Removing previous schedule link $($l.name) ($($l.properties.schedule.name))"
            Invoke-Arm Delete "$aaPath/jobSchedules/$($l.name)?api-version=2023-11-01" | Out-Null
        }
    }
}

# ---------------------------------------------------------------- 4. deploy
$params = @{
    subscriptionId    = $SubscriptionId
    resourceGroupName = $ResourceGroupName
    location          = $Location
    automationAccountName = $AutomationAccountName
    emailTo           = $EmailTo
    actionGroupResourceId = $actionGroupId
    includeResolved   = [bool]$IncludeResolved
    acsMode           = $AcsMode
    acsDataLocation   = $AcsDataLocation
    scheduleFrequency = $ScheduleFrequency
    scheduleWeekDays  = @($ScheduleWeekDays)
    scheduleTimeUtc   = $ScheduleTimeUtc
}
if ($AcsMode -eq 'existing') { $params.existingAcsResourceId = $ExistingAcsResourceId; $params.existingSenderAddress = $SenderAddress }
if ($RunbookContentUri)      { $params.runbookContentUri = $RunbookContentUri }

$paramFile = Join-Path ([IO.Path]::GetTempPath()) "impacted-resources-params-$([guid]::NewGuid().ToString('N')).json"
$paramDoc  = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{} }
foreach ($k in $params.Keys) { $paramDoc.parameters[$k] = @{ value = $params[$k] } }
$paramDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $paramFile -Encoding UTF8

$name = "impacted-resources-$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    if ($WhatIf) {
        az deployment mg what-if --management-group-id $ManagementGroup --location $Location --name $name `
            --template-file $template --parameters "@$paramFile"
        if ($LASTEXITCODE) { throw 'what-if failed.' }
        return
    }
    Write-Host "`nDeploying $name (a few minutes)..." -ForegroundColor Cyan
    $result = az deployment mg create --management-group-id $ManagementGroup --location $Location --name $name `
        --template-file $template --parameters "@$paramFile" -o json | ConvertFrom-Json
    if ($LASTEXITCODE -or -not $result) { throw "Deployment failed. See: az deployment mg show --management-group-id $ManagementGroup --name $name" }
}
finally { Remove-Item $paramFile -Force -ErrorAction SilentlyContinue }

$o = $result.properties.outputs
Write-Host "`nDeployed." -ForegroundColor Green
Write-Host "  Automation account : $($o.automationAccountId.value)"
Write-Host "  Runbook identity   : $($o.principalId.value)"
Write-Host "  ACS endpoint       : $($o.acsEndpoint.value)"
Write-Host "  Sender             : $($o.senderAddress.value)"
Write-Host "  Schedule           : $($o.scheduleName.value)"

# ---------------------------------------------------------------- 5. optional first run
if ($RunNow) {
    Write-Host "`nWaiting 60 seconds for the new role assignments to propagate, then starting the runbook..."
    Start-Sleep -Seconds 60
    $jobParams = @{ All = 'true'; ManagementGroup = $ManagementGroup; UseManagedIdentity = 'true'
                    EmailFrom = $o.senderAddress.value; AcsEndpoint = $o.acsEndpoint.value }
    if ($EmailTo)       { $jobParams.EmailTo = $EmailTo }
    if ($actionGroupId) { $jobParams.ActionGroupId = $actionGroupId }
    if ($IncludeResolved) { $jobParams.IncludeResolved = 'true' }
    $jobId = [guid]::NewGuid().ToString()
    Invoke-Arm Put "$aaPath/jobs/$($jobId)?api-version=2023-11-01" @{ properties = @{ runbook = @{ name = $runbook }; parameters = $jobParams } } | Out-Null
    Write-Host "Started job $jobId. Track it in the portal: Automation account > Jobs."
}
