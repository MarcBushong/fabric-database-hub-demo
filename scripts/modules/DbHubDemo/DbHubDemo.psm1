Set-StrictMode -Version Latest

# Module-wide state. Secrets registered at run time are redacted from every log line and result.
$script:DemoSecrets = [System.Collections.Generic.List[string]]::new()
# In GitHub Actions only: identifiers (subscription, tenant, client, and object IDs, accounts, and the deployment's
# random suffix) that Register-DemoLogMask masked with add-mask, and that Protect-DemoLogText turns into *** in the
# module's log lines, job summaries, and out/*.jsonl results, because a public repository's Actions logs and
# artifacts are public (ADR 0022). Results in memory keep their values.
$script:DemoLogMasks = [System.Collections.Generic.List[string]]::new()
$script:DemoLogGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:ModuleRoot = $PSScriptRoot
$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../..'))
$script:ValidStatuses = @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')

# Azure CLI command groups that are local and don't accept --subscription. 'az ad' isn't here: Invoke-DemoAz
# refuses it, because it calls Microsoft Graph with the CLI's default account (live finding, 2026-10-21).
$script:AzCommandsWithoutSubscription = @('bicep', 'version', 'extension', 'config', 'cloud')

# The Azure CLI context that Assert-DemoAzContext validated in this process: subscription, tenant, account,
# and the caller's object ID from a verified token. Invoke-DemoAz refuses writes and token requests until it's
# set, and Get-DemoAccessToken checks every token against it. Never set by anything but the guard (and the
# unit-test hook Set-DemoValidatedAzContext).
$script:DemoAzContext = $null
$script:DemoAzGuardActive = $false

# Phase 28: the VMs deploy.ps1's watchdog restarted in this process (Restart-DemoVmOnce restarts each at most once).
$script:DemoVmRestarted = @{}

# Review fix (Phase 28): the golden guest action (the Release) running on the T2 host in this process, keyed
# '<resource group>/archost01' (Invoke-DemoGoldenGuestAction). The watchdog never restarts the host meanwhile.
$script:DemoHostAction = @{}

# Azure CLI verbs that only read. Any other command (and every token request) needs the validated context.
$script:AzReadOnlyVerbs = @('show', 'list', 'exists', 'get-instance-view', 'list-skus', 'list-usage', 'list-usages', 'list-versions', 'show-deleted', 'list-locations', 'version')

# Token audiences. The guard checks a token for each one the scripts use; Invoke-DemoRestRequest calls only
# the Azure Resource Manager and Microsoft Graph hosts.
$script:ArmTokenResource = 'https://management.azure.com/'
$script:GraphTokenResource = 'https://graph.microsoft.com'

# After a claims challenge (Continuous Access Evaluation revoked a cached token), Get-DemoAccessToken -Refresh
# asks for the other spelling of the audience: the Azure CLI keys its token cache by the exact resource, so the
# other spelling skips the revoked token without signing anyone out. Microsoft Graph accepts both spellings;
# Azure Resource Manager needs its trailing slash, so it has no entry. The second table records, for this
# process, the spelling each audience uses after a refresh.
# https://learn.microsoft.com/entra/identity-platform/scopes-oidc#trailing-slash-and-default
$script:TokenResourceAlternates = @{
    'https://graph.microsoft.com'  = 'https://graph.microsoft.com/'
    'https://graph.microsoft.com/' = 'https://graph.microsoft.com'
}
$script:DemoTokenResourceInUse = @{}

