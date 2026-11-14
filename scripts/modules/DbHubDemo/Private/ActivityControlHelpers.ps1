# The on-demand activity control (ADR 0020): its names, settings, role, vault mode, runbook content, webhook, Fabric
# notebook, and role grants. Internal; Invoke-DemoActivityControlSetup (scripts/setup-activity-control.ps1),
# Test-DemoActivityControl (validate.ps1, status.ps1), and deploy.ps1's A1 re-grant call these.

# The one custom role, exactly as the owner approved it on 2026-10-26 (ADR 0020, section "The role"): every action
# the run, Stop now, and the auto-stop need, and nothing else. Changing this list needs the owner's approval.
# 2026-11-14 (ADR 0026, approved for the user by the coordinator, who reviews it with the user before any merge): the
# session's actions, at the demo resource group only (A1), with what each could touch there:
# - flexibleServers/write and /delete: create and delete T4's read replica; they could also change or delete T4, which
#   the runbook never does (it touches pgreplica01-<id> only, and deletes a server only when its replicationRole says
#   it's a read replica).
# - flexibleServers/configurations/write: the replica's max_standby_streaming_delay; it could change any server
#   parameter of T4 or the replica.
# - No network join action: the replica's create names T4's delegated subnet and private DNS zone, and Azure created it
#   without virtualNetworks/subnets/join/action or privateDnsZones/join/action (live, 2026-11-14), so neither is granted.
# - Microsoft.Insights/metrics/read: T4's and the replica's Azure Monitor metrics for the history; read-only.
# - Microsoft.Resources/tags/write: the busy marker and the session's ID on the demo resource group (the safety stop
#   honors the marker); it could change any tag in the demo resource group, the deploymentId included.
$script:ActivityControlRoleName = 'DbHub Demo Activity Operator'
$script:ActivityControlRoleDescription = 'Start, deallocate, and run commands on the Database Hub demo''s VMs, start and stop its PostgreSQL server, create and delete its read replica, read their metrics, mark the demo busy, and manage the demo control account''s own one-time stop schedules. Assigned only at the demo resource group and at the control Automation account.'
$script:ActivityControlRoleActions = @(
    'Microsoft.Resources/subscriptions/resourceGroups/read'
    'Microsoft.Compute/virtualMachines/read'
    'Microsoft.Compute/virtualMachines/instanceView/read'
    'Microsoft.Compute/virtualMachines/start/action'
    'Microsoft.Compute/virtualMachines/deallocate/action'
    'Microsoft.Compute/virtualMachines/extensions/read'
    'Microsoft.Compute/virtualMachines/runCommands/read'
    'Microsoft.Compute/virtualMachines/runCommands/write'
    'Microsoft.Compute/virtualMachines/runCommands/delete'
    'Microsoft.Sql/servers/databases/read'
    'Microsoft.DBforPostgreSQL/flexibleServers/read'
    'Microsoft.DBforPostgreSQL/flexibleServers/start/action'
    'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'
    'Microsoft.DBforPostgreSQL/flexibleServers/write'
    'Microsoft.DBforPostgreSQL/flexibleServers/delete'
    'Microsoft.DBforPostgreSQL/flexibleServers/configurations/write'
    'Microsoft.Insights/metrics/read'
    'Microsoft.Resources/tags/write'
    'Microsoft.Automation/automationAccounts/read'
    'Microsoft.Automation/automationAccounts/runbooks/read'
    'Microsoft.Automation/automationAccounts/jobs/read'
    'Microsoft.Automation/automationAccounts/schedules/read'
    'Microsoft.Automation/automationAccounts/schedules/write'
    'Microsoft.Automation/automationAccounts/schedules/delete'
    'Microsoft.Automation/automationAccounts/jobSchedules/read'
    'Microsoft.Automation/automationAccounts/jobSchedules/write'
    'Microsoft.Automation/automationAccounts/jobSchedules/delete'
)
# The second custom role (2026-11-14, ADR 0026, approved as above): the control identity writes the session's status and
# the history's metrics to two secrets of the control vault through Azure Resource Manager (A4, at those two secrets
# only, never at the demo resource group, whose optional vault it can't reach). It could overwrite those two secrets'
# values, which the notebook reads as status and metrics, never as credentials.
$script:SessionWriterRoleName = 'DbHub Demo Session Writer'
$script:SessionWriterRoleDescription = 'Read and write the Database Hub demo control''s session status and metrics secrets through Azure Resource Manager. Assigned only at those two secrets of the control vault.'
$script:SessionWriterRoleActions = @(
    'Microsoft.KeyVault/vaults/secrets/read'
    'Microsoft.KeyVault/vaults/secrets/write'
)
# What each action added on 2026-11-14 could touch, for the grant's output (ADR 0026, docs/permissions.md).
$script:ActivityControlActionReach = [ordered]@{
    'Microsoft.DBforPostgreSQL/flexibleServers/write'                 = 'creates T4''s read replica; it could also change T4, which the runbook never does'
    'Microsoft.DBforPostgreSQL/flexibleServers/delete'                = 'deletes T4''s read replica after a session; it could also delete T4, which the runbook never does (it deletes only a server whose replicationRole says it''s a read replica)'
    'Microsoft.DBforPostgreSQL/flexibleServers/configurations/write'  = 'sets the replica''s max_standby_streaming_delay; it could change any server parameter of T4 or the replica'
    'Microsoft.Insights/metrics/read'                                 = 'reads T4''s and the replica''s Azure Monitor metrics for the history; read-only'
    'Microsoft.Resources/tags/write'                                  = 'marks the demo busy for the nightly stop and records the session; it could change any tag in the demo resource group'
    'Microsoft.KeyVault/vaults/secrets/read'                          = 'reads the session secrets'' properties (never their values through Azure Resource Manager); at those two secrets only'
    'Microsoft.KeyVault/vaults/secrets/write'                         = 'writes the session''s status and metrics; it could overwrite those two secrets'' values, at those two secrets only'
}
# Key Vault Secrets User (built-in): https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user
$script:VaultReaderRoleGuid = '4633458b-17de-408a-b874-0445c86b69e6'
$script:ActivityControlDoc = 'https://learn.microsoft.com/azure/automation/automation-webhooks'
# A job that's queued or running, as the runbooks count it ($script:DbHubActiveJobStatuses in DbHubControl.Common.ps1):
# the REST API has no Queued status, so a queued job is New or Activating
# (https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account).
$script:ActivityControlActiveJobStatuses = @('New', 'Activating', 'Running', 'Resuming', 'Blocked', 'Stopping', 'Suspending')

function Get-DemoActivityControlList {
    <#
    .SYNOPSIS
    The items of an array member (for example an Azure Resource Manager list's value), one by one, or none.
    Get-DemoMemberValue returns an array whole, so @(Get-DemoMemberValue ...) would be an array of one array. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = Get-DemoMemberValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) {
        return
    }
    foreach ($item in @($value)) {
        $item
    }
}

function Get-DemoActivityControlSetting {
    <#
    .SYNOPSIS
    The control section of the configuration with its defaults (config/environment.schema.json). Internal.

    .DESCRIPTION
    The control is part of every deployment since 2026-11-14 (ADR 0026), so Enabled is always true: an older
    configuration's "enabled": false, which init.ps1 wrote by default, is ignored, and LegacyOff says it was there for
    deploy.ps1's note. The workspace for a private vault's notebook is control.fabricWorkspaceName when it names one of
    its own. "DBHub Control", which init.ps1 also wrote, stays only for a control set up before 2026-11-14 ("enabled":
    true), which deploy.ps1 adopts as it is; otherwise it's the demo workspace's name followed by " Control", so two
    environments in one tenant never share it. RoleNameSuffix (control.roleNameSuffix) gives this environment its own
    two custom roles, "<role> (<suffix>)", for an environment that shares its subscription with a demo on other code.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $control = $Config['control']
    $value = { param([string] $Name, [object] $Default) $item = Get-DemoMemberValue -InputObject $control -Name $Name; if ($null -eq $item -or ($item -is [string] -and -not $item)) { $Default } else { $item } }
    $configured = Get-DemoMemberValue -InputObject $control -Name 'enabled'
    $optedIn = $configured -is [bool] -and $configured
    $workspace = [string](& $value 'fabricWorkspaceName' '')
    if (-not $workspace -or ($workspace -ceq 'DBHub Control' -and -not $optedIn)) {
        $demoWorkspace = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceName')
        if (-not $demoWorkspace) {
            $demoWorkspace = 'Database Hub Demo'
        }
        $workspace = '{0} Control' -f $demoWorkspace
        if ($workspace.Length -gt 100) {
            $workspace = $workspace.Substring(0, 100).TrimEnd()
        }
    }
    return [pscustomobject]@{
        Enabled               = $true
        LegacyOff             = $configured -is [bool] -and -not $configured
        VaultNetworkMode      = [string](& $value 'vaultNetworkMode' 'auto')
        WebhookExpiryDays     = [int](& $value 'webhookExpiryDays' 90)
        T4SafetyStopTime      = [string](& $value 't4SafetyStopTime' '')
        NotebookUserObjectIds = @(& $value 'notebookUserObjectIds' @() | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
        FabricFolderName      = [string](& $value 'fabricFolderName' 'DBHub Control')
        FabricWorkspaceName   = $workspace
        RoleNameSuffix        = [string](& $value 'roleNameSuffix' '')
    }
}

function Get-DemoActivityControlRoleNameText {
    # A custom role's name in this environment: the base name, or "<base> (<suffix>)" with control.roleNameSuffix. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Base,

        [AllowEmptyString()]
        [string] $Suffix = ''
    )

    if ($Suffix) {
        return ('{0} ({1})' -f $Base, $Suffix)
    }
    return $Base
}

function Get-DemoActivityControlName {
    <#
    .SYNOPSIS
    The control's names and ARM IDs (ADR 0020). The vault's suffix is the first six hexadecimal characters of the
    SHA-256 of '<subscriptionId>|<prefix>|control', so its global name is stable for a subscription and prefix. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = ([string]$Config['subscriptionId']).ToLowerInvariant()
    $prefix = [string]$Config['prefix']
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(('{0}|{1}|control' -f $subscriptionId, $prefix)))
    $suffix = -join ($hash | Select-Object -First 3 | ForEach-Object { $_.ToString('x2') })
    $group = 'rg-{0}-control' -f $prefix
    $account = 'aa-{0}-control' -f $prefix
    $vault = 'kv-{0}-ctl-{1}' -f $prefix, $suffix
    $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $group
    $setting = Get-DemoActivityControlSetting -Config $Config
    return [pscustomobject]@{
        SubscriptionId      = $subscriptionId
        ResourceGroup       = $group
        ResourceGroupId     = $groupId
        DemoResourceGroup   = Get-DemoResourceGroupName -Config $Config
        DemoResourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, (Get-DemoResourceGroupName -Config $Config)
        AutomationAccount   = $account
        AutomationAccountId = '{0}/providers/Microsoft.Automation/automationAccounts/{1}' -f $groupId, $account
        Identity            = 'id-{0}-automation' -f $prefix
        IdentityId          = '{0}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-{1}-automation' -f $groupId, $prefix
        KeyVault            = $vault
        KeyVaultId          = '{0}/providers/Microsoft.KeyVault/vaults/{1}' -f $groupId, $vault
        KeyVaultUri         = 'https://{0}.vault.azure.net/' -f $vault
        Secret              = 'dbhub-activity-webhook'
        SecretId            = '{0}/providers/Microsoft.KeyVault/vaults/{1}/secrets/dbhub-activity-webhook' -f $groupId, $vault
        # The session's status and the history's metrics (2026-11-14, ADR 0026): the runbook writes them, the notebook reads them.
        StatusSecret        = 'dbhub-session-status'
        StatusSecretId      = '{0}/providers/Microsoft.KeyVault/vaults/{1}/secrets/dbhub-session-status' -f $groupId, $vault
        MetricsSecret       = 'dbhub-session-metrics'
        MetricsSecretId     = '{0}/providers/Microsoft.KeyVault/vaults/{1}/secrets/dbhub-session-metrics' -f $groupId, $vault
        ControlRunbook      = 'DbHub-Control'
        StopRunbook         = 'DbHub-Stop'
        MonitorRunbook      = 'DbHub-Monitor'
        AutoStopSchedule    = 'dbhub-autostop'
        AutoStopBackupSchedule = 'dbhub-autostop-backup'
        MonitorPrefix       = 'dbhub-monitor-'
        SafetyStopSchedule  = 'dbhub-t4-safety-stop'
        WebhookPrefix       = 'dbhub-activity-'
        RunCommandPrefix    = 'DbHubControl-'
        RoleName            = Get-DemoActivityControlRoleNameText -Base $script:ActivityControlRoleName -Suffix $setting.RoleNameSuffix
        WriterRoleName      = Get-DemoActivityControlRoleNameText -Base $script:SessionWriterRoleName -Suffix $setting.RoleNameSuffix
        Notebook            = 'NB_DatabaseHub_Control'
        FabricFolder        = $setting.FabricFolderName
        FabricWorkspace     = $setting.FabricWorkspaceName
        PrivateEndpoint     = 'mpe-{0}' -f $vault
        TemplateDeployment  = 'dbhub-control'
        WebhookDeployment   = 'dbhub-control-webhook'
    }
}

function Get-DemoActivityControlTag {
    <#
    .SYNOPSIS
    Tags for the control resources: the demo's tags without environment and deploymentId (the group outlives every
    environment, and destroy.ps1's residual check looks for those), plus component activity-control. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $tags = [ordered]@{ solution = 'fabric-database-hub-demo'; component = 'activity-control'; purpose = 'customer-demo' }
    foreach ($name in 'owner', 'costCenter') {
        if ($Config[$name]) {
            $tags[$name] = [string]$Config[$name]
        }
    }
    return $tags
}

function Get-DemoActivityControlRoleDefinition {
    <#
    .SYNOPSIS
    The custom role "DbHub Demo Activity Operator", or with -Writer "DbHub Demo Session Writer" (2026-11-14), as an Azure
    Resource Manager role definition body, assignable in the configured subscription only. Each action list is the
    approved one and nothing else. Internal.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [switch] $Writer,

        # This environment's name for the role (Get-DemoActivityControlName's RoleName or WriterRoleName).
        [string] $RoleName = ''
    )

    if (-not $RoleName) {
        $RoleName = if ($Writer) { $script:SessionWriterRoleName } else { $script:ActivityControlRoleName }
    }
    $description = if ($Writer) { $script:SessionWriterRoleDescription } else { $script:ActivityControlRoleDescription }
    $actions = if ($Writer) { @($script:SessionWriterRoleActions) } else { @($script:ActivityControlRoleActions) }
    return [ordered]@{
        properties = [ordered]@{
            roleName         = $RoleName
            description      = $description
            type             = 'CustomRole'
            permissions      = @([ordered]@{ actions = $actions; notActions = @(); dataActions = @(); notDataActions = @() })
            assignableScopes = @('/subscriptions/{0}' -f $SubscriptionId.ToLowerInvariant())
        }
    }
}

function Resolve-DemoActivityControlVaultMode {
    <#
    .SYNOPSIS
    Decides whether the control vault is public or private from vaultNetworkMode and the tenant's policy rules
    (Get-DemoPolicyConstraint), and returns Mode, Status, Message, Remediation, and Evidence. Internal.

    .DESCRIPTION
    A rule forces a private vault when it modifies Microsoft.KeyVault/vaults/publicNetworkAccess to Disabled (or to a
    value that can't be resolved), or denies a vault whose public network access is Enabled.
    - auto: private when such a rule applies, public otherwise; private when the policy couldn't be read (a private
      vault works everywhere, only slower).
    - private: always private.
    - public: public; Fail when such a rule applies, because the vault would end up private and the notebook in the
      shared workspace couldn't read it. This never adds a policy's exclusion tag: that's a governance decision.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('auto', 'public', 'private')]
        [string] $ConfiguredMode,

        [AllowNull()]
        [object[]] $Rule,

        [switch] $PolicyUnknown
    )

    $field = '^Microsoft\.KeyVault/vaults/publicNetworkAccess$'
    $forcing = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Rule | Where-Object { $null -ne $_ })) {
        $effect = [string](Get-DemoMemberValue -InputObject $item -Name 'Effect')
        $types = @(Get-DemoActivityControlList -InputObject $item -Name 'Types')
        $anyType = [bool](Get-DemoMemberValue -InputObject $item -Name 'AnyType')
        if (-not $anyType -and $types -notcontains 'Microsoft.KeyVault/vaults') {
            continue
        }
        $parameters = Get-DemoMemberValue -InputObject $item -Name 'Parameters'
        $forces = $false
        if ($effect -eq 'Modify') {
            $details = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'Then') -Name 'details'
            foreach ($operation in @(Get-DemoActivityControlList -InputObject $details -Name 'operations')) {
                if ($operation -isnot [System.Collections.IDictionary]) {
                    continue
                }
                $target = Resolve-DemoPolicyExpression -Value $operation['field'] -Parameter $parameters
                $value = Resolve-DemoPolicyExpression -Value $operation['value'] -Parameter $parameters
                if ($target.Known -and [string]$target.Value -match $field -and (-not $value.Known -or [string]$value.Value -eq 'Disabled')) {
                    $forces = $true
                }
            }
        }
        elseif ($effect -eq 'Deny' -and @(@(Get-DemoActivityControlList -InputObject $item -Name 'Fields') | Where-Object { $_ -match $field }).Count -gt 0) {
            $facts = @{ type = 'Microsoft.KeyVault/vaults'; 'Microsoft.KeyVault/vaults/publicNetworkAccess' = 'Enabled' }
            $forces = (Test-DemoPolicyCondition -Condition (Get-DemoMemberValue -InputObject $item -Name 'Condition') -Fact $facts -Parameter $parameters) -ne $false
        }
        if ($forces) {
            $tag = ''
            $tagName = Get-DemoMemberValue -InputObject $parameters -Name 'AllowedTagName'
            $tagValue = Get-DemoMemberValue -InputObject $parameters -Name 'AllowedTagValue'
            if ($tagName -is [System.Collections.IDictionary] -and $tagName.Contains('value')) {
                $tagName = $tagName['value']
            }
            if ($tagValue -is [System.Collections.IDictionary] -and $tagValue.Contains('value')) {
                $tagValue = $tagValue['value']
            }
            if ($tagName) {
                $tag = '{0}={1}' -f $tagName, $tagValue
            }
            $forcing.Add([pscustomobject]@{ Policy = [string](Get-DemoMemberValue -InputObject $item -Name 'Policy'); Effect = $effect; ExclusionTag = $tag })
        }
    }
    $names = @($forcing | ForEach-Object { '{0} ({1})' -f $_.Policy, $_.Effect } | Select-Object -Unique)
    $tags = @($forcing | Where-Object { $_.ExclusionTag } | ForEach-Object { $_.ExclusionTag } | Select-Object -Unique)
    $evidence = [ordered]@{ configuredMode = $ConfiguredMode; forcingPolicies = $names; exclusionTags = $tags; policyUnknown = [bool]$PolicyUnknown }
    $docUrl = 'https://learn.microsoft.com/fabric/security/security-managed-vnets-fabric-overview'
    $result = { param([string] $Mode, [string] $Status, [string] $Message, [string] $Remediation) $evidence['mode'] = $Mode; [pscustomobject]@{ Mode = $Mode; Status = $Status; Message = $Message; Remediation = $Remediation; Evidence = $evidence; DocUrl = $docUrl } }
    switch ($ConfiguredMode) {
        'private' {
            return (& $result 'private' 'Pass' 'vaultNetworkMode is private: the vault has no public access, and the notebook reads it through a managed private endpoint from the DBHub Control workspace.' '')
        }
        'public' {
            if ($forcing.Count -gt 0) {
                $tagNote = if ($tags.Count) { (' The policy skips resources tagged {0}; this script never adds that tag, because opting out of the control is a governance decision.' -f ($tags -join ' or ')) } else { '' }
                return (& $result 'public' 'Fail' ('vaultNetworkMode is public, but Azure Policy makes new vaults private: {0}. The vault would end up without public access, and the notebook in the shared workspace couldn''t read it, so nothing was created.{1}' -f ($names -join '; '), $tagNote) 'Set control.vaultNetworkMode to auto or private (the control workspace path), or ask your governance team; then run setup-activity-control.ps1 again.')
            }
            $unknownNote = if ($PolicyUnknown) { ' The policy assignments couldn''t all be read, so a policy may still change the vault.' } else { '' }
            return (& $result 'public' $(if ($PolicyUnknown) { 'Warning' } else { 'Pass' }) ('vaultNetworkMode is public: the vault keeps public network access, and only users with Key Vault Secrets User on its one secret can read it.{0}' -f $unknownNote) '')
        }
        default {
            if ($forcing.Count -gt 0) {
                return (& $result 'private' 'Pass' ('auto: Azure Policy makes new vaults private ({0}), so the vault is private and the notebook runs in the DBHub Control workspace with a managed private endpoint to it. Its Spark sessions start in 3 to 5 minutes, because a managed virtual network turns off starter pools.' -f ($names -join '; ')) '')
            }
            if ($PolicyUnknown) {
                return (& $result 'private' 'Warning' 'auto: the policy assignments couldn''t all be read, so the vault is private (that path works whatever the policy says) and the notebook runs in the DBHub Control workspace.' 'Run setup-activity-control.ps1 again with read access to the policy assignments (Reader) to get the faster public path where policy allows it.')
            }
            return (& $result 'public' 'Pass' 'auto: no policy makes new vaults private, so the vault keeps public network access (Azure RBAC per user) and the notebook goes in a folder of the existing workspace, with its fast start.' '')
        }
    }
}

