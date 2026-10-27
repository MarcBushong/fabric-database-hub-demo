// The webhook and its secret (ADR 0020), deployed by scripts/setup-activity-control.ps1 into rg-<prefix>-control after
// the runbooks are published. The URL comes from the documented generateUri call and arrives here only as a secure
// parameter, which Azure Resource Manager doesn't keep in the deployment's history; nothing is output. The secret is
// written through Azure Resource Manager (a control-plane action), so it works on a private vault too.
// - Webhooks: https://learn.microsoft.com/azure/automation/automation-webhooks
// - Key Vault secrets in templates: https://learn.microsoft.com/azure/key-vault/secrets/quick-create-bicep

targetScope = 'resourceGroup'

@description('The Automation account: aa-<prefix>-control.')
param automationAccountName string

@description('The webhook\'s name: dbhub-activity-<yyyyMMddHHmm>, new at each rotation.')
@minLength(1)
@maxLength(128)
param webhookName string

@description('The webhook URL from generateUri: a bearer secret.')
@secure()
param webhookUri string

@description('When the webhook stops working (ISO 8601, UTC).')
param expiryTime string

@description('The same expiry in seconds since 1970-01-01 UTC, for the secret.')
param expiryUnixTime int

@description('The runbook the webhook starts.')
param runbookName string = 'DbHub-Control'

@description('The vault for the webhook URL: kv-<prefix>-ctl-<suffix>.')
param keyVaultName string

@description('The secret that holds the webhook URL.')
param secretName string = 'dbhub-activity-webhook'

resource account 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource webhook 'Microsoft.Automation/automationAccounts/webhooks@2024-10-23' = {
  parent: account
  name: webhookName
  properties: {
    isEnabled: true
    uri: webhookUri
    expiryTime: expiryTime
    runbook: {
      name: runbookName
    }
  }
}

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: vault
  name: secretName
  properties: {
    value: webhookUri
    contentType: 'automation-webhook-url'
    attributes: {
      enabled: true
      exp: expiryUnixTime
    }
  }
  dependsOn: [
    webhook
  ]
}
