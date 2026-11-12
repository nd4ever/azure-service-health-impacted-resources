// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
// New Azure Communication Services + Email service with an Azure-managed domain (DoNotReply@<guid>.azurecomm.net).
// Grants the runbook identity Contributor on the Communication Services resource (needed to send with Entra ID auth).

param communicationServiceName string
param emailServiceName string
@description('Data residency for ACS and the email service, e.g. United States, Europe, UK, Australia.')
param dataLocation string
param principalId string
param tags object = {}

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = {
  name: emailServiceName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
  }
}

resource domain 'Microsoft.Communication/emailServices/domains@2023-04-01' = {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  tags: tags
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource acs 'Microsoft.Communication/communicationServices@2023-04-01' = {
  name: communicationServiceName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
    linkedDomains: [
      domain.id
    ]
  }
}

resource sendRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acs.id, principalId, contributorRoleId)
  scope: acs
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
  }
}

output endpoint string = 'https://${acs.properties.hostName}'
output senderAddress string = 'DoNotReply@${domain.properties.mailFromSenderDomain}'
output communicationServiceId string = acs.id