function Get-DemoActivityControlCatalog {
    <#
    .SYNOPSIS
    The scenarios the control may run, from scenarios/<id>/scenario.json: each one's maximum minutes, maximum
    concurrency, and the targets it can run on (targets.applicable). healthy-baseline isn't one: the control runs it as
    the baseline profile. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $catalog = [ordered]@{}
    foreach ($folder in Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'scenarios') -Directory | Sort-Object -Property Name) {
        $path = Join-Path -Path $folder.FullName -ChildPath 'scenario.json'
        if ($folder.Name -eq 'healthy-baseline' -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        $definition = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $catalog[$folder.Name] = [ordered]@{
            maxMinutes     = [int][System.Math]::Floor([double]$definition['duration']['maxSeconds'] / 60)
            maxConcurrency = [int]$definition['concurrency']['max']
            targets        = @($definition['targets']['applicable'] | ForEach-Object { [string]$_ })
        }
    }
    return $catalog
}

function Get-DemoActivityControlProfile {
    <#
    .SYNOPSIS
    The activity profiles the control runs as a whole (2026-11-04: showcase, Run all's default), from
    scenarios/activity-profiles.json: each one's maximum and default minutes and the targets it has incidents for. off
    isn't one: the runbook takes it as its own word, which turns a target's activity off. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $definitions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'scenarios/activity-profiles.json') -Raw | ConvertFrom-Json -AsHashtable
    $profiles = [ordered]@{}
    foreach ($name in @('showcase')) {
        $definition = $definitions['profiles'][$name]
        # cycleMinutes (2026-11-14): a session cut short by the VMs' auto-shutdown ends after whole cycles, so no beat is cut.
        $profiles[$name] = [ordered]@{
            maxMinutes     = [int]$definition['maxDurationMinutes']
            defaultMinutes = [int]$definition['defaultDurationMinutes']
            cycleMinutes   = [int]$definition['cycleMinutes']
            targets        = @($definition['incidents'] | ForEach-Object { [string]$_['target'] } | Sort-Object -Unique)
        }
    }
    return $profiles
}

function Get-DemoActivityControlRunbookSetting {
    <#
    .SYNOPSIS
    The settings baked into the three runbooks: names, the demo's schedule, the bounds, the allow-lists from the scenario
    catalog and the activity profiles the control runs as a whole (showcase), how long the VM-side control waits for
    each target (readySeconds), how T1's monitoring plugin is looked after, the pinned API versions, and the VM-side
    workload-control template. Nothing in it is secret; it holds the subscription ID and the identity's client ID, which
    live in Azure only. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $IdentityClientId
    )

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $apiVersions = [ordered]@{}
    foreach ($type in 'Microsoft.Automation/automationAccounts', 'Microsoft.Compute/virtualMachines', 'Microsoft.Compute/virtualMachines/runCommands', 'Microsoft.Resources/resourceGroups', 'Microsoft.Sql/servers/databases', 'Microsoft.DBforPostgreSQL/flexibleServers', 'Microsoft.DBforPostgreSQL/flexibleServers/configurations', 'Microsoft.KeyVault/vaults', 'Microsoft.Resources/tags', 'Microsoft.Insights/metrics') {
        $apiVersions[$type] = [string]$versions['apiVersions'][$type]
        if (-not $apiVersions[$type]) {
            throw ('config/versions.json has no API version for {0}.' -f $type)
        }
    }
    $catalog = Get-DemoActivityControlCatalog
    $targets = [ordered]@{ T1 = [ordered]@{}; T2 = [ordered]@{}; T3 = [ordered]@{} }
    if (@($catalog.Values | Where-Object { $_['targets'] -contains 'T4' }).Count -gt 0) {
        $targets['T4'] = [ordered]@{}
    }
    $guest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/dsc/guest.psd1')
    $sqlVm = (Get-DemoArcSetting).SqlVm
    return [ordered]@{
        schemaVersion          = 1
        subscriptionId         = $Name.SubscriptionId
        location               = [string]$Config['location']
        demoResourceGroup      = $Name.DemoResourceGroup
        controlResourceGroup   = $Name.ResourceGroup
        automationAccount      = $Name.AutomationAccount
        identityClientId       = $IdentityClientId.ToLowerInvariant()
        controlRunbook         = $Name.ControlRunbook
        stopRunbook            = $Name.StopRunbook
        monitorRunbook         = $Name.MonitorRunbook
        autoStopSchedule       = $Name.AutoStopSchedule
        autoStopBufferMinutes  = 10
        monitorSchedulePrefix  = $Name.MonitorPrefix
        monitorRecheckMinutes  = 30
        runCommandPrefix       = $Name.RunCommandPrefix
        sqlVmName              = 'sqlvm01'
        hostVmName             = Get-DemoHostVmName -Config $Config
        t2GuestName            = [string]$guest.Name
        t3ServerPrefix         = 'azuresql01-'
        demoDatabase           = 'ContosoCare'
        t4ServerPrefix         = 'pgflex01-'
        # T4's read replica (ADR 0025): a run starts a stopped one before T4 (Azure's order). A session (the control
        # notebook's Run all, 2026-11-14, ADR 0026) creates it once T4 is Ready, at T4's size or the next documented size
        # Azure accepts, and the stop deletes it after saving its metrics; without the grant, it's stopped after T4.
        t4ReplicaPrefix        = ('{0}-' -f (Get-DemoT4ReplicaSetting)['serverNamePrefix'])
        t4Replica              = [ordered]@{
            sizes                      = @((Get-DemoT4ReplicaSetting)['generalPurposeSizes'])
            maxStandbyStreamingDelayMs = [int](Get-DemoT4ReplicaSetting)['maxStandbyStreamingDelayMs']
            createWaitMinutes          = 25
            deleteWaitMinutes          = [int](Get-DemoT4ReplicaSetting)['deleteTimeoutMinutes']
            raceMinutes                = 10
        }
        # The session's status and the history's metrics (2026-11-14): written to these secrets of the control vault through
        # Azure Resource Manager, for the control notebook to read.
        controlVault           = $Name.KeyVault
        statusName             = $Name.StatusSecret
        metricsName            = $Name.MetricsSecret
        # A session's second auto-stop, for when the first one's job fails; it goes with the first.
        autoStopBackupSchedule = $Name.AutoStopBackupSchedule
        autoStopBackupMinutes  = 30
        minSessionMinutes      = 30
        # The busy marker of a session ends this long after its auto-stop.
        busyMarginMinutes      = 15
        autoShutdownTime       = $(if ($Config['autoShutdownTime']) { [string]$Config['autoShutdownTime'] } else { '1900' })
        autoShutdownTimeZone   = $(if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' })
        shutdownMarginMinutes  = 2
        # The busy marker (2026-11-14): the daily T4 safety stop changes nothing while it's active, and one further ahead
        # than this is ignored.
        busyMarkerMaximumMinutes = [int]$script:BusyMarkerSetting['maximumMinutes']
        minDurationMinutes     = 5
        maxDurationMinutes     = 120
        maxBodyBytes           = 4096
        targets                = $targets
        scenarios              = $catalog
        profiles               = Get-DemoActivityControlProfile
        readySeconds           = [ordered]@{ T1 = 600; T2 = 1200; T3 = 600; T4 = 600 }
        monitoring             = [ordered]@{ extensionInstanceName = [string]$sqlVm['extensionInstanceName']; statusPlugin = [string]$sqlVm['statusPlugin']; featureFlag = [string]$sqlVm['featureFlag']; serviceName = 'SQLIaaSExtension'; settleMinutes = 8; verifyMinutes = 5 }
        apiVersions            = $apiVersions
        controlScriptTemplate  = (Get-DemoWorkloadControlTemplate).Replace('__ACTION__', 'Runner')
    }
}

function Get-DemoActivityControlRunbookContent {
    <#
    .SYNOPSIS
    A runbook as it's published: automation/runbooks/<Name>.ps1 with the settings JSON and
    automation/runbooks/DbHubControl.Common.ps1 in place of its two markers. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DbHub-Control', 'DbHub-Stop', 'DbHub-Monitor')]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $root = Join-Path -Path $script:RepoRoot -ChildPath 'automation/runbooks'
    $main = [System.IO.File]::ReadAllText((Join-Path -Path $root -ChildPath ('{0}.ps1' -f $Name))).Replace("`r`n", "`n")
    $common = [System.IO.File]::ReadAllText((Join-Path -Path $root -ChildPath 'DbHubControl.Common.ps1')).Replace("`r`n", "`n")
    $json = ConvertTo-Json -InputObject $Setting -Depth 16 -Compress -EscapeHandling EscapeNonAscii
    if ($json -match "[`r`n]" -or $json.Contains("'@")) {
        throw 'The runbook settings would break the here-string they go into.'
    }
    foreach ($marker in "`n__DBHUB_SETTINGS__`n", "`n# __DBHUB_COMMON__`n") {
        if (([regex]::Matches($main, [regex]::Escape($marker))).Count -ne 1) {
            throw ('automation/runbooks/{0}.ps1 must hold the marker {1} exactly once.' -f $Name, $marker.Trim())
        }
    }
    return $main.Replace("`n__DBHUB_SETTINGS__`n", "`n" + $json + "`n").Replace("`n# __DBHUB_COMMON__`n", "`n" + $common.TrimEnd("`n") + "`n")
}

function Invoke-DemoActivityControlArm {
    <#
    .SYNOPSIS
    One Azure Resource Manager request through 'az rest' and Invoke-DemoAz (the subscription guard). A body goes in a
    file in a private directory, never on the command line, and so do the query parameters of -Query (--url-parameters
    @<path>, which the Azure CLI encodes), because an encoded query string has '%', which cmd.exe can't pass to az.cmd
    (Phase 25d, live: every role check and the stop-job read failed that way). The directory is deleted afterwards.
    Returns Ok, StatusMissing (HTTP 404), Value (parsed JSON), and Error (redacted). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateSet('get', 'put', 'post', 'delete', 'patch')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Url,

        [AllowNull()]
        [object] $Body,

        [string] $ContentType = 'application/json',

        [AllowNull()]
        [System.Collections.IDictionary] $Query
    )

    $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('rest', '--method', $Method, '--url', $Url))
    $directory = ''
    try {
        if ($null -ne $Body -or ($null -ne $Query -and $Query.Count -gt 0)) {
            $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-control'
        }
        if ($null -ne $Query -and $Query.Count -gt 0) {
            $queryPath = Write-DemoPrivateFile -Directory $directory -Name 'query.json' -Content (ConvertTo-Json -InputObject $Query -Depth 4 -Compress)
            $arguments.AddRange([string[]]@('--url-parameters', "@$queryPath"))
        }
        if ($null -ne $Body) {
            $text = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 32 -Compress }
            $path = Write-DemoPrivateFile -Directory $directory -Name 'body.txt' -Content $text
            $arguments.AddRange([string[]]@('--body', "@$path", '--headers', ('Content-Type={0}' -f $ContentType)))
        }
        $run = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $arguments.ToArray() -AllowFailure
    }
    finally {
        if ($directory) {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
        }
    }
    $value = $null
    if ($run.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$run.StdOut)) {
        try {
            $value = [string]$run.StdOut | ConvertFrom-Json -AsHashtable -Depth 64
        }
        catch {
            $value = [string]$run.StdOut
        }
    }
    $errorText = if ($run.ExitCode -ne 0) { (Protect-DemoText -Text ([string]$run.StdErr)).Trim() } else { '' }
    return [pscustomobject]@{
        Ok      = $run.ExitCode -eq 0
        Missing = $run.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$run.StdErr))
        Value   = $value
        Error   = $errorText
    }
}

function Get-DemoActivityControlUrl {
    # ARM URL of a control resource with its pinned API version. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [string] $ApiVersion,

        [string] $Query = ''
    )

    $url = 'https://management.azure.com{0}?api-version={1}' -f $Id, $ApiVersion
    if ($Query) {
        $url += '&' + $Query
    }
    return $url
}

function Get-DemoActivityControlRoleId {
    <#
    .SYNOPSIS
    A custom role's definition ID (a GUID) in the subscription, found by its name (the operator role by default); empty
    when it doesn't exist. With -WithActions, an object with Id and Actions instead. Throws when the role definitions
    can't be read. Internal.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/list
    #>
    [CmdletBinding()]
    [OutputType([string], [pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [string] $RoleName = $script:ActivityControlRoleName,

        [switch] $WithActions
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions' -f $SubscriptionId) -Query ([ordered]@{ '$filter' = ("roleName eq '{0}'" -f $RoleName); 'api-version' = '2022-04-01' })
    if (-not $read.Ok) {
        throw ('The role definitions couldn''t be read: {0}' -f $read.Error)
    }
    $match = @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value') | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'roleName') -ceq $RoleName } | Select-Object -First 1
    if ($WithActions) {
        $actions = @(foreach ($permission in @(Get-DemoActivityControlList -InputObject (Get-DemoMemberValue -InputObject $match -Name 'properties') -Name 'permissions')) { Get-DemoActivityControlList -InputObject $permission -Name 'actions' })
        return [pscustomobject]@{ Id = [string](Get-DemoMemberValue -InputObject $match -Name 'name'); Actions = @($actions | ForEach-Object { [string]$_ }) }
    }
    return [string](Get-DemoMemberValue -InputObject $match -Name 'name')
}

function Get-DemoActivityControlCommand {
    # The exact command an Owner runs to grant the control's roles; without -GrantRole, the control's setup. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigPath = ''
    )

    $path = if ($ConfigPath) { $ConfigPath } else { './config/demo.config.json' }
    return ('./scripts/setup-activity-control.ps1 -ConfigPath {0} -GrantRole' -f $path)
}

function Get-DemoActivityControlGrantCommand {
    # The one grant script an Owner runs for the safety stop's role and the control's roles together (2026-11-14,
    # ADR 0026), which the control's role Warnings name. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigPath = ''
    )

    $path = if ($ConfigPath) { $ConfigPath } else { './config/demo.config.json' }
    return ('./scripts/grant-safety-stop.ps1 -ConfigPath {0}' -f $path)
}

function Get-DemoActivityControlPrincipalId {
    # The automation identity's principal (object) ID; empty when the identity doesn't exist yet. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.IdentityId -ApiVersion '2024-11-30')
    if (-not $read.Ok) {
        return ''
    }
    return [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $read.Value -Name 'properties') -Name 'principalId')
}