# Every resource type the demo creates, including those created at run time by scripts, Arc onboarding,
# and on-demand Bastion. The policy inventory (Get-DemoPolicyConstraint) checks Azure Policy against this list.
$script:DemoResourceTypes = @(
    'Microsoft.Resources/resourceGroups'
    'Microsoft.Network/virtualNetworks'
    'Microsoft.Network/virtualNetworks/subnets'
    'Microsoft.Network/networkSecurityGroups'
    'Microsoft.Network/networkInterfaces'
    'Microsoft.Network/natGateways'
    'Microsoft.Network/bastionHosts'
    'Microsoft.Network/publicIPAddresses'
    'Microsoft.Network/privateEndpoints'
    'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
    'Microsoft.Network/privateDnsZones'
    'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
    'Microsoft.Compute/virtualMachines'
    'Microsoft.Compute/virtualMachines/extensions'
    'Microsoft.Compute/virtualMachines/runCommands'
    'Microsoft.Compute/disks'
    'Microsoft.Compute/snapshots'
    'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
    'Microsoft.HybridCompute/machines'
    'Microsoft.HybridCompute/machines/extensions'
    'Microsoft.AzureArcData/sqlServerInstances'
    'Microsoft.AzureArcData/sqlServerInstances/databases'
    'Microsoft.Sql/servers'
    'Microsoft.Sql/servers/databases'
    'Microsoft.Sql/servers/virtualNetworkRules'
    'Microsoft.Sql/servers/firewallRules'
    'Microsoft.DBforPostgreSQL/flexibleServers'
    'Microsoft.DBforPostgreSQL/flexibleServers/administrators'
    'Microsoft.DBforPostgreSQL/flexibleServers/databases'
    'Microsoft.DBforPostgreSQL/flexibleServers/configurations'
    'Microsoft.DevTestLab/schedules'
    'Microsoft.Consumption/budgets'
    'Microsoft.Authorization/locks'
    'Microsoft.ManagedIdentity/userAssignedIdentities'
    'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials'
    # The optional on-demand activity control in rg-<prefix>-control (ADR 0020), created by setup-activity-control.ps1.
    'Microsoft.Automation/automationAccounts'
    'Microsoft.Automation/automationAccounts/runbooks'
    'Microsoft.Automation/automationAccounts/schedules'
    'Microsoft.Automation/automationAccounts/jobSchedules'
    'Microsoft.Automation/automationAccounts/webhooks'
    'Microsoft.KeyVault/vaults'
    'Microsoft.KeyVault/vaults/secrets'
    'Microsoft.KeyVault/vaults/privateEndpointConnections'
    'Microsoft.Authorization/roleDefinitions'
    'Microsoft.Authorization/roleAssignments'
)

# Redaction rules, applied after exact-match replacement of registered secrets.
$script:RedactionRules = @(
    @{ Name = 'jwt'; Pattern = 'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'; Replacement = '[REDACTED:jwt]' }
    @{ Name = 'bearer'; Pattern = '(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}'; Replacement = '$1[REDACTED]' }
    @{ Name = 'sas-signature'; Pattern = '(?i)((?:^|[?&;\s"''])sig=)[^&\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Name = 'account-key'; Pattern = '(?i)(AccountKey=)[^;\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Name = 'connection-password'; Pattern = '(?i)(\b(?:password|pwd)\s*=\s*)[^;\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Name = 'json-secret'; Pattern = '(?i)("(?:adminPassword|password|accessToken|access_token|refreshToken|clientSecret|client_secret|productKey|sasToken|sasUrl|token)"\s*:\s*")[^"]*(")'; Replacement = '$1[REDACTED]$2' }
    @{ Name = 'github-token'; Pattern = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'; Replacement = '[REDACTED:github-token]' }
    # An Azure Automation webhook URL is a bearer secret: anyone who has it starts the runbook (ADR 0020).
    @{ Name = 'automation-webhook'; Pattern = '(?i)(\.azure-automation\.net/webhooks\?token=)[^&\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Name = 'product-key'; Pattern = '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b'; Replacement = '[REDACTED:product-key]' }
)

foreach ($folder in 'Private', 'Public') {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (Test-Path -LiteralPath $folderPath) {
        Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File | Sort-Object -Property Name | ForEach-Object {
            . $_.FullName
        }
    }
}

$publicFunctions = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -File |
    Select-Object -ExpandProperty BaseName
Export-ModuleMember -Function $publicFunctions
