function Initialize-DemoConfig {
    <#
    .SYNOPSIS
    Writes the demo's Git-ignored configuration (config/demo.config.json) from the signed-in Azure CLI context, so a
    first run needs no IDs looked up by hand (Phase 26b, ADR 0023). init.ps1 calls it.

    .DESCRIPTION
    1. The file: a path Git would commit is refused (Fail). An existing file is never replaced without -Force; with
       -Force it's first copied to -BackupDirectory (out/config-backup, which Git ignores).
    2. Discovery before the subscription guard, the one documented exception (ADR 0023): 'az account list' reads the
       subscriptions the Azure CLI's own sign-in cached, locally and read-only (Get-DemoAzProfileSubscription). Nothing
       signs in, and the default subscription never changes ('az account set' is never run). Not signed in: Manual
       action required with the 'az login' command. More than one subscription: it asks (or takes -SubscriptionId).
    3. The subscription guard (Assert-DemoAzContext) for the chosen subscription, its tenant, and its account. Every
       later call goes through it: Invoke-DemoAz, Invoke-DemoRestRequest, and the Fabric REST helpers.
    4. The signed-in user from Microsoft Graph (/me): the owner tag and the budget alerts' address (INIT.USER).
    5. P1 (INIT.P1.CONTRIBUTOR): the caller's permissions on the subscription, as preflight reads them; without
       Contributor, Manual action required with the Owner's exact command.
    6. Fabric (INIT.FABRIC.CAPACITY, INIT.FABRIC.WORKSPACE): the capacities you can assign (Capacities - List
       Capacities; it asks when there's more than one) and whether the workspace fabric.workspaceName already exists
       (Workspaces - List Workspaces). A workspace that doesn't exist yet gets fabric.importNotebooks true; deploy.ps1
       creates it, its lakehouse, and the notebooks (ADR 0021). Nothing is created in Fabric here.
    7. P6 (INIT.P6.GROUP): the Microsoft Entra security group by -AdminGroupObjectId, or by name (default
       <prefix>-<environment>-sql-admins), and whether you own it. With -CreateAdminGroup, a missing group is created
       with you as its owner (Microsoft Graph Create group and Add owners, the calls behind 'az ad group create' and
       'az ad group owner add'). A tenant that forbids it is Manual action required with the Entra steps.
    8. T2's SQL Server install mode: PaygWizard (the default: Hub Performance on T2, after a one-time setup wizard of
       about an hour per guest build) or Developer (no wizard; T2 in Hub's Estate only). It asks unless
       -T2SqlInstallMode or -NonInteractive.
    9. The file (INIT.CONFIG): the example configuration with these values, validated against
       config/environment.schema.json, then written (not with -WhatIf). fabric.manageCapacity stays false unless
       -ManageCapacity.

    Results use the ADR 0012 statuses. Messages name the subscription, workspace, capacity, and group; their IDs are
    only in the evidence and the file. Returns Results, Config, Path, Written, BackupPath, and NextSteps.

    Sources (checked 2026-10-27):
    - az account list: https://learn.microsoft.com/cli/azure/account#az-account-list
    - Sign in with the Azure CLI: https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively
    - Get the signed-in user: https://learn.microsoft.com/graph/api/user-get
    - List groups: https://learn.microsoft.com/graph/api/group-list
    - Create group: https://learn.microsoft.com/graph/api/group-post-groups
    - Add owners: https://learn.microsoft.com/graph/api/group-post-owners
    - Permissions - List For Resource Group, subscription scope: https://learn.microsoft.com/rest/api/authorization/permissions
    - List Capacities: https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities
    - List Workspaces: https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces

    .PARAMETER Path
    The configuration file to write.

    .PARAMETER SubscriptionId
    Use this subscription from the Azure CLI profile instead of asking.

    .PARAMETER TenantId
    Only consider subscriptions in this tenant.

    .PARAMETER Location
    The Azure region (default: the example's, westus3).

    .PARAMETER Prefix
    The resource name prefix (default dbhub).

    .PARAMETER T2SqlInstallMode
    PaygWizard or Developer; empty asks (or PaygWizard with -NonInteractive).

    .PARAMETER WorkspaceName
    The Fabric workspace's name (default "Database Hub Demo").

    .PARAMETER LakehouseName
    The lakehouse's name (default LH_DatabaseHub).

    .PARAMETER CapacityName
    The Fabric capacity to put a new workspace on; empty picks the one you can assign, or asks.

    .PARAMETER AdminGroupName
    The P6 group's display name (default <prefix>-<environment>-sql-admins).

    .PARAMETER AdminGroupObjectId
    Use this P6 group instead of finding one by name.

    .PARAMETER CreateAdminGroup
    Create the P6 group, owned by you, when no group has its name.

    .PARAMETER OwnerEmail
    The budget alerts' address, when Microsoft Graph doesn't return yours (for example for a service principal).

    .PARAMETER TimeZone
    The Windows time zone ID for the VMs' daily auto-shutdown (default: this machine's).

    .PARAMETER ManageCapacity
    Write fabric.manageCapacity true: start-demo.ps1 resumes the capacity when it's paused and stop-demo.ps1 pauses
    what it resumed. Only for a capacity that's yours alone.

    .PARAMETER Force
    Replace an existing configuration, after a backup.

    .PARAMETER NonInteractive
    Never ask: ambiguous choices become Manual action required.

    .PARAMETER BackupDirectory
    Where -Force copies the old configuration (default out/config-backup).

    .EXAMPLE
    $init = Initialize-DemoConfig -Path ./config/demo.config.json -CreateAdminGroup
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $TenantId = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[a-z0-9]+$')]
        [string] $Location = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[a-z][a-z0-9]{2,7}$')]
        [string] $Prefix = '',

        [AllowEmptyString()]
        [ValidateSet('', 'PaygWizard', 'Developer')]
        [string] $T2SqlInstallMode = '',

        [AllowEmptyString()]
        [ValidateLength(0, 256)]
        [string] $WorkspaceName = '',

        [AllowEmptyString()]
        [ValidateLength(0, 256)]
        [string] $LakehouseName = '',

        [AllowEmptyString()]
        [ValidateLength(0, 256)]
        [string] $CapacityName = '',

        [AllowEmptyString()]
        [ValidateLength(0, 256)]
        [string] $AdminGroupName = '',

        [AllowEmptyString()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $AdminGroupObjectId = '',

        [switch] $CreateAdminGroup,

        [AllowEmptyString()]
        [ValidatePattern('^$|^[^@\s]+@[^@\s]+\.[^@\s]+$')]
        [string] $OwnerEmail = '',

        [AllowEmptyString()]
        [string] $TimeZone = '',

        [switch] $ManageCapacity,

        [switch] $Force,

        [switch] $NonInteractive,

        [string] $BackupDirectory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/config-backup'),

        [string] $ExamplePath = (Join-Path -Path $script:RepoRoot -ChildPath 'config/demo.config.example.json'),

        [string] $SchemaPath = (Join-Path -Path $script:RepoRoot -ChildPath 'config/environment.schema.json')
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextSteps = [System.Collections.Generic.List[string]]::new()
    $zeroGuid = '00000000-0000-0000-0000-000000000000'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dryRun = [bool]$WhatIfPreference
    $interactive = -not $NonInteractive -and (Test-DemoInteractiveSession)
    $docs = @{
        AccountList   = 'https://learn.microsoft.com/cli/azure/account#az-account-list'
        SignIn        = 'https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively'
        Me            = 'https://learn.microsoft.com/graph/api/user-get'
        Roles         = 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-cli'
        Capacities    = 'https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities'
        Workspaces    = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces'
        CreateGroup   = 'https://learn.microsoft.com/graph/api/group-post-groups'
        GroupSettings = 'https://learn.microsoft.com/entra/identity/users/groups-self-service-management'
        ListGroups    = 'https://learn.microsoft.com/graph/api/group-list'
        Schema        = 'https://json-schema.org/draft/2020-12/release-notes'
    }
    $add = {
        param([string] $CheckId, [string] $Area, [string] $Target, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '')
        $results.Add((New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $finish = {
        param([bool] $Written, [string] $BackupPath = '', $Config = $null)
        [pscustomobject]@{
            PSTypeName = 'DbHubDemo.InitResult'
            Results    = $results.ToArray()
            Config     = $Config
            Path       = $fullPath
            Written    = $Written
            BackupPath = $BackupPath
            NextSteps  = $nextSteps.ToArray()
        }
    }

    #region 1. The file
    if (-not (Test-DemoConfigPathIgnored -Path $fullPath)) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('{0} is a file Git would commit, so init.ps1 won''t write real IDs to it.' -f $fullPath) @{} 'Write to config/demo.config.json (the default, which Git ignores), a config/*.local.json file, or a path outside the repository.'
        return (& $finish $false)
    }
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($exists -and -not $Force -and -not $dryRun) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Not selected' ('{0} already exists, so nothing was changed.' -f $fullPath) @{ path = $fullPath } 'To write it again from your sign-in, run init.ps1 -Force: it keeps a copy of the old file in out/config-backup first.'
        $nextSteps.Add('./scripts/preflight.ps1')
        $nextSteps.Add('./scripts/deploy.ps1')
        return (& $finish $false)
    }
    if (-not (Test-Path -LiteralPath $ExamplePath -PathType Leaf) -or -not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' 'config/demo.config.example.json or config/environment.schema.json is missing from this clone.' @{} 'Clone the repository again.'
        return (& $finish $false)
    }
    #endregion 1. The file

    #region 2. Discovery before the guard (ADR 0023): az account list, local and read-only
    $loginHint = "Sign in yourself first: 'az login' (add --tenant <tenantId> for one tenant, and --use-device-code in a codespace or a container without a browser), press Enter at the subscription selector, then run init.ps1 again. Nothing here signs in for you or changes your default subscription."
    $profileRead = Get-DemoAzProfileSubscription
    if (-not $profileRead.Installed) {
        & $add 'INIT.AZ.SIGNIN' 'preflight' 'subscription' 'Fail' ('The Azure CLI isn''t available: {0}' -f $profileRead.Error) @{} 'Install the Azure CLI (or open the repository''s dev container), then sign in and run init.ps1 again.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
        return (& $finish $false)
    }
    if (-not $profileRead.SignedIn) {
        & $add 'INIT.AZ.SIGNIN' 'preflight' 'subscription' 'Manual action required' ('No Azure subscription is available to the Azure CLI. {0}' -f $profileRead.Error) @{} $loginHint $docs.SignIn
        return (& $finish $false)
    }
    $candidates = @($profileRead.Subscriptions)
    if ($TenantId) {
        $candidates = @($candidates | Where-Object { $_.TenantId -eq $TenantId.ToLowerInvariant() })
    }
    & $add 'INIT.AZ.SIGNIN' 'preflight' 'subscription' 'Pass' ('The Azure CLI is signed in, with {0} enabled subscription(s){1}.' -f $candidates.Count, $(if ($TenantId) { ' in the tenant you named' } else { '' })) ([ordered]@{ subscriptions = $candidates.Count }) '' $docs.AccountList
    $chosen = $null
    if ($SubscriptionId) {
        $chosen = $candidates | Where-Object { $_.SubscriptionId -eq $SubscriptionId.ToLowerInvariant() } | Select-Object -First 1
        if (-not $chosen) {
            & $add 'INIT.SUBSCRIPTION' 'preflight' 'subscription' 'Manual action required' 'The subscription in -SubscriptionId isn''t among the Azure CLI''s enabled subscriptions.' @{} ("Sign in to its tenant ('az login --tenant <tenantId>'), check it with 'az account list --output table', then run init.ps1 again.") $docs.AccountList
            return (& $finish $false)
        }
    }
    elseif ($candidates.Count -eq 1) {
        $chosen = $candidates[0]
    }
    elseif ($candidates.Count -eq 0) {
        & $add 'INIT.SUBSCRIPTION' 'preflight' 'subscription' 'Manual action required' 'The Azure CLI has no enabled subscription in the tenant you named.' @{} $loginHint $docs.SignIn
        return (& $finish $false)
    }
    elseif ($interactive) {
        $labels = @($candidates | ForEach-Object { '{0} ({1}){2}' -f $_.Name, $_.SubscriptionId, $(if ($_.IsDefault) { ', the Azure CLI default' } else { '' }) })
        $chosen = $candidates[(Read-DemoChoice -Title 'Which subscription should the demo deploy into? (Contributor is enough.)' -Option $labels -Default 0)]
    }
    else {
        & $add 'INIT.SUBSCRIPTION' 'preflight' 'subscription' 'Manual action required' ('The Azure CLI has {0} subscriptions, and init.ps1 doesn''t guess one without asking.' -f $candidates.Count) ([ordered]@{ subscriptions = @($candidates | ForEach-Object { $_.Name }) }) 'Run init.ps1 -SubscriptionId <id> (''az account list --output table'' lists them), or run it without -NonInteractive to choose.' $docs.AccountList
        return (& $finish $false)
    }
    $subscription = [string]$chosen.SubscriptionId
    $tenant = [string]$chosen.TenantId
    $accountKind = switch ([string]$chosen.AccountType) {
        'servicePrincipal' { 'ServicePrincipal' }
        default { 'User' }
    }
    $account = [string]$chosen.Account
    if ($account -in 'systemAssignedIdentity', 'userAssignedIdentity' -or ($accountKind -eq 'User' -and $account -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') -or ($accountKind -eq 'ServicePrincipal' -and $account -notmatch $script:GuidPattern)) {
        $account = ''
    }
    & $add 'INIT.SUBSCRIPTION' 'preflight' 'subscription' 'Pass' ('The demo deploys into the subscription "{0}"{1}. Your default subscription stays as it is.' -f $chosen.Name, $(if ($account) { ' as ' + $account } else { '' })) ([ordered]@{ subscriptionId = $subscription; tenantId = $tenant; account = $account; accountType = [string]$chosen.AccountType }) '' $docs.AccountList
    #endregion 2. Discovery before the guard

    #region 3. The subscription guard
    try {
        # The guard keeps its validated context in memory, also in a dry run: -WhatIf means no file and no group here,
        # and the reads after the guard need that context (live, 2026-10-27: under -WhatIf it wasn't recorded).
        $guard = & {
            $WhatIfPreference = $false
            Assert-DemoAzContext -SubscriptionId $subscription -TenantId $tenant -Account $account
        }
        $results.Add($guard)
    }
    catch {
        & $add 'PREFLIGHT.GUARD.CONTEXT' 'preflight' 'subscription' 'Fail' $_.Exception.Message @{} 'Nothing was written. Sign in yourself again (az login --tenant <tenantId>) and run init.ps1 again.'
        return (& $finish $false)
    }
    $caller = Get-DemoCallerIdentity -SubscriptionId $subscription
    #endregion 3. The subscription guard

    #region 4. The signed-in user
    $ownerAlias = ''
    $email = $OwnerEmail
    $user = $null
    if ($caller.PrincipalType -eq 'User') {
        $user = Get-DemoSignedInUser -SubscriptionId $subscription
    }
    $emailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    if (-not $email -and $user) {
        $email = @($user.Mail, $user.UserPrincipalName, $account) | Where-Object { $_ -match $emailPattern -and $_ -notmatch '#EXT#' } | Select-Object -First 1
    }
    if (-not $email -and $account -match $emailPattern) {
        $email = $account
    }
    $aliasSource = if ($email) { ([string]$email).Split('@')[0] } elseif ($user) { [string]$user.DisplayName } else { '' }
    $ownerAlias = ($aliasSource -replace '[^A-Za-z0-9._-]', '')
    if ($ownerAlias.Length -gt 64) {
        $ownerAlias = $ownerAlias.Substring(0, 64)
    }
    if (-not $email) {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Manual action required' 'No email address was found for the budget alerts (ownerEmail): Microsoft Graph returned none for this sign-in.' @{} 'Run init.ps1 -OwnerEmail <address> -Force.' $docs.Me
    }
    elseif ($user) {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Pass' ('Signed in as {0}: budget alerts go to {1}, and the owner tag is {2}.' -f $(if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $account }), $email, $(if ($ownerAlias) { $ownerAlias } else { 'demo-owner' })) @{} '' $docs.Me
    }
    else {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Warning' ('Microsoft Graph didn''t return the signed-in user, so budget alerts go to {0}.' -f $email) @{} 'Check ownerEmail in the configuration, or run init.ps1 -OwnerEmail <address> -Force.' $docs.Me
    }
    #endregion 4. The signed-in user

    #region 5. P1: Contributor on the subscription
    $permissionUrl = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $subscription
    $permissions = Invoke-DemoAz -SubscriptionId $subscription -ArgumentList @('rest', '--method', 'get', '--url', $permissionUrl) -AsJson -AllowFailure
    $ownerCommand = 'az role assignment create --assignee-object-id {0} --assignee-principal-type {1} --role Contributor --scope /subscriptions/{2}' -f $(if ($caller.ObjectId) { $caller.ObjectId } else { '<your object ID>' }), $(if ($caller.PrincipalType -eq 'ServicePrincipal') { 'ServicePrincipal' } else { 'User' }), $subscription
    if ($null -eq $permissions) {
        & $add 'INIT.P1.CONTRIBUTOR' 'preflight' 'subscription' 'Warning' 'Your permissions on the subscription couldn''t be read; preflight.ps1 checks them again (PREFLIGHT.P1.CONTRIBUTOR).' @{} '' $docs.Roles
    }
    else {
        $required = @('Microsoft.Resources/subscriptions/resourceGroups/write', 'Microsoft.Resources/deployments/write', 'Microsoft.Compute/virtualMachines/runCommands/write', 'Microsoft.HybridCompute/machines/write', 'Microsoft.Consumption/budgets/write')
        # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
        $value = Get-DemoMemberValue -InputObject $permissions -Name 'value'
        $entries = @($value)
        $missing = @($required | Where-Object { -not (Test-DemoPermission -Permission @($entries | Where-Object { $null -ne $_ }) -Action $_) })
        if ($missing.Count -eq 0) {
            & $add 'INIT.P1.CONTRIBUTOR' 'preflight' 'subscription' 'Pass' 'You have Contributor-level permissions on the subscription (P1), all the default path needs.' @{} '' $docs.Roles
        }
        else {
            & $add 'INIT.P1.CONTRIBUTOR' 'preflight' 'subscription' 'Manual action required' ('You''re missing Contributor on the subscription (P1): {0}.' -f ($missing -join ', ')) ([ordered]@{ missing = $missing }) ('A subscription Owner or User Access Administrator runs: {0}' -f $ownerCommand) $docs.Roles
        }
    }
    #endregion 5. P1

    #region Defaults
    $example = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $schemaDefaults = Get-DemoSchemaDefault -Node (Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64)
    $effectivePrefix = if ($Prefix) { $Prefix } elseif ($example['prefix']) { [string]$example['prefix'] } else { 'dbhub' }
    $environment = if ($example['environment']) { [string]$example['environment'] } else { 'demo' }
    $exampleFabric = if ($example['fabric'] -is [System.Collections.IDictionary]) { $example['fabric'] } else { @{} }
    $workspace = if ($WorkspaceName) { $WorkspaceName.Trim() } elseif ($exampleFabric['workspaceName']) { [string]$exampleFabric['workspaceName'] } else { 'Database Hub Demo' }
    $lakehouse = if ($LakehouseName) { $LakehouseName.Trim() } elseif ($exampleFabric['lakehouseName']) { [string]$exampleFabric['lakehouseName'] } else { 'LH_DatabaseHub' }
    #endregion Defaults

    #region 6. Fabric: the capacity and the workspace
    $capacityChosen = ''
    $workspaceExists = $false
    $fabricToken = $null
    try {
        $fabricToken = Get-DemoFabricToken -SubscriptionId $subscription
    }
    catch {
        & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Warning' ('Fabric couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) @{} 'Set fabric.capacityName in the configuration to the F or Trial capacity for the workspace; deploy.ps1 resolves the rest.' $docs.Capacities
    }
    if ($null -ne $fabricToken) {
        $capacityList = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $script:FabricApiBaseUri) -Token $fabricToken -MaxPages 10
        # Only F, Fabric trial (FT..., FTL64 live on 2026-10-27), and P capacities run Fabric items; Premium Per User (PP3)
        # and Embedded (A) capacities don't, so they aren't offered.
        $allCapacities = @($capacityList.Items | Where-Object { $null -ne $_ })
        $capacities = @($allCapacities | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'sku') -match '^(F[0-9]+|FT[A-Z]*[0-9]+|P[0-9]+)$' })
        $skipped = $allCapacities.Count - $capacities.Count
        $describe = { param($Item) '{0} ({1}, {2}, {3})' -f [string](Get-DemoMemberValue -InputObject $Item -Name 'displayName'), [string](Get-DemoMemberValue -InputObject $Item -Name 'sku'), [string](Get-DemoMemberValue -InputObject $Item -Name 'state'), [string](Get-DemoMemberValue -InputObject $Item -Name 'region') }
        $visible = (@($capacities | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') }) | Select-Object -First 8) -join ', '
        $addContributor = 'A capacity administrator adds you as a contributor (Fabric admin portal > Capacity settings > the capacity > Contributor permissions), or start a Fabric trial in the Fabric portal. The scripts never create a capacity.'
        $capacity = $null
        if (-not $capacityList.Succeeded) {
            & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Warning' ('The Fabric capacities you can assign couldn''t be listed: {0}' -f $capacityList.Error) @{} 'Set fabric.capacityName in the configuration to the F or Trial capacity for the workspace.' $docs.Capacities
        }
        elseif ($CapacityName) {
            $named = @(Select-DemoFabricNamed -Items $capacities -Name $CapacityName)
            if ($named.Count -eq 1) {
                $capacity = $named[0]
            }
            else {
                & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Manual action required' ('{0} capacity named "{1}" is among those you can assign ({2}).' -f $(if ($named.Count -eq 0) { 'No' } else { 'More than one' }), $CapacityName, $(if ($visible) { $visible } else { 'none' })) @{} ('Run init.ps1 -Force -CapacityName with one of them. {0}' -f $addContributor) $docs.Capacities
            }
        }
        elseif ($capacities.Count -eq 0) {
            & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Manual action required' ('You can''t assign any F or Trial Fabric capacity{0}, so deploy.ps1 can''t create the workspace on one.' -f $(if ($skipped -gt 0) { ' ({0} other capacities, such as Premium Per User, don''t run Fabric items)' -f $skipped } else { '' })) @{} ('{0} Then run init.ps1 -Force.' -f $addContributor) $docs.Capacities
        }
        elseif ($capacities.Count -eq 1) {
            $capacity = $capacities[0]
        }
        elseif ($interactive) {
            $active = @(for ($i = 0; $i -lt $capacities.Count; $i++) { if ([string](Get-DemoMemberValue -InputObject $capacities[$i] -Name 'state') -ieq 'Active') { $i } })
            $index = Read-DemoChoice -Title 'Which Fabric capacity should the demo''s workspace use? (Its administrator decides when it runs.)' -Option @($capacities | ForEach-Object { & $describe $_ }) -Default $(if ($active.Count -gt 0) { $active[0] } else { 0 })
            $capacity = $capacities[$index]
        }
        else {
            & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Manual action required' ('You can assign {0} Fabric capacities ({1}), and init.ps1 doesn''t guess one without asking.' -f $capacities.Count, $visible) @{} 'Run init.ps1 -Force -CapacityName <name>, or without -NonInteractive to choose.' $docs.Capacities
        }
        if ($null -ne $capacity) {
            $capacityChosen = [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName')
            $state = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
            $evidence = [ordered]@{ capacityName = $capacityChosen; sku = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku'); state = $state; region = [string](Get-DemoMemberValue -InputObject $capacity -Name 'region') }
            if ($state -ieq 'Active') {
                & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Pass' ('The workspace goes on the capacity {0}.' -f (& $describe $capacity)) $evidence '' $docs.Capacities
            }
            else {
                $resume = if ($ManageCapacity) { 'With fabric.manageCapacity true, start-demo.ps1 resumes it; deploy.ps1 doesn''t, so resume it once yourself before deploy.ps1 (Azure portal > the Fabric capacity > Resume).' } else { 'Its administrator resumes it before deploy.ps1 (Azure portal > the Fabric capacity > Resume): the Fabric track needs it running, and the scripts never resume it unless fabric.manageCapacity is true.' }
                & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Warning' ('The workspace goes on the capacity {0}, which isn''t running now.' -f (& $describe $capacity)) $evidence $resume 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
            }
        }

        $workspaceList = Read-DemoHubFabricList -Uri ('{0}/workspaces' -f $script:FabricApiBaseUri) -Token $fabricToken -MaxPages 20
        if (-not $workspaceList.Succeeded) {
            & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Warning' ('Your Fabric workspaces couldn''t be listed: {0}' -f $workspaceList.Error) @{ workspaceName = $workspace } 'deploy.ps1 finds or creates the workspace by name (ADR 0021).' $docs.Workspaces
        }
        else {
            $shared = @($workspaceList.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ine 'Personal' })
            $found = @(Select-DemoFabricNamed -Items $shared -Name $workspace)
            if ($found.Count -gt 1) {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ('More than one workspace named "{0}" is visible to you.' -f $workspace) @{ workspaceName = $workspace; matches = $found.Count } 'Run init.ps1 -Force -WorkspaceName with a name no other workspace uses.' $docs.Workspaces
            }
            elseif ($found.Count -eq 1) {
                $workspaceExists = $true
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Pass' ('The Fabric workspace "{0}" exists; the scripts use it, and deploy.ps1 adds only the notebooks that are missing.' -f $workspace) @{ workspaceName = $workspace } '' $docs.Workspaces
            }
            elseif ($capacityChosen) {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Pass' ('The Fabric workspace "{0}" doesn''t exist yet: deploy.ps1 creates it on "{1}" with the lakehouse "{2}", and imports the notebooks (fabric.importNotebooks true). Creating it needs the Fabric tenant setting "Create workspaces" for you.' -f $workspace, $capacityChosen, $lakehouse) @{ workspaceName = $workspace; capacityName = $capacityChosen } '' 'https://learn.microsoft.com/fabric/admin/portal-workspace'
            }
            else {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ('The Fabric workspace "{0}" doesn''t exist yet, and no capacity is chosen to create it on.' -f $workspace) @{ workspaceName = $workspace } 'Fix INIT.FABRIC.CAPACITY above, or create the workspace on an F or Trial capacity yourself and add a lakehouse named LH_DatabaseHub; then run init.ps1 -Force.' $docs.Workspaces
            }
        }
    }
    #endregion 6. Fabric

    #region 7. P6: the Microsoft Entra security group
    $groupId = $zeroGuid
    $groupName = if ($AdminGroupName) { $AdminGroupName.Trim() } else { '{0}-{1}-sql-admins' -f $effectivePrefix, $environment }
    $callerId = [string]$caller.ObjectId
    $ownership = {
        param([string] $Id, [string] $Name, [string] $How)
        $owned = if ($callerId) { Test-DemoEntraGroupOwner -SubscriptionId $subscription -GroupId $Id -OwnerId $callerId } else { $null }
        if ($owned -eq $true) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Pass' ('{0} the security group "{1}", which you own, so deploy.ps1 adds T1 to it and T1 sets up T3 and T4 (P6).' -f $How, $Name) @{ groupDisplayName = $Name } '' $docs.ListGroups
        }
        else {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Warning' ('{0} the security group "{1}", but you {2} its owner, so T1 can''t be added to it automatically; T3''s fallback is an interactive T-SQL step (ADR 0008).' -f $How, $Name, $(if ($null -eq $owned) { 'may not be' } else { 'aren''t' })) @{ groupDisplayName = $Name } 'Ask a group owner to add you as an owner, or run init.ps1 -Force -CreateAdminGroup -AdminGroupName <a new name>.' $docs.ListGroups
        }
    }
    $createSteps = "An Entra administrator creates a security group named '{0}' with you as its owner (Microsoft Entra admin center > Groups > All groups > New group: Security, Owners: you), or runs: az ad group create --display-name {0} --mail-nickname {0}, then az ad group owner add --group {0} --owner-object-id {1}. Then run init.ps1 -Force -AdminGroupObjectId <the group's object ID>." -f $groupName, $(if ($callerId) { $callerId } else { '<your object ID>' })
    if ($AdminGroupObjectId) {
        $read = Find-DemoEntraGroup -SubscriptionId $subscription -ObjectId $AdminGroupObjectId
        if ($read.Succeeded -and @($read.Groups).Count -eq 1) {
            $groupId = $AdminGroupObjectId.ToLowerInvariant()
            $groupName = [string](Get-DemoMemberValue -InputObject @($read.Groups)[0] -Name 'displayName')
            & $ownership $groupId $groupName 'Using'
        }
        else {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('The group in -AdminGroupObjectId wasn''t found in the tenant ({0}).' -f $(if ($read.Error) { $read.Error } else { 'not found' })) @{} 'Check the object ID in the Microsoft Entra admin center (Groups), then run init.ps1 -Force again.' $docs.ListGroups
        }
    }
    else {
        $read = Find-DemoEntraGroup -SubscriptionId $subscription -DisplayName $groupName
        $matched = @($read.Groups | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $groupName -or [string]::Equals([string](Get-DemoMemberValue -InputObject $_ -Name 'displayName'), $groupName, [System.StringComparison]::OrdinalIgnoreCase) })
        if (-not $read.Succeeded) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('Microsoft Entra groups couldn''t be searched: {0}' -f $read.Error) @{} $createSteps $docs.ListGroups
        }
        elseif ($matched.Count -gt 1) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('More than one group is named "{0}".' -f $groupName) @{ matches = $matched.Count } 'Run init.ps1 -Force -AdminGroupObjectId <the one you own>, or -AdminGroupName <another name> -CreateAdminGroup.' $docs.ListGroups
        }
        elseif ($matched.Count -eq 1) {
            $groupId = ([string](Get-DemoMemberValue -InputObject $matched[0] -Name 'id')).ToLowerInvariant()
            & $ownership $groupId $groupName 'Found'
        }
        elseif (-not $CreateAdminGroup) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('No security group named "{0}" exists, so T3 and T4 have no administrator group yet (P6).' -f $groupName) @{ groupDisplayName = $groupName } ('Run init.ps1 -Force -CreateAdminGroup to create it with you as its owner, or: {0}' -f $createSteps) $docs.CreateGroup
        }
        elseif ($groupName -notmatch '^[A-Za-z0-9._-]{1,63}$') {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('"{0}" can''t be used for a new group here: use letters, digits, periods, underscores, and hyphens only, at most 63 characters (it''s also T4''s PostgreSQL role name).' -f $groupName) @{} 'Run init.ps1 -Force -CreateAdminGroup -AdminGroupName <name>.' $docs.CreateGroup
        }
        elseif (-not $callerId) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' 'Your object ID isn''t known, so no group was created with you as its owner.' @{} $createSteps $docs.CreateGroup
        }
        elseif ($dryRun) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Not selected' ('What if: the security group "{0}" would be created with you as its owner (Microsoft Graph, Create group).' -f $groupName) @{ groupDisplayName = $groupName } '' $docs.CreateGroup
        }
        else {
            $created = New-DemoEntraSecurityGroup -SubscriptionId $subscription -DisplayName $groupName -OwnerId $callerId -OwnerType $(if ($caller.PrincipalType -eq 'ServicePrincipal') { 'ServicePrincipal' } else { 'User' }) -Confirm:$false
            switch ($created.Status) {
                'Created' {
                    $groupId = $created.GroupId
                    & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Pass' ('Created the security group "{0}" with you as its owner, so deploy.ps1 adds T1 to it and T1 sets up T3 and T4 (P6).' -f $groupName) @{ groupDisplayName = $groupName; created = $true } '' $docs.CreateGroup
                }
                'OwnerMissing' {
                    $groupId = $created.GroupId
                    & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Warning' ('Created the security group "{0}", but you couldn''t be added as its owner: {1}' -f $groupName, $created.Error) @{ groupDisplayName = $groupName; created = $true } ('An Entra administrator adds you as an owner: az ad group owner add --group {0} --owner-object-id {1}' -f $groupName, $callerId) 'https://learn.microsoft.com/graph/api/group-post-owners'
                }
                'Forbidden' {
                    & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('Your tenant doesn''t let you create the security group "{0}" (HTTP {1}): creating groups is restricted to administrators there.' -f $groupName, $created.StatusCode) @{ groupDisplayName = $groupName } $createSteps $docs.GroupSettings
                }
                default {
                    & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Fail' ('The security group "{0}" couldn''t be created: {1}' -f $groupName, $created.Error) @{ groupDisplayName = $groupName } $createSteps $docs.CreateGroup
                }
            }
        }
    }
    #endregion 7. P6

    #region 8. T2's SQL Server install mode
    $mode = $T2SqlInstallMode
    if (-not $mode) {
        $mode = 'PaygWizard'
        if ($interactive) {
            $options = @(
                'PaygWizard (default): Database Hub shows T2''s performance. Once per guest build, you run the SQL Server setup wizard through Bastion (about an hour).'
                'Developer: no wizard, unattended. T2 shows in Database Hub''s Estate only, not Performance; T1, T3, and T4 still show performance.'
            )
            $mode = @('PaygWizard', 'Developer')[(Read-DemoChoice -Title 'How should T2 (the Arc-enabled SQL Server) install SQL Server?' -Option $options -Default 0)]
        }
    }
    #endregion 8. T2

    #region 9. The configuration
    $zone = $TimeZone
    $zoneNote = ''
    if ($zone -and -not (Test-DemoWindowsTimeZoneId -Id $zone)) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('"{0}" isn''t a Windows time zone ID.' -f $zone) @{} 'Pass a Windows time zone ID, for example -TimeZone ''Eastern Standard Time'' (Get-TimeZone -ListAvailable lists them).' 'https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-time-zones'
        return (& $finish $false)
    }
    if (-not $zone) {
        $local = Get-DemoWindowsTimeZoneId
        $zone = if ($local.Id) { $local.Id } else { [string]$schemaDefaults['autoShutdownTimeZone'] }
        if ($local.IsUtc -or -not $local.Id) {
            $zoneNote = ' This machine''s time zone is {0}, so the VMs stop at {1} {0}; pass -TimeZone (for example ''Eastern Standard Time'') for your own.' -f $zone, $example['autoShutdownTime']
        }
    }
    $config = $example
    $config['subscriptionId'] = $subscription
    $config['tenantId'] = $tenant
    if ($account) {
        $config['azureAccount'] = $account
    }
    else {
        $config.Remove('azureAccount')
    }
    if ($Location) {
        $config['location'] = $Location
    }
    $config['prefix'] = $effectivePrefix
    $config['t2SqlInstallMode'] = $mode
    $config['t3AdminGroupObjectId'] = $groupId
    $config['owner'] = if ($ownerAlias) { $ownerAlias } else { [string]$schemaDefaults['owner'] }
    if ($email) {
        $config['ownerEmail'] = [string]$email
    }
    $config['autoShutdownTimeZone'] = $zone
    $fabric = [ordered]@{}
    foreach ($key in $exampleFabric.Keys) {
        $fabric[$key] = $exampleFabric[$key]
    }
    $fabric['workspaceName'] = $workspace
    $fabric['lakehouseName'] = $lakehouse
    $fabric['capacityName'] = $capacityChosen
    $fabric['createIfMissing'] = $true
    $fabric['importNotebooks'] = -not $workspaceExists
    $fabric['manageCapacity'] = [bool]$ManageCapacity
    $config['fabric'] = $fabric
    $repository = Get-DemoGitHubRepositoryName
    if ($repository -and $config['github'] -is [System.Collections.IDictionary]) {
        $config['github']['repository'] = $repository
    }

    $json = $config | ConvertTo-Json -Depth 32
    $validationErrors = @()
    $valid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorVariable validationErrors -ErrorAction SilentlyContinue
    $written = @('subscriptionId', 'tenantId', $(if ($account) { 'azureAccount' }), 'prefix', 't2SqlInstallMode', 't3AdminGroupObjectId', 'owner', 'ownerEmail', 'autoShutdownTimeZone', 'fabric') | Where-Object { $_ }
    $summary = 'subscription "{0}", region {1}, prefix {2}, T2 {3}, the workspace "{4}" on "{5}", and the P6 group {6}' -f $chosen.Name, $config['location'], $effectivePrefix, $mode, $workspace, $(if ($capacityChosen) { $capacityChosen } else { '(none yet)' }), $(if ($groupId -ne $zeroGuid) { '"' + $groupName + '"' } else { '(none yet)' })
    if (-not $valid) {
        $details = ($validationErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique) -join '; '
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('The configuration doesn''t match config/environment.schema.json, so it wasn''t written: {0}' -f $details) @{} 'Check the values you passed to init.ps1 and run it again.' $docs.Schema
        return (& $finish $false '' $config)
    }
    $backupPath = ''
    if ($dryRun -or -not $PSCmdlet.ShouldProcess($fullPath, 'Write the demo configuration')) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Not selected' ('What if: {0} would be written ({1}){2}, validated against the schema.{3}' -f $fullPath, $summary, $(if ($exists -and -not $Force) { '; it exists, so init.ps1 needs -Force to replace it' } else { '' }), $zoneNote) ([ordered]@{ path = $fullPath; keys = @($written) }) '' ''
    }
    else {
        try {
            if ($exists) {
                $null = New-Item -ItemType Directory -Path $BackupDirectory -Force
                $stamp = [System.DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
                $backupPath = Join-Path -Path $BackupDirectory -ChildPath ('{0}.{1}.json' -f [System.IO.Path]::GetFileNameWithoutExtension($fullPath), $stamp)
                Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
            }
            $directory = Split-Path -Path $fullPath -Parent
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                $null = New-Item -ItemType Directory -Path $directory -Force
            }
            [System.IO.File]::WriteAllText($fullPath, ($json + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
        catch {
            & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('The configuration couldn''t be written: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) @{} 'Check that the folder is writable, then run init.ps1 again.' ''
            return (& $finish $false $backupPath $config)
        }
        $message = 'Wrote {0}: {1}. It''s Git-ignored and holds no secrets, and it matches the schema.{2}{3}' -f $fullPath, $summary, $(if ($backupPath) { ' The old file is in ' + $backupPath + '.' } else { '' }), $zoneNote
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Pass' $message ([ordered]@{ path = $fullPath; backupPath = $backupPath; keys = @($written) }) '' ''
    }
    #endregion 9. The configuration

    #region Next steps
    $configArgument = if ($fullPath -ieq [System.IO.Path]::GetFullPath((Join-Path -Path $script:RepoRoot -ChildPath 'config/demo.config.json'))) { '' } else { ' -ConfigPath "{0}"' -f $fullPath }
    $open = @($results | Where-Object { $_.checkId -like 'INIT.*' -and $_.status -in 'Manual action required', 'Fail' })
    if ($open.Count -gt 0) {
        $nextSteps.Add(('Fix what''s listed under Manual action required above ({0}), then run init.ps1 -Force again.' -f (($open | ForEach-Object { $_.checkId }) -join ', ')))
    }
    $nextSteps.Add(('./scripts/preflight.ps1{0}   # checks P1-P6, quota, policies, and the cost; registers missing providers' -f $configArgument))
    $nextSteps.Add(('./scripts/deploy.ps1{0}      # a first deploy takes about 1.5-2 hours; keep this machine awake' -f $configArgument))
    if ($mode -eq 'PaygWizard') {
        $nextSteps.Add(('When status.ps1 says the T2 host waits for the setup wizard (DEPLOY.T2.BACKGROUND), follow its steps, then: ./scripts/deploy.ps1 -FromStage T2{0}' -f $configArgument))
    }
    $nextSteps.Add(('./scripts/configure-fabric-app.ps1 -SignIn{0}   # optional, the Insights app: one browser sign-in, then it deploys' -f $configArgument))
    $nextSteps.Add(('Each session: ./scripts/start-demo.ps1{0}, then ./scripts/stop-demo.ps1 -SaveHistory{0}' -f $configArgument))
    #endregion Next steps

    $isWritten = @($results | Where-Object { $_.checkId -eq 'INIT.CONFIG' -and $_.status -eq 'Pass' }).Count -gt 0
    return (& $finish $isWritten $backupPath $config)
}