function Test-DemoActivityControlAssignment {
    <#
    .SYNOPSIS
    Whether a principal holds a role definition at exactly a scope. Returns Exists and Error. Internal.
    https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [string] $RoleId
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments' -f $Scope) -Query ([ordered]@{ '$filter' = ("principalId eq '{0}'" -f $PrincipalId); 'api-version' = '2022-04-01' })
    if (-not $read.Ok) {
        return [pscustomobject]@{ Exists = $false; Missing = $read.Missing; Error = $read.Error }
    }
    foreach ($assignment in @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $assignment -Name 'properties'
        $role = [string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')
        $at = [string](Get-DemoMemberValue -InputObject $properties -Name 'scope')
        if ($role.EndsWith('/' + $RoleId, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($at, $Scope, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Exists = $true; Missing = $false; Error = '' }
        }
    }
    return [pscustomobject]@{ Exists = $false; Missing = $false; Error = '' }
}

function Get-DemoActivityControlGrantPlan {
    <#
    .SYNOPSIS
    The approved role assignments (ADR 0020), as the owner approved them on 2026-10-26: A1, the custom role for the
    automation identity at the demo resource group; A2, the same at the control Automation account; A3, Key Vault
    Secrets User at the one secret dbhub-activity-webhook, for the signed-in owner and control.notebookUserObjectIds.
    2026-11-14 (ADR 0026): A3 also at the session's two secrets, dbhub-session-status and dbhub-session-metrics, which the
    notebook reads; and A4, the custom role "DbHub Demo Session Writer" for the automation identity at those two secrets
    only, which the runbook writes. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $RoleId = '',

        [AllowEmptyString()]
        [string] $WriterRoleId = '',

        [AllowEmptyString()]
        [string] $PrincipalId = '',

        [AllowEmptyString()]
        [string] $CallerObjectId = '',

        [AllowEmptyString()]
        [string] $CallerPrincipalType = 'User',

        [ValidateSet('A1', 'A2', 'A3', 'A4')]
        [string[]] $Assignment = @('A1', 'A2', 'A3', 'A4')
    )

    $roleDefinition = if ($RoleId) { '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $RoleId } else { '' }
    $writerDefinition = if ($WriterRoleId) { '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $WriterRoleId } else { '' }
    $secretsUser = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $script:VaultReaderRoleGuid
    $sessionSecrets = @(
        [pscustomobject]@{ Name = $Name.StatusSecret; Id = $Name.StatusSecretId }
        [pscustomobject]@{ Name = $Name.MetricsSecret; Id = $Name.MetricsSecretId }
    )
    $plan = [System.Collections.Generic.List[object]]::new()
    if ('A1' -in $Assignment) {
        $plan.Add([pscustomobject]@{ Id = 'A1'; Role = $Name.RoleName; RoleId = $RoleId; RoleDefinitionId = $roleDefinition; Scope = $Name.DemoResourceGroupId; ScopeLabel = $Name.DemoResourceGroup; PrincipalId = $PrincipalId; PrincipalType = 'ServicePrincipal'; PrincipalLabel = $Name.Identity })
    }
    if ('A2' -in $Assignment) {
        $plan.Add([pscustomobject]@{ Id = 'A2'; Role = $Name.RoleName; RoleId = $RoleId; RoleDefinitionId = $roleDefinition; Scope = $Name.AutomationAccountId; ScopeLabel = $Name.AutomationAccount; PrincipalId = $PrincipalId; PrincipalType = 'ServicePrincipal'; PrincipalLabel = $Name.Identity })
    }
    if ('A3' -in $Assignment) {
        $users = [System.Collections.Generic.List[object]]::new()
        if ($CallerObjectId) {
            $users.Add([pscustomobject]@{ Id = $CallerObjectId.ToLowerInvariant(); Type = $(if ($CallerPrincipalType) { $CallerPrincipalType } else { 'User' }); Label = 'you (the signed-in owner)' })
        }
        foreach ($id in (Get-DemoActivityControlSetting -Config $Config).NotebookUserObjectIds) {
            if (-not $CallerObjectId -or $id -ne $CallerObjectId.ToLowerInvariant()) {
                $users.Add([pscustomobject]@{ Id = $id; Type = ''; Label = ('notebook user {0}' -f $id) })
            }
        }
        $secrets = @([pscustomobject]@{ Name = $Name.Secret; Id = $Name.SecretId }) + $sessionSecrets
        foreach ($user in $users) {
            foreach ($secret in $secrets) {
                $plan.Add([pscustomobject]@{ Id = 'A3'; Role = 'Key Vault Secrets User'; RoleId = $script:VaultReaderRoleGuid; RoleDefinitionId = $secretsUser; Scope = $secret.Id; ScopeLabel = ('{0}/secrets/{1}' -f $Name.KeyVault, $secret.Name); PrincipalId = $user.Id; PrincipalType = $user.Type; PrincipalLabel = $user.Label })
            }
        }
    }
    if ('A4' -in $Assignment) {
        foreach ($secret in $sessionSecrets) {
            $plan.Add([pscustomobject]@{ Id = 'A4'; Role = $Name.WriterRoleName; RoleId = $WriterRoleId; RoleDefinitionId = $writerDefinition; Scope = $secret.Id; ScopeLabel = ('{0}/secrets/{1}' -f $Name.KeyVault, $secret.Name); PrincipalId = $PrincipalId; PrincipalType = 'ServicePrincipal'; PrincipalLabel = $Name.Identity })
        }
    }
    return $plan.ToArray()
}

function Grant-DemoActivityControlRole {
    <#
    .SYNOPSIS
    Creates or updates the custom roles (with -IncludeDefinition) and the requested assignments of A1-A4, as the
    signed-in caller, and returns CONTROL.ROLE.DEFINITION, CONTROL.ROLE.WRITER, and CONTROL.ROLE.<A1|A2|A3|A4> results.
    The one function behind scripts/grant-safety-stop.ps1 and setup-activity-control.ps1 -GrantRole (every assignment,
    and the roles), and deploy.ps1's control setup (2026-11-14). Internal.

    .DESCRIPTION
    An assignment that exists is kept (Pass). One that can't be made, because the caller isn't an Owner or User Access
    Administrator, a write needs a fresh multifactor sign-in, the role definition or the identity doesn't exist yet, or
    Azure refuses it, is a Warning with the exact grant command (./scripts/grant-safety-stop.ps1), as the safety stop's
    role is: a session runs without what it needs and says so. Every write is a documented Azure Resource Manager call
    through the subscription guard:
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    https://learn.microsoft.com/rest/api/authorization/role-assignments/create
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('A1', 'A2', 'A3', 'A4')]
        [string[]] $Assignment = @('A1', 'A2', 'A3', 'A4'),

        [switch] $IncludeDefinition,

        [string] $ConfigPath = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $name = Get-DemoActivityControlName -Config $Config
    $subscriptionId = $name.SubscriptionId
    $command = Get-DemoActivityControlGrantCommand -ConfigPath $ConfigPath
    $doc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-rest'
    $manual = {
        param([string] $CheckId, [string] $Message, [System.Collections.IDictionary] $Evidence)
        New-DemoResult -CheckId $CheckId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $Message -Evidence $Evidence -Remediation ('An Owner of the subscription runs, signed in with multifactor authentication: {0}' -f $command) -DocUrl $doc
    }

    $permissions = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $subscriptionId)
    $entries = @()
    if ($permissions.Ok) {
        $entries = @(Get-DemoActivityControlList -InputObject $permissions.Value -Name 'value')
    }
    $canAssign = $permissions.Ok -and (Test-DemoPermission -Permission $entries -Action 'Microsoft.Authorization/roleAssignments/write')
    $canDefine = $permissions.Ok -and (Test-DemoPermission -Permission $entries -Action 'Microsoft.Authorization/roleDefinitions/write')

    $roleIds = @{ Operator = ''; Writer = '' }
    $roleActions = @{ Operator = @(); Writer = @() }
    try {
        $operatorRole = Get-DemoActivityControlRoleId -SubscriptionId $subscriptionId -RoleName $name.RoleName -WithActions
        $writerRole = Get-DemoActivityControlRoleId -SubscriptionId $subscriptionId -RoleName $name.WriterRoleName -WithActions
        $roleIds.Operator = [string]$operatorRole.Id
        $roleActions.Operator = @($operatorRole.Actions)
        $roleIds.Writer = [string]$writerRole.Id
        $roleActions.Writer = @($writerRole.Actions)
    }
    catch {
        $results.Add((& $manual 'CONTROL.ROLE.DEFINITION' (Protect-DemoText -Text $_.Exception.Message) ([ordered]@{ role = $name.RoleName })))
        return $results.ToArray()
    }
    if ($IncludeDefinition) {
        foreach ($kind in 'Operator', 'Writer') {
            $writer = $kind -eq 'Writer'
            $roleName = if ($writer) { $name.WriterRoleName } else { $name.RoleName }
            $actions = if ($writer) { @($script:SessionWriterRoleActions) } else { @($script:ActivityControlRoleActions) }
            $checkId = if ($writer) { 'CONTROL.ROLE.WRITER' } else { 'CONTROL.ROLE.DEFINITION' }
            $definition = Get-DemoActivityControlRoleDefinition -SubscriptionId $subscriptionId -Writer:$writer -RoleName $roleName
            $definitionId = if ($roleIds[$kind]) { $roleIds[$kind] } else { ConvertTo-DemoStableGuid -Key ('{0}|{1}' -f $subscriptionId, $roleName) }
            $evidence = [ordered]@{ role = $roleName; roleId = $definitionId; actions = $actions; assignableScopes = @('/subscriptions/{0}' -f $subscriptionId) }
            $reach = @($actions | Where-Object { $script:ActivityControlActionReach.Contains($_) } | ForEach-Object { '{0}: {1}' -f $_, $script:ActivityControlActionReach[$_] })
            $reachText = if ($reach.Count) { ' What the session''s actions (2026-11-14) could touch: {0}.' -f ($reach -join '; ') } else { '' }
            $current = @($roleActions[$kind])
            if ($roleIds[$kind] -and $current.Count -eq $actions.Count -and @($actions | Where-Object { $_ -cnotin $current }).Count -eq 0) {
                # Already exactly the approved actions (an Owner's grant, or an earlier run): nothing to write, so no
                # roleDefinitions/write is needed, and a Contributor's deploy.ps1 has nothing to report here.
                $evidence['reach'] = $reach
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The custom role "{0}" has exactly the {1} approved actions, assignable in this subscription only.{2}' -f $roleName, $actions.Count, $reachText) -Evidence $evidence -DocUrl $doc))
                continue
            }
            if (-not $canDefine) {
                $results.Add((& $manual $checkId ('The custom role "{0}" {1}, and writing it needs Microsoft.Authorization/roleDefinitions/write, which the signed-in caller doesn''t have.' -f $roleName, $(if ($roleIds[$kind]) { 'lacks some of its approved actions' } else { 'doesn''t exist yet' })) $evidence))
            }
            elseif (-not $PSCmdlet.ShouldProcess(('/subscriptions/{0}' -f $subscriptionId), ('{0} the custom role "{1}" with exactly the {2} approved actions' -f $(if ($roleIds[$kind]) { 'Update' } else { 'Create' }), $roleName, $actions.Count))) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: the custom role "{0}" would be {1} with exactly these actions: {2}.' -f $roleName, $(if ($roleIds[$kind]) { 'updated' } else { 'created' }), ($actions -join ', ')) -Evidence $evidence -DocUrl $doc))
                $roleIds[$kind] = $definitionId
            }
            else {
                $write = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method put -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version=2022-04-01' -f $subscriptionId, $definitionId) -Body $definition
                if ($write.Ok) {
                    $roleIds[$kind] = $definitionId
                    $evidence['reach'] = $reach
                    $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The custom role "{0}" exists with exactly the {1} approved actions, assignable in this subscription only.{2}' -f $roleName, $actions.Count, $reachText) -Evidence $evidence -DocUrl $doc))
                }
                else {
                    $results.Add((& $manual $checkId ('The custom role "{0}" couldn''t be written: {1}' -f $roleName, $write.Error) $evidence))
                }
            }
        }
    }

    $principalId = Get-DemoActivityControlPrincipalId -Name $name
    $caller = Get-DemoCallerIdentity -SubscriptionId $subscriptionId
    $plan = @(Get-DemoActivityControlGrantPlan -Name $name -Config $Config -RoleId $roleIds.Operator -WriterRoleId $roleIds.Writer -PrincipalId $principalId -CallerObjectId ([string]$caller.ObjectId) -CallerPrincipalType ([string]$caller.PrincipalType) -Assignment $Assignment)
    foreach ($item in $plan) {
        $checkId = 'CONTROL.ROLE.{0}' -f $item.Id
        $evidence = [ordered]@{ assignment = $item.Id; role = $item.Role; scope = $item.ScopeLabel; principal = $item.PrincipalLabel; principalId = $item.PrincipalId }
        $label = '{0}: {1} for {2} at {3}' -f $item.Id, $item.Role, $item.PrincipalLabel, $item.ScopeLabel
        if (-not $item.RoleId) {
            $results.Add((& $manual $checkId ('{0} wasn''t granted: the custom role "{1}" doesn''t exist yet.' -f $label, $item.Role) $evidence))
            continue
        }
        if (-not $item.PrincipalId) {
            $why = if ($item.Id -eq 'A3') { 'the signed-in caller''s object ID is unknown' } else { ('the identity {0} doesn''t exist yet; ./scripts/deploy.ps1 creates it' -f $name.Identity) }
            $results.Add((& $manual $checkId ('{0} wasn''t granted: {1}.' -f $label, $why) $evidence))
            continue
        }
        $existing = Test-DemoActivityControlAssignment -SubscriptionId $subscriptionId -Scope $item.Scope -PrincipalId $item.PrincipalId -RoleId $item.RoleId
        if ($existing.Exists) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} is in place.' -f $label) -Evidence $evidence -DocUrl $doc))
            continue
        }
        if ($existing.Missing) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t granted: {1} doesn''t exist.' -f $label, $item.ScopeLabel) -Evidence $evidence -Remediation ('Run ./scripts/deploy.ps1, which creates it, then {0}.' -f $command) -DocUrl $doc))
            continue
        }
        if (-not $canAssign) {
            $results.Add((& $manual $checkId ('{0} wasn''t granted: the signed-in caller can''t create role assignments (it needs Owner or User Access Administrator).' -f $label) $evidence))
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.ScopeLabel, ('Assign {0} to {1} (object ID {2})' -f $item.Role, $item.PrincipalLabel, $item.PrincipalId))) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} (object ID {1}) would be assigned.' -f $label, $item.PrincipalId) -Evidence $evidence -DocUrl $doc))
            continue
        }
        $properties = [ordered]@{ roleDefinitionId = $item.RoleDefinitionId; principalId = $item.PrincipalId }
        if ($item.PrincipalType) {
            $properties['principalType'] = $item.PrincipalType
        }
        $assignmentName = ConvertTo-DemoStableGuid -Key ('{0}|{1}|{2}' -f $item.Scope.ToLowerInvariant(), $item.RoleId, $item.PrincipalId)
        $write = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method put -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments/{1}?api-version=2022-04-01' -f $item.Scope, $assignmentName) -Body ([ordered]@{ properties = $properties })
        if ($write.Ok -or $write.Error -match 'RoleAssignmentExists') {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} is assigned.' -f $label) -Evidence $evidence -DocUrl $doc))
        }
        else {
            $results.Add((& $manual $checkId ('{0} couldn''t be assigned: {1}' -f $label, $write.Error) $evidence))
        }
    }
    return $results.ToArray()
}

function Initialize-DemoActivityControlGroup {
    <#
    .SYNOPSIS
    Registers Microsoft.Automation when it isn't (Contributor can), and creates rg-<prefix>-control with the control's
    tags when it doesn't exist. An existing group (it also holds the GitHub OIDC identity, ADR 0002) keeps its tags.
    Returns CONTROL.PROVIDER and CONTROL.GROUP. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $subscriptionId = $Name.SubscriptionId
    $providerDoc = 'https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types'
    $state = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('provider', 'show', '--namespace', 'Microsoft.Automation', '--query', 'registrationState', '--output', 'tsv') -AllowFailure
    $registered = $state.ExitCode -eq 0 -and ([string]$state.StdOut).Trim() -eq 'Registered'
    if ($registered) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.PROVIDER' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'The Microsoft.Automation resource provider is registered.' -DocUrl $providerDoc))
    }
    elseif (-not $PSCmdlet.ShouldProcess('Microsoft.Automation', 'Register the resource provider')) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.PROVIDER' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message 'What if: the Microsoft.Automation resource provider would be registered.' -DocUrl $providerDoc))
    }
    else {
        $register = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('provider', 'register', '--namespace', 'Microsoft.Automation', '--wait') -AllowFailure -TimeoutSeconds 900
        $status = if ($register.ExitCode -eq 0) { 'Pass' } else { 'Fail' }
        $message = if ($register.ExitCode -eq 0) { 'The Microsoft.Automation resource provider was registered.' } else { 'The Microsoft.Automation resource provider couldn''t be registered: {0}' -f (Protect-DemoText -Text ([string]$register.StdErr)).Trim() }
        $results.Add((New-DemoResult -CheckId 'CONTROL.PROVIDER' -Area 'workload' -Target 'subscription' -Status $status -Message $message -Remediation $(if ($status -eq 'Fail') { 'Register it (az provider register --namespace Microsoft.Automation), then run setup-activity-control.ps1 again.' } else { '' }) -DocUrl $providerDoc))
    }

    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $Name.ResourceGroup) -AllowFailure
    $groupDoc = 'https://learn.microsoft.com/cli/azure/group#az-group-create'
    if ($exists.ExitCode -eq 0 -and ([string]$exists.StdOut).Trim() -eq 'true') {
        $results.Add((New-DemoResult -CheckId 'CONTROL.GROUP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} exists; destroy.ps1 keeps it.' -f $Name.ResourceGroup) -DocUrl $groupDoc))
    }
    elseif (-not $PSCmdlet.ShouldProcess($Name.ResourceGroup, 'Create the control resource group')) {
        $results.Add((New-DemoResult -CheckId 'CONTROL.GROUP' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} would be created in {1}.' -f $Name.ResourceGroup, $Config['location']) -DocUrl $groupDoc))
    }
    else {
        $tags = (Get-DemoActivityControlTag -Config $Config).GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
        $create = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('group', 'create', '--name', $Name.ResourceGroup, '--location', [string]$Config['location'], '--tags') + @($tags) + @('--output', 'none')) -AllowFailure
        $status = if ($create.ExitCode -eq 0) { 'Pass' } else { 'Fail' }
        $message = if ($create.ExitCode -eq 0) { '{0} was created; destroy.ps1 keeps it.' -f $Name.ResourceGroup } else { '{0} couldn''t be created: {1}' -f $Name.ResourceGroup, (Protect-DemoText -Text ([string]$create.StdErr)).Trim() }
        $results.Add((New-DemoResult -CheckId 'CONTROL.GROUP' -Area 'workload' -Target 'subscription' -Status $status -Message $message -DocUrl $groupDoc))
    }
    return $results.ToArray()
}

