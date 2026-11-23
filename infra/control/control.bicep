// The session control's Azure resources in the group rg-<prefix>-control (ADR 0020, ADR 0026), deployed into that
// group by deploy.ps1 on every run since 2026-11-14 (or scripts/setup-activity-control.ps1); destroy.ps1 deletes them
// when the runbooks serve its environment, as setup-activity-control.ps1 -Remove does:
// - id-<prefix>-automation: the user-assigned identity the runbooks use; its roles are DbHub Demo Activity Operator
//   at the demo resource group (A1) and at the control account (A2), and DbHub Demo Session Writer at the two session
//   secrets (A4), which deploy.ps1 assigns when the deployer may, and otherwise an Owner's grant-safety-stop.ps1, once
//   (docs/permissions.md).
// - aa-<prefix>-control: the Automation account (Basic; public network access and local authentication on, because
//   webhooks need both), with only that identity and no system-assigned identity, and its variable DbHubSessionStatus
//   (2026-11-16), the session's last status, which DbHub-Monitor reads back, created only when it's missing (2026-11-23).
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

@description('Whether to create the variable DbHubSessionStatus. deploy.ps1 passes false when Azure already has it, encrypted or not, so an update keeps the status a session\'s stop wrote, with its lists of evidence still on the VMs, and the tenant\'s encryption of it.')
param createSessionStatus bool = true

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

// The session's last status for DbHub-Monitor (2026-11-16, ADR 0026): DbHub-Control keeps a copy of what it writes to
// the vault here (Set-AutomationVariable), and DbHub-Monitor's re-checks read it back to add a host's failure, because
// the identity can't read the vault's value through Azure Resource Manager. Never a credential. Created only when it's
// missing (2026-11-23, ADR 0031): a session's next start reads the status it replaces from here, the lists of the Incident
// RCA's evidence still on the VMs included, so an update that wrote it again empty lost them. A deployment in incremental
// mode leaves a resource the template doesn't deploy as it is.
resource sessionStatus 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = if (createSessionStatus) {
  parent: account
  name: 'DbHubSessionStatus'
  properties: {
    description: 'The demo session\'s last status (JSON), which the DbHub-Control runbook keeps and DbHub-Monitor reads back. Never a credential.'
    isEncrypted: false
    value: '""'
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
