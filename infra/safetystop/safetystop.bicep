// The nightly safety stop's Azure resources in the demo resource group (ADR 0024). scripts/deploy.ps1 deploys this
// template after infra/main.bicep on every run (Invoke-DemoSafetyStopSetup), so the safety stop is part of every
// deployment, and destroy.ps1 deletes it with the group:
// - id-<prefix>-<environment>-safetystop: the user-assigned identity the runbook uses. Its only role is the custom role
//   "DbHub Demo Safety Stop" (read and stop) at the demo resource group, which deploy.ps1 assigns when the person who
//   runs it may, and an Owner otherwise with scripts/grant-safety-stop.ps1.
// - aa-<prefix>-<environment>-safetystop: the Automation account (Basic) with only that identity, and local
//   authentication off, because nothing starts its runbook with a webhook
//   (https://learn.microsoft.com/azure/automation/disable-local-authentication).
// The runbook, its two daily schedules, and the role go through documented REST calls from the module.

targetScope = 'resourceGroup'

@description('Region of the safety stop\'s resources; the demo region.')
param location string = resourceGroup().location

@description('The Automation account: aa-<prefix>-<environment>-safetystop.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('The runbook\'s user-assigned identity: id-<prefix>-<environment>-safetystop.')
@minLength(3)
@maxLength(128)
param identityName string

@description('Tags for both resources: the demo\'s own tags, plus component safety-stop.')
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  tags: tags
}

resource account 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: true
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
output automationAccountId string = account.id