function Invoke-DemoActivityControlTemplate {
    <#
    .SYNOPSIS
    Deploys infra/control/control.bicep (the identity, the Automation account, and the vault in the resolved mode) and
    returns Result (CONTROL.RESOURCES) and Outputs (identityClientId, identityPrincipalId, keyVaultId, keyVaultUri).
    The parameters go in a file in a private directory. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $Mode
    )

    $doc = 'https://learn.microsoft.com/azure/automation/quickstarts/create-azure-automation-account-portal'
    $evidence = [ordered]@{ resourceGroup = $Name.ResourceGroup; automationAccount = $Name.AutomationAccount; identity = $Name.Identity; keyVault = $Name.KeyVault; vaultNetworkMode = $Mode }
    if (-not $PSCmdlet.ShouldProcess($Name.ResourceGroup, ('Deploy infra/control/control.bicep: {0}, {1}, and {2} ({3})' -f $Name.Identity, $Name.AutomationAccount, $Name.KeyVault, $Mode))) {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'CONTROL.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0}, {1} (Basic, public network access and local authentication on for webhooks), and {2} ({3} network access, Azure RBAC, 7-day soft delete, purge protection off) would be deployed in {4}.' -f $Name.Identity, $Name.AutomationAccount, $Name.KeyVault, $Mode, $Name.ResourceGroup) -Evidence $evidence -DocUrl $doc); Outputs = $null }
    }
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            location              = @{ value = [string]$Config['location'] }
            automationAccountName = @{ value = $Name.AutomationAccount }
            identityName          = @{ value = $Name.Identity }
            keyVaultName          = @{ value = $Name.KeyVault }
            vaultNetworkMode      = @{ value = $Mode }
            tags                  = @{ value = (Get-DemoActivityControlTag -Config $Config) }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-control'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'control.parameters.json' -Content (ConvertTo-Json -InputObject $parameters -Depth 8)
        $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/control/control.bicep'
        $run = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $Name.ResourceGroup, '--name', $Name.TemplateDeployment, '--template-file', $template, '--parameters', "@$path", '--query', 'properties.outputs', '--output', 'json') -AllowFailure -TimeoutSeconds 1800
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
    if ($run.ExitCode -ne 0) {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'CONTROL.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('infra/control/control.bicep couldn''t be deployed: {0}' -f (Protect-DemoText -Text ([string]$run.StdErr)).Trim()) -Evidence $evidence -Remediation 'Fix the cause (a policy denial names its policy), then run setup-activity-control.ps1 again.' -DocUrl $doc); Outputs = $null }
    }
    $raw = [string]$run.StdOut | ConvertFrom-Json -AsHashtable -Depth 16
    $outputs = [ordered]@{}
    foreach ($key in 'identityClientId', 'identityPrincipalId', 'keyVaultId', 'keyVaultUri', 'automationAccountId') {
        $outputs[$key] = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $raw -Name $key) -Name 'value')
    }
    $vault = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.KeyVaultId -ApiVersion '2026-02-01')
    $actual = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $vault.Value -Name 'properties') -Name 'publicNetworkAccess')
    $evidence['vaultPublicNetworkAccess'] = $actual
    if ($Mode -eq 'public' -and $actual -and $actual -ne 'Enabled') {
        return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'CONTROL.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('{0} was deployed with public network access, but it''s {1} now: a policy changed it, so the notebook in the shared workspace can''t read it.' -f $Name.KeyVault, $actual) -Evidence $evidence -Remediation 'Set control.vaultNetworkMode to auto or private, then run setup-activity-control.ps1 again; it never adds a policy''s exclusion tag.' -DocUrl $doc); Outputs = $outputs }
    }
    return [pscustomobject]@{ Result = (New-DemoResult -CheckId 'CONTROL.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0}, {1}, and {2} ({3} network access) are deployed in {4}.' -f $Name.Identity, $Name.AutomationAccount, $Name.KeyVault, $(if ($actual) { $actual } else { $Mode }), $Name.ResourceGroup) -Evidence $evidence -DocUrl $doc); Outputs = $outputs }
}

function Publish-DemoActivityControlRunbook {
    <#
    .SYNOPSIS
    Creates or updates DbHub-Control, DbHub-Stop, and DbHub-Monitor (PowerShell, that is Windows PowerShell 5.1),
    replaces each draft with the assembled content, and publishes it. Returns CONTROL.RUNBOOKS. Internal.
    - Runbook - Create Or Update: https://learn.microsoft.com/rest/api/automation/runbook/create-or-update
    - Runbook Draft - Replace Content: https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content
    - Runbook - Publish: https://learn.microsoft.com/rest/api/automation/runbook/publish
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $doc = 'https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content'
    $version = '2024-10-23'
    $published = [System.Collections.Generic.List[string]]::new()
    foreach ($runbook in $Name.ControlRunbook, $Name.StopRunbook, $Name.MonitorRunbook) {
        $content = Get-DemoActivityControlRunbookContent -Name $runbook -Setting $Setting
        if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $Name.AutomationAccount, $runbook), 'Create, replace the content of, and publish the runbook')) {
            continue
        }
        $id = '{0}/runbooks/{1}' -f $Name.AutomationAccountId, $runbook
        $body = [ordered]@{ location = [string]$Config['location']; properties = [ordered]@{ runbookType = 'PowerShell'; logVerbose = $false; logProgress = $false; description = 'On-demand activity control (ADR 0020), published by setup-activity-control.ps1.'; draft = @{} } }
        $steps = @(
            @{ Method = 'put'; Url = (Get-DemoActivityControlUrl -Id $id -ApiVersion $version); Body = $body; ContentType = 'application/json'; Label = 'create' }
            @{ Method = 'put'; Url = (Get-DemoActivityControlUrl -Id ($id + '/draft/content') -ApiVersion $version); Body = $content; ContentType = 'text/powershell'; Label = 'replace the draft' }
            @{ Method = 'post'; Url = (Get-DemoActivityControlUrl -Id ($id + '/publish') -ApiVersion $version); Body = $null; ContentType = 'application/json'; Label = 'publish' }
        )
        foreach ($step in $steps) {
            $call = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method $step.Method -Url $step.Url -Body $step.Body -ContentType $step.ContentType
            if (-not $call.Ok) {
                return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('{0}: couldn''t {1}: {2}' -f $runbook, $step.Label, $call.Error) -Remediation 'Run setup-activity-control.ps1 again; it publishes all three runbooks each time.' -DocUrl $doc)
            }
        }
        $published.Add($runbook)
    }
    if ($published.Count -eq 0) {
        return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0}, {1}, and {2} would be published (Windows PowerShell 5.1) with the current catalog and settings.' -f $Name.ControlRunbook, $Name.StopRunbook, $Name.MonitorRunbook) -DocUrl $doc)
    }
    return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} published (Windows PowerShell 5.1) with the current scenario catalog ({1} scenarios) and settings.' -f ($published -join ', '), @($Setting['scenarios'].Keys).Count) -Evidence ([ordered]@{ runbooks = $published.ToArray(); targets = @($Setting['targets'].Keys); scenarios = @($Setting['scenarios'].Keys) }) -DocUrl $doc)
}

function Get-DemoActivityControlRunbookNote {
    # DONE's and NOT DONE's line, on the console and the status page, when deploy.ps1 couldn't publish the session
    # control's runbooks with this code (its setup, Invoke-DemoControlDeployStep; 2026-11-13, ADR 0026): what fails until
    # then, and the exact command. Empty otherwise. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $problem = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'CONTROL.RUNBOOKS' -and [string]$_.status -in 'Warning', 'Fail' }) | Select-Object -Last 1
    if ($null -eq $problem) {
        return ''
    }
    return ('{0} {1}' -f (ConvertTo-DemoPlainText -Value $problem.message).TrimEnd(), (ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $problem -Name 'remediation'))).Trim()
}

function Get-DemoActivityControlSafetyStopTime {
    <#
    .SYNOPSIS
    The daily T4 safety stop's next run: control.t4SafetyStopTime (HH:mm) or, by default, 15 minutes after
    autoShutdownTime, in autoShutdownTimeZone. Returns StartTime (ISO 8601 with the zone's offset, at least 10 minutes
    ahead), LocalTime (HH:mm), and TimeZone. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $setting = Get-DemoActivityControlSetting -Config $Config
    $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
    if ($setting.T4SafetyStopTime -match '^([01]\d|2[0-3]):([0-5]\d)$') {
        $time = [timespan]::new([int]$Matches[1], [int]$Matches[2], 0)
    }
    else {
        $shutdown = if ([string]$Config['autoShutdownTime'] -match '^([01]\d|2[0-3])([0-5]\d)$') { [timespan]::new([int]$Matches[1], [int]$Matches[2], 0) } else { [timespan]::new(19, 0, 0) }
        $time = [timespan]::FromMinutes(($shutdown.TotalMinutes + 15) % 1440)
    }
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc), $zone)
    $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, 0, 0, 0, [System.DateTimeKind]::Unspecified).Add($time)
    if ($candidate -le $local.AddMinutes(10)) {
        $candidate = $candidate.AddDays(1)
    }
    if ($zone.IsInvalidTime($candidate)) {
        $candidate = $candidate.AddHours(1)
    }
    $offset = $zone.GetUtcOffset($candidate)
    return [pscustomobject]@{
        StartTime = ([DateTimeOffset]::new($candidate, $offset)).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
        LocalTime = '{0:hh\:mm}' -f $time
        TimeZone  = $zoneId
    }
}

function Get-DemoActivityControlTimeZone {
    # A time zone by its Windows or IANA ID, or $null when there's none by that ID. Internal.
    [CmdletBinding()]
    [OutputType([System.TimeZoneInfo])]
    param(
        [AllowEmptyString()]
        [string] $Id
    )

    if (-not $Id) {
        return $null
    }
    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($Id)
    }
    catch [System.TimeZoneNotFoundException], [System.InvalidTimeZoneException] {
        return $null
    }
}

function Set-DemoActivityControlSafetyStop {
    <#
    .SYNOPSIS
    The daily T4 safety stop: the schedule dbhub-t4-safety-stop linked to DbHub-Stop with Scope T4. It stops T4 only
    when it's running (a stopped flexible server starts itself after 7 days) and never starts anything. An existing
    schedule at the right time is kept. Returns CONTROL.SAFETYSTOP. Internal.
    - Schedule: https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    - Job schedule: https://learn.microsoft.com/rest/api/automation/job-schedule/create
    - Time zones (an IANA or a Windows ID): https://learn.microsoft.com/powershell/module/az.automation/new-azautomationschedule
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $doc = 'https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server'
    $version = '2024-10-23'
    $when = Get-DemoActivityControlSafetyStopTime -Config $Config -NowUtc $NowUtc
    $evidence = [ordered]@{ schedule = $Name.SafetyStopSchedule; runbook = $Name.StopRunbook; scope = 'T4'; localTime = $when.LocalTime; timeZone = $when.TimeZone }
    $scheduleId = '{0}/schedules/{1}' -f $Name.AutomationAccountId, $Name.SafetyStopSchedule
    $existing = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
    $links = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $Name.AutomationAccountId) -ApiVersion $version)
    $link = @(Get-DemoActivityControlList -InputObject $links.Value -Name 'value') | Where-Object {
        $properties = Get-DemoMemberValue -InputObject $_ -Name 'properties'
        [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'schedule') -Name 'name') -eq $Name.SafetyStopSchedule -and
        [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name') -eq $Name.StopRunbook
    } | Select-Object -First 1
    $current = ''
    if ($existing.Ok) {
        $properties = Get-DemoMemberValue -InputObject $existing.Value -Name 'properties'
        $next = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'nextRun')
        $zone = Get-DemoActivityControlTimeZone -Id ([string](Get-DemoMemberValue -InputObject $properties -Name 'timeZone'))
        $wanted = Get-DemoActivityControlTimeZone -Id $when.TimeZone
        # Azure Automation reports the zone it was given in its IANA form (Eastern Standard Time comes back as
        # America/New_York, Phase 25d live), so compare the zones' rules, not their names.
        if ($null -ne $next -and $null -ne $zone -and $null -ne $wanted -and $zone.HasSameRules($wanted)) {
            $current = '{0:HH\:mm}' -f [System.TimeZoneInfo]::ConvertTimeFromUtc($next, $zone)
        }
    }
    if ($existing.Ok -and $current -eq $when.LocalTime -and $null -ne $link) {
        return (New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The daily T4 safety stop runs DbHub-Stop -Scope T4 at {0} ({1}); it stops T4 only when it''s running.' -f $when.LocalTime, $when.TimeZone) -Evidence $evidence -DocUrl $doc)
    }
    if (-not $PSCmdlet.ShouldProcess($Name.SafetyStopSchedule, ('Schedule DbHub-Stop -Scope T4 daily at {0} ({1})' -f $when.LocalTime, $when.TimeZone))) {
        return (New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: the daily T4 safety stop would run DbHub-Stop -Scope T4 at {0} ({1}).' -f $when.LocalTime, $when.TimeZone) -Evidence $evidence -DocUrl $doc)
    }
    if ($null -ne $link) {
        $linkId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $link -Name 'properties') -Name 'jobScheduleId')
        $null = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, $linkId) -ApiVersion $version)
    }
    if ($existing.Ok) {
        $null = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
    }
    $schedule = [ordered]@{ name = $Name.SafetyStopSchedule; properties = [ordered]@{ description = 'Daily T4 safety stop: DbHub-Stop -Scope T4 stops the PostgreSQL server only when it runs (ADR 0020).'; startTime = $when.StartTime; frequency = 'Day'; interval = 1; timeZone = $when.TimeZone } }
    $created = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version) -Body $schedule
    if (-not $created.Ok) {
        return (New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The daily T4 safety stop couldn''t be scheduled: {0}' -f $created.Error) -Evidence $evidence -Remediation 'Run setup-activity-control.ps1 again; until then, stop-demo.ps1 stops T4.' -DocUrl $doc)
    }
    # A new link ID each time: Azure Automation refused the ID of a link deleted moments earlier ("A jobSchedule with
    # same id already exists", Phase 25d live), and the link is found by its schedule's and runbook's names anyway.
    $linkId = [guid]::NewGuid().ToString()
    $linked = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, $linkId) -ApiVersion $version) -Body ([ordered]@{ properties = [ordered]@{ schedule = @{ name = $Name.SafetyStopSchedule }; runbook = @{ name = $Name.StopRunbook }; parameters = @{ Scope = 'T4' } } })
    if (-not $linked.Ok) {
        return (New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The daily T4 safety stop''s schedule exists, but it couldn''t be linked to DbHub-Stop: {0}' -f $linked.Error) -Evidence $evidence -Remediation 'Run setup-activity-control.ps1 again.' -DocUrl $doc)
    }
    return (New-DemoResult -CheckId 'CONTROL.SAFETYSTOP' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The daily T4 safety stop runs DbHub-Stop -Scope T4 at {0} ({1}), first at {2}; it stops T4 only when it''s running and never starts anything.' -f $when.LocalTime, $when.TimeZone, $when.StartTime) -Evidence $evidence -DocUrl $doc)
}

function Get-DemoT4SafetyStopState {
    <#
    .SYNOPSIS
    Whether the on-demand control's daily T4 safety stop is in place (ADR 0020): the schedule dbhub-t4-safety-stop, enabled
    and linked to DbHub-Stop, read as CONTROL.SAFETYSTOP reads it (Schedule - Get, Job Schedule - List). Returns State and
    NextRunUtc. Internal.

    .DESCRIPTION
    State: Off (control.enabled is false; nothing is read), Scheduled, NotScheduled (setup-activity-control.ps1 can end
    with "couldn't be scheduled"), or Unknown (a read failed for another reason than not found). stop-demo.ps1 and
    status.ps1 say from it whether anything stops a T4 that Azure started again after 7 days (Phase 28 follow-up, review of
    20e855c). Never throws.
    - Schedule: https://learn.microsoft.com/rest/api/automation/schedule/get
    - Job schedules: https://learn.microsoft.com/rest/api/automation/job-schedule/list-by-automation-account
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not (Get-DemoActivityControlSetting -Config $Config).Enabled) {
        return [pscustomobject]@{ State = 'Off'; NextRunUtc = $null }
    }
    try {
        $name = Get-DemoActivityControlName -Config $Config
        $version = '2024-10-23'
        $safety = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $name.SafetyStopSchedule) -ApiVersion $version)
        $links = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $name.AutomationAccountId) -ApiVersion $version)
        $linked = @(@(Get-DemoActivityControlList -InputObject $links.Value -Name 'value') | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'schedule') -Name 'name') -eq $name.SafetyStopSchedule }).Count -gt 0
        $properties = Get-DemoMemberValue -InputObject $safety.Value -Name 'properties'
        if ($safety.Ok -and [bool](Get-DemoMemberValue -InputObject $properties -Name 'isEnabled') -and $linked) {
            return [pscustomobject]@{ State = 'Scheduled'; NextRunUtc = (ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'nextRun')) }
        }
        if ((-not $safety.Ok -and -not $safety.Missing) -or -not $links.Ok) {
            return [pscustomobject]@{ State = 'Unknown'; NextRunUtc = $null }
        }
        return [pscustomobject]@{ State = 'NotScheduled'; NextRunUtc = $null }
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The daily T4 safety stop''s schedule couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return [pscustomobject]@{ State = 'Unknown'; NextRunUtc = $null }
    }
}

function Get-DemoActivityControlWebhook {
    <#
    .SYNOPSIS
    The control account's webhooks for DbHub-Control, newest expiry first (Name, Enabled, ExpiryUtc), and whether the
    secret exists. Metadata only: Azure never returns a webhook's URL after it's created. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $list = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/webhooks' -f $Name.AutomationAccountId) -ApiVersion '2024-10-23')
    $hooks = @(foreach ($item in @(Get-DemoActivityControlList -InputObject $list.Value -Name 'value')) {
            $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
            if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name') -ne $Name.ControlRunbook) {
                continue
            }
            [pscustomobject]@{
                Name      = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
                Enabled   = [bool](Get-DemoMemberValue -InputObject $properties -Name 'isEnabled')
                ExpiryUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $properties -Name 'expiryTime')
            }
        })
    $secret = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $Name.SecretId -ApiVersion '2026-02-01')
    $secretExpiry = $null
    $exp = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $secret.Value -Name 'properties') -Name 'attributes') -Name 'exp'
    if ($secret.Ok -and $null -ne $exp) {
        $secretExpiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$exp).UtcDateTime
    }
    return [pscustomobject]@{
        Read          = $list.Ok
        Error         = $list.Error
        Webhooks      = @($hooks | Sort-Object -Property { if ($_.ExpiryUtc) { $_.ExpiryUtc } else { [datetime]::MinValue } } -Descending)
        SecretExists  = $secret.Ok
        SecretExpiry  = $secretExpiry
    }
}

