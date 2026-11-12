<#
.SYNOPSIS
  Offline tests for src/Get-ImpactedResources.ps1. Azure CLI and REST calls are mocked; no subscription needed.
  Exits 1 on any failure (CI-friendly). Works on Windows PowerShell 5.1 and PowerShell 7+.

.NOTES
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 nd4ever
  Licensed under the MIT License. See the LICENSE file in the project root for the full text.
#>
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo 'src/Get-ImpactedResources.ps1'
$out    = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$script:failures = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  PASS  $Message" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $Message" -ForegroundColor Red; $script:failures++ }
}

# ---------------------------------------------------------------- fixtures
$global:MockEvents = @(
    [pscustomobject]@{ trackingId='7Z6Y-2L8'; eventTitle='App Service maintenance';     eventType='PlannedMaintenance'; eventSubType='';           eventStatus='Active' }
    [pscustomobject]@{ trackingId='TG2W-S4G'; eventTitle='Old maintenance &amp;amp; patching'; eventType='PlannedMaintenance'; eventSubType='';     eventStatus='Resolved' }  # double-encoded at source
    [pscustomobject]@{ trackingId='VNRS-RFG'; eventTitle='Dependency Agent retirement'; eventType='HealthAdvisory';     eventSubType='Retirement'; eventStatus='Active' }
    [pscustomobject]@{ trackingId='PQFS-Z1G'; eventTitle='PowerShell 7.4 end of support'; eventType='HealthAdvisory';   eventSubType='Retirement'; eventStatus='Active' }
    [pscustomobject]@{ trackingId='PQFS-Z1G'; eventTitle='PowerShell 7.4 end of support'; eventType='HealthAdvisory';   eventSubType='Retirement'; eventStatus='Active' }  # same ID in 2 subscriptions
    [pscustomobject]@{ trackingId='MQR7-KK0'; eventTitle='SSD billing & <pricing> change'; eventType='HealthAdvisory';  eventSubType='';           eventStatus='Active' }  # XML/HTML escaping
)
$global:MockImpacted = @(
    [pscustomobject]@{ trackingId='7Z6Y-2L8'; subscriptionId='sub-1'; resourceId='/subscriptions/sub-1/resourceGroups/rg-web/providers/Microsoft.Web/serverFarms/asp-1'; resourceType='Microsoft.Web/serverFarms'; region='centralus' }
    [pscustomobject]@{ trackingId='TG2W-S4G'; subscriptionId='sub-1'; resourceId='/subscriptions/sub-1/resourceGroups/rg-old/providers/Microsoft.Web/serverFarms/asp-old'; resourceType='Microsoft.Web/serverFarms'; region='centralus' }
)
function global:New-MockRecType($Id, $DisplayName, $TrackingIds) {
    [pscustomobject]@{ id=$Id; displayName=$DisplayName
        sourceProperties=[pscustomobject]@{ serviceRetirement=[pscustomobject]@{ serviceHealth=[pscustomobject]@{ trackingIds=$TrackingIds } } } }
}
$global:MockRecTypes = @(
    (New-MockRecType 'A8FFBD6C-0000-0000-0000-000000000001' 'Migrate from Dependency Agent and VM Insights Map' @('SKLP-HFZ'))   # upper-case on purpose
    (New-MockRecType '3055fad1-0000-0000-0000-000000000002' 'Migrate from Dependency Agent and VM Insights Map' @('SKLP-HFZ'))
    (New-MockRecType 'f49d7356-0000-0000-0000-000000000003' 'Migrate from Dependency Agent and VM Insights Map' @('VNRS-RFG'))
    (New-MockRecType 'efd285e2-0000-0000-0000-000000000004' 'Migrate your apps from PowerShell 7.4 to PowerShell 7.6' @('PQFS-Z1G'))
    [pscustomobject]@{ id='not-a-retirement'; displayName='Enable soft delete'; sourceProperties=$null }
)
$global:MockAdvisor = @(
    [pscustomobject]@{ recTypeId='a8ffbd6c-0000-0000-0000-000000000001'; subscriptionId='sub-2'; resourceId='/subscriptions/sub-2/resourcegroups/rg-arc/providers/microsoft.hybridcompute/machines/srv-01'; resourceName='srv-01'; resourceType='Microsoft.HybridCompute/machines'; recommendation='Migrate from Dependency Agent and VM Insights Map'; retirementFeature='Dependency Agent and VM Insights Map'; retirementDate='2028-06-30' }
    [pscustomobject]@{ recTypeId='3055fad1-0000-0000-0000-000000000002'; subscriptionId='sub-1'; resourceId='/subscriptions/sub-1/resourcegroups/rg-mon/providers/microsoft.operationalinsights/workspaces/law-01'; resourceName='law-01'; resourceType='Microsoft.OperationalInsights/workspaces'; recommendation='Migrate from Dependency Agent and VM Insights Map'; retirementFeature='Dependency Agent and VM Insights Map'; retirementDate='2028-06-30' }
    [pscustomobject]@{ recTypeId='efd285e2-0000-0000-0000-000000000004'; subscriptionId='sub-1'; resourceId='/subscriptions/sub-1/resourcegroups/rg-func/providers/microsoft.web/sites/func-01'; resourceName='func-01'; resourceType='Microsoft.Web/sites'; recommendation='Migrate your apps from PowerShell 7.4 to PowerShell 7.6 &amp; later'; retirementFeature='Support for PowerShell 7.4 &amp; earlier'; retirementDate='2026-11-10' }
    [pscustomobject]@{ recTypeId='9d5717d2-0000-0000-0000-00000000000f'; subscriptionId='sub-2'; resourceId='/subscriptions/sub-2/resourcegroups/rg-arc/providers/microsoft.hybridcompute/machines/srv-02'; resourceName='srv-02'; resourceType='Microsoft.HybridCompute/machines'; recommendation='Upgrade agent'; retirementFeature=''; retirementDate='' }
)
$global:MockBodies = New-Object System.Collections.Generic.List[object]
$global:MockAuth   = New-Object System.Collections.Generic.List[string]
$global:MockEmails = New-Object System.Collections.Generic.List[object]
$global:MockTokenRequests = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- mocks
function global:az { 'fake-token' }
function global:Invoke-RestMethod {
    param($Method, $Headers, $ContentType, $Body, $Uri)
    if ($Uri -like 'http://mock-identity/*' -or $Uri -like 'http://169.254.169.254/*') {   # managed identity endpoint
        $global:MockTokenRequests.Add("$Uri|$($Headers['X-IDENTITY-HEADER'])")
        $res = [uri]::UnescapeDataString(([regex]::Match($Uri, 'resource=([^&]+)')).Groups[1].Value)
        return [pscustomobject]@{ access_token = "mi-token-for-$res" }
    }
    if ($Headers -and $Headers.Authorization) { $global:MockAuth.Add($Headers.Authorization) }
    if ($Uri -like '*/microsoft.insights/actionGroups/*') {
        return [pscustomobject]@{ name = 'NotifyMe'; properties = [pscustomobject]@{ emailReceivers = @(
            [pscustomobject]@{ name = 'a'; emailAddress = 'ag@contoso.com';  status = 'Enabled' }
            [pscustomobject]@{ name = 'b'; emailAddress = 'off@contoso.com'; status = 'Disabled' }
            [pscustomobject]@{ name = 'c'; emailAddress = 'ops@contoso.com'; status = 'Enabled' }) } }
    }
    if ($Uri -like '*/emails:send*') {
        $global:MockEmails.Add([pscustomobject]@{ Uri = $Uri; Auth = $Headers.Authorization; Body = (ConvertFrom-Json $Body) })
        return [pscustomobject]@{ id = 'op-1'; status = 'Running' }
    }
    if ($Uri -like '*Microsoft.Advisor/metadata*') {
        $values = $global:MockRecTypes
        if ($Uri -match 'filter=(.+)$') {
            $tid = ([regex]::Match([uri]::UnescapeDataString($Matches[1]), "eq '([^']+)'")).Groups[1].Value
            $values = @($global:MockRecTypes | Where-Object { $_.sourceProperties -and ($_.sourceProperties.serviceRetirement.serviceHealth.trackingIds -contains $tid) })
        }
        return [pscustomobject]@{ value = @([pscustomobject]@{ name='recommendationType'; properties=[pscustomobject]@{ supportedValues=$values } }) }
    }
    $req = ConvertFrom-Json $Body
    $global:MockBodies.Add($req)
    $q = $req.query
    $data = @()
    if ($q -match "name =~ '([^']+)'") {                                   # per-ID event lookup
        $t = $Matches[1]; $data = @($global:MockEvents | Where-Object { $_.trackingId -eq $t } | Select-Object -First 1)
    }
    elseif ($q -match "contains '/events/([^/']+)/'") {                  # per-ID impacted resources
        $t = $Matches[1]; $data = @($global:MockImpacted | Where-Object { $_.trackingId -eq $t })
    }
    elseif ($q -match 'split\(split\(id') { $data = $global:MockImpacted } # bulk impacted resources
    elseif ($q -match 'project trackingId = name') { $data = $global:MockEvents }  # bulk events
    elseif ($q -match 'recTypeId in \(') {                                 # Advisor by type list
        $data = @($global:MockAdvisor | Where-Object { $q -match [regex]::Escape($_.recTypeId) })
    }
    elseif ($q -match 'ServiceUpgradeAndRetirement') { $data = $global:MockAdvisor }  # Advisor all retirements
    else { throw "Unmocked query: $q" }
    return [pscustomobject]@{ data = $data }
}

