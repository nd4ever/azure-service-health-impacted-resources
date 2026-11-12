<#
.SYNOPSIS
  CI entry point: runs PSScriptAnalyzer + Bicep build/lint (-Task Lint) or the offline mock tests (-Task Test).

.DESCRIPTION
  Keeps CI logic out of .github/workflows so it can change without editing the workflow file.
  When running in GitHub Actions, every lint finding, failed test, or unhandled exception is also
  emitted as an '::error' annotation, so failures are visible on the run summary and via the
  check-runs API without opening the job log.

.EXAMPLE
  ./tests/Invoke-CI.ps1 -Task Test
.EXAMPLE
  ./tests/Invoke-CI.ps1 -Task Lint

.NOTES
  SPDX-License-Identifier: MIT
  Copyright (c) 2026 nd4ever
  Licensed under the MIT License. See the LICENSE file in the project root for the full text.
#>
#Requires -Version 5.1

param(
    [ValidateSet('Lint', 'Test')]
    [string]$Task = 'Test'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gha  = [bool]$env:GITHUB_ACTIONS
$psv  = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

function Write-Annotation([string]$Message, [string]$File, [int]$Line) {
    if (-not $gha) { return }
    $msg = $Message -replace '%', '%25' -replace "`r", '' -replace "`n", '%0A'
    if ($File) { Write-Host "::error file=$File,line=$Line::$msg" } else { Write-Host "::error::$msg" }
}

Write-Host "== $Task on $psv =="

if ($Task -eq 'Lint') {
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
    }
    Import-Module PSScriptAnalyzer
    $findings = @()
    foreach ($dir in 'src', 'tests', 'deploy') {     # -Path accepts a single path, so call once per folder
        $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $dir) -Recurse -Severity Error)
    }
    foreach ($f in $findings) {
        $rel = ($f.ScriptPath.Substring($root.Length).TrimStart('\', '/')) -replace '\\', '/'
        Write-Host "${rel}:$($f.Line) [$($f.RuleName)] $($f.Message)"
        Write-Annotation "$($f.RuleName): $($f.Message)" $rel $f.Line
    }
    Write-Host "PSScriptAnalyzer error-severity findings: $($findings.Count)"

    # Bicep: build + lint every template; warnings and errors both fail CI
    $bicepIssues = 0
    $useCli = [bool](Get-Command bicep -ErrorAction SilentlyContinue)
    if (-not $useCli -and -not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Neither bicep nor az is installed.' }
    if (-not $useCli) { az bicep install 2>&1 | Out-Null }
    $main = Join-Path $root 'infra/main.bicep'
    foreach ($verb in 'build', 'lint') {
        $out = if ($useCli) { & bicep $verb $main $(if ($verb -eq 'build') { '--stdout' }) 2>&1 }
               else         { & az bicep $verb --file $main $(if ($verb -eq 'build') { '--stdout' }) 2>&1 }
        $code = $LASTEXITCODE
        foreach ($l in @($out | ForEach-Object { "$_" } | Where-Object { $_ -match ' : (Warning|Error) ' })) {
            Write-Host $l; $bicepIssues++
            if ($l -match '^(.+?)\((\d+),\d+\) : (.+)$') {
                $rel = ($Matches[1].Substring([math]::Min($root.Length, $Matches[1].Length)).TrimStart('\', '/')) -replace '\\', '/'
                Write-Annotation $Matches[3] $rel ([int]$Matches[2])
            } else { Write-Annotation $l }
        }
        if ($code) { $bicepIssues++; Write-Annotation "bicep $verb exited with $code" }
    }
    Write-Host "Bicep warnings/errors: $bicepIssues"
    if ($findings.Count -or $bicepIssues) { exit 1 }
    exit 0
}

# -Task Test
$tests  = Join-Path $PSScriptRoot 'Invoke-MockTests.ps1'
$lines  = New-Object System.Collections.Generic.List[string]
$failed = $false
$global:LASTEXITCODE = 0
try {
    & $tests *>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $lines.Add($s) }
    if ($LASTEXITCODE) { $failed = $true }
}
catch {
    $failed = $true
    $msg = "Unhandled exception on ${psv}: $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)"
    Write-Host $msg
    Write-Annotation $msg
}
foreach ($l in $lines) {
    if ($l -match '^\s*FAIL\s+(.+)$') { Write-Annotation "Test failed on ${psv}: $($Matches[1])" }
}
if ($failed) { exit 1 }
exit 0
