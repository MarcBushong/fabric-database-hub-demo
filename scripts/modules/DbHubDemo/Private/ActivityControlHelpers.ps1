# The on-demand activity control (ADR 0020): its names, settings, role, vault mode, runbook content, webhook, Fabric
# notebook, and role grants. Internal; Invoke-DemoActivityControlSetup (scripts/setup-activity-control.ps1),
# Test-DemoActivityControl (validate.ps1, status.ps1), and deploy.ps1's A1 re-grant call these.

# The one custom role, exactly as the owner approved it on 2026-10-26 (ADR 0020, section "The role"): every action
# the run, Stop now, and the auto-stop need, and nothing else. Changing this list needs the owner's approval.
$script:ActivityControlRoleName = 'DbHub Demo Activity Operator'
$script:ActivityControlRoleDescription = 'Start, deallocate, and run commands on the Database Hub demo''s VMs, start and stop its PostgreSQL server, and manage the demo control account''s own one-time stop schedules. Assigned only at the demo resource group and at the control Automation account.'
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
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $control = $Config['control']
    $value = { param([string] $Name, [object] $Default) $item = Get-DemoMemberValue -InputObject $control -Name $Name; if ($null -eq $item -or ($item -is [string] -and -not $item)) { $Default } else { $item } }
    return [pscustomobject]@{
        Enabled               = [bool](& $value 'enabled' $false)
        VaultNetworkMode      = [string](& $value 'vaultNetworkMode' 'auto')
        WebhookExpiryDays     = [int](& $value 'webhookExpiryDays' 90)
        T4SafetyStopTime      = [string](& $value 't4SafetyStopTime' '')
        NotebookUserObjectIds = @(& $value 'notebookUserObjectIds' @() | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
        FabricFolderName      = [string](& $value 'fabricFolderName' 'DBHub Control')
        FabricWorkspaceName   = [string](& $value 'fabricWorkspaceName' 'DBHub Control')
    }
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
        ControlRunbook      = 'DbHub-Control'
        StopRunbook         = 'DbHub-Stop'
        AutoStopSchedule    = 'dbhub-autostop'
        SafetyStopSchedule  = 'dbhub-t4-safety-stop'
        WebhookPrefix       = 'dbhub-activity-'
        RunCommandPrefix    = 'DbHubControl-'
        RoleName            = $script:ActivityControlRoleName
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
    The custom role "DbHub Demo Activity Operator" as an Azure Resource Manager role definition body, assignable in the
    configured subscription only. The action list is the owner-approved one and nothing else. Internal.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    return [ordered]@{
        properties = [ordered]@{
            roleName         = $script:ActivityControlRoleName
            description      = $script:ActivityControlRoleDescription
            type             = 'CustomRole'
            permissions      = @([ordered]@{ actions = @($script:ActivityControlRoleActions); notActions = @(); dataActions = @(); notDataActions = @() })
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

function Get-DemoActivityControlRunbookSetting {
    <#
    .SYNOPSIS
    The settings baked into both runbooks: names, the demo's schedule, the bounds, the allow-lists from the scenario
    catalog, the pinned API versions, and the VM-side workload-control template. Nothing in it is secret; it holds the
    subscription ID and the identity's client ID, which live in Azure only. Internal.
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
    foreach ($type in 'Microsoft.Automation/automationAccounts', 'Microsoft.Compute/virtualMachines', 'Microsoft.Compute/virtualMachines/runCommands', 'Microsoft.Resources/resourceGroups', 'Microsoft.Sql/servers/databases', 'Microsoft.DBforPostgreSQL/flexibleServers') {
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
        autoStopSchedule       = $Name.AutoStopSchedule
        autoStopBufferMinutes  = 10
        runCommandPrefix       = $Name.RunCommandPrefix
        sqlVmName              = 'sqlvm01'
        hostVmName             = Get-DemoHostVmName -Config $Config
        t2GuestName            = [string]$guest.Name
        t3ServerPrefix         = 'azuresql01-'
        demoDatabase           = 'ContosoCare'
        t4ServerPrefix         = 'pgflex01-'
        autoShutdownTime       = $(if ($Config['autoShutdownTime']) { [string]$Config['autoShutdownTime'] } else { '1900' })
        autoShutdownTimeZone   = $(if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' })
        shutdownMarginMinutes  = 2
        minDurationMinutes     = 5
        maxDurationMinutes     = 120
        maxBodyBytes           = 4096
        targets                = $targets
        scenarios              = $catalog
        monitoring             = [ordered]@{ extensionInstanceName = [string]$sqlVm['extensionInstanceName']; statusPlugin = [string]$sqlVm['statusPlugin']; serviceName = 'SQLIaaSExtension' }
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
        [ValidateSet('DbHub-Control', 'DbHub-Stop')]
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
    The custom role's definition ID (a GUID) in the subscription, found by its name; empty when it doesn't exist.
    Throws when the role definitions can't be read. Internal.
    https://learn.microsoft.com/rest/api/authorization/role-definitions/list
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $read = Invoke-DemoActivityControlArm -SubscriptionId $SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions' -f $SubscriptionId) -Query ([ordered]@{ '$filter' = ("roleName eq '{0}'" -f $script:ActivityControlRoleName); 'api-version' = '2022-04-01' })
    if (-not $read.Ok) {
        throw ('The role definitions couldn''t be read: {0}' -f $read.Error)
    }
    $match = @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value') | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'roleName') -ceq $script:ActivityControlRoleName } | Select-Object -First 1
    return [string](Get-DemoMemberValue -InputObject $match -Name 'name')
}

function Get-DemoActivityControlCommand {
    # The exact command an Owner runs to grant the control's roles. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigPath = ''
    )

    $path = if ($ConfigPath) { $ConfigPath } else { './config/demo.config.json' }
    return ('./scripts/setup-activity-control.ps1 -ConfigPath {0} -GrantRole' -f $path)
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
    Internal and pure.
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
        [string] $PrincipalId = '',

        [AllowEmptyString()]
        [string] $CallerObjectId = '',

        [AllowEmptyString()]
        [string] $CallerPrincipalType = 'User',

        [ValidateSet('A1', 'A2', 'A3')]
        [string[]] $Assignment = @('A1', 'A2', 'A3')
    )

    $roleDefinition = if ($RoleId) { '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $RoleId } else { '' }
    $secretsUser = '/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Name.SubscriptionId, $script:VaultReaderRoleGuid
    $plan = [System.Collections.Generic.List[object]]::new()
    if ('A1' -in $Assignment) {
        $plan.Add([pscustomobject]@{ Id = 'A1'; Role = $script:ActivityControlRoleName; RoleId = $RoleId; RoleDefinitionId = $roleDefinition; Scope = $Name.DemoResourceGroupId; ScopeLabel = $Name.DemoResourceGroup; PrincipalId = $PrincipalId; PrincipalType = 'ServicePrincipal'; PrincipalLabel = $Name.Identity })
    }
    if ('A2' -in $Assignment) {
        $plan.Add([pscustomobject]@{ Id = 'A2'; Role = $script:ActivityControlRoleName; RoleId = $RoleId; RoleDefinitionId = $roleDefinition; Scope = $Name.AutomationAccountId; ScopeLabel = $Name.AutomationAccount; PrincipalId = $PrincipalId; PrincipalType = 'ServicePrincipal'; PrincipalLabel = $Name.Identity })
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
        foreach ($user in $users) {
            $plan.Add([pscustomobject]@{ Id = 'A3'; Role = 'Key Vault Secrets User'; RoleId = $script:VaultReaderRoleGuid; RoleDefinitionId = $secretsUser; Scope = $Name.SecretId; ScopeLabel = ('{0}/secrets/{1}' -f $Name.KeyVault, $Name.Secret); PrincipalId = $user.Id; PrincipalType = $user.Type; PrincipalLabel = $user.Label })
        }
    }
    return $plan.ToArray()
}

function Grant-DemoActivityControlRole {
    <#
    .SYNOPSIS
    Creates or updates the custom role (with -IncludeDefinition) and the requested assignments of A1-A3, as the
    signed-in caller, and returns CONTROL.ROLE.DEFINITION and CONTROL.ROLE.<A1|A2|A3> results. The one function behind
    setup-activity-control.ps1 -GrantRole (every assignment, and the role) and deploy.ps1's re-grant (A1 only, when
    assignRoles and control.enabled are true). Internal.

    .DESCRIPTION
    An assignment that exists is kept (Pass). One that can't be made, because the caller isn't an Owner or User
    Access Administrator, a write needs a fresh multifactor sign-in, the role definition or the identity doesn't
    exist yet, or Azure refuses it, is Manual action required with the exact -GrantRole command. Every write is a
    documented Azure Resource Manager call through the subscription guard:
    https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update
    https://learn.microsoft.com/rest/api/authorization/role-assignments/create
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('A1', 'A2', 'A3')]
        [string[]] $Assignment = @('A1', 'A2', 'A3'),

        [switch] $IncludeDefinition,

        [string] $ConfigPath = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $name = Get-DemoActivityControlName -Config $Config
    $subscriptionId = $name.SubscriptionId
    $command = Get-DemoActivityControlCommand -ConfigPath $ConfigPath
    $doc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-rest'
    $manual = {
        param([string] $CheckId, [string] $Message, [System.Collections.IDictionary] $Evidence)
        New-DemoResult -CheckId $CheckId -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message $Message -Evidence $Evidence -Remediation ('An Owner of the subscription runs, signed in with multifactor authentication: {0}' -f $command) -DocUrl $doc
    }

    $permissions = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $subscriptionId)
    $entries = @()
    if ($permissions.Ok) {
        $entries = @(Get-DemoActivityControlList -InputObject $permissions.Value -Name 'value')
    }
    $canAssign = $permissions.Ok -and (Test-DemoPermission -Permission $entries -Action 'Microsoft.Authorization/roleAssignments/write')
    $canDefine = $permissions.Ok -and (Test-DemoPermission -Permission $entries -Action 'Microsoft.Authorization/roleDefinitions/write')

    $roleId = ''
    try {
        $roleId = Get-DemoActivityControlRoleId -SubscriptionId $subscriptionId
    }
    catch {
        $results.Add((& $manual 'CONTROL.ROLE.DEFINITION' (Protect-DemoText -Text $_.Exception.Message) ([ordered]@{ role = $script:ActivityControlRoleName })))
        return $results.ToArray()
    }
    if ($IncludeDefinition) {
        $definition = Get-DemoActivityControlRoleDefinition -SubscriptionId $subscriptionId
        $definitionId = if ($roleId) { $roleId } else { ConvertTo-DemoStableGuid -Key ('{0}|{1}' -f $subscriptionId, $script:ActivityControlRoleName) }
        $evidence = [ordered]@{ role = $script:ActivityControlRoleName; roleId = $definitionId; actions = @($script:ActivityControlRoleActions); assignableScopes = @('/subscriptions/{0}' -f $subscriptionId) }
        if (-not $canDefine) {
            $results.Add((& $manual 'CONTROL.ROLE.DEFINITION' ('The custom role "{0}" needs Microsoft.Authorization/roleDefinitions/write, which the signed-in caller doesn''t have.' -f $script:ActivityControlRoleName) $evidence))
        }
        elseif (-not $PSCmdlet.ShouldProcess(('/subscriptions/{0}' -f $subscriptionId), ('{0} the custom role "{1}" with exactly the {2} approved actions' -f $(if ($roleId) { 'Update' } else { 'Create' }), $script:ActivityControlRoleName, $script:ActivityControlRoleActions.Count))) {
            $results.Add((New-DemoResult -CheckId 'CONTROL.ROLE.DEFINITION' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: the custom role "{0}" would be {1} with exactly these actions: {2}.' -f $script:ActivityControlRoleName, $(if ($roleId) { 'updated' } else { 'created' }), ($script:ActivityControlRoleActions -join ', ')) -Evidence $evidence -DocUrl $doc))
            $roleId = $definitionId
        }
        else {
            $write = Invoke-DemoActivityControlArm -SubscriptionId $subscriptionId -Method put -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version=2022-04-01' -f $subscriptionId, $definitionId) -Body $definition
            if ($write.Ok) {
                $roleId = $definitionId
                $results.Add((New-DemoResult -CheckId 'CONTROL.ROLE.DEFINITION' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('The custom role "{0}" exists with exactly the {1} approved actions, assignable in this subscription only.' -f $script:ActivityControlRoleName, $script:ActivityControlRoleActions.Count) -Evidence $evidence -DocUrl $doc))
            }
            else {
                $results.Add((& $manual 'CONTROL.ROLE.DEFINITION' ('The custom role couldn''t be written: {0}' -f $write.Error) $evidence))
            }
        }
    }

    $principalId = Get-DemoActivityControlPrincipalId -Name $name
    $caller = Get-DemoCallerIdentity -SubscriptionId $subscriptionId
    $plan = @(Get-DemoActivityControlGrantPlan -Name $name -Config $Config -RoleId $roleId -PrincipalId $principalId -CallerObjectId ([string]$caller.ObjectId) -CallerPrincipalType ([string]$caller.PrincipalType) -Assignment $Assignment)
    foreach ($item in $plan) {
        $checkId = 'CONTROL.ROLE.{0}' -f $item.Id
        $evidence = [ordered]@{ assignment = $item.Id; role = $item.Role; scope = $item.ScopeLabel; principal = $item.PrincipalLabel; principalId = $item.PrincipalId }
        $label = '{0}: {1} for {2} at {3}' -f $item.Id, $item.Role, $item.PrincipalLabel, $item.ScopeLabel
        if (-not $item.RoleId) {
            $results.Add((& $manual $checkId ('{0} wasn''t granted: the custom role "{1}" doesn''t exist yet.' -f $label, $script:ActivityControlRoleName) $evidence))
            continue
        }
        if (-not $item.PrincipalId) {
            $why = if ($item.Id -eq 'A3') { 'the signed-in caller''s object ID is unknown' } else { ('the identity {0} doesn''t exist yet; run setup-activity-control.ps1 first' -f $name.Identity) }
            $results.Add((& $manual $checkId ('{0} wasn''t granted: {1}.' -f $label, $why) $evidence))
            continue
        }
        $existing = Test-DemoActivityControlAssignment -SubscriptionId $subscriptionId -Scope $item.Scope -PrincipalId $item.PrincipalId -RoleId $item.RoleId
        if ($existing.Exists) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} is in place.' -f $label) -Evidence $evidence -DocUrl $doc))
            continue
        }
        if ($existing.Missing) {
            $status = if ($item.Id -eq 'A1') { 'Warning' } else { 'Manual action required' }
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status $status -Message ('{0} wasn''t granted: {1} doesn''t exist.' -f $label, $item.ScopeLabel) -Evidence $evidence -Remediation $(if ($item.Id -eq 'A1') { ('Deploy the demo; deploy.ps1 grants A1 when assignRoles and control.enabled are true, or run {0}.' -f $command) } else { ('Run setup-activity-control.ps1, then {0}.' -f $command) }) -DocUrl $doc))
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
    Creates or updates DbHub-Control and DbHub-Stop (PowerShell, that is Windows PowerShell 5.1), replaces each draft
    with the assembled content, and publishes it. Returns CONTROL.RUNBOOKS. Internal.
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
    foreach ($runbook in $Name.ControlRunbook, $Name.StopRunbook) {
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
                return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('{0}: couldn''t {1}: {2}' -f $runbook, $step.Label, $call.Error) -Remediation 'Run setup-activity-control.ps1 again; it publishes both runbooks each time.' -DocUrl $doc)
            }
        }
        $published.Add($runbook)
    }
    if ($published.Count -eq 0) {
        return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} and {1} would be published (Windows PowerShell 5.1) with the current catalog and settings.' -f $Name.ControlRunbook, $Name.StopRunbook) -DocUrl $doc)
    }
    return (New-DemoResult -CheckId 'CONTROL.RUNBOOKS' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0} published (Windows PowerShell 5.1) with the current scenario catalog ({1} scenarios) and settings.' -f ($published -join ' and '), @($Setting['scenarios'].Keys).Count) -Evidence ([ordered]@{ runbooks = $published.ToArray(); targets = @($Setting['targets'].Keys); scenarios = @($Setting['scenarios'].Keys) }) -DocUrl $doc)
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