function Invoke-Target([hashtable]$Params) {
    # Callers wrap the result in @() - a function returning one row unrolls to a scalar,
    # and Windows PowerShell 5.1 has no .Count on a single object.
    & $script @Params *> $null
    return @(Import-Csv $Params.OutCsv)
}

function Read-Xlsx([byte[]]$Bytes) {
    # Returns @{ '<entry name>' = '<text>' } for every part in an .xlsx package
    Add-Type -AssemblyName System.IO.Compression
    $ms  = New-Object System.IO.MemoryStream(, $Bytes)
    $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    $parts = @{}
    try {
        foreach ($e in $zip.Entries) {
            $r = New-Object System.IO.StreamReader($e.Open())
            try { $parts[$e.FullName] = $r.ReadToEnd() } finally { $r.Dispose() }
        }
    } finally { $zip.Dispose(); $ms.Dispose() }
    return $parts
}
function Get-SheetRows([string]$Xml) { ([regex]::Matches($Xml, '<row ')).Count }

# ---------------------------------------------------------------- tests
Write-Host 'Parse'
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs) | Out-Null
Assert-True (-not $errs) 'script parses without errors'

Write-Host 'Help and license'
$help  = Get-Help $script -Full
$notes = ($help.alertSet.alert | Out-String)
Assert-True ($help.Synopsis -like '*impacted resources*') 'comment-based help is recognized (not auto-generated syntax)'
Assert-True (@($help.examples.example).Count -ge 3) 'help examples are present'
Assert-True ($notes -match 'MIT License' -and $notes -match 'AS IS') 'MIT license notice embedded in help'

