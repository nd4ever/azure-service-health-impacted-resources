# Azure Service Health Impacted Resources

[![CI](https://github.com/nd4ever/azure-service-health-impacted-resources/actions/workflows/ci.yml/badge.svg)](https://github.com/nd4ever/azure-service-health-impacted-resources/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Turn Azure **Service Health tracking IDs** into a **per-resource list** your IT teams can act on — in one CSV, fully automated.

## Why this exists

The **Impacted Resources** tab in Service Health is empty for many health advisories. Microsoft only publishes
resource-level data for a subset of events; retirements often expose their affected resources through **Azure Advisor**
instead, and a single retirement can use **a different tracking ID per resource type** (so the notice you received may not
be the ID that carries your resources).

This script combines both sources so every tracking ID ends up with either a resource list or an explicit
"no resource-level data" row.

| Source | What it provides |
|---|---|
| Service Health (`ServiceHealthResources` in Azure Resource Graph) | Events, titles, and impacted resources where Microsoft publishes them |
| Advisor Recommendation Metadata API | Maps a retirement **tracking ID → Advisor recommendation type(s)** |
| Advisor recommendations (`advisorresources` in Azure Resource Graph) | The actual affected resources for each retirement |

## Prerequisites

- PowerShell **5.1** (Windows PowerShell) or **7+** (Windows, macOS, Linux)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), signed in with `az login` (used only to obtain a token)
- **Reader** access on the subscriptions or management group you want to report on

No PowerShell modules required.

## Quick start

```powershell
# 1. Get the script
git clone https://github.com/nd4ever/azure-service-health-impacted-resources.git
cd azure-service-health-impacted-resources

# 2. Sign in and allow the script for this session
az login
Unblock-File .\src\Get-ImpactedResources.ps1          # Windows only, if downloaded
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 3. Run
.\src\Get-ImpactedResources.ps1 -All
```

> Run the **file**. Do not paste the script's contents into the console line by line.

## Usage

| Goal | Command |
|---|---|
| Everything active, all subscriptions you can read | `.\src\Get-ImpactedResources.ps1 -All` |
| Include resolved events too | `.\src\Get-ImpactedResources.ps1 -All -IncludeResolved` |
| Limit to one management group | `.\src\Get-ImpactedResources.ps1 -All -ManagementGroup 'contoso-mg'` |
| Specific tracking IDs | `.\src\Get-ImpactedResources.ps1 -TrackingId 'ABCD-123','EFGH-456'` |
| Choose the output file | add `-OutCsv .\report.csv` |

### Parameters

| Parameter | Description |
|---|---|
| `-All` | Report every Service Health event in scope plus every Advisor retirement tracking ID. Alias: `-AllRetirements`. |
| `-TrackingId <string[]>` | One or more tracking IDs to look up. Quote them. |
| `-ManagementGroup <string>` | Management group **ID** to scope queries. Omit to search all subscriptions the signed-in account can read. |
| `-IncludeResolved` | With `-All`, include resolved events (default: active only). |
| `-OutCsv <path>` | Output path. Default: `.\impacted-resources-<yyyyMMdd-HHmm>.csv`. |

## Output

One row per resource per tracking ID. See [examples/sample-output.csv](examples/sample-output.csv).

| Column | Description |
|---|---|
| `trackingId` | Service Health tracking ID |
| `eventTitle` | Notice title (falls back to the Advisor recommendation name when the notice isn't in your Service Health) |
| `titleSource` | `ServiceHealth` or `Advisor` — where `eventTitle` came from |
| `eventType` / `eventSubType` / `eventStatus` | e.g. `HealthAdvisory` / `Retirement` / `Active` |
| `source` | `ServiceHealth`, `Advisor`, or `None` (no resource-level data) |
| `subscriptionId`, `resourceGroup`, `resourceName`, `resourceType`, `region`, `resourceId` | The affected resource |
| `recommendation`, `retirementFeature`, `retirementDate` | Advisor retirement details |
| `note` | Explanation for `None` rows and Advisor-only tracking IDs |

### Reading the `source` column

- **ServiceHealth** — Microsoft listed the resource on the event's Impacted Resources tab.
- **Advisor** — The resource is affected by a retirement linked to this tracking ID via Advisor.
  If `note` says *Advisor-only tracking ID*, the retirement affects you but that notice ID was never delivered to your Service Health.
- **None** — Microsoft published no resource-level data for this event. Typical for billing, informational, and
  platform-wide advisories. Options: build a custom Azure Resource Graph inventory query for the affected SKU/API/runtime,
  or open a support request quoting the tracking ID.

## How it works

```mermaid
flowchart LR
    A[Service Health events<br/>ServiceHealthResources] --> D[CSV]
    B[Impacted resources<br/>ServiceHealthResources] --> D
    C1[Advisor Metadata API<br/>tracking ID → rec type] --> C2[advisorresources<br/>rec type → resources] --> D
    A -. no data for event .-> E[None row with note] --> D
```

1. Lists Service Health events in scope (active only unless `-IncludeResolved`).
2. Pulls Service Health impacted resources for those events.
3. Maps every Advisor retirement recommendation type to its tracking IDs, then pulls the affected resources.
4. Adds a `None` row for any event with no resource-level data, so every tracking ID is accounted for.

All Azure calls use REST (`Invoke-RestMethod`) with a token from `az account get-access-token`, which avoids
Windows `az.cmd` quoting issues and pages through results larger than 1,000 rows automatically.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The term 'TID=$1' is not recognized` / `sed` errors | You're running Bash syntax in PowerShell. Use this `.ps1` script. |
| `Supply values for the following parameters` | The script was pasted into the console. Save it as a file and run the file. |
| `ManagementGroupsNotFoundInTenant` | Use the management group **ID** (not display name), or omit `-ManagementGroup`. |
| `Could not get a token` | Run `az login` (and `az account show` to confirm). |
| Script blocked by execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` and `Unblock-File`. |
| Many `None` rows | Expected — Microsoft doesn't publish resource lists for those events. See *Reading the source column*. |

## Limitations

- Coverage depends on what Microsoft publishes. Impacted resources can take up to two weeks to appear after an event is published.
- The Advisor mapping covers **retirements** only.
- Tenant-scoped Service Health events are not included.
- Azure public cloud only (sovereign clouds use different endpoints).

## Testing

Tests run offline against mocked Azure responses — no subscription needed:

```powershell
./tests/Invoke-MockTests.ps1
```

CI runs PSScriptAnalyzer and the tests on Windows PowerShell 5.1 and PowerShell 7 (Windows + Linux).
The CI logic lives in [tests/Invoke-CI.ps1](tests/Invoke-CI.ps1) (`-Task Lint` or `-Task Test`); failures are
surfaced as annotations on the workflow run summary.

## References

- [Impacted resources from Azure Health Advisories](https://learn.microsoft.com/azure/service-health/impacted-resources-retirements)
- [Service retirement alerts and actions – choosing the right signal](https://learn.microsoft.com/azure/service-health/service-retirement-alerting-guidance)
- [Azure Resource Graph sample queries for Service Health](https://learn.microsoft.com/azure/service-health/resource-graph-samples)

## License

Copyright (c) 2026 nd4ever

Licensed under the [MIT License](LICENSE). You may use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of this software, provided the copyright notice and permission notice are included in all
copies or substantial portions of the software. The software is provided "as is", without warranty of any kind.
See [LICENSE](LICENSE) for the full text.

The license notice is also embedded in [src/Get-ImpactedResources.ps1](src/Get-ImpactedResources.ps1)
(view it with `Get-Help .\src\Get-ImpactedResources.ps1 -Full`), so it travels with the script if it's copied on its own.