function Initialize-DemoActivityControlSessionSecret {
    <#
    .SYNOPSIS
    Creates the session's two secrets in the control vault when they don't exist (2026-11-14, ADR 0026):
    dbhub-session-status and dbhub-session-metrics, each with an empty JSON object, through Azure Resource Manager
    (Secrets - Create Or Update), which Contributor may and which works with the vault private. They must exist to be the
    scopes of A3 and A4; the runbook writes them during a session, and an existing one is never overwritten here.
    Returns CONTROL.SECRETS. Internal.
    https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $doc = 'https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update'
    $version = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.KeyVault/vaults/secrets'
    $created = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($secret in @([pscustomobject]@{ Name = $Name.StatusSecret; Id = $Name.StatusSecretId }, [pscustomobject]@{ Name = $Name.MetricsSecret; Id = $Name.MetricsSecretId })) {
        $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $secret.Id -ApiVersion $version)
        if ($read.Ok) {
            $kept.Add($secret.Name)
            continue
        }
        if (-not $read.Missing) {
            return (New-DemoResult -CheckId 'CONTROL.SECRETS' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The session''s secret {0} couldn''t be read: {1}' -f $secret.Name, $read.Error) -Remediation 'Run ./scripts/deploy.ps1 again.' -DocUrl $doc)
        }
        if (-not $PSCmdlet.ShouldProcess(('{0}/secrets/{1}' -f $Name.KeyVault, $secret.Name), 'Create the session''s secret with an empty JSON object')) {
            $created.Add(('{0} (what if)' -f $secret.Name))
            continue
        }
        $write = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id $secret.Id -ApiVersion $version) -Body ([ordered]@{ properties = [ordered]@{ value = '{}'; contentType = 'application/json' } })
        if (-not $write.Ok) {
            return (New-DemoResult -CheckId 'CONTROL.SECRETS' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The session''s secret {0} couldn''t be created: {1}' -f $secret.Name, $write.Error) -Remediation 'Run ./scripts/deploy.ps1 again; a Contributor on the control resource group can create it.' -DocUrl $doc)
        }
        $created.Add($secret.Name)
    }
    $text = @()
    if ($created.Count) {
        $text += ('created {0}' -f ($created -join ', '))
    }
    if ($kept.Count) {
        $text += ('kept {0}' -f ($kept -join ', '))
    }
    return (New-DemoResult -CheckId 'CONTROL.SECRETS' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The session''s secrets in {0}: {1}. The runbook writes a session''s status and metrics there, and the notebook reads them.' -f $Name.KeyVault, ($text -join '; ')) -Evidence ([ordered]@{ vault = $Name.KeyVault; created = $created.ToArray(); kept = $kept.ToArray() }) -DocUrl $doc)
}

function New-DemoActivityControlWebhook {
    <#
    .SYNOPSIS
    Creates a webhook for DbHub-Control and stores its URL as the secret dbhub-activity-webhook (a new version), then
    deletes the control's older webhooks. Returns CONTROL.WEBHOOK. Internal.

    .DESCRIPTION
    The URL comes from the documented generateUri call, is registered for redaction at once, and reaches
    infra/control/webhook.bicep only as a secure parameter in a file in a private directory, which is deleted
    afterwards; Azure Resource Manager keeps no secure parameter value in the deployment's history, and the template
    has no output. The URL is never printed, logged, or returned.
    - Webhook - Generate Uri: https://learn.microsoft.com/rest/api/automation/webhook/generate-uri
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $doc = 'https://learn.microsoft.com/azure/automation/automation-webhooks'
    $days = (Get-DemoActivityControlSetting -Config $Config).WebhookExpiryDays
    $expiry = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc).AddDays($days)
    $webhookName = '{0}{1}' -f $Name.WebhookPrefix, $NowUtc.ToString('yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture)
    $evidence = [ordered]@{ webhook = $webhookName; runbook = $Name.ControlRunbook; secret = ('{0}/{1}' -f $Name.KeyVault, $Name.Secret); expiresUtc = $expiry.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if (-not $PSCmdlet.ShouldProcess($Name.ControlRunbook, ('Create the webhook {0} (expires in {1} days) and store its URL in {2}' -f $webhookName, $days, $Name.KeyVault))) {
        return (New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: a webhook for {0} would be created, expiring in {1} days, with its URL stored only as the secret {2} in {3}.' -f $Name.ControlRunbook, $days, $Name.Secret, $Name.KeyVault) -Evidence $evidence -DocUrl $doc)
    }
    $before = Get-DemoActivityControlWebhook -Name $Name
    $generated = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method post -Url (Get-DemoActivityControlUrl -Id ('{0}/webhooks/generateUri' -f $Name.AutomationAccountId) -ApiVersion '2024-10-23')
    $uri = if ($generated.Ok -and $generated.Value -is [string]) { [string]$generated.Value } else { '' }
    if ($uri -notmatch '^https://[A-Za-z0-9.-]+\.azure-automation\.net/webhooks\?token=\S+$') {
        $uri = ''
        return (New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('No webhook URL could be generated: {0}' -f $(if ($generated.Error) { $generated.Error } else { 'the answer wasn''t a webhook URL' })) -Evidence $evidence -Remediation 'Run setup-activity-control.ps1 again.' -DocUrl $doc)
    }
    Register-DemoSecret -Value $uri
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            automationAccountName = @{ value = $Name.AutomationAccount }
            webhookName           = @{ value = $webhookName }
            webhookUri            = @{ value = $uri }
            expiryTime            = @{ value = $expiry.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
            expiryUnixTime        = @{ value = [DateTimeOffset]::new($expiry).ToUnixTimeSeconds() }
            runbookName           = @{ value = $Name.ControlRunbook }
            keyVaultName          = @{ value = $Name.KeyVault }
            secretName            = @{ value = $Name.Secret }
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-control'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'webhook.parameters.json' -Content (ConvertTo-Json -InputObject $parameters -Depth 8)
        $parameters = $null
        $uri = ''
        $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/control/webhook.bicep'
        $run = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $Name.ResourceGroup, '--name', $Name.WebhookDeployment, '--template-file', $template, '--parameters', "@$path", '--query', 'properties.provisioningState', '--output', 'tsv') -AllowFailure -TimeoutSeconds 900
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
    if ($run.ExitCode -ne 0) {
        return (New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('The webhook or its secret couldn''t be created: {0}' -f (Protect-DemoText -Text ([string]$run.StdErr)).Trim()) -Evidence $evidence -Remediation 'Run setup-activity-control.ps1 again; a webhook without its secret is replaced.' -DocUrl $doc)
    }
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($old in @($before.Webhooks | Where-Object { $_.Name -ne $webhookName -and $_.Name.StartsWith($Name.WebhookPrefix, [System.StringComparison]::Ordinal) })) {
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/webhooks/{1}' -f $Name.AutomationAccountId, $old.Name) -ApiVersion '2024-10-23')
        if ($delete.Ok) {
            $removed.Add($old.Name)
        }
    }
    $evidence['replaced'] = $removed.ToArray()
    return (New-DemoResult -CheckId 'CONTROL.WEBHOOK' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The webhook {0} starts {1} until {2:yyyy-MM-dd}; its URL is only in the secret {3} ({4}), never printed.{5}' -f $webhookName, $Name.ControlRunbook, $expiry, $Name.Secret, $Name.KeyVault, $(if ($removed.Count) { ' Replaced: ' + ($removed -join ', ') + '.' } else { '' })) -Evidence $evidence -DocUrl $doc)
}

function Get-DemoActivityControlSessionRule {
    <#
    .SYNOPSIS
    The session's rules for the control notebook's plan (2026-11-14), from the runbook's settings: the minimum minutes,
    the margin before the VMs' auto-shutdown, the auto-stop's buffer, and the auto-shutdown itself, with its zone's IANA
    name for Python (zoneinfo), which knows no Windows time zone ID. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $zone = [string]$Setting['autoShutdownTimeZone']
    $iana = ''
    if ($zone -and -not [System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($zone, [ref]$iana)) {
        $iana = if ($zone -match '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$' -or $zone -eq 'UTC') { $zone } else { '' }
    }
    return [ordered]@{
        minMinutes            = [int]$Setting['minSessionMinutes']
        shutdownMarginMinutes = [int]$Setting['shutdownMarginMinutes']
        autoStopBufferMinutes = [int]$Setting['autoStopBufferMinutes']
        autoShutdownTime      = [string]$Setting['autoShutdownTime']
        autoShutdownTimeZone  = $zone
        autoShutdownIana      = $(if ($iana) { $iana } else { 'UTC' })
    }
}

function Get-DemoActivityControlShowcase {
    <#
    .SYNOPSIS
    The showcase's beats for the control notebook's guide (2026-11-14), from scenarios/activity-profiles.json: its cycle,
    each incident slot as the runner reads it (target, scenario, startMinute, durationMinutes, and cycles, tier, and
    replica when set), and each scenario's title and the first Database Hub signal it fills (scenarios/<id>/scenario.json).
    Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $definition = (Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'scenarios/activity-profiles.json') -Raw | ConvertFrom-Json -AsHashtable)['profiles']['showcase']
    $slots = [System.Collections.Generic.List[object]]::new()
    $scenarios = [ordered]@{}
    foreach ($incident in @($definition['incidents'])) {
        $slot = [ordered]@{ target = [string]$incident['target']; scenario = [string]$incident['scenario']; startMinute = [int]$incident['startMinute']; durationMinutes = [int]$incident['durationMinutes'] }
        foreach ($key in 'cycles', 'tier') {
            if ($incident.ContainsKey($key)) {
                $slot[$key] = [string]$incident[$key]
            }
        }
        if ($incident.ContainsKey('replica')) {
            $slot['replica'] = [bool]$incident['replica']
        }
        $slots.Add($slot)
        if (-not $scenarios.Contains($slot['scenario'])) {
            # The first signal for the SQL targets and the first for T4 (its text starts with "T4"), Performance first:
            # what the guide says each beat fills.
            $scenario = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath ('scenarios/{0}/scenario.json' -f $slot['scenario'])) -Raw | ConvertFrom-Json -AsHashtable
            $signals = @($scenario['expectedHubSignals'] | Sort-Object -Stable -Property { if ($_['surface'] -eq 'Performance') { 0 } else { 1 } })
            $entry = [ordered]@{ title = [string]$scenario['title'] }
            foreach ($kind in 'sql', 't4') {
                $match = @($signals | Where-Object { ([string]$_['signal']).StartsWith('T4') -eq ($kind -eq 't4') }) | Select-Object -First 1
                if ($null -ne $match) {
                    $entry[$kind] = [ordered]@{ surface = [string]$match['surface']; signal = [string]$match['signal'] }
                }
            }
            $scenarios[$slot['scenario']] = $entry
        }
    }
    return [ordered]@{ cycleMinutes = [int]$definition['cycleMinutes']; incidents = $slots.ToArray(); scenarios = $scenarios }
}

function Get-DemoActivityControlNotebook {
    <#
    .SYNOPSIS
    The control notebook (fabric/control/NB_DatabaseHub_Control.ipynb) with its parameters cell filled for this
    environment: the vault URL and its secrets' names, the demo's names, its tenant, Fabric workspace, and lakehouse, the
    rules the runbook applies (the catalog and the session's), and the showcase's beats. No secret goes in: the notebook
    reads the webhook URL from the vault at run time. Returns a Fabric notebook definition
    (Get-DemoFabricNotebookDefinition). Internal.

    .DESCRIPTION
    With -DemoLakehouseId and -DemoWorkspaceId, the copy is bound to the demo's lakehouse as its default lakehouse
    (2026-11-14): Run all then saves each history in its own Spark session, a reference run of NB_DatabaseHub_LiveActivity
    (notebookutils.notebook.run), so no second Spark job is submitted for a small capacity to refuse (HTTP 430). Fabric
    blocks a reference run whose notebook names another lakehouse than the caller's. The repository's copy names none.
    - Reference run: https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run
    - Concurrency limits: https://learn.microsoft.com/fabric/data-engineering/spark-job-concurrency-and-queueing
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting,

        [AllowEmptyString()]
        [string] $TenantId = '',

        [AllowEmptyString()]
        [string] $DemoWorkspaceId = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $DemoLakehouseId = '',

        [AllowEmptyString()]
        [string] $DemoLakehouseName = ''
    )

    $path = Join-Path -Path $script:RepoRoot -ChildPath 'fabric/control/NB_DatabaseHub_Control.ipynb'
    $notebook = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $bind = [bool]($DemoLakehouseId -and $DemoWorkspaceId)
    $catalog = [ordered]@{ targets = @($Setting['targets'].Keys); scenarios = $Setting['scenarios']; profiles = $Setting['profiles']; minDurationMinutes = $Setting['minDurationMinutes']; maxDurationMinutes = $Setting['maxDurationMinutes']; session = (Get-DemoActivityControlSessionRule -Setting $Setting) }
    $values = [ordered]@{
        KEY_VAULT_URL       = $Name.KeyVaultUri
        WEBHOOK_SECRET_NAME = $Name.Secret
        STATUS_SECRET_NAME  = $Name.StatusSecret
        METRICS_SECRET_NAME = $Name.MetricsSecret
        RESOURCE_GROUP      = $Name.DemoResourceGroup
        T1_VM_NAME          = 'sqlvm01'
        T2_MACHINE_NAME     = [string]$Setting['t2GuestName']
        T3_SERVER_PREFIX    = [string]$Setting['t3ServerPrefix']
        DEMO_DATABASE       = [string]$Setting['demoDatabase']
        TENANT_ID           = $TenantId.ToLowerInvariant()
        DEMO_WORKSPACE_ID   = $DemoWorkspaceId.ToLowerInvariant()
        DEMO_LAKEHOUSE_ID   = $(if ($bind) { $DemoLakehouseId.ToLowerInvariant() } else { '' })
        CATALOG_JSON        = (ConvertTo-Json -InputObject $catalog -Depth 8 -Compress)
        SHOWCASE_JSON       = (ConvertTo-Json -InputObject (Get-DemoActivityControlShowcase) -Depth 8 -Compress)
    }
    $cell = @($notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' }) | Select-Object -First 1
    if ($null -eq $cell) {
        throw 'fabric/control/NB_DatabaseHub_Control.ipynb has no cell tagged parameters.'
    }
    $lines = @($cell['source'])
    foreach ($key in $values.Keys) {
        $literal = ConvertTo-Json -InputObject ([string]$values[$key]) -Compress
        $index = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($line) $line -match ('^{0} = ' -f [regex]::Escape($key)) })
        if ($index -lt 0) {
            throw ('The parameters cell has no {0} line.' -f $key)
        }
        $comment = ''
        $match = [regex]::Match($lines[$index], '\s+#.*$')
        if ($key -notin 'CATALOG_JSON', 'SHOWCASE_JSON' -and $match.Success) {
            $comment = $match.Value.TrimEnd("`n")
        }
        $lines[$index] = '{0} = {1}{2}{3}' -f $key, $literal, $comment, $(if ($lines[$index].EndsWith("`n")) { "`n" } else { '' })
    }
    $cell['source'] = $lines
    if ($bind) {
        # Get-DemoFabricNotebookDefinition fills the binding's IDs into metadata.dependencies.lakehouse.
        $lakehouseName = if ($DemoLakehouseName) { $DemoLakehouseName } else { 'LH_DatabaseHub' }
        $notebook['metadata']['dependencies'] = [ordered]@{ lakehouse = [ordered]@{ default_lakehouse_name = $lakehouseName } }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-control-nb'
    try {
        $file = Write-DemoPrivateFile -Directory $directory -Name 'NB_DatabaseHub_Control.ipynb' -Content (ConvertTo-Json -InputObject $notebook -Depth 64)
        if ($bind) {
            return (Get-DemoFabricNotebookDefinition -Path $file -DisplayName $Name.Notebook -LakehouseId $DemoLakehouseId.ToLowerInvariant() -LakehouseWorkspaceId $DemoWorkspaceId.ToLowerInvariant() -LakehouseName $lakehouseName)
        }
        return (Get-DemoFabricNotebookDefinition -Path $file -DisplayName $Name.Notebook)
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
}

function Get-DemoActivityControlFabricList {
    # Every item of a Fabric list API (value, following continuationUri). Returns StatusCode, Items, and Error. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    for ($page = 0; $page -lt 20 -and $next; $page++) {
        $response = Invoke-DemoFabricRequest -Method Get -Uri $next -Token $Token
        if ($response.StatusCode -ne 200) {
            return [pscustomobject]@{ StatusCode = $response.StatusCode; Items = $items.ToArray(); Error = (Get-DemoFabricErrorText -Response $response) }
        }
        foreach ($item in @(Get-DemoActivityControlList -InputObject $response.Body -Name 'value')) {
            $items.Add($item)
        }
        $next = [string](Get-DemoMemberValue -InputObject $response.Body -Name 'continuationUri')
    }
    return [pscustomobject]@{ StatusCode = 200; Items = $items.ToArray(); Error = '' }
}

function Set-DemoActivityControlFabric {
    <#
    .SYNOPSIS
    Puts the control notebook where it can read the vault, through documented Fabric REST calls only, and returns
    CONTROL.FABRIC.* results. Internal.

    .DESCRIPTION
    - public: the folder fabric.folderName (default "DBHub Control") in the existing workspace (Folders - Create Folder,
      a documented preview API; when it fails, the notebook goes in the workspace's root, a Warning), and the notebook
      in it. Its sessions start fast on the workspace's starter pool.
    - private: the workspace control.fabricWorkspaceName (default "DBHub Control") on the existing workspace's capacity,
      with outbound access protection left off (checked), a managed private endpoint to the vault, approved on the
      vault through Azure Resource Manager, and the notebook in it. A managed private endpoint creates a managed
      virtual network for the whole workspace, which turns off starter pools, so its sessions start in 3 to 5 minutes;
      that's why it's a separate workspace, not a folder.
    The capacity is never resumed, paused, or scaled: when it isn't Active, nothing is created (Manual action required).
    The notebook's default lakehouse is the demo's, resolved by name (read-only), so Run all saves each history in its
    own Spark session (CONTROL.FABRIC.LAKEHOUSE; a Warning, with the fallback it means, when it isn't resolved).
    - Folders: https://learn.microsoft.com/rest/api/fabric/core/folders/create-folder
    - Workspaces: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace
    - Network communication policy: https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-network-communication-policy
    - Managed private endpoints: https://learn.microsoft.com/rest/api/fabric/core/managed-private-endpoints/create-workspace-managed-private-endpoint
    - Key Vault private endpoint connections: https://learn.microsoft.com/rest/api/keyvault/keyvault/private-endpoint-connections/put
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('public', 'private')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting,

        [securestring] $Token,

        [ValidateRange(0, 60)]
        [int] $ApprovalWaitMinutes = 10
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $base = $script:FabricApiBaseUri
    $add = { param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation, [string] $DocUrl) $results.Add((New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl)) }
    $notebook = Get-DemoActivityControlNotebook -Name $Name -Setting $Setting -TenantId ([string]$Config['tenantId'])
    if ($WhatIfPreference -or -not $Token) {
        $plan = if ($Mode -eq 'public') { ('the folder "{0}" in the existing workspace, with {1} in it' -f $Name.FabricFolder, $Name.Notebook) } else { ('the workspace "{0}" on the existing workspace''s capacity, a managed private endpoint to {1} approved on the vault, and {2} in it' -f $Name.FabricWorkspace, $Name.KeyVault, $Name.Notebook) }
        & $add 'CONTROL.FABRIC.NOTEBOOK' 'Not selected' ('What if: {0} would be created through the Fabric REST API; the capacity is never resumed, paused, or scaled.' -f $plan) ([ordered]@{ mode = $Mode; notebookSha256 = $notebook.Sha256 }) '' 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'
        return $results.ToArray()
    }
    # The demo's workspace and lakehouse by name (Phase 26a, ADR 0021), read-only: deploy.ps1 and configure-fabric.ps1
    # create them. The lakehouse becomes the control notebook's default lakehouse (2026-11-14).
    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $Token -Confirm:$false
    $sharedId = [string]$resolution.WorkspaceId
    if ($sharedId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $why = @($resolution.Results | ForEach-Object { [string]$_.message }) -join ' '
        & $add 'CONTROL.FABRIC.NOTEBOOK' 'Manual action required' ('The demo''s Fabric workspace isn''t resolved, so the control notebook wasn''t imported. {0}' -f $why).Trim() @{} 'Run ./scripts/configure-fabric.ps1 or ./scripts/deploy.ps1 first (they create the workspace when fabric.createIfMissing is true), then run setup-activity-control.ps1 again.' 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces'
        return $results.ToArray()
    }
    $lakehouseId = [string]$resolution.LakehouseId
    if ($lakehouseId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $lakehouseId = ''
    }
    $lakehouseName = [string]$resolution.LakehouseName
    # The notebook runs the activity notebook in the demo's workspace and links to its report (2026-11-14).
    $notebook = Get-DemoActivityControlNotebook -Name $Name -Setting $Setting -TenantId ([string]$Config['tenantId']) -DemoWorkspaceId $sharedId -DemoLakehouseId $lakehouseId -DemoLakehouseName $lakehouseName
    $Config = $resolution.Config
    $workspaceCheck = @(Test-DemoFabricWorkspace -Config $Config -Token $Token)
    $capacity = @($workspaceCheck | Where-Object { $_.checkId -eq 'FABRIC.P5.CAPACITY' }) | Select-Object -First 1
    if ($null -eq $capacity -or $capacity.status -notin 'Pass', 'Warning') {
        & $add 'CONTROL.FABRIC.NOTEBOOK' 'Manual action required' ('The existing workspace''s capacity isn''t usable now ({0}), so nothing was created in Fabric; this script never resumes, pauses, or scales a capacity.' -f $(if ($null -ne $capacity) { $capacity.message } else { 'unknown' })) @{} 'When the capacity''s administrator has it Active, run setup-activity-control.ps1 again.' 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
        return $results.ToArray()
    }

    $targetWorkspace = $sharedId
    $folderId = ''
    if ($Mode -eq 'public') {
        $folderDoc = 'https://learn.microsoft.com/rest/api/fabric/core/folders/create-folder'
        $folders = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/folders' -f $base, $sharedId) -Token $Token
        $found = @($folders.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $Name.FabricFolder -and -not (Get-DemoMemberValue -InputObject $_ -Name 'parentFolderId') }) | Select-Object -First 1
        if ($null -ne $found) {
            $folderId = [string](Get-DemoMemberValue -InputObject $found -Name 'id')
            & $add 'CONTROL.FABRIC.FOLDER' 'Pass' ('The folder "{0}" exists in the workspace.' -f $Name.FabricFolder) ([ordered]@{ folder = $Name.FabricFolder }) '' $folderDoc
        }
        elseif ($folders.StatusCode -eq 200 -and $PSCmdlet.ShouldProcess(('workspace {0}' -f $sharedId), ('Create the folder "{0}"' -f $Name.FabricFolder))) {
            # Creates here aren't looked up again by name, so each is sent again only when it never reached the service.
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/folders' -f $base, $sharedId) -Body ([ordered]@{ displayName = $Name.FabricFolder }) -Token $Token -NotIdempotent
            if ($created.StatusCode -in 200, 201) {
                $folderId = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'id')
                & $add 'CONTROL.FABRIC.FOLDER' 'Pass' ('The folder "{0}" was created in the workspace (Folders - Create Folder, a documented preview API).' -f $Name.FabricFolder) ([ordered]@{ folder = $Name.FabricFolder }) '' $folderDoc
            }
            else {
                & $add 'CONTROL.FABRIC.FOLDER' 'Warning' ('The folder "{0}" couldn''t be created ({1}), so the notebook goes in the workspace''s root.' -f $Name.FabricFolder, (Get-DemoFabricErrorText -Response $created)) ([ordered]@{ folder = $Name.FabricFolder }) 'Move the notebook into a folder in the workspace yourself if you like; nothing depends on the folder.' $folderDoc
            }
        }
        else {
            & $add 'CONTROL.FABRIC.FOLDER' 'Warning' ('The workspace''s folders couldn''t be listed ({0}), so the notebook goes in the workspace''s root.' -f $folders.Error) ([ordered]@{ folder = $Name.FabricFolder }) 'Nothing depends on the folder.' $folderDoc
        }
    }
    else {
        $workspaceDoc = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace'
        $shared = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/workspaces/{1}' -f $base, $sharedId) -Token $Token
        $capacityId = [string](Get-DemoMemberValue -InputObject $shared.Body -Name 'capacityId')
        $workspaces = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces' -f $base) -Token $Token
        $found = @($workspaces.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $Name.FabricWorkspace }) | Select-Object -First 1
        if ($null -ne $found) {
            $targetWorkspace = [string](Get-DemoMemberValue -InputObject $found -Name 'id')
            & $add 'CONTROL.FABRIC.WORKSPACE' 'Pass' ('The workspace "{0}" exists.' -f $Name.FabricWorkspace) ([ordered]@{ workspace = $Name.FabricWorkspace }) '' $workspaceDoc
        }
        elseif (-not $capacityId -or $workspaces.StatusCode -ne 200) {
            & $add 'CONTROL.FABRIC.WORKSPACE' 'Fail' ('The workspace "{0}" couldn''t be prepared: the existing workspace''s capacity or the workspace list couldn''t be read ({1}).' -f $Name.FabricWorkspace, $workspaces.Error) @{} 'Check your Fabric access, then run setup-activity-control.ps1 again.' $workspaceDoc
            return $results.ToArray()
        }
        elseif (-not $PSCmdlet.ShouldProcess($Name.FabricWorkspace, 'Create the control workspace on the existing workspace''s capacity')) {
            return $results.ToArray()
        }
        else {
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces' -f $base) -Body ([ordered]@{ displayName = $Name.FabricWorkspace; description = 'The Database Hub demo''s session control (ADR 0026): NB_DatabaseHub_Control, whose Run all runs a whole demo session, and its managed private endpoint to the control vault.'; capacityId = $capacityId }) -Token $Token -NotIdempotent
            if ($created.StatusCode -notin 200, 201) {
                & $add 'CONTROL.FABRIC.WORKSPACE' 'Fail' ('The workspace "{0}" couldn''t be created: {1}' -f $Name.FabricWorkspace, (Get-DemoFabricErrorText -Response $created)) @{} 'Creating a workspace needs the Fabric tenant setting that allows it and a role on the capacity; then run setup-activity-control.ps1 again.' $workspaceDoc
                return $results.ToArray()
            }
            $targetWorkspace = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'id')
            & $add 'CONTROL.FABRIC.WORKSPACE' 'Pass' ('The workspace "{0}" was created on the existing workspace''s capacity.' -f $Name.FabricWorkspace) ([ordered]@{ workspace = $Name.FabricWorkspace }) '' $workspaceDoc
        }

        $policyDoc = 'https://learn.microsoft.com/fabric/security/workspace-outbound-access-protection-data-engineering'
        $policy = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/workspaces/{1}/networking/communicationPolicy' -f $base, $targetWorkspace) -Token $Token
        $outbound = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $policy.Body -Name 'outbound') -Name 'publicAccessRules') -Name 'defaultAction')
        if ($policy.StatusCode -eq 200 -and $outbound -eq 'Deny') {
            & $add 'CONTROL.FABRIC.OUTBOUND' 'Fail' ('Outbound access protection is on in "{0}", so its notebook can''t reach the webhook or the telemetry endpoint.' -f $Name.FabricWorkspace) @{} 'Turn outbound access protection off in the workspace''s network settings (it stays off for the control workspace), then run setup-activity-control.ps1 again.' $policyDoc
        }
        elseif ($policy.StatusCode -eq 200) {
            & $add 'CONTROL.FABRIC.OUTBOUND' 'Pass' ('Outbound access protection is off in "{0}", so its notebook reaches the webhook and the telemetry endpoint.' -f $Name.FabricWorkspace) @{} '' $policyDoc
        }
        else {
            & $add 'CONTROL.FABRIC.OUTBOUND' 'Warning' ('The workspace''s outbound access protection couldn''t be read ({0}); it''s off by default.' -f (Get-DemoFabricErrorText -Response $policy)) @{} 'Check it in the workspace''s network settings.' $policyDoc
        }

        $endpointDoc = 'https://learn.microsoft.com/fabric/security/security-managed-private-endpoints-create'
        $request = 'DBHub Control notebook to the control vault (ADR 0020)'
        $endpoints = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints' -f $base, $targetWorkspace) -Token $Token
        $endpoint = @($endpoints.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $Name.PrivateEndpoint }) | Select-Object -First 1
        if ($null -eq $endpoint -and $PSCmdlet.ShouldProcess($Name.FabricWorkspace, ('Create the managed private endpoint {0} to {1}' -f $Name.PrivateEndpoint, $Name.KeyVault))) {
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints' -f $base, $targetWorkspace) -Body ([ordered]@{ name = $Name.PrivateEndpoint; targetPrivateLinkResourceId = $Name.KeyVaultId; targetSubresourceType = 'vault'; requestMessage = $request }) -Token $Token -NotIdempotent
            if ($created.StatusCode -notin 200, 201, 202) {
                & $add 'CONTROL.FABRIC.ENDPOINT' 'Fail' ('The managed private endpoint couldn''t be created: {0}' -f (Get-DemoFabricErrorText -Response $created)) @{} 'Creating it needs the Admin role in the control workspace; then run setup-activity-control.ps1 again.' $endpointDoc
                return $results.ToArray()
            }
        }
        $approved = $false
        $deadline = [DateTime]::UtcNow.AddMinutes($ApprovalWaitMinutes)
        do {
            $connections = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/privateEndpointConnections' -f $Name.KeyVaultId) -ApiVersion '2026-02-01')
            foreach ($connection in @(Get-DemoActivityControlList -InputObject $connections.Value -Name 'value')) {
                $state = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $connection -Name 'properties') -Name 'privateLinkServiceConnectionState'
                $status = [string](Get-DemoMemberValue -InputObject $state -Name 'status')
                if ($status -eq 'Approved' -and [string](Get-DemoMemberValue -InputObject $state -Name 'description') -match 'ADR 0020') {
                    $approved = $true
                }
                elseif ($status -eq 'Pending' -and [string](Get-DemoMemberValue -InputObject $state -Name 'description') -eq $request) {
                    $body = [ordered]@{ properties = [ordered]@{ privateLinkServiceConnectionState = [ordered]@{ status = 'Approved'; description = 'Approved by setup-activity-control.ps1 for the DBHub Control workspace (ADR 0020)' } } }
                    $put = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method put -Url (Get-DemoActivityControlUrl -Id ([string](Get-DemoMemberValue -InputObject $connection -Name 'id')) -ApiVersion '2026-02-01') -Body $body
                    $approved = $put.Ok
                }
            }
            if (-not $approved -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Seconds 30
            }
        } while (-not $approved -and [DateTime]::UtcNow -lt $deadline)
        if ($approved) {
            & $add 'CONTROL.FABRIC.ENDPOINT' 'Pass' ('The managed private endpoint {0} from "{1}" to {2} is approved on the vault.' -f $Name.PrivateEndpoint, $Name.FabricWorkspace, $Name.KeyVault) @{} '' $endpointDoc
        }
        else {
            & $add 'CONTROL.FABRIC.ENDPOINT' 'Manual action required' ('The managed private endpoint to {0} isn''t approved yet (Fabric creates it in a few minutes).' -f $Name.KeyVault) @{} ('Run setup-activity-control.ps1 again in a few minutes, or approve the pending connection in the vault''s Networking > Private endpoint connections in the Azure portal.') $endpointDoc
        }
    }

    $import = @{ WorkspaceId = $targetWorkspace; Notebook = $notebook; Token = $Token; Description = 'One Run all runs a whole Database Hub demo session (ADR 0026); imported by deploy.ps1.'; Confirm = $false }
    if ($folderId) {
        $import['FolderId'] = $folderId
    }
    $imported = Import-DemoFabricNotebook @import
    $results.Add((New-DemoResult -CheckId 'CONTROL.FABRIC.NOTEBOOK' -Area 'fabric' -Target 'fabric' -Status ([string]$imported.status) -Message ('{0} {1}' -f $Name.Notebook, [string]$imported.message) -Evidence ([ordered]@{ workspace = $(if ($Mode -eq 'public') { 'existing' } else { $Name.FabricWorkspace }); folder = $(if ($folderId) { $Name.FabricFolder } else { '' }); mode = $Mode }) -Remediation ([string]$imported.remediation) -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'))
    if ([string]$imported.status -eq 'Pass') {
        # A reference run uses the caller's Spark session, so the history needs no second Spark job (2026-11-14).
        $runDoc = 'https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run'
        if ($lakehouseId) {
            & $add 'CONTROL.FABRIC.LAKEHOUSE' 'Pass' ('{0}''s default lakehouse is the demo''s "{1}", so Run all saves each session''s history in its own Spark session, with no second Spark job for the capacity to admit.' -f $Name.Notebook, $lakehouseName) ([ordered]@{ lakehouseName = $lakehouseName }) '' $runDoc
        }
        else {
            $why = (@($resolution.Results | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'FABRIC.RESOLVE.LAKEHOUSE' } | ForEach-Object { ([string]$_.message).TrimEnd('.') }) -join '; ')
            & $add 'CONTROL.FABRIC.LAKEHOUSE' 'Warning' ('{0} isn''t attached to the demo''s lakehouse ({1}), so Run all saves each history with a separate Spark job, which a capacity whose Spark cores are all in use refuses (HTTP 430); the notebook then says so, with the fix.' -f $Name.Notebook, $(if ($why) { $why } else { 'it wasn''t resolved' })) @{} 'Run ./scripts/deploy.ps1 again: it creates the lakehouse when it''s missing and attaches it to the notebook.' $runDoc
        }
    }
    return $results.ToArray()
}