Write-Host 'Deploy script'
$deploy = Join-Path $repo 'deploy/Deploy-ImpactedResourcesReport.ps1'
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$null, [ref]$errs) | Out-Null
Assert-True (-not $errs) 'deploy script parses without errors'
$dhelp = Get-Help $deploy -Full
Assert-True ($dhelp.Synopsis -like '*Automation runbook*') 'deploy script help is recognized'
$dparams = (Get-Command $deploy).Parameters
Assert-True ((@($dparams['AcsMode'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })[0].ValidValues -join ',') -eq ',new,existing') 'deploy -AcsMode accepts new/existing (blank = prompt)'
foreach ($p in 'ManagementGroup', 'EmailTo', 'ActionGroup', 'ExistingAcsResourceId', 'SenderAddress', 'WhatIf', 'RunNow') {
    Assert-True ($dparams.ContainsKey($p)) "deploy script has -$p"
}
Assert-True (Test-Path (Join-Path $repo 'infra/main.bicep')) 'infra/main.bicep present'

Write-Host 'Per tracking ID'
$rows = @(Invoke-Target @{ TrackingId = @('7Z6Y-2L8','SKLP-HFZ','VNRS-RFG','ZZZZ-000','bad;id'); ManagementGroup = 'test-mg'; OutCsv = "$out/ids.csv" })
$by = { param($t, $s) @($rows | Where-Object { $_.trackingId -eq $t -and $_.source -eq $s }) }
Assert-True (@(& $by '7Z6Y-2L8' 'ServiceHealth').Count -eq 1) '7Z6Y-2L8: 1 Service Health resource'
Assert-True (@(& $by 'SKLP-HFZ' 'Advisor').Count -eq 2)       'SKLP-HFZ: 2 Advisor resources (2 rec types)'
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'SKLP-HFZ' -and $_.titleSource -eq 'Advisor' -and $_.eventTitle }).Count -eq 2) 'SKLP-HFZ: title falls back to Advisor'
Assert-True (@(& $by 'VNRS-RFG' 'None' | Where-Object { $_.note -like 'Advisor mapping exists*' }).Count -eq 1) 'VNRS-RFG: None row, mapping but no resources'
Assert-True (@(& $by 'ZZZZ-000' 'None' | Where-Object { $_.note -like 'No resource-level data*' }).Count -eq 1) 'unknown ID: None row with explanation'
Assert-True (-not @($rows | Where-Object { $_.trackingId -eq 'bad;id' }).Count) 'invalid ID skipped'
Assert-True (@(& $by '7Z6Y-2L8' 'ServiceHealth' | Where-Object { $_.resourceGroup -eq 'rg-web' }).Count -eq 1) 'resourceGroup parsed from resource ID'

