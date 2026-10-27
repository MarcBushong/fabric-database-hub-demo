targetScope = 'resourceGroup'

metadata name = 'Deployment stack trial, resource group scope'
metadata description = 'Phase 16 deployment-stack trial (ADR 0001). Free user-assigned identities only: one always, one only with includeOptional, so an update that drops it shows what actionOnUnmanage does.'

@description('Azure region for the identities.')
param location string = resourceGroup().location

@description('Deploy the optional identity. An update with false removes it from the stack.')
param includeOptional bool = true

@description('Tags for the identities.')
param tags object = {}

resource managed 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-dbhub-stacktrial-a'
  location: location
  tags: tags
}

resource optional 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (includeOptional) {
  name: 'id-dbhub-stacktrial-b'
  location: location
  tags: tags
}

@description('Resource ID of the identity that is always managed.')
output managedId string = managed.id
