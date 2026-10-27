metadata description = 'Opt-in Azure Key Vault for the one-time T2 host password (keyVault.enabled, ADR 0009): RBAC authorization, soft delete, no access policies. Deployed at resource group scope on its own by Initialize-DemoKeyVault; no secret passes through this template, and the role assignments are made by script, by role name (ADR 0008).'

@description('Azure region.')
param location string = resourceGroup().location

@description('Vault name, kv-<prefix><environment>-<deploymentId>.')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Days a deleted vault and its secrets stay recoverable. Key Vault fixes it when the vault is created.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 7

@description('Purge protection. Irreversible: a deleted vault then stays for the whole retention period. Some tenant policies require it.')
param enablePurgeProtection bool = false

@description('Public IPv4 addresses or CIDR ranges allowed through the vault firewall. Empty allows every network; the data plane still needs an RBAC role.')
param allowedIpRanges array = []

@description('Tags from the resource group.')
param tags object = {}

// https://learn.microsoft.com/azure/key-vault/general/rbac-guide
// https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview
resource vault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Purge protection can't be turned off once it's on, so false leaves the property out.
    enablePurgeProtection: enablePurgeProtection ? true : null
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: empty(allowedIpRanges) ? 'Allow' : 'Deny'
      ipRules: [for range in allowedIpRanges: {
        value: range
      }]
      virtualNetworkRules: []
    }
    accessPolicies: []
  }
}

@description('Name of the vault.')
output vaultName string = vault.name

@description('Resource ID of the vault.')
output vaultId string = vault.id