function Test-DemoActivityControlRole {
    <#
    .SYNOPSIS
    Read-only: whether the control's roles and assignments are in place (ADR 0020; A4 and A3's session secrets since
    2026-11-14, ADR 0026). Returns CONTROL.ROLE.DEFINITION (the operator role has every approved action),
    CONTROL.ROLE.<A1|A2|A3|A4>: Pass when present, a Warning with the exact grant command (./scripts/grant-safety-stop.ps1)
    when missing, as the safety stop's role is, and a Warning when it can't be read. A3 passes when someone holds Key
    Vault Secrets User on each of the three secrets. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('A1', 'A2', 'A3', 'A4')]
        [string[]] $Assignment = @('A1', 'A2', 'A3', 'A4'),

        [string] $ConfigPath = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $name = Get-DemoActivityControlName -Config $Config
    $command = Get-DemoActivityControlGrantCommand -ConfigPath $ConfigPath
    $doc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-list-rest'
    $missing = { param([string] $CheckId, [string] $Message) $results.Add((New-DemoResult -CheckId $CheckId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $Message -Remediation ('An Owner of the subscription runs, signed in with multifactor authentication: {0}' -f $command) -DocUrl $doc)) }
    $operator = $null
    $writerId = ''
    try {
        $operator = Get-DemoActivityControlRoleId -SubscriptionId $name.SubscriptionId -RoleName $name.RoleName -WithActions
        if ('A4' -in $Assignment) {
            $writerId = Get-DemoActivityControlRoleId -SubscriptionId $name.SubscriptionId -RoleName $name.WriterRoleName
        }
    }
    catch {
        foreach ($item in $Assignment) {
            $results.Add((New-DemoResult -CheckId ('CONTROL.ROLE.{0}' -f $item) -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t checked: {1}' -f $item, (Protect-DemoText -Text $_.Exception.Message)) -DocUrl $doc))
        }
        return $results.ToArray()
    }
    $roleId = [string]$operator.Id
    if ($roleId -and ('A1' -in $Assignment -or 'A2' -in $Assignment)) {
        # An environment set up before 2026-11-14 has the role with its first 22 actions: the session then runs without its
        # read replica, the busy marker, and the history's metrics, and says so.
        $lacking = @($script:ActivityControlRoleActions | Where-Object { $_ -notin @($operator.Actions) })
        if ($lacking.Count -gt 0) {
            & $missing 'CONTROL.ROLE.DEFINITION' ('The custom role "{0}" lacks {1} of its approved actions ({2}), so a session in the control notebook runs without T4''s read replica, the busy marker, or the history''s metrics.' -f $name.RoleName, $lacking.Count, ($lacking -join ', '))
        }
    }
    $principalId = Get-DemoActivityControlPrincipalId -Name $name
    $secrets = @(
        [pscustomobject]@{ Name = $name.Secret; Id = $name.SecretId; Why = 'the notebook can''t read the webhook URL' }
        [pscustomobject]@{ Name = $name.StatusSecret; Id = $name.StatusSecretId; Why = 'the notebook can''t follow a session' }
        [pscustomobject]@{ Name = $name.MetricsSecret; Id = $name.MetricsSecretId; Why = 'the notebook can''t save the replica''s metrics in the history' }
    )
    $holders = {
        param([string] $Scope, [string] $RoleGuid, [string] $PrincipalId)
        $read = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments?$filter=atScope()&api-version=2022-04-01' -f $Scope)
        if (-not $read.Ok) {
            return [pscustomobject]@{ Ok = $false; Missing = $read.Missing; Error = $read.Error; Count = 0 }
        }
        $found = @(@(Get-DemoActivityControlList -InputObject $read.Value -Name 'value') | Where-Object {
                $properties = Get-DemoMemberValue -InputObject $_ -Name 'properties'
                ([string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')).EndsWith('/' + $RoleGuid, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string](Get-DemoMemberValue -InputObject $properties -Name 'scope'), $Scope, [System.StringComparison]::OrdinalIgnoreCase) -and
                (-not $PrincipalId -or [string](Get-DemoMemberValue -InputObject $properties -Name 'principalId') -eq $PrincipalId)
            })
        return [pscustomobject]@{ Ok = $true; Missing = $false; Error = ''; Count = $found.Count }
    }
    foreach ($item in $Assignment) {
        $checkId = 'CONTROL.ROLE.{0}' -f $item
        if ($item -in 'A3', 'A4') {
            $wanted = if ($item -eq 'A3') { $secrets } else { @($secrets | Select-Object -Skip 1) }
            if ($item -eq 'A4' -and -not $writerId) {
                & $missing $checkId ('A4 isn''t in place: the custom role "{0}" doesn''t exist yet, so the runbook can''t write a session''s status or metrics for the notebook.' -f $name.WriterRoleName)
                continue
            }
            if ($item -eq 'A4' -and -not $principalId) {
                & $missing $checkId ('A4 isn''t in place: the identity {0} doesn''t exist yet; ./scripts/deploy.ps1 creates it.' -f $name.Identity)
                continue
            }
            $gaps = [System.Collections.Generic.List[string]]::new()
            $unread = ''
            foreach ($secret in $wanted) {
                $count = if ($item -eq 'A3') { & $holders $secret.Id $script:VaultReaderRoleGuid '' } else { & $holders $secret.Id $writerId $principalId }
                if (-not $count.Ok -and -not $count.Missing) {
                    $unread = $count.Error
                }
                elseif ($count.Missing -or $count.Count -eq 0) {
                    $gaps.Add($(if ($item -eq 'A3') { '{0} ({1})' -f $secret.Name, $secret.Why } else { $secret.Name }))
                }
            }
            if ($unread) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t checked: {1}' -f $item, $unread) -DocUrl $doc))
            }
            elseif ($gaps.Count -gt 0) {
                $what = if ($item -eq 'A3') { 'nobody holds Key Vault Secrets User on' } else { ('{0} doesn''t hold "{1}" on' -f $name.Identity, $name.WriterRoleName) }
                & $missing $checkId ('{0} isn''t in place: {1} {2}.' -f $item, $what, ($gaps -join '; '))
            }
            else {
                $text = if ($item -eq 'A3') { 'A3: Key Vault Secrets User is held on the secrets {0} only.' -f (@($wanted | ForEach-Object { $_.Name }) -join ', ') } else { 'A4: {0} holds "{1}" on the secrets {2} only.' -f $name.Identity, $name.WriterRoleName, (@($wanted | ForEach-Object { $_.Name }) -join ', ') }
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message $text -DocUrl $doc))
            }
            continue
        }
        $scope = if ($item -eq 'A1') { $name.DemoResourceGroupId } else { $name.AutomationAccountId }
        $label = if ($item -eq 'A1') { $name.DemoResourceGroup } else { $name.AutomationAccount }
        if (-not $roleId) {
            & $missing $checkId ('{0} isn''t in place: the custom role "{1}" doesn''t exist yet.' -f $item, $name.RoleName)
            continue
        }
        if (-not $principalId) {
            & $missing $checkId ('{0} isn''t in place: the identity {1} doesn''t exist yet; ./scripts/deploy.ps1 creates it.' -f $item, $name.Identity)
            continue
        }
        $existing = Test-DemoActivityControlAssignment -SubscriptionId $name.SubscriptionId -Scope $scope -PrincipalId $principalId -RoleId $roleId
        if ($existing.Exists) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0}: {1} holds "{2}" at {3}.' -f $item, $name.Identity, $name.RoleName, $label) -DocUrl $doc))
        }
        elseif ($existing.Missing -and $item -eq 'A1') {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('A1 has no scope: {0} doesn''t exist (not deployed).' -f $label) -DocUrl $doc))
        }
        elseif ($existing.Error) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t checked: {1}' -f $item, $existing.Error) -DocUrl $doc))
        }
        else {
            $why = if ($item -eq 'A1') { ' A redeploy deletes it with the group; deploy.ps1 grants it again when you may.' } else { '' }
            & $missing $checkId ('{0} isn''t in place: {1} doesn''t hold "{2}" at {3}, so the runbooks can''t act there.{4}' -f $item, $name.Identity, $name.RoleName, $label, $why)
        }
    }
    return $results.ToArray()
}

