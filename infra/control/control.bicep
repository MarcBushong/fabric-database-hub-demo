// The on-demand activity control's Azure resources in the persistent group rg-<prefix>-control (ADR 0020), deployed by
// scripts/setup-activity-control.ps1 into an existing group, never by deploy.ps1, so destroy.ps1 keeps them:
// - id-<prefix>-automation: the user-assigned identity the runbooks use; its only role is DbHub Demo Activity Operator
//   at the demo resource group (A1) and at the control account (A2), which setup-activity-control.ps1 -GrantRole
//   assigns as the signed-in owner.
// - aa-<prefix>-control: the Automation account (Basic; public network access and local authentication on, because
//   webhooks need both), with only that identity and no system-assigned identity.
// - kv-<prefix>-ctl-<suffix>: the vault for the webhook URL (Azure RBAC, Standard, 7-day soft delete, purge protection
//   off so setup-activity-control.ps1 -Remove can purge it), public or private by vaultNetworkMode, which the setup
//   script resolves from the tenant's policy. No diagnostic settings.
// Runbooks, schedules, and the webhook go through documented REST calls and infra/control/webhook.bicep.

targetScope = 'resourceGroup'

@description('Region of the control resources; the demo region.')
param location string = resourceGroup().location

@description('The Automation account: aa-<prefix>-control.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('The runbooks\' user-assigned identity: id-<prefix>-automation.')
@minLength(3)
@maxLength(128)
param identityName string

@description('The vault for the webhook URL: kv-<prefix>-ctl-<suffix>.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('public: public network access with Azure RBAC per user (the notebook runs in the shared workspace). private: public network access Disabled (a policy forces it; the notebook reaches the vault through a Fabric managed private endpoint).')
@allowed([
  'public'
  'private'
])
param vaultNetworkMode string

@description('Days a deleted vault stays recoverable (7 is the minimum, so a cleanup can purge it soon).')
@minValue(7)
@maxValue(90)
param softDeleteRetentionDays int = 7

@description('Tags for every resource: the demo\'s tags without its environment and deploymentId, plus component activity-control.')
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
    disableLocalAuth: false
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionDays
    publicNetworkAccess: vaultNetworkMode == 'public' ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: vaultNetworkMode == 'public' ? 'Allow' : 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
output automationAccountId string = account.id
output keyVaultId string = vault.id
output keyVaultUri string = vault.properties.vaultUri
