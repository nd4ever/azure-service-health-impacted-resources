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
    [pscustomobject]@{ trackingId='TG2W-S4G'; eventTitle='Old maintenance';             eventType='PlannedMaintenance'; eventSubType='';           eventStatus='Resolved' }
    [pscustomobject]@{ trackingId='VNRS-RFG'; eventTitle='Dependency Agent retirement'; eventType='HealthAdvisory';     eventSubType='Retirement'; eventStatus='Active' }
    [pscustomobject]@{ trackingId='PQFS-Z1G'; eventTitle='PowerShell 7.4 end of support'; eventType='HealthAdvisory';   eventSubType='Retirement'; eventStatus='Active' }
    [pscustomobject]@{ trackingId='PQFS-Z1G'; eventTitle='PowerShell 7.4 end of support'; eventType='HealthAdvisory';   eventSubType='Retirement'; eventStatus='Active' }  # same ID in 2 subscriptions
    [pscustomobject]@{ trackingId='MQR7-KK0'; eventTitle='SSD billing change';          eventType='HealthAdvisory';     eventSubType='';           eventStatus='Active' }
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
    [pscustomobject]@{ recTypeId='efd285e2-0000-0000-0000-000000000004'; subscriptionId='sub-1'; resourceId='/subscriptions/sub-1/resourcegroups/rg-func/providers/microsoft.web/sites/func-01'; resourceName='func-01'; resourceType='Microsoft.Web/sites'; recommendation='Migrate your apps from PowerShell 7.4 to PowerShell 7.6'; retirementFeature='Support for PowerShell 7.4'; retirementDate='2026-11-10' }
    [pscustomobject]@{ recTypeId='9d5717d2-0000-0000-0000-00000000000f'; subscriptionId='sub-2'; resourceId='/subscriptions/sub-2/resourcegroups/rg-arc/providers/microsoft.hybridcompute/machines/srv-02'; resourceName='srv-02'; resourceType='Microsoft.HybridCompute/machines'; recommendation='Upgrade agent'; retirementFeature=''; retirementDate='' }
)
$global:MockBodies = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- mocks
function global:az { 'fake-token' }
function global:Invoke-RestMethod {
    param($Method, $Headers, $ContentType, $Body, $Uri)
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

Write-Host '-All -IncludeResolved'
$global:MockBodies.Clear()
$rows = @(Invoke-Target @{ All = $true; IncludeResolved = $true; ManagementGroup = 'test-mg'; OutCsv = "$out/all-resolved.csv" })
Assert-True ($rows.Count -eq 7) "7 rows (got $($rows.Count))"
Assert-True (@($rows | Where-Object { $_.trackingId -eq 'TG2W-S4G' -and $_.eventStatus -eq 'Resolved' }).Count -eq 1) 'resolved event included'
Assert-True (@($global:MockBodies | Where-Object { $_.managementGroups -contains 'test-mg' }).Count -gt 0) '-ManagementGroup passed to Resource Graph'

Write-Host 'Alias and validation'
$rows = @(Invoke-Target @{ AllRetirements = $true; OutCsv = "$out/alias.csv" })
Assert-True ($rows.Count -eq 6) '-AllRetirements alias behaves like -All'
$msg = ''; try { & $script -All -ManagementGroup '<your-mg>' -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*placeholder*') 'placeholder management group rejected'
$msg = ''; try { & $script -OutCsv "$out/x.csv" *> $null } catch { $msg = $_.Exception.Message }
Assert-True ($msg -like '*-TrackingId*') 'missing -TrackingId/-All rejected'

Remove-Item -Path $out -Recurse -Force -ErrorAction SilentlyContinue
if ($script:failures) { Write-Host "`n$($script:failures) test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed" -ForegroundColor Green
