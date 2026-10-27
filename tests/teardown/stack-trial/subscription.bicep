targetScope = 'subscription'

metadata name = 'Deployment stack trial, subscription scope'
metadata description = 'Phase 16 deployment-stack trial (ADR 0001): the shape main.bicep would have as a stack. It creates the resource group and deploys group.bicep into it.'

@description('Azure region for the resource group and the identities.')
param location string

@description('The disposable resource group the stack creates and owns.')
param resourceGroupName string

@description('Tags for the resource group and the identities.')
param tags object = {}

resource group 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module identities 'group.bicep' = {
  name: 'stacktrial-identities'
  scope: group
  params: {
    location: location
    includeOptional: false
    tags: tags
  }
}

@description('Resource ID of the managed identity in the stack-owned resource group.')
output managedId string = identities.outputs.managedId