function Get-DemoActivityControlNotebook {
    <#
    .SYNOPSIS
    The control notebook (fabric/control/NB_DatabaseHub_Control.ipynb) with its parameters cell filled for this
    environment: the vault URL, the demo's names, and the catalog the runbook allows. No secret goes in: the notebook
    reads the webhook URL from the vault at run time. Returns a Fabric notebook definition (Get-DemoFabricNotebookDefinition).
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $path = Join-Path -Path $script:RepoRoot -ChildPath 'fabric/control/NB_DatabaseHub_Control.ipynb'
    $notebook = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $catalog = [ordered]@{ targets = @($Setting['targets'].Keys); scenarios = $Setting['scenarios']; minDurationMinutes = $Setting['minDurationMinutes']; maxDurationMinutes = $Setting['maxDurationMinutes'] }
    $values = [ordered]@{
        KEY_VAULT_URL       = $Name.KeyVaultUri
        WEBHOOK_SECRET_NAME = $Name.Secret
        RESOURCE_GROUP      = $Name.DemoResourceGroup
        T1_VM_NAME          = 'sqlvm01'
        T2_MACHINE_NAME     = [string]$Setting['t2GuestName']
        T3_SERVER_PREFIX    = [string]$Setting['t3ServerPrefix']
        DEMO_DATABASE       = [string]$Setting['demoDatabase']
        CATALOG_JSON        = (ConvertTo-Json -InputObject $catalog -Depth 8 -Compress)
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
        if ($key -ne 'CATALOG_JSON' -and $match.Success) {
            $comment = $match.Value.TrimEnd("`n")
        }
        $lines[$index] = '{0} = {1}{2}{3}' -f $key, $literal, $comment, $(if ($lines[$index].EndsWith("`n")) { "`n" } else { '' })
    }
    $cell['source'] = $lines
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-control-nb'
    try {
        $file = Write-DemoPrivateFile -Directory $directory -Name 'NB_DatabaseHub_Control.ipynb' -Content (ConvertTo-Json -InputObject $notebook -Depth 64)
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
    $notebook = Get-DemoActivityControlNotebook -Name $Name -Setting $Setting
    if ($WhatIfPreference -or -not $Token) {
        $plan = if ($Mode -eq 'public') { ('the folder "{0}" in the existing workspace, with {1} in it' -f $Name.FabricFolder, $Name.Notebook) } else { ('the workspace "{0}" on the existing workspace''s capacity, a managed private endpoint to {1} approved on the vault, and {2} in it' -f $Name.FabricWorkspace, $Name.KeyVault, $Name.Notebook) }
        & $add 'CONTROL.FABRIC.NOTEBOOK' 'Not selected' ('What if: {0} would be created through the Fabric REST API; the capacity is never resumed, paused, or scaled.' -f $plan) ([ordered]@{ mode = $Mode; notebookSha256 = $notebook.Sha256 }) '' 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'
        return $results.ToArray()
    }
    # The demo's workspace by name (Phase 26a, ADR 0021), read-only: deploy.ps1 and configure-fabric.ps1 create it.
    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $Token -SkipLakehouse -Confirm:$false
    $sharedId = [string]$resolution.WorkspaceId
    if ($sharedId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $why = @($resolution.Results | ForEach-Object { [string]$_.message }) -join ' '
        & $add 'CONTROL.FABRIC.NOTEBOOK' 'Manual action required' ('The demo''s Fabric workspace isn''t resolved, so the control notebook wasn''t imported. {0}' -f $why).Trim() @{} 'Run ./scripts/configure-fabric.ps1 or ./scripts/deploy.ps1 first (they create the workspace when fabric.createIfMissing is true), then run setup-activity-control.ps1 again.' 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces'
        return $results.ToArray()
    }
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
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/folders' -f $base, $sharedId) -Body ([ordered]@{ displayName = $Name.FabricFolder }) -Token $Token
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
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces' -f $base) -Body ([ordered]@{ displayName = $Name.FabricWorkspace; description = 'On-demand activity control for the Database Hub demo (ADR 0020): the control notebook and its managed private endpoint to the control vault.'; capacityId = $capacityId }) -Token $Token
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
            $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints' -f $base, $targetWorkspace) -Body ([ordered]@{ name = $Name.PrivateEndpoint; targetPrivateLinkResourceId = $Name.KeyVaultId; targetSubresourceType = 'vault'; requestMessage = $request }) -Token $Token
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

    $import = @{ WorkspaceId = $targetWorkspace; Notebook = $notebook; Token = $Token; Description = 'On-demand activity control for the Database Hub demo (ADR 0020), imported by scripts/setup-activity-control.ps1.'; Confirm = $false }
    if ($folderId) {
        $import['FolderId'] = $folderId
    }
    $imported = Import-DemoFabricNotebook @import
    $results.Add((New-DemoResult -CheckId 'CONTROL.FABRIC.NOTEBOOK' -Area 'fabric' -Target 'fabric' -Status ([string]$imported.status) -Message ('{0} {1}' -f $Name.Notebook, [string]$imported.message) -Evidence ([ordered]@{ workspace = $(if ($Mode -eq 'public') { 'existing' } else { $Name.FabricWorkspace }); folder = $(if ($folderId) { $Name.FabricFolder } else { '' }); mode = $Mode }) -Remediation ([string]$imported.remediation) -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'))
    return $results.ToArray()
}

function Test-DemoActivityControlRole {
    <#
    .SYNOPSIS
    Read-only: whether A1, A2, and A3 are in place. Returns CONTROL.ROLE.<A1|A2|A3>: Pass when present, Manual action
    required with the exact -GrantRole command when missing, Warning when it can't be read. A3 passes when at least one
    principal holds Key Vault Secrets User on the secret. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('A1', 'A2', 'A3')]
        [string[]] $Assignment = @('A1', 'A2', 'A3'),

        [string] $ConfigPath = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $name = Get-DemoActivityControlName -Config $Config
    $command = Get-DemoActivityControlCommand -ConfigPath $ConfigPath
    $doc = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-list-rest'
    $missing = { param([string] $CheckId, [string] $Message) $results.Add((New-DemoResult -CheckId $CheckId -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message $Message -Remediation ('An Owner of the subscription runs, signed in with multifactor authentication: {0}' -f $command) -DocUrl $doc)) }
    $roleId = ''
    try {
        $roleId = Get-DemoActivityControlRoleId -SubscriptionId $name.SubscriptionId
    }
    catch {
        foreach ($item in $Assignment) {
            $results.Add((New-DemoResult -CheckId ('CONTROL.ROLE.{0}' -f $item) -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t checked: {1}' -f $item, (Protect-DemoText -Text $_.Exception.Message)) -DocUrl $doc))
        }
        return $results.ToArray()
    }
    $principalId = Get-DemoActivityControlPrincipalId -Name $name
    foreach ($item in $Assignment) {
        $checkId = 'CONTROL.ROLE.{0}' -f $item
        if ($item -eq 'A3') {
            $read = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments?$filter=atScope()&api-version=2022-04-01' -f $name.SecretId)
            if (-not $read.Ok) {
                if ($read.Missing) {
                    & $missing $checkId ('A3 isn''t in place: the secret {0} doesn''t exist yet; run setup-activity-control.ps1.' -f $name.Secret)
                }
                else {
                    $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('A3 wasn''t checked: {0}' -f $read.Error) -DocUrl $doc))
                }
                continue
            }
            $holders = @(@(Get-DemoActivityControlList -InputObject $read.Value -Name 'value') | Where-Object {
                    $properties = Get-DemoMemberValue -InputObject $_ -Name 'properties'
                    ([string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')).EndsWith('/' + $script:VaultReaderRoleGuid, [System.StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string](Get-DemoMemberValue -InputObject $properties -Name 'scope'), $name.SecretId, [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($holders.Count -gt 0) {
                $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('A3: {0} principal(s) hold Key Vault Secrets User on the secret {1} only.' -f $holders.Count, $name.Secret) -Evidence ([ordered]@{ holders = $holders.Count }) -DocUrl $doc))
            }
            else {
                & $missing $checkId ('A3 isn''t in place: nobody holds Key Vault Secrets User on the secret {0}, so the notebook can''t read the webhook URL.' -f $name.Secret)
            }
            continue
        }
        $scope = if ($item -eq 'A1') { $name.DemoResourceGroupId } else { $name.AutomationAccountId }
        $label = if ($item -eq 'A1') { $name.DemoResourceGroup } else { $name.AutomationAccount }
        if (-not $roleId) {
            & $missing $checkId ('{0} isn''t in place: the custom role "{1}" doesn''t exist yet.' -f $item, $script:ActivityControlRoleName)
            continue
        }
        if (-not $principalId) {
            & $missing $checkId ('{0} isn''t in place: the identity {1} doesn''t exist yet; run setup-activity-control.ps1 first.' -f $item, $name.Identity)
            continue
        }
        $existing = Test-DemoActivityControlAssignment -SubscriptionId $name.SubscriptionId -Scope $scope -PrincipalId $principalId -RoleId $roleId
        if ($existing.Exists) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('{0}: {1} holds "{2}" at {3}.' -f $item, $name.Identity, $script:ActivityControlRoleName, $label) -DocUrl $doc))
        }
        elseif ($existing.Missing -and $item -eq 'A1') {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('A1 has no scope: {0} doesn''t exist (not deployed).' -f $label) -DocUrl $doc))
        }
        elseif ($existing.Error) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} wasn''t checked: {1}' -f $item, $existing.Error) -DocUrl $doc))
        }
        else {
            $why = if ($item -eq 'A1') { ' A redeploy deletes it with the group; deploy.ps1 grants it again only when assignRoles is true.' } else { '' }
            & $missing $checkId ('{0} isn''t in place: {1} doesn''t hold "{2}" at {3}, so the runbooks can''t act there.{4}' -f $item, $name.Identity, $script:ActivityControlRoleName, $label, $why)
        }
    }
    return $results.ToArray()
}

