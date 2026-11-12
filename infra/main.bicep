// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
//
// Impacted resources report as an Azure Automation runbook that emails the CSV through
// Azure Communication Services (ACS) Email.
//
// Deployed at MANAGEMENT GROUP scope so the runbook identity can be given Reader on the management group
// it reports on. Creates (in the chosen subscription):
//   - resource group, Automation account (system-assigned identity), PowerShell 7.4 runtime environment,
//     runbook (published from runbookContentUri), recurring schedule + link with the runbook parameters
//   - Reader for the identity on this management group
//   - acsMode 'new':      Email service + Azure-managed domain + Communication Services (linked), Contributor for the identity
//     acsMode 'existing': Contributor for the identity on your existing Communication Services resource
//
// Use deploy/Deploy-ImpactedResourcesReport.ps1 for an interactive deployment, or:
//   az deployment mg create --management-group-id <mg> --location <region> --template-file infra/main.bicep --parameters ...
targetScope = 'managementGroup'

// ---------------------------------------------------------------- where to deploy
@description('Subscription that hosts the Automation account (and a new ACS, if created).')
param subscriptionId string

@description('Resource group for the Automation account (created if missing).')
param resourceGroupName string = 'rg-impacted-resources-report'

@description('Region for the resource group and Automation account.')
param location string

@description('Automation account name (6-50 chars, letters, numbers and hyphens).')
@minLength(6)
@maxLength(50)
param automationAccountName string = 'aa-impacted-resources'

param runbookName string = 'Get-ImpactedResources'

@description('Raw URL of src/Get-ImpactedResources.ps1 that is published as the runbook. Pin a release tag or point at your fork.')
param runbookContentUri string = 'https://raw.githubusercontent.com/nd4ever/azure-service-health-impacted-resources/v1.1.0/src/Get-ImpactedResources.ps1'

param tags object = {
  solution: 'impacted-resources-report'
}

// ---------------------------------------------------------------- report
@description('Include resolved Service Health events in the report.')
param includeResolved bool = false

@description('Recipients, comma separated. Optional when actionGroupResourceId is set.')
param emailTo string = ''

@description('Optional action group resource ID; its enabled email receivers are read at run time and added to the recipients.')
param actionGroupResourceId string = ''

@description('Email subject.')
param emailSubject string = 'Azure Service Health impacted resources report'

// ---------------------------------------------------------------- Azure Communication Services
@description('new = create ACS + Email service + Azure-managed domain; existing = use your own ACS resource.')
@allowed([
  'new'
  'existing'
])
param acsMode string = 'new'

@description('acsMode=existing: resource ID of the existing Microsoft.Communication/communicationServices resource (must have an email domain linked).')
param existingAcsResourceId string = ''

@description('acsMode=existing: sender address on a domain linked to that ACS resource, e.g. DoNotReply@<guid>.azurecomm.net or alerts@contoso.com.')
param existingSenderAddress string = ''

@description('acsMode=new: Communication Services name (globally unique).')
param acsName string = 'acs-impacted-${uniqueString(managementGroup().id, subscriptionId, resourceGroupName)}'

@description('acsMode=new: Email Communication Services name.')
param emailServiceName string = 'ecs-impacted-${uniqueString(managementGroup().id, subscriptionId, resourceGroupName)}'

@description('acsMode=new: data location for ACS and the email service.')
param acsDataLocation string = 'United States'

// ---------------------------------------------------------------- schedule
@allowed([
  'Day'
  'Week'
])
param scheduleFrequency string = 'Week'

@minValue(1)
param scheduleInterval int = 1

@description('Used when scheduleFrequency = Week.')
param scheduleWeekDays array = [
  'Monday'
]

@description('Time of day (HH:mm, UTC) for the run. The first run is tomorrow at this time.')
param scheduleTimeUtc string = '13:00'

@description('Do not set: deployment time, used for the first run date and the job schedule link name.')
param baseTime string = utcNow('u')

// ---------------------------------------------------------------- validation
var existingParts = split(existingAcsResourceId, '/')
var useExisting = acsMode == 'existing'
#disable-next-line no-unused-vars
var validateExisting = useExisting && (length(existingParts) < 9 || empty(existingSenderAddress))
  ? fail('acsMode=existing requires existingAcsResourceId (full resource ID) and existingSenderAddress.')
  : true
#disable-next-line no-unused-vars
var validateRecipients = empty(emailTo) && empty(actionGroupResourceId)
  ? fail('Set emailTo and/or actionGroupResourceId.')
  : true

// ---------------------------------------------------------------- resources
module rg 'modules/resource-group.bicep' = {
  name: 'impacted-rg'
  scope: subscription(subscriptionId)
  params: {
    name: resourceGroupName
    location: location
    tags: tags
  }
}

module automation 'modules/automation.bicep' = {
  name: 'impacted-automation'
  scope: resourceGroup(subscriptionId, resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    location: location
    automationAccountName: automationAccountName
    runbookName: runbookName
    runbookContentUri: runbookContentUri
    tags: tags
  }
}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, subscriptionId, resourceGroupName, automationAccountName, readerRoleId)
  properties: {
    principalId: automation.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    description: 'Impacted resources report runbook: read Service Health, Advisor and Resource Graph'
  }
}

module acsNew 'modules/acs-new.bicep' = if (!useExisting) {
  name: 'impacted-acs-new'
  scope: resourceGroup(subscriptionId, resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    communicationServiceName: acsName
    emailServiceName: emailServiceName
    dataLocation: acsDataLocation
    principalId: automation.outputs.principalId
    tags: tags
  }
}

module acsExisting 'modules/acs-existing.bicep' = if (useExisting) {
  name: 'impacted-acs-existing'
  scope: resourceGroup(useExisting ? existingParts[2] : subscriptionId, useExisting ? existingParts[4] : resourceGroupName)
  params: {
    communicationServiceName: useExisting ? last(existingParts) : 'unused'
    principalId: automation.outputs.principalId
  }
}

var acsEndpoint = useExisting ? acsExisting!.outputs.endpoint : acsNew!.outputs.endpoint
var senderAddress = useExisting ? existingSenderAddress : acsNew!.outputs.senderAddress

module schedule 'modules/schedule.bicep' = {
  name: 'impacted-schedule'
  scope: resourceGroup(subscriptionId, resourceGroupName)
  dependsOn: [
    reader
  ]
  params: {
    automationAccountName: automation.outputs.automationAccountName
    runbookName: automation.outputs.runbookName
    scheduleName: 'impacted-resources-${toLower(scheduleFrequency)}'
    startTime: '${substring(dateTimeAdd(baseTime, 'P1D'), 0, 10)}T${scheduleTimeUtc}:00+00:00'
    frequency: scheduleFrequency
    interval: scheduleInterval
    weekDays: scheduleWeekDays
    timeZone: 'UTC'
    baseTime: baseTime
    runbookParameters: union(
      {
        All: 'true'
        ManagementGroup: managementGroup().name
        UseManagedIdentity: 'true'
        EmailFrom: senderAddress
        AcsEndpoint: acsEndpoint
        EmailSubject: emailSubject
      },
      empty(emailTo) ? {} : { EmailTo: emailTo },
      empty(actionGroupResourceId) ? {} : { ActionGroupId: actionGroupResourceId },
      includeResolved ? { IncludeResolved: 'true' } : {}
    )
  }
}

output automationAccountId string = automation.outputs.automationAccountId
output runbookName string = automation.outputs.runbookName
output principalId string = automation.outputs.principalId
output acsEndpoint string = acsEndpoint
output senderAddress string = senderAddress
output scheduleName string = schedule.outputs.scheduleName