Write-Host '-All (active only)'
$global:MockBodies.Clear()
$rows = @(Invoke-Target @{ All = $true; OutCsv = "$out/all.csv" })
Assert-True ($rows.Count -eq 6) "6 rows (got $($rows.Count))"
Assert-True (-not @($rows | Where-Object { -not $_.eventTitle }).Count) 'every row has an eventTitle'
Assert-True (-not @($rows | Where-Object { $_.trackingId -eq 'TG2W-S4G' }).Count) 'resolved event excluded'
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'SKLP-HFZ' -and $_.note -like 'Advisor-only*' }).Count -eq 2) 'Advisor-only tracking ID flagged'
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'PQFS-Z1G' -and $_.titleSource -eq 'ServiceHealth' }).Count -eq 1) 'delivered retirement keeps Service Health title (no duplicate per subscription)'
Assert-True (@($rows | Where-Object { $_.source -eq 'None' }).Count -eq 2) 'events without resource data get a None row'
Assert-True (-not @($rows | Where-Object { $_.resourceName -eq 'srv-02' }).Count) 'Advisor recs without tracking ID mapping excluded'
Assert-True (-not @($global:MockBodies | Where-Object { $_.managementGroups }).Count) 'no -ManagementGroup => tenant-wide scope'

Write-Host 'Excel workbook (two worksheets)'
$xlsxPath = Join-Path $out 'all.xlsx'
Assert-True (Test-Path $xlsxPath) 'workbook written next to the CSV by default'
$parts = Read-Xlsx ([IO.File]::ReadAllBytes($xlsxPath))
foreach ($p in '[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml', 'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml') {
    Assert-True ($parts.ContainsKey($p)) "package part $p present"
}
$xmlOk = $true
foreach ($k in @($parts.Keys)) { try { [xml]$parts[$k] | Out-Null } catch { $xmlOk = $false; Write-Host "    bad XML in ${k}: $($_.Exception.Message)" } }
Assert-True $xmlOk 'every package part is well-formed XML'
$wb = [xml]$parts['xl/workbook.xml']
Assert-True ((@($wb.workbook.sheets.sheet | ForEach-Object { $_.name }) -join '|') -eq 'Affected resources|No affected resources') "sheets 'Affected resources' and 'No affected resources'"
Assert-True ((Get-SheetRows $parts['xl/worksheets/sheet1.xml']) -eq 5) 'Affected sheet: header + 4 resource rows'
Assert-True ((Get-SheetRows $parts['xl/worksheets/sheet2.xml']) -eq 3) 'No-affected sheet: header + 2 notifications'
Assert-True ($parts['xl/worksheets/sheet1.xml'] -notmatch 'MQR7-KK0|VNRS-RFG') 'notifications without resources not on the Affected sheet'
Assert-True ($parts['xl/worksheets/sheet2.xml'] -match 'MQR7-KK0' -and $parts['xl/worksheets/sheet2.xml'] -match 'VNRS-RFG') 'notifications without resources on the No-affected sheet'
Assert-True ($parts['xl/worksheets/sheet2.xml'] -match 'SSD billing &amp; &lt;pricing&gt; change') 'cell text XML-escaped'
Assert-True ($parts['xl/worksheets/sheet2.xml'] -notmatch '>resourceId<') 'No-affected sheet omits empty resource columns'
Assert-True ($parts['xl/worksheets/sheet1.xml'] -match 'state="frozen"' -and $parts['xl/worksheets/sheet1.xml'] -match '<autoFilter ref="A1:Q5"/>') 'header row frozen with autofilter'