function Invoke-DemoActivityControlRegrant {
    <#
    .SYNOPSIS
    deploy.ps1's A1 step after the template (ADR 0020): with control.enabled, grants A1 again when assignRoles is true
    (Grant-DemoActivityControlRole, A1 only), and otherwise checks it. A missing or failed A1 is Manual action
    required with the exact -GrantRole command, so DEPLOY.SUMMARY lists it. Nothing when control.enabled is false.
    Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = ''
    )

    if (-not (Get-DemoActivityControlSetting -Config $Config).Enabled) {
        return @()
    }
    try {
        if ($Config['assignRoles']) {
            return @(Grant-DemoActivityControlRole -Config $Config -Assignment 'A1' -ConfigPath $ConfigPath -Confirm:$false)
        }
        return @(Test-DemoActivityControlRole -Config $Config -Assignment 'A1' -ConfigPath $ConfigPath)
    }
    catch {
        return @(New-DemoResult -CheckId 'CONTROL.ROLE.A1' -Area 'workload' -Target 'subscription' -Status 'Manual action required' -Message ('A1 wasn''t granted: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation ('An Owner of the subscription runs, signed in with multifactor authentication: {0}' -f (Get-DemoActivityControlCommand -ConfigPath $ConfigPath)) -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-rest')
    }
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
    try {
        $roleId = Get-DemoActivityControlRoleId -SubscriptionId $Name.SubscriptionId
    }
    catch {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The role assignments weren''t removed: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -DocUrl $doc)
    }
    $targets = [System.Collections.Generic.List[string]]::new()
    $principalId = Get-DemoActivityControlPrincipalId -Name $Name
    if ($principalId -and $roleId) {
        $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments' -f $Name.SubscriptionId) -Query ([ordered]@{ '$filter' = ("principalId eq '{0}'" -f $principalId); 'api-version' = '2022-04-01' })
        foreach ($item in @(Get-DemoActivityControlList -InputObject $read.Value -Name 'value')) {
            if (([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'properties') -Name 'roleDefinitionId')).EndsWith('/' + $roleId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $targets.Add([string](Get-DemoMemberValue -InputObject $item -Name 'id'))
            }
        }
    }
    $secretRead = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/providers/Microsoft.Authorization/roleAssignments?$filter=atScope()&api-version=2022-04-01' -f $Name.SecretId)
    foreach ($item in @(Get-DemoActivityControlList -InputObject $secretRead.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
        if (([string](Get-DemoMemberValue -InputObject $properties -Name 'roleDefinitionId')).EndsWith('/' + $script:VaultReaderRoleGuid, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string](Get-DemoMemberValue -InputObject $properties -Name 'scope'), $Name.SecretId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $targets.Add([string](Get-DemoMemberValue -InputObject $item -Name 'id'))
        }
    }
    if (-not $PSCmdlet.ShouldProcess(('{0} role assignment(s) and the custom role "{1}"' -f $targets.Count, $script:ActivityControlRoleName), 'Delete')) {
        return (New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} role assignment(s) (A1-A3) and the custom role "{1}" would be deleted.' -f $targets.Count, $script:ActivityControlRoleName) -DocUrl $doc)
    }
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $targets) {
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url ('https://management.azure.com{0}?api-version=2022-04-01' -f $id)
        if (-not $delete.Ok -and -not $delete.Missing) {
            $failed.Add($delete.Error)
        }
    }
    $roleNote = 'the custom role didn''t exist'
    if ($roleId) {
        $delete = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method delete -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version=2022-04-01' -f $Name.SubscriptionId, $roleId)
        $roleNote = if ($delete.Ok -or $delete.Missing) { 'the custom role was deleted' } else { 'the custom role was kept ({0})' -f $delete.Error }
    }
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