function Remove-DemoActivityControlRole {
    <#
    .SYNOPSIS
    Deletes A1, A2, and A3 (every assignment of the custom role to the automation identity, and every Key Vault Secrets
    User assignment on the secret), then the custom role when nothing else holds it. Returns CONTROL.REMOVE.ROLES.
    Internal.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $doc = 'https://learn.microsoft.com/rest/api/authorization/role-assignments/delete'
    $roleId = ''
    $writerId = ''
    try {
        $roleId = Get-DemoActivityControlRoleId -SubscriptionId $Name.SubscriptionId -RoleName $Name.RoleName
        $writerId = Get-DemoActivityControlRoleId -SubscriptionId $Name.SubscriptionId -RoleName $Name.WriterRoleName
    }
    catch {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The role assignments weren''t removed: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -DocUrl $doc)
    }
    $targets = [System.Collections.Generic.List[string]]::new()
    $principalId = Get-DemoActivityControlPrincipalId -Name $Name
    if ($principalId -and ($roleId -or $writerId)) {
        $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments' -f $Name.SubscriptionId) -Query ([ordered]@{ '$filter' = ("principalId eq '{0}'" -f $principalId); 'api-version' = '2022-04-01' })
        foreach ($item in @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value')) {
            $definition = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'properties') -Name 'roleDefinitionId')
            if (($roleId -and $definition.EndsWith('/' + $roleId, [System.StringComparison]::OrdinalIgnoreCase)) -or ($writerId -and $definition.EndsWith('/' + $writerId, [System.StringComparison]::OrdinalIgnoreCase))) {
                $targets.Add([string](Get-DemoMemberValue -InputObject $item -Name 'id'))
            }
        }
    }
    foreach ($secretId in $Name.SecretId, $Name.StatusSecretId, $Name.MetricsSecretId) {
        $secretRead = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments?$filter=atScope()&api-version=2022-04-01' -f $secretId)
        foreach ($item in @(Get-DemoActivityControlList -InputObject $secretRead.Value -Name 'value')) {
            $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
            if (([string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')).EndsWith('/' + $script:VaultReaderRoleGuid, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string](Get-DemoMemberValue -InputObject $properties -Name 'scope'), $secretId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $targets.Add([string](Get-DemoMemberValue -InputObject $item -Name 'id'))
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess(('{0} role assignment(s) and the custom roles "{1}" and "{2}"' -f $targets.Count, $Name.RoleName, $Name.WriterRoleName), 'Delete')) {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} role assignment(s) (A1-A4) and the custom roles "{1}" and "{2}" would be deleted.' -f $targets.Count, $Name.RoleName, $Name.WriterRoleName) -DocUrl $doc)
    }
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $targets) {
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url ('https://management.azure.com{0}?api-version=2022-04-01' -f $id)
        if (-not $delete.Ok -and -not $delete.Missing) {
            $failed.Add($delete.Error)
        }
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($role in @(@{ Id = $roleId; Label = 'the custom role' }, @{ Id = $writerId; Label = ('the custom role "{0}"' -f $Name.WriterRoleName) })) {
        if (-not $role.Id) {
            $notes.Add(('{0} didn''t exist' -f $role.Label))
            continue
        }
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version=2022-04-01' -f $Name.SubscriptionId, $role.Id)
        $notes.Add($(if ($delete.Ok -or $delete.Missing) { '{0} was deleted' -f $role.Label } else { '{0} was kept ({1})' -f $role.Label, $delete.Error }))
    }
    $roleNote = $notes -join '; '
    $status = if ($failed.Count -gt 0) { 'Manual action required' } else { 'Pass' }
    return (New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status $status -Message ('{0} of {1} role assignment(s) deleted; {2}.{3}' -f ($targets.Count - $failed.Count), $targets.Count, $roleNote, $(if ($failed.Count) { ' Failed: ' + ($failed -join '; ') } else { '' })) -Remediation $(if ($failed.Count) { 'Deleting role assignments needs Owner or User Access Administrator, signed in with multifactor authentication.' } else { '' }) -DocUrl $doc)
}

function Remove-DemoActivityControlResource {
    <#
    .SYNOPSIS
    Deletes the control's Azure resources one by one (the Automation account with its runbooks, schedules, and webhook;
    the identity; the vault, then purges it), and the group only when nothing else is left in it (it may also hold
    the GitHub OIDC identity, ADR 0002). Returns CONTROL.REMOVE.RESOURCES. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $doc = 'https://learn.microsoft.com/azure/key-vault/general/key-vault-recovery'
    if (-not $PSCmdlet.ShouldProcess($Name.ResourceGroup, ('Delete {0}, {1}, and {2} (then purge it)' -f $Name.AutomationAccount, $Name.Identity, $Name.KeyVault))) {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0}, {1}, and {2} would be deleted and the vault purged; {3} would be deleted only if nothing else is left in it.' -f $Name.AutomationAccount, $Name.Identity, $Name.KeyVault, $Name.ResourceGroup) -DocUrl $doc)
    }
    $done = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(
            @{ Label = $Name.AutomationAccount; Url = (Get-DemoActivityControlUrl -Id $Name.AutomationAccountId -ApiVersion '2024-10-23') }
            @{ Label = $Name.Identity; Url = (Get-DemoActivityControlUrl -Id $Name.IdentityId -ApiVersion '2024-11-30') }
            @{ Label = $Name.KeyVault; Url = (Get-DemoActivityControlUrl -Id $Name.KeyVaultId -ApiVersion '2026-02-01') }
        )) {
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url $item.Url
        if ($delete.Ok -or $delete.Missing) {
            $done.Add($item.Label)
        }
        else {
            $failed.Add(('{0}: {1}' -f $item.Label, $delete.Error))
        }
    }
    $purge = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method post -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.KeyVault/locations/{1}/deletedVaults/{2}/purge?api-version=2026-02-01' -f $Name.SubscriptionId, [string]$Config['location'], $Name.KeyVault)
    if ($purge.Ok) {
        $done.Add('the vault purge')
    }
    elseif (-not $purge.Missing) {
        $failed.Add(('purge: {0}' -f $purge.Error))
    }
    foreach ($deployment in $Name.TemplateDeployment, $Name.WebhookDeployment) {
        $null = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('deployment', 'group', 'delete', '--resource-group', $Name.ResourceGroup, '--name', $deployment) -AllowFailure
    }
    $left = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('resource', 'list', '--resource-group', $Name.ResourceGroup, '--query', 'length(@)', '--output', 'tsv') -AllowFailure
    $groupNote = ''
    if ($left.ExitCode -eq 0 -and ([string]$left.StdOut).Trim() -eq '0') {
        $group = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('group', 'delete', '--name', $Name.ResourceGroup, '--yes', '--no-wait') -AllowFailure
        $groupNote = if ($group.ExitCode -eq 0) { (' {0} was empty and is being deleted.' -f $Name.ResourceGroup) } else { (' {0} couldn''t be deleted: {1}' -f $Name.ResourceGroup, (Protect-DemoText -Text ([string]$group.StdErr)).Trim()) }
    }
    elseif ($left.ExitCode -eq 0) {
        $groupNote = (' {0} was kept: it holds {1} other resource(s), for example the GitHub OIDC identity.' -f $Name.ResourceGroup, ([string]$left.StdOut).Trim())
    }
    $status = if ($failed.Count -gt 0) { 'Fail' } else { 'Pass' }
    return (New-DemoResult -CheckId 'CONTROL.REMOVE.RESOURCES' -Area 'workload' -Target 'subscription' -Status $status -Message ('Deleted: {0}.{1}{2}' -f ($done -join ', '), $(if ($failed.Count) { ' Failed: ' + ($failed -join '; ') + '.' } else { '' }), $groupNote) -Remediation $(if ($failed.Count) { 'Run setup-activity-control.ps1 -Remove again.' } else { '' }) -DocUrl $doc)
}

function Remove-DemoActivityControlFabric {
    <#
    .SYNOPSIS
    Deletes the control notebook (and its folder, when it's empty) from the existing workspace, and the control
    workspace with its managed private endpoint, through documented Fabric REST calls. Returns CONTROL.REMOVE.FABRIC.
    Internal.
    - Delete Item: https://learn.microsoft.com/rest/api/fabric/core/items/delete-item
    - Delete Folder: https://learn.microsoft.com/rest/api/fabric/core/folders/delete-folder
    - Delete Managed Private Endpoint: https://learn.microsoft.com/rest/api/fabric/core/managed-private-endpoints/delete-workspace-managed-private-endpoint
    - Delete Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/delete-workspace
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [securestring] $Token
    )

    $doc = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/delete-workspace'
    if (-not $PSCmdlet.ShouldProcess('Fabric', ('Delete {0}, the folder "{1}" when empty, and the workspace "{2}" with its managed private endpoint' -f $Name.Notebook, $Name.FabricFolder, $Name.FabricWorkspace))) {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.FABRIC' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('What if: {0} would be deleted from the existing workspace (and its folder "{1}" when empty), and the workspace "{2}" with its managed private endpoint.' -f $Name.Notebook, $Name.FabricFolder, $Name.FabricWorkspace) -DocUrl $doc)
    }
    if (-not $Token) {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.FABRIC' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'No Fabric token, so nothing was removed from Fabric.' -Remediation ('Delete {0} and the workspace "{1}" in Fabric yourself.' -f $Name.Notebook, $Name.FabricWorkspace) -DocUrl $doc)
    }
    $base = $script:FabricApiBaseUri
    $done = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    # The demo workspace by name (Phase 26a, ADR 0021), read-only: removing the control never creates anything.
    $sharedId = [string](Resolve-DemoFabricConfig -Config $Config -Token $Token -SkipLakehouse -Confirm:$false).WorkspaceId
    if ($sharedId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $found = Find-DemoFabricItem -WorkspaceId $sharedId -DisplayName $Name.Notebook -Type 'Notebook' -Token $Token
        foreach ($item in @($found.Items)) {
            $delete = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}/items/{2}' -f $base, $sharedId, [string](Get-DemoMemberValue -InputObject $item -Name 'id')) -Token $Token
            if ($delete.StatusCode -in 200, 204) { $done.Add($Name.Notebook) } else { $failed.Add((Get-DemoFabricErrorText -Response $delete)) }
        }
        $folders = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/folders' -f $base, $sharedId) -Token $Token
        foreach ($folder in @($folders.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $Name.FabricFolder })) {
            $delete = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}/folders/{2}' -f $base, $sharedId, [string](Get-DemoMemberValue -InputObject $folder -Name 'id')) -Token $Token
            if ($delete.StatusCode -in 200, 204) { $done.Add(('the folder "{0}"' -f $Name.FabricFolder)) } else { $done.Add(('the folder "{0}" kept (not empty)' -f $Name.FabricFolder)) }
        }
    }
    $workspaces = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces' -f $base) -Token $Token
    foreach ($workspace in @($workspaces.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $Name.FabricWorkspace })) {
        $id = [string](Get-DemoMemberValue -InputObject $workspace -Name 'id')
        $endpoints = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints' -f $base, $id) -Token $Token
        foreach ($endpoint in @($endpoints.Items)) {
            $null = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints/{2}' -f $base, $id, [string](Get-DemoMemberValue -InputObject $endpoint -Name 'id')) -Token $Token
        }
        $delete = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}' -f $base, $id) -Token $Token
        if ($delete.StatusCode -in 200, 204) { $done.Add(('the workspace "{0}"' -f $Name.FabricWorkspace)) } else { $failed.Add((Get-DemoFabricErrorText -Response $delete)) }
    }
    $status = if ($failed.Count -gt 0) { 'Manual action required' } else { 'Pass' }
    return (New-DemoResult -CheckId 'CONTROL.REMOVE.FABRIC' -Area 'fabric' -Target 'fabric' -Status $status -Message ('Fabric: {0}.{1}' -f $(if ($done.Count) { ($done -join ', ') + ' removed' } else { 'nothing to remove' }), $(if ($failed.Count) { ' Failed: ' + ($failed -join '; ') } else { '' })) -Remediation $(if ($failed.Count) { 'Delete what''s left in Fabric yourself (it needs the Admin role in the control workspace).' } else { '' }) -DocUrl $doc)
}

