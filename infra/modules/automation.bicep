// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
// Automation account (system-assigned identity), PowerShell 7.4 runtime environment and the runbook.

param location string
param automationAccountName string
param runbookName string
param runbookContentUri string
param tags object = {}

resource aa 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: true // the runbook only uses its managed identity
  }
}

resource runtime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: aa
  name: 'PowerShell-7-4' // letters, digits, '-' and '_' only
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {} // script uses REST only; no Az modules needed
    description: 'PowerShell 7.4 for the impacted resources report'
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: aa
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtime.name
    description: 'Lists Service Health / Advisor impacted resources and emails the CSV via Azure Communication Services'
    logProgress: false
    logVerbose: false
    publishContentLink: {
      uri: runbookContentUri
    }
  }
}

output automationAccountId string = aa.id
output automationAccountName string = aa.name
output principalId string = aa.identity.principalId
output runbookName string = runbook.name