$rows = @(Invoke-Target @{ All = $true; OutCsv = "$out/all2.csv"; OutXlsx = "$out/custom-name.xlsx" })
Assert-True (Test-Path (Join-Path $out 'custom-name.xlsx')) '-OutXlsx path honored'
Push-Location $out
try { & $script -All -OutCsv '.\relative.csv' *> $null } finally { Pop-Location }
Assert-True ((Test-Path (Join-Path $out 'relative.csv')) -and (Test-Path (Join-Path $out 'relative.xlsx'))) 'relative paths resolve against the PowerShell location'

Write-Host '-All -IncludeResolved'
$global:MockBodies.Clear()
$rows = @(Invoke-Target @{ All = $true; IncludeResolved = $true; ManagementGroup = 'test-mg'; OutCsv = "$out/all-resolved.csv" })
Assert-True ($rows.Count -eq 7) "7 rows (got $($rows.Count))"
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'TG2W-S4G' -and $_.eventStatus -eq 'Resolved' }).Count -eq 1) 'resolved event included'
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'TG2W-S4G' })[0].eventTitle -eq 'Old maintenance & patching') 'double-encoded title (&amp;amp;) decoded'
$func = @($rows | Where-Object { $_.resourceName -eq 'func-01' })[0]
Assert-True ($func.recommendation -eq 'Migrate your apps from PowerShell 7.4 to PowerShell 7.6 & later' -and $func.retirementFeature -eq 'Support for PowerShell 7.4 & earlier') 'Advisor text (&amp;) decoded'
Assert-True (@($global:MockBodies | Where-Object { $_.managementGroups -contains 'test-mg' }).Count -gt 0) '-ManagementGroup passed to Resource Graph'

