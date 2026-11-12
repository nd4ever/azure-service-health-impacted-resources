// SPDX-License-Identifier: MIT
// Copyright (c) 2026 nd4ever
targetScope = 'subscription'

param name string
param location string
param tags object = {}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: name
  location: location
  tags: tags
}

output name string = rg.name