function Get-DemoActivityControlActiveJob {
    <#
    .SYNOPSIS
    One control runbook's jobs that are queued or running, from Job - List By Automation Account
    (https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account). A control Automation account or
    group that doesn't exist has none. Returns Ok, Error, and Jobs (Id and Status). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Name,

        [Parameter(Mandatory)]
        [string] $Runbook
    )

    $jobs = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/jobs' -f $Name.AutomationAccountId) -Query ([ordered]@{ '$filter' = ("properties/runbook/name eq '{0}'" -f $Runbook); 'api-version' = '2024-10-23' })
    if (-not $jobs.Ok -and -not $jobs.Missing) {
        return [pscustomobject]@{ Ok = $false; Error = $jobs.Error; Jobs = @() }
    }
    $active = [System.Collections.Generic.List[object]]::new()
    foreach ($job in @(Get-DemoActivityControlList -InputObject $jobs.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $job -Name 'properties'
        $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
        $name = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name')
        if ($name -eq $Runbook -and $status -in $script:ActivityControlActiveJobStatuses) {
            $active.Add([pscustomobject]@{ Id = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobId'); Status = $status })
        }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Jobs = $active.ToArray() }
}

function Get-DemoActivityControlActiveStopJob {
    <#
    .SYNOPSIS
    The control's DbHub-Stop jobs that are queued or running (Get-DemoActivityControlActiveJob). Returns Ok, Error, and
    Jobs (Id and Status). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Name
    )

    return (Get-DemoActivityControlActiveJob -Name $Name -Runbook $Name.StopRunbook)
}

function Wait-DemoActivityControlStopJob {
    <#
    .SYNOPSIS
    start-demo.ps1's wait for an on-demand stop job (ADR 0020): DbHub-Stop removes its schedule first and then
    deallocates the VMs, so a job that's queued or running could deallocate the VMs this start brings up. The start
    waits up to 10 minutes for it to finish, polling about every 30 seconds, and never stops it. Internal.
    https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account

    .DESCRIPTION
    START.CONTROL.STOPJOB:
    - Not selected: no DbHub-Stop job is queued or running, or the control's Automation account doesn't exist.
    - Pass: one was, and it finished within the wait; an Info line says how long the start waited.
    - Warning: it's still queued or running after the wait, so it may deallocate the VMs; the start carries on.
    - Warning: the jobs can't be read, so one may be running now; with the auto-stop's due time (-AutoStopUtc) when
      it passed within the hour.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [Nullable[datetime]] $AutoStopUtc = $null,

        [ValidateRange(1, 3600)]
        [int] $WaitSeconds = 600,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 30
    )

    $name = Get-DemoActivityControlName -Config $Config
    $checkId = 'START.CONTROL.STOPJOB'
    $doc = 'https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account'
    $check = 'Check the {0} job in the Automation account {1} (Process automation > Jobs); if the VMs deallocate, run start-demo.ps1 again once it has finished. start-demo.ps1 never stops it.' -f $name.StopRunbook, $name.AutomationAccount
    $state = Get-DemoActivityControlActiveStopJob -Name $name
    $job = $null
    $polls = 0
    $maxPolls = [int][Math]::Ceiling($WaitSeconds / $PollSeconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($state.Ok -and @($state.Jobs).Count -gt 0 -and $polls -lt $maxPolls -and $watch.Elapsed.TotalSeconds -lt $WaitSeconds) {
        $job = @($state.Jobs)[0]
        if ($polls -eq 0) {
            Write-DemoLog -Level Info -Message ('The on-demand stop job {0} ({1}) is {2} and could deallocate the VMs this start brings up: waiting up to {3} minutes for it to finish. It isn''t stopped.' -f $name.StopRunbook, $job.Id, $job.Status, [Math]::Round($WaitSeconds / 60.0, 1))
        }
        Start-Sleep -Seconds $PollSeconds
        $polls++
        $state = Get-DemoActivityControlActiveStopJob -Name $name
    }
    $waitedSeconds = $polls * $PollSeconds
    $waited = if ($waitedSeconds -lt 60) { 'about {0} seconds' -f $waitedSeconds } elseif ($waitedSeconds -lt 90) { 'about a minute' } else { 'about {0} minutes' -f [int][Math]::Round($waitedSeconds / 60.0, [System.MidpointRounding]::AwayFromZero) }
    $evidence = [ordered]@{ runbook = $name.StopRunbook; jobId = $(if ($null -ne $job) { $job.Id } else { '' }); waitedSeconds = $waitedSeconds }
    if (-not $state.Ok) {
        $intro = if ($null -ne $AutoStopUtc) { 'An on-demand run''s auto-stop was due at {0:yyyy-MM-dd HH:mm} UTC, so its {1} job may be running now and deallocate the VMs this start brings up' -f $AutoStopUtc, $name.StopRunbook } else { 'A {0} job may be running now and deallocate the VMs this start brings up' -f $name.StopRunbook }
        $message = '{0}: the control''s jobs couldn''t be read ({1}).' -f $intro, $state.Error
        if ($polls -gt 0) {
            $message += ' The start had waited {0} for job {1}, and carried on.' -f $waited, $job.Id
        }
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $check -DocUrl $doc)
    }
    if (@($state.Jobs).Count -gt 0) {
        $job = @($state.Jobs)[0]
        $evidence['jobId'] = $job.Id
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The on-demand stop job {0} ({1}) was still {2} after {3}: the start carried on, and that job may deallocate the VMs this start brings up.' -f $name.StopRunbook, $job.Id, $job.Status, $waited) -Evidence $evidence -Remediation $check -DocUrl $doc)
    }
    if ($polls -eq 0) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('No on-demand stop job ({0}) is queued or running.' -f $name.StopRunbook) -Evidence $evidence -DocUrl $doc)
    }
    Write-DemoLog -Level Info -Message ('Waited {0} for the on-demand stop job {1} ({2}) to finish; starting now.' -f $waited, $name.StopRunbook, $job.Id)
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The on-demand stop job {0} ({1}) finished after {2}, before anything started, so it can''t deallocate the VMs this start brings up.' -f $name.StopRunbook, $job.Id, $waited) -Evidence $evidence -DocUrl $doc)
}

function Clear-DemoActivityControlAutoStop {
    <#
    .SYNOPSIS
    stop-demo.ps1's and start-demo.ps1's part of the on-demand activity control (ADR 0020): removes a pending
    auto-stop (the one-time schedule dbhub-autostop and its links to DbHub-Stop, with the run's monitoring re-checks
    dbhub-monitor-<n> and their links to DbHub-Monitor), and for a start, waits for a stop job in flight. Internal.
    https://learn.microsoft.com/rest/api/automation/schedule/delete
    https://learn.microsoft.com/rest/api/automation/job-schedule/delete

    .DESCRIPTION
    - Stop (STOP.CONTROL.AUTOSTOP): stop-demo.ps1 stops the demo itself, so the auto-stop goes, and it can't
      deallocate the VMs of a later session. Removed is a Pass.
    - Start (START.CONTROL.AUTOSTOP): a local session takes over from an on-demand run, so its pending auto-stop is
      cancelled. That's a Warning, because the VMs now run until stop-demo.ps1 or the nightly auto-shutdown, and
      the message says when that is. When it can't be removed, the Warning gives the pending stop's time and how to
      cancel it, and the start carries on. An auto-stop whose time has passed isn't pending, so it's left alone:
      removing a schedule that has fired doesn't stop its job.
    - Start, then (START.CONTROL.STOPJOB, Wait-DemoActivityControlStopJob): a DbHub-Stop job that's queued or
      running is waited for, up to 10 minutes, before anything starts. Its result is returned too unless it's Not
      selected; -WhatIf skips it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('Stop', 'Start')]
        [string] $Purpose = 'Stop',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $name = Get-DemoActivityControlName -Config $Config
    $version = '2024-10-23'
    $doc = 'https://learn.microsoft.com/rest/api/automation/schedule/delete'
    $checkId = '{0}.CONTROL.AUTOSTOP' -f $Purpose.ToUpperInvariant()
    $cancel = 'To cancel it, delete the schedule {0} in the Automation account {1} (Shared resources > Schedules) in the Azure portal, or run {2} again.' -f $name.AutoStopSchedule, $name.AutomationAccount, $(if ($Purpose -eq 'Start') { 'start-demo.ps1' } else { 'stop-demo.ps1' })
    # A control session's backup auto-stop (dbhub-autostop-backup, ADR 0026) goes too, whatever the first one's state: it
    # deallocates the VMs 30 minutes after the auto-stop when that one's job failed, which would cut this session or the
    # next one short. Its links to DbHub-Stop go with it.
    $backup = Clear-DemoActivityControlBackupStop -Name $name -ApiVersion $version
    $withBackup = {
        param([object] $Result)
        if ($null -eq $Result -or -not $backup.Found) {
            return $Result
        }
        $Result.evidence['backupStop'] = $name.AutoStopBackupSchedule
        $Result.evidence['backupRemoved'] = [bool]$backup.Removed
        if ($backup.Removed) {
            $Result.message = '{0} The session''s backup auto-stop {1} was removed too.' -f $Result.message, $name.AutoStopBackupSchedule
            return $Result
        }
        $Result.message = '{0} The session''s backup auto-stop {1} is still pending: it couldn''t be removed ({2}).' -f $Result.message, $name.AutoStopBackupSchedule, (Protect-DemoText -Text $backup.Error)
        if ([string]$Result.status -in 'Pass', 'Not selected') {
            $Result.status = 'Warning'
            $Result.remediation = 'To cancel it, delete the schedule {0} in the Automation account {1} (Shared resources > Schedules) in the Azure portal, or run {2} again.' -f $name.AutoStopBackupSchedule, $name.AutomationAccount, $(if ($Purpose -eq 'Start') { 'start-demo.ps1' } else { 'stop-demo.ps1' })
        }
        return $Result
    }
    $scheduleId = '{0}/schedules/{1}' -f $name.AutomationAccountId, $name.AutoStopSchedule
    $schedule = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
    if (-not $schedule.Ok -and -not $schedule.Missing) {
        return (& $withBackup (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The on-demand auto-stop couldn''t be read: {0}. If {1} is still pending, it deallocates the VMs at its time.' -f $schedule.Error, $name.AutoStopSchedule) -Remediation $cancel -DocUrl $doc))
    }
    $stopUtc = $null
    $evidence = [ordered]@{ schedule = $name.AutoStopSchedule; autoStopUtc = '' }
    if ($schedule.Ok) {
        $stopUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $schedule.Value -Name 'properties') -Name 'startTime')
        if ($null -ne $stopUtc) {
            $evidence['autoStopUtc'] = $stopUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    $passed = $Purpose -eq 'Start' -and $null -ne $stopUtc -and $stopUtc -le $NowUtc
    if (-not $schedule.Ok) {
        $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message 'No on-demand run is pending: there''s no auto-stop to remove.' -DocUrl $doc
    }
    elseif ($passed) {
        $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('No on-demand run is pending: the last auto-stop''s time ({0:yyyy-MM-dd HH:mm} UTC) has passed.' -f $stopUtc) -Evidence $evidence -DocUrl $doc
    }
    else {
        $until = 'the nightly auto-shutdown'
        if ($Purpose -eq 'Start') {
            # Read before anything changes, so a configuration problem can't leave a cancelled auto-stop unreported.
            try {
                $shutdownUtc = Get-DemoNextShutdownUtc -Config $Config -NowUtc $NowUtc
                $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
                $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($shutdownUtc, [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId))
                $until = 'the nightly auto-shutdown at {0:yyyy-MM-dd HH:mm} UTC ({1:HH:mm} {2})' -f $shutdownUtc, $local, $zoneId
                $evidence['shutdownUtc'] = $shutdownUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The next auto-shutdown couldn''t be worked out: {0}' -f $_.Exception.Message)
            }
        }
        $action = if ($Purpose -eq 'Start') { 'Cancel the pending on-demand auto-stop: this session takes over' } else { 'Remove the pending on-demand auto-stop' }
        if (-not $PSCmdlet.ShouldProcess($name.AutoStopSchedule, $action)) {
            return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: the pending auto-stop {0} would be removed.' -f $name.AutoStopSchedule) -Evidence $evidence -DocUrl $doc)
        }
        $monitorPattern = '^{0}\d+$' -f [regex]::Escape($name.MonitorPrefix)
        $links = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $name.AutomationAccountId) -ApiVersion $version)
        foreach ($link in @(Get-DemoActivityControlList -InputObject $links.Value -Name 'value')) {
            $properties = Get-DemoMemberValue -InputObject $link -Name 'properties'
            $linkId = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobScheduleId')
            $linked = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'schedule') -Name 'name')
            if (($linked -eq $name.AutoStopSchedule -or $linked -match $monitorPattern) -and $linkId -match '^[0-9a-fA-F-]{36}$') {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $name.AutomationAccountId, $linkId) -ApiVersion $version)
            }
        }
        # The run's monitoring re-checks (dbhub-monitor-<n>, linked to DbHub-Monitor) go with its auto-stop. One that's
        # left behind does nothing: DbHub-Monitor acts only while an auto-stop is pending.
        $schedules = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules' -f $name.AutomationAccountId) -ApiVersion $version)
        foreach ($item in @(Get-DemoActivityControlList -InputObject $schedules.Value -Name 'value')) {
            $recheck = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            if ($recheck -match $monitorPattern) {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/schedules/{1}' -f $name.AutomationAccountId, $recheck) -ApiVersion $version)
            }
        }
        $deleted = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
        $removed = $deleted.Ok -or $deleted.Missing
        if ($Purpose -eq 'Stop') {
            if ($removed) {
                return (& $withBackup (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'The pending on-demand auto-stop was removed; stop-demo.ps1 stops the demo itself.' -Evidence $evidence -DocUrl $doc))
            }
            return (& $withBackup (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The pending on-demand auto-stop couldn''t be removed: {0}. It deallocates the VMs at its time; start-demo.ps1 cancels it when the next session starts.' -f $deleted.Error) -Evidence $evidence -Remediation $cancel -DocUrl $doc))
        }
        if ($removed) {
            $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('An on-demand run''s auto-stop was cancelled; the VMs now run until stop-demo.ps1 or {0}.' -f $until) -Evidence $evidence -Remediation 'Run stop-demo.ps1 when the session ends.' -DocUrl $doc
        }
        else {
            $when = if ($null -ne $stopUtc) { 'at {0:yyyy-MM-dd HH:mm} UTC' -f $stopUtc } else { 'at its time' }
            $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('An on-demand run''s auto-stop is still pending and deallocates the VMs {0}: it couldn''t be cancelled ({1}). The start carried on.' -f $when, $deleted.Error) -Evidence $evidence -Remediation $cancel -DocUrl $doc
        }
    }
    $result = & $withBackup $result
    if ($Purpose -eq 'Stop' -or $WhatIfPreference) {
        return $result
    }
    $recent = if ($passed -and $stopUtc -gt $NowUtc.AddHours(-1)) { $stopUtc } else { $null }
    $stopJob = Wait-DemoActivityControlStopJob -Config $Config -AutoStopUtc $recent
    $result
    if ($stopJob.status -ne 'Not selected') {
        $stopJob
    }
}

function Clear-DemoActivityControlBackupStop {
    <#
    .SYNOPSIS
    Removes a control session's backup auto-stop (the one-time schedule dbhub-autostop-backup and its links to DbHub-Stop,
    ADR 0026) when it's there. Returns Found, Removed, and Error; -WhatIf removes nothing. Never throws. Internal.
    https://learn.microsoft.com/rest/api/automation/schedule/delete
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [string] $ApiVersion
    )

    $id = '{0}/schedules/{1}' -f $Name.AutomationAccountId, $Name.AutoStopBackupSchedule
    try {
        $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $id -ApiVersion $ApiVersion)
        if (-not $read.Ok) {
            # Missing, or unreadable: an account without one, or a read that a later start or stop does again.
            return [pscustomobject]@{ Found = $false; Removed = $false; Error = [string]$read.Error }
        }
        if (-not $PSCmdlet.ShouldProcess($Name.AutoStopBackupSchedule, 'Remove the session''s backup auto-stop')) {
            return [pscustomobject]@{ Found = $false; Removed = $false; Error = '' }
        }
        $links = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $Name.AutomationAccountId) -ApiVersion $ApiVersion)
        foreach ($link in @(Get-DemoActivityControlList -InputObject $links.Value -Name 'value')) {
            $properties = Get-DemoMemberValue -InputObject $link -Name 'properties'
            $linkId = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobScheduleId')
            $linked = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'schedule') -Name 'name')
            if ($linked -eq $Name.AutoStopBackupSchedule -and $linkId -match '^[0-9a-fA-F-]{36}$') {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $Name.AutomationAccountId, $linkId) -ApiVersion $ApiVersion)
            }
        }
        $deleted = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id $id -ApiVersion $ApiVersion)
        return [pscustomobject]@{ Found = $true; Removed = [bool]($deleted.Ok -or $deleted.Missing); Error = [string]$deleted.Error }
    }
    catch {
        return [pscustomobject]@{ Found = $true; Removed = $false; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
}

function Get-DemoActivityControlStatus {
    <#
    .SYNOPSIS
    STATUS.CONTROL for status.ps1: the on-demand activity control's checks (Test-DemoActivityControl) in one line, with
    the worst of their statuses: an active run and its auto-stop, the webhook's expiry, and any role an Owner must grant
    again. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $checks = @(Test-DemoActivityControl -Config $Config -NowUtc $NowUtc)
    $rank = @{ 'Pass' = 0; 'Not selected' = 0; 'Not supported' = 1; 'Warning' = 2; 'Manual action required' = 3; 'Fail' = 4 }
    $worst = 'Pass'
    foreach ($check in $checks) {
        if ($rank[[string]$check.status] -gt $rank[$worst]) {
            $worst = [string]$check.status
        }
    }
    $notes = @($checks | Where-Object { $_.status -ne 'Pass' -or $_.checkId -in 'CONTROL.AUTOSTOP', 'CONTROL.WEBHOOK' } | ForEach-Object { '{0}: {1}' -f ($_.checkId -replace '^CONTROL\.', ''), $_.message })
    $remediation = @($checks | Where-Object { $_.status -in 'Warning', 'Manual action required', 'Fail' -and $_.remediation } | ForEach-Object { $_.remediation } | Select-Object -Unique) -join ' '
    return (New-DemoResult -CheckId 'STATUS.CONTROL' -Area 'workload' -Target 'subscription' -Status $worst -Message ('On-demand activity control: {0}' -f ($notes -join ' | ')) -Evidence ([ordered]@{ checks = @($checks | ForEach-Object { [ordered]@{ checkId = $_.checkId; status = $_.status } }) }) -Remediation $remediation -DocUrl $script:ActivityControlDoc)
}
