metadata description = 'T5: T1\'s managed identity gets the Cosmos DB Built-in Data Contributor data-plane role on the account, so the workload runner on T1 reads and writes documents with a Microsoft Entra token (ADR 0027). A data-plane role assignment is a child of the account, not an Azure role assignment, so Contributor can create it.'

@description('Name of the T5 account (cosmos01-<deploymentId>).')
param accountName string

@description('Object ID of T1\'s system-assigned managed identity.')
@minLength(36)
@maxLength(36)
param principalId string

@description('The built-in data-plane role definition\'s ID: 00000000-0000-0000-0000-000000000002 is Cosmos DB Built-in Data Contributor.')
param roleDefinitionId string

resource account 'Microsoft.DocumentDB/databaseAccounts@2025-10-15' existing = {
  name: accountName
}

// Its own module, so the account starts deploying at once rather than after T1's module, which this assignment needs for
// T1's identity. The name is stable for the same account, role, and identity, so a redeploy changes nothing.
resource dataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-10-15' = {
  parent: account
  name: guid(account.id, roleDefinitionId, principalId)
  properties: {
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${roleDefinitionId}'
    principalId: principalId
    scope: account.id
  }
}

@description('Resource ID of the data-plane role assignment.')
output roleAssignmentId string = dataContributor.id