function Get-DemoActivityControlActiveStopJob {
    <#
    .SYNOPSIS
    The control's DbHub-Stop jobs that are queued or running, from Job - List By Automation Account
    (https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account). A control Automation account or
    group that doesn't exist has none. Returns Ok, Error, and Jobs (Id and Status). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Name
    )

    $jobs = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url ('https://management.azure.com{0}/jobs' -f $Name.AutomationAccountId) -Query ([ordered]@{ '$filter' = ("properties/runbook/name eq '{0}'" -f $Name.StopRunbook); 'api-version' = '2024-10-23' })
    if (-not $jobs.Ok -and -not $jobs.Missing) {
        return [pscustomobject]@{ Ok = $false; Error = $jobs.Error; Jobs = @() }
    }
    $active = [System.Collections.Generic.List[object]]::new()
    foreach ($job in @(Get-DemoActivityControlList -InputObject $jobs.Value -Name 'value')) {
        $properties = Get-DemoMemberValue -InputObject $job -Name 'properties'
        $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
        $runbook = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'runbook') -Name 'name')
        if ($runbook -eq $Name.StopRunbook -and $status -in $script:ActivityControlActiveJobStatuses) {
            $active.Add([pscustomobject]@{ Id = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobId'); Status = $status })
        }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Jobs = $active.ToArray() }
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
    auto-stop (the one-time schedule dbhub-autostop and its links to DbHub-Stop), and for a start, waits for a stop
    job in flight. Internal.
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
    $scheduleId = '{0}/schedules/{1}' -f $name.AutomationAccountId, $name.AutoStopSchedule
    $schedule = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
    if (-not $schedule.Ok -and -not $schedule.Missing) {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The on-demand auto-stop couldn''t be read: {0}. If {1} is still pending, it deallocates the VMs at its time.' -f $schedule.Error, $name.AutoStopSchedule) -Remediation $cancel -DocUrl $doc)
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
        $links = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules' -f $name.AutomationAccountId) -ApiVersion $version)
        foreach ($link in @(Get-DemoActivityControlList -InputObject $links.Value -Name 'value')) {
            $properties = Get-DemoMemberValue -InputObject $link -Name 'properties'
            $linkId = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobScheduleId')
            if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'schedule') -Name 'name') -eq $name.AutoStopSchedule -and $linkId -match '^[0-9a-fA-F-]{36}$') {
                $null = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id ('{0}/jobSchedules/{1}' -f $name.AutomationAccountId, $linkId) -ApiVersion $version)
            }
        }
        $deleted = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method delete -Url (Get-DemoActivityControlUrl -Id $scheduleId -ApiVersion $version)
        $removed = $deleted.Ok -or $deleted.Missing
        if ($Purpose -eq 'Stop') {
            if ($removed) {
                return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'The pending on-demand auto-stop was removed; stop-demo.ps1 stops the demo itself.' -Evidence $evidence -DocUrl $doc)
            }
            return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The pending on-demand auto-stop couldn''t be removed: {0}. It deallocates the VMs at its time; start-demo.ps1 cancels it when the next session starts.' -f $deleted.Error) -Evidence $evidence -Remediation $cancel -DocUrl $doc)
        }
        if ($removed) {
            $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('An on-demand run''s auto-stop was cancelled; the VMs now run until stop-demo.ps1 or {0}.' -f $until) -Evidence $evidence -Remediation 'Run stop-demo.ps1 when the session ends.' -DocUrl $doc
        }
        else {
            $when = if ($null -ne $stopUtc) { 'at {0:yyyy-MM-dd HH:mm} UTC' -f $stopUtc } else { 'at its time' }
            $result = New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('An on-demand run''s auto-stop is still pending and deallocates the VMs {0}: it couldn''t be cancelled ({1}). The start carried on.' -f $when, $deleted.Error) -Evidence $evidence -Remediation $cancel -DocUrl $doc
        }
    }
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
