// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
// Recurring schedule + link to the runbook with its parameters.
// Job schedules cannot be updated in place, so the link name includes the deployment time.
// Deploy-ImpactedResourcesReport.ps1 removes the previous link before redeploying.

param automationAccountName string
param runbookName string
param scheduleName string
param startTime string
@allowed([
  'Day'
  'Week'
])
param frequency string
param interval int
param weekDays array
param timeZone string
param runbookParameters object
param baseTime string

resource aa 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = {
  parent: aa
  name: scheduleName
  properties: {
    description: 'Runs ${runbookName}'
    startTime: startTime
    frequency: frequency
    interval: interval
    timeZone: timeZone
    advancedSchedule: frequency == 'Week' ? { weekDays: weekDays } : null
  }
}

resource link 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = {
  parent: aa
  name: guid(aa.id, runbookName, scheduleName, baseTime)
  properties: {
    runbook: {
      name: runbookName
    }
    schedule: {
      name: schedule.name
    }
    parameters: runbookParameters
  }
}

output scheduleName string = schedule.name
output jobScheduleId string = link.name