Write-Host 'Alias and validation'
$rows = @(Invoke-Target @{ AllRetirements = $true; OutCsv = "$out/alias.csv" })
Assert-True ($rows.Count -eq 6) '-AllRetirements alias behaves like -All'
$msg = ''; try { & $script -All -ManagementGroup '<your-mg>' -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*placeholder*') 'placeholder management group rejected'
$msg = ''; try { & $script -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*-TrackingId*') 'missing -TrackingId/-All rejected'
Assert-True (-not $global:MockEmails.Count) 'no email sent without -EmailTo'

Write-Host 'Managed identity + ACS email (runbook mode)'
$env:IDENTITY_ENDPOINT = 'http://mock-identity/msi/token'; $env:IDENTITY_HEADER = 'mock-secret'
$global:MockAuth.Clear(); $global:MockEmails.Clear(); $global:MockTokenRequests.Clear()
$acs = 'https://acs-test.unitedstates.communication.azure.com/'
$rows = @(Invoke-Target @{ All = $true; ManagementGroup = 'test-mg'; UseManagedIdentity = $true; ManagedIdentityClientId = '11111111-2222-3333-4444-555555555555'
                           EmailTo = @('ops@contoso.com; cloud@contoso.com'); EmailFrom = 'DoNotReply@abc.azurecomm.net'; AcsEndpoint = $acs; OutCsv = "$out/mi.csv" })
Assert-True ($rows.Count -eq 6) 'report content unchanged under managed identity'
Assert-True (@($global:MockAuth | Where-Object { $_ -eq 'Bearer mi-token-for-https://management.azure.com' }).Count -gt 0) 'ARM calls use the managed identity token'
Assert-True (-not @($global:MockAuth | Where-Object { $_ -like '*fake-token*' }).Count) 'Azure CLI not used with -UseManagedIdentity'
Assert-True (@($global:MockTokenRequests | Where-Object { $_ -like '*client_id=11111111-2222-3333-4444-555555555555*' -and $_ -like '*|mock-secret' }).Count -gt 0) 'user-assigned client ID and X-IDENTITY-HEADER sent'
Assert-True ($global:MockEmails.Count -eq 1) 'exactly one email sent'
$mail = $global:MockEmails[0]
Assert-True ($mail.Uri -eq 'https://acs-test.unitedstates.communication.azure.com/emails:send?api-version=2023-03-31') 'ACS endpoint + api-version (trailing slash trimmed)'
Assert-True ($mail.Auth -eq 'Bearer mi-token-for-https://communication.azure.com') 'ACS call uses a communication.azure.com token'
Assert-True ((@($mail.Body.recipients.to | ForEach-Object { $_.address }) -join ',') -eq 'ops@contoso.com,cloud@contoso.com') 'recipients split on ; and ,'
Assert-True ($mail.Body.senderAddress -eq 'DoNotReply@abc.azurecomm.net') 'sender address set'
$att = @($mail.Body.attachments)[0]
Assert-True (@($mail.Body.attachments).Count -eq 1 -and $att.name -eq 'mi.xlsx' -and $att.contentType -eq 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') 'Excel workbook attached'
$attParts = Read-Xlsx ([Convert]::FromBase64String($att.contentInBase64))
Assert-True ($attParts['xl/worksheets/sheet1.xml'] -match 'SKLP-HFZ' -and $attParts['xl/worksheets/sheet2.xml'] -match 'MQR7-KK0') 'attachment contains both worksheets'
$html = $mail.Body.content.html
Assert-True ($html -match 'Notifications with affected resources \(3\)' -and $html -match 'Notifications with no affected resources \(2\)') 'email has both sections with counts'
$iAff = $html.IndexOf('Notifications with affected resources'); $iNo = $html.IndexOf('Notifications with no affected resources')
Assert-True ($html.IndexOf('SKLP-HFZ') -gt $iAff -and $html.IndexOf('SKLP-HFZ') -lt $iNo) 'notification with resources listed in the first section'
Assert-True ($html.IndexOf('MQR7-KK0') -gt $iNo) 'notification without resources listed in the second section'
Assert-True ($html -match 'SSD billing &amp; &lt;pricing&gt; change') 'titles HTML-encoded in the email'
Assert-True ($mail.Body.content.plainText -match 'affected resources: 3 \(4 resources\)') 'plain-text body has the counts'

$global:MockTokenRequests.Clear()
Remove-Item Env:\IDENTITY_ENDPOINT, Env:\IDENTITY_HEADER
$rows = @(Invoke-Target @{ TrackingId = @('7Z6Y-2L8'); UseManagedIdentity = $true; OutCsv = "$out/imds.csv" })
Assert-True (@($global:MockTokenRequests | Where-Object { $_ -like 'http://169.254.169.254/*' }).Count -gt 0) 'falls back to IMDS when IDENTITY_ENDPOINT is absent'

Write-Host 'Action group recipients'
$global:MockEmails.Clear()
$agId = '/subscriptions/sub-1/resourceGroups/rg-mon/providers/microsoft.insights/actionGroups/NotifyMe'
$rows = @(Invoke-Target @{ TrackingId = @('7Z6Y-2L8'); ActionGroupId = $agId; EmailTo = 'ops@contoso.com'; EmailFrom = 'ServiceHealth@abc.azurecomm.net'; AcsEndpoint = $acs; OutCsv = "$out/ag.csv" })
$to = @($global:MockEmails[0].Body.recipients.to | ForEach-Object { $_.address })
Assert-True ($global:MockEmails.Count -eq 1) 'email sent with -ActionGroupId'
Assert-True (($to -contains 'ag@contoso.com') -and ($to -contains 'ops@contoso.com')) 'action group receivers + -EmailTo combined'
Assert-True (-not ($to -contains 'off@contoso.com')) 'disabled action group receivers skipped'
Assert-True ($to.Count -eq 2) 'duplicate recipients removed'
$global:MockEmails.Clear()
$rows = @(Invoke-Target @{ TrackingId = @('7Z6Y-2L8'); ActionGroupId = $agId; EmailFrom = 'ServiceHealth@abc.azurecomm.net'; AcsEndpoint = $acs; OutCsv = "$out/ag2.csv" })
Assert-True ($global:MockEmails.Count -eq 1) '-ActionGroupId alone (no -EmailTo) sends'
$msg = ''; try { & $script -All -ActionGroupId 'NotifyMe' -EmailFrom 'a@b.net' -AcsEndpoint $acs -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*full action group resource ID*') 'action group name (not ID) rejected'

Write-Host 'Email validation'
$msg = ''; try { & $script -All -EmailTo 'a@contoso.com' -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*require -EmailFrom*') '-EmailTo without sender/endpoint rejected'
$msg = ''; try { & $script -All -EmailTo 'not-an-email' -EmailFrom 'a@b.net' -AcsEndpoint $acs -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*not a valid email*') 'invalid recipient rejected'
$msg = ''; try { & $script -All -EmailTo 'a@contoso.com' -EmailFrom 'a@b.net' -AcsEndpoint 'acs-test.communication.azure.com' -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*-AcsEndpoint must*') 'endpoint without https:// rejected'

Remove-Item -Path $out -Recurse -Force -ErrorAction SilentlyContinue
if ($script:failures) { Write-Host "`n$($script:failures) test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed" -ForegroundColor Green
