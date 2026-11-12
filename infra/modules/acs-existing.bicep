// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
// Existing Azure Communication Services resource (must already have an email domain linked).
// Deployed into the resource group of the existing ACS; only adds a role assignment.

param communicationServiceName string
param principalId string

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource acs 'Microsoft.Communication/communicationServices@2023-04-01' existing = {
  name: communicationServiceName
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
output linkedDomains array = acs.properties.?linkedDomains ?? []
