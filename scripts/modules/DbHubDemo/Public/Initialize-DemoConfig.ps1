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
    4b. An environment that exists already (INIT.EXISTING; issue 60, 2026-11-18), read-only: the subscription's resource
       groups and deployment records (Resolve-DemoExistingEnvironment). No rg-<prefix>-<environment>, rg-<prefix>-control,
       rg-<prefix>-golden, or record <prefix>-<environment>-main: a new environment (Pass), as before. One that's yours
       (its owner tag or budget address is your sign-in, or you own the group that administers its T3 and T4): the
       configuration is written from what's deployed, its deployment record's parameters and its resource group's tags
       (ConvertFrom-DemoDeploymentRecord), so the next deploy.ps1 changes nothing you didn't ask for; its Fabric
       workspaces and their capacity come from what it records (Resolve-DemoRecoveredWorkspace), its session control's
       custom roles keep their suffix (control.roleNameSuffix, Get-DemoControlRoleSuffix), its administrators'
       group is kept (never created), and the settings Azure doesn't record keep their defaults, listed (Warning). One
       that isn't yours, or can't be told apart: never written for. With an explicit -Prefix, Manual action required
       (-OwnerEmail with its recorded budget address claims it); otherwise the first prefix after it that's yours, or
       that's free (<prefix>2 to <prefix>99), with its own group and the Fabric workspace "Database Hub Demo <prefix>"
       (Warning). A read that fails is a Fail, and nothing is written. Parameters you pass win over what's recovered.
       A new environment gets "Database Hub Demo <prefix>" for every prefix but the default, whether -Prefix named it or
       the run picked it (2026-11-19), so a second environment never shares the first one's workspace.
    5. P1 (INIT.P1.CONTRIBUTOR): the caller's permissions on the subscription, as preflight reads them; without
       Contributor, Manual action required with the Owner's exact command.
    6. Fabric (INIT.FABRIC.CAPACITY, INIT.FABRIC.WORKSPACE): the capacities you can assign (Capacities - List
       Capacities; it asks when there's more than one) and whether the workspace fabric.workspaceName already exists
       (Workspaces - List Workspaces). A workspace that doesn't exist yet gets fabric.importNotebooks true; deploy.ps1
       creates it, its lakehouse, and the notebooks (ADR 0021). One that exists gets false, so deploy.ps1 only adds the
       notebooks that are missing, except a recovered environment's own (4b): the workspace its resource group records,
       one that holds only what the demo creates, or one the demo's notebooks are already in (Items - List Items,
       read-only), gets true, as the update republishes its notebooks (Resolve-DemoRecoveredNotebookImport), and
       INIT.EXISTING says which and why. Nothing is created in Fabric here. A workspace that exists is checked against
       what the other demo environments record (2026-11-19: one Azure Resource Graph query, Get-DemoFabricWorkspaceClaim;
       Resolve-DemoFabricWorkspaceClaim), and one that another records is never a Pass: a default name gives way to the
       environment's own, "Database Hub Demo <prefix>" (a Warning that says so); a -WorkspaceName that names one is
       Manual action required, with the environment that records it; an environment's own that another records too is
       a Warning, with how to move; and a Resource Graph that can't answer is a Warning.
    7. P6 (INIT.P6.GROUP): the Microsoft Entra security group by -AdminGroupObjectId, or by name (default
       <prefix>-<environment>-sql-admins), and whether you own it. With -CreateAdminGroup, a missing group is created
       with you as its owner (Microsoft Graph Create group and Add owners, the calls behind 'az ad group create' and
       'az ad group owner add'). A tenant that forbids it is Manual action required with the Entra steps.
    8. T2's SQL Server install mode, without a question since 2026-11-09 (user-directed, so a first deployment never needs
       anyone to sign in to a VM): -T2SqlInstallMode when it's given, otherwise JumpstartImage (the default: Arc Jumpstart's
       prebuilt SQL Server 2022 Standard guest, no stop, Hub Performance on T2), with one line that says so and how to pick
       another on purpose: Developer (no stop; T2 in Hub's Estate only). PaygWizard is retired from the one-click
       deployment: deploy.ps1 runs a configuration's PaygWizard as JumpstartImage.
    9. The file (INIT.CONFIG): the example configuration with these values, validated against
       config/environment.schema.json, then written (not with -WhatIf). fabric.manageCapacity stays false unless
       -ManageCapacity.

    Results use the ADR 0012 statuses. Messages name the subscription, workspace, capacity, and group; their IDs are
    only in the evidence and the file. Every command a result, its fix, or a next step tells you to run names this run's
    -Prefix when it isn't the default, and its -ConfigPath when it isn't config/demo.config.json (Resolve-DemoInitCommandText,
    2026-11-19), so it never writes the default prefix's configuration for another environment. Returns Results, Config,
    Path, Written, BackupPath, NextSteps, and Existing (Kind:
    New, Recovered, NewPrefix, NotYours, or Unreadable; Prefix, ResourceGroup, Signal, and Note, the line deploy.ps1's
    banner and status page show).

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
    - Azure Resource Graph, query scope (checked 2026-11-19): https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language#query-scope

    .PARAMETER Path
    The configuration file to write.

    .PARAMETER SubscriptionId
    Use this subscription from the Azure CLI profile instead of asking.

    .PARAMETER TenantId
    Only consider subscriptions in this tenant.

    .PARAMETER Location
    The Azure region (default: the example's, westus3).

    .PARAMETER Prefix
    The resource name prefix (default dbhub). When its environment exists and isn't yours, nothing is written (issue 60);
    without it, a first run picks a free prefix by itself, and a run over an existing configuration keeps the prefix it
    holds, as if -Prefix named it (2026-11-19).

    .PARAMETER T2SqlInstallMode
    JumpstartImage or Developer, to choose T2's mode on purpose; empty gives JumpstartImage, the default, without a
    question (2026-11-09). PaygWizard is retired from the one-click deployment.

    .PARAMETER WorkspaceName
    The Fabric workspace's name (default "Database Hub Demo", and "Database Hub Demo <prefix>" for a new environment whose
    prefix isn't the default). One that another demo environment records is Manual action required.

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
    The budget alerts' address, when Microsoft Graph doesn't return yours (for example for a service principal). With an
    explicit -Prefix whose environment records it as its budget address or owner tag, it claims that environment as yours
    (issue 60).

    .PARAMETER TimeZone
    The Windows time zone ID for the VMs' daily auto-shutdown (default: this machine's).

    .PARAMETER ManageCapacity
    Write fabric.manageCapacity true: start-demo.ps1 resumes the capacity when it's paused and stop-demo.ps1 pauses
    what it resumed. Only for a capacity that's yours alone.

    .PARAMETER Force
    Replace an existing configuration, after a backup. Without -Prefix, the new one keeps the old one's prefix and
    environment (Get-DemoConfigFileIdentity), so it stays that environment's; INIT.CONFIG says so.

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
        [ValidateSet('', 'JumpstartImage', 'Developer')]
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
    # Relative to PowerShell's current location, not the process's working directory (review fix 8).
    $fullPath = Resolve-DemoUserPath -Path $Path
    $dryRun = [bool]$WhatIfPreference
    $interactive = -not $NonInteractive -and (Test-DemoInteractiveSession)
    # How a fix says to choose where this run couldn't ask (the final tests' F6): without -NonInteractive only when it was
    # given here, where a person could answer; otherwise the terminal couldn't take input (CI, an assistant, redirected
    # input, or deploy.ps1's first run there).
    $chooseHow = if ($NonInteractive -and (Test-DemoInteractiveSession)) { 'without -NonInteractive' } else { 'in a terminal that can take input' }
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
    $existingSummary = $null
    # The prefix the commands this run prints name (Resolve-DemoInitCommandText): -Prefix until the run resolves its own.
    $commandPrefix = $Prefix
    $commandDefaultPrefix = 'dbhub'
    $finish = {
        param([bool] $Written, [string] $BackupPath = '', $Config = $null)
        # Every command a result, its fix, or a next step tells you to run names this run's -Prefix and -ConfigPath
        # (2026-11-19), so it never writes the default prefix's configuration, or config/demo.config.json, for another
        # environment, nor runs another script on it.
        foreach ($item in $results) {
            $item.message = Protect-DemoText -Text (Resolve-DemoInitCommandText -Text ([string]$item.message) -Prefix $commandPrefix -DefaultPrefix $commandDefaultPrefix -ConfigPath $fullPath)
            $item.remediation = Protect-DemoText -Text (Resolve-DemoInitCommandText -Text ([string]$item.remediation) -Prefix $commandPrefix -DefaultPrefix $commandDefaultPrefix -ConfigPath $fullPath)
        }
        [pscustomobject]@{
            PSTypeName = 'DbHubDemo.InitResult'
            Results    = $results.ToArray()
            Config     = $Config
            Path       = $fullPath
            Written    = $Written
            BackupPath = $BackupPath
            NextSteps  = @($nextSteps | ForEach-Object { Resolve-DemoInitCommandText -Text $_ -Prefix $commandPrefix -DefaultPrefix $commandDefaultPrefix -ConfigPath $fullPath })
            Existing   = $existingSummary
        }
    }

    #region 1. The file
    if (-not (Test-DemoConfigPathIgnored -Path $fullPath)) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('{0} is a file Git would commit, so init.ps1 won''t write real IDs to it.' -f $fullPath) @{} 'Write to config/demo.config.json (the default, which Git ignores), a config/*.local.json file, or a path outside the repository.'
        return (& $finish $false)
    }
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    # The environment the file is for (2026-11-19, the final tests' F7): a run that overwrites it without -Prefix keeps its
    # prefix, as if -Prefix named it, and its environment (Defaults), never the example's dbhub, so whatever command is
    # followed, the file never moves to another environment. An explicit -Prefix still wins.
    $held = if ($exists) { Get-DemoConfigFileIdentity -Path $fullPath } else { $null }
    $keptPrefix = ''
    if ($null -ne $held -and $held.Prefix -and -not $Prefix) {
        $keptPrefix = $held.Prefix
        $Prefix = $keptPrefix
        $commandPrefix = $Prefix
    }
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
        & $add 'INIT.SUBSCRIPTION' 'preflight' 'subscription' 'Manual action required' ('The Azure CLI has {0} subscriptions, and init.ps1 doesn''t guess one without asking.' -f $candidates.Count) ([ordered]@{ subscriptions = @($candidates | ForEach-Object { $_.Name }) }) ('Run init.ps1 -SubscriptionId <id> (''az account list --output table'' lists them), or run init.ps1 {0}, to choose.' -f $chooseHow) $docs.AccountList
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
    # Your sign-in's addresses, which tell an environment that's yours (issue 60). Never -OwnerEmail, which can be any
    # address: it counts only as a claim, with an explicit -Prefix (region 4b).
    $signIn = [System.Collections.Generic.List[string]]::new()
    if ($user) {
        $signIn.Add([string]$user.UserPrincipalName)
        $signIn.Add([string]$user.Mail)
    }
    $signIn.Add($account)
    $addresses = @($signIn | Where-Object { $_ -match $emailPattern })
    #endregion 4. The signed-in user (INIT.USER is reported in region 4b, with the values the configuration gets)

    #region Defaults
    $example = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $schemaDefaults = Get-DemoSchemaDefault -Node (Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64)
    $defaultPrefix = if ($example['prefix']) { [string]$example['prefix'] } else { 'dbhub' }
    $commandDefaultPrefix = $defaultPrefix
    $effectivePrefix = if ($Prefix) { $Prefix } else { $defaultPrefix }
    $environment = if ($example['environment']) { [string]$example['environment'] } else { 'demo' }
    $keptEnvironment = ''
    if ($null -ne $held -and $held.Environment -and $held.Prefix -ceq $effectivePrefix -and $held.Environment -cne $environment) {
        # The file's environment stays with its prefix, so rg-<prefix>-<environment> stays the group it's for (F7).
        $environment = $held.Environment
        $keptEnvironment = $environment
    }
    $exampleFabric = if ($example['fabric'] -is [System.Collections.IDictionary]) { $example['fabric'] } else { @{} }
    $defaultWorkspace = if ($exampleFabric['workspaceName']) { [string]$exampleFabric['workspaceName'] } else { 'Database Hub Demo' }
    $workspace = if ($WorkspaceName) { $WorkspaceName.Trim() } else { $defaultWorkspace }
    $lakehouse = if ($LakehouseName) { $LakehouseName.Trim() } elseif ($exampleFabric['lakehouseName']) { [string]$exampleFabric['lakehouseName'] } else { 'LH_DatabaseHub' }
    #endregion Defaults

    #region 4b. An environment that exists already (issue 60, 2026-11-18)
    # Before 2026-11-18 a first run wrote the defaults for the prefix without checking whether its environment existed, so
    # the next deploy.ps1 applied them to it. Reads only: the subscription's resource groups and deployment records, the
    # environment's record, and Microsoft Graph for its administrators' group.
    $callerId = [string]$caller.ObjectId
    $claims = if ($Prefix -and $OwnerEmail) { @($OwnerEmail) } else { @() }
    $existing = Resolve-DemoExistingEnvironment -SubscriptionId $subscription -Prefix $effectivePrefix -Environment $environment -ExplicitPrefix:([bool]$Prefix) -Address $addresses -Claim $claims -CallerId $callerId
    $recovered = $existing.Kind -eq 'Recovered'
    $recoveredValue = { param([string] $Key) if ($recovered -and $existing.Values.Contains($Key)) { $existing.Values[$Key] } else { $null } }
    if ($existing.Kind -in 'Unreadable', 'NotYours') {
        $report = Get-DemoExistingEnvironmentReport -Existing $existing -Path $fullPath
        $results.Add($report.Result)
        $existingSummary = [pscustomobject]@{ Kind = [string]$existing.Kind; Prefix = [string]$existing.Prefix; ResourceGroup = [string]$existing.ResourceGroup; Signal = ''; Note = '' }
        return (& $finish $false)
    }
    $effectivePrefix = [string]$existing.Prefix
    $commandPrefix = $effectivePrefix
    if ($existing.Kind -in 'New', 'NewPrefix' -and -not $WorkspaceName -and $effectivePrefix -cne $defaultPrefix) {
        # A new environment's own workspace, so it never shares another environment's: "Database Hub Demo <prefix>" for every
        # prefix but the default, whether -Prefix named it or the run picked it. Before 2026-11-19 an explicit -Prefix kept
        # "Database Hub Demo", the default prefix's environment's (the final tests' F5).
        $workspace = '{0} {1}' -f $defaultWorkspace, $effectivePrefix
    }
    # The budget alerts' address and the owner tag: -OwnerEmail, else what the environment records, else your sign-in.
    $emailSource = if ($OwnerEmail) { 'option' } else { 'sign-in' }
    if (-not $OwnerEmail -and (& $recoveredValue 'ownerEmail')) {
        $email = [string](& $recoveredValue 'ownerEmail')
        $emailSource = 'recorded'
    }
    $aliasSource = if ($email) { ([string]$email).Split('@')[0] } elseif ($user) { [string]$user.DisplayName } else { '' }
    $ownerAlias = ($aliasSource -replace '[^A-Za-z0-9._-]', '')
    if ($ownerAlias.Length -gt 64) {
        $ownerAlias = $ownerAlias.Substring(0, 64)
    }
    $ownerTag = if (& $recoveredValue 'owner') { [string](& $recoveredValue 'owner') } elseif ($ownerAlias) { $ownerAlias } else { [string]$schemaDefaults['owner'] }
    $recordedNote = ' (as {0} has it)' -f $existing.ResourceGroup
    if (-not $email) {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Manual action required' 'No email address was found for the budget alerts (ownerEmail): Microsoft Graph returned none for this sign-in.' @{} 'Run init.ps1 -OwnerEmail <address> -Force.' $docs.Me
    }
    elseif ($user) {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Pass' ('Signed in as {0}: budget alerts go to {1}{2}, and the owner tag is {3}{4}.' -f $(if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $account }), $email, $(if ($emailSource -eq 'recorded') { $recordedNote } else { '' }), $ownerTag, $(if (& $recoveredValue 'owner') { $recordedNote } else { '' })) @{} '' $docs.Me
    }
    else {
        & $add 'INIT.USER' 'preflight' 'subscription' 'Warning' ('Microsoft Graph didn''t return the signed-in user, so budget alerts go to {0}{1}.' -f $email, $(if ($emailSource -eq 'recorded') { $recordedNote } else { '' })) @{} 'Check ownerEmail in the configuration, or run init.ps1 -OwnerEmail <address> -Force.' $docs.Me
    }
    #endregion 4b. An environment that exists already

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

    #region 6. Fabric: the capacity and the workspace
    $capacityChosen = ''
    $workspaceExists = $false
    $fabricToken = $null
    # A recovered environment's workspaces and capacity come from what's deployed (issue 60, Resolve-DemoRecoveredWorkspace).
    $workspaceSource = ''
    $controlWorkspace = ''
    $controlEnabled = $false
    $workspaceNote = ''
    $preferredCapacity = $null
    $capacityKept = $false
    # A recovered environment's fabric.importNotebooks, and why (Resolve-DemoRecoveredNotebookImport); $null keeps the
    # first run's rule.
    $notebookImport = $null
    # What another demo environment's record of the workspace changed (Resolve-DemoFabricWorkspaceClaim), when Fabric was read.
    $claimOutcome = $null
    $stateTags = Get-DemoDeploymentStateTagName
    $recordedId = { param([string] $Key) if ($existing.Tags.Contains($stateTags[$Key])) { ([string]$existing.Tags[$stateTags[$Key]]).Trim() } else { '' } }
    $unknownWorkspace = {
        & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ('{0} doesn''t record its Fabric workspace (it was deployed before 2026-11-17, or Fabric couldn''t be read), and none has the name a first run gives it ("{1}"). "{2}" may be another environment''s, so init.ps1 doesn''t take it.' -f $existing.ResourceGroup, $workspace, $defaultWorkspace) @{ workspaceName = $workspace } ('Run init.ps1 -Force -Prefix {0} -WorkspaceName <its Fabric workspace''s name>.' -f $effectivePrefix) $docs.Workspaces
    }
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
        $workspaceList = Read-DemoHubFabricList -Uri ('{0}/workspaces' -f $script:FabricApiBaseUri) -Token $fabricToken -MaxPages 20
        $shared = @($workspaceList.Items | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ine 'Personal' })
        if ($recovered) {
            $place = Resolve-DemoRecoveredWorkspace -Workspace $shared -Listed ([bool]$workspaceList.Succeeded) -Prefix $effectivePrefix -DefaultPrefix $defaultPrefix -DefaultName $defaultWorkspace -FabricWorkspaceId (& $recordedId 'FabricWorkspaceId') -ControlWorkspaceId (& $recordedId 'ControlWorkspaceId') -ControlGroup ([bool]$existing.ControlGroup)
            $workspaceSource = [string]$place.Source
            $controlWorkspace = [string]$place.ControlName
            $controlEnabled = [bool]$place.ControlEnabled
            $workspaceNote = [string]$place.Note
            if (-not $WorkspaceName) {
                $workspace = [string]$place.WorkspaceName
            }
        }
        # A workspace that another demo environment records (2026-11-19) is never this environment's by default, and never a
        # silent Pass (Resolve-DemoFabricWorkspaceClaim): one Azure Resource Graph query, only for a workspace that exists.
        if ($workspaceList.Succeeded -and @(Select-DemoFabricNamed -Items $shared -Name $workspace).Count -eq 1) {
            $claim = Get-DemoFabricWorkspaceClaim -Config ([ordered]@{ subscriptionId = $subscription; prefix = $effectivePrefix; environment = $environment })
            $origin = if ($WorkspaceName) { 'option' } elseif ($recovered) { 'recovered' } else { 'default' }
            $claimOutcome = Resolve-DemoFabricWorkspaceClaim -WorkspaceName $workspace -Workspace $shared -Claim $claim -Origin $origin -OwnId @((& $recordedId 'FabricWorkspaceId'), (& $recordedId 'ControlWorkspaceId')) -Prefix $effectivePrefix -DefaultName $defaultWorkspace -ResourceGroup ([string]$existing.ResourceGroup)
            if ($claimOutcome.Renamed) {
                $workspace = [string]$claimOutcome.WorkspaceName
                if ($recovered) {
                    # Not the workspace it had, so INIT.EXISTING doesn't list it among what was recovered.
                    $workspaceSource = 'renamed'
                }
            }
        }
        if ($recovered) {
            # Its workspace keeps the capacity it's on, so there's nothing to ask (a workspace with a capacity is never moved).
            $current = @(Select-DemoFabricNamed -Items $shared -Name $workspace) | Select-Object -First 1
            $currentCapacity = if ($null -ne $current) { ([string](Get-DemoMemberValue -InputObject $current -Name 'capacityId')).ToLowerInvariant() } else { '' }
            if ($currentCapacity -and -not $CapacityName) {
                $preferredCapacity = @($capacities | Where-Object { ([string](Get-DemoMemberValue -InputObject $_ -Name 'id')).ToLowerInvariant() -eq $currentCapacity }) | Select-Object -First 1
            }
        }
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
        elseif ($null -ne $preferredCapacity) {
            $capacity = $preferredCapacity
            $capacityKept = $true
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
            & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Manual action required' ('You can assign {0} Fabric capacities ({1}), and init.ps1 doesn''t guess one without asking.' -f $capacities.Count, $visible) @{} ('Run init.ps1 -Force -CapacityName <name>, or run init.ps1 -Force {0}, to choose.' -f $chooseHow) $docs.Capacities
        }
        if ($null -ne $capacity) {
            $capacityChosen = [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName')
            $state = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
            $evidence = [ordered]@{ capacityName = $capacityChosen; sku = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku'); state = $state; region = [string](Get-DemoMemberValue -InputObject $capacity -Name 'region') }
            $where = if ($capacityKept) { 'The workspace "{0}" stays on its capacity' -f $workspace } else { 'The workspace goes on the capacity' }
            if ($state -ieq 'Active') {
                & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Pass' ('{0} {1}.' -f $where, (& $describe $capacity)) $evidence '' $docs.Capacities
            }
            else {
                $resume = if ($ManageCapacity) { 'With fabric.manageCapacity true, start-demo.ps1 resumes it; deploy.ps1 doesn''t, so resume it once yourself before deploy.ps1 (Azure portal > the Fabric capacity > Resume).' } else { 'Its administrator resumes it before deploy.ps1 (Azure portal > the Fabric capacity > Resume): the Fabric track needs it running, and the scripts never resume it unless fabric.manageCapacity is true.' }
                & $add 'INIT.FABRIC.CAPACITY' 'fabric' 'fabric' 'Warning' ('{0} {1}, which isn''t running now.' -f $where, (& $describe $capacity)) $evidence $resume 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
            }
        }

        if ($recovered) {
            # The update republishes the notebooks of the demo's own workspace (issue 60, Resolve-DemoRecoveredNotebookImport):
            # the one its resource group records, or else, read-only, one that holds only what the demo creates, or the
            # demo's notebooks already.
            $recordedWorkspace = & $recordedId 'FabricWorkspaceId'
            $namedWorkspaces = @(if ($workspaceList.Succeeded) { Select-DemoFabricNamed -Items $shared -Name $workspace })
            $itemList = $null
            if ($namedWorkspaces.Count -eq 1) {
                $namedId = ([string](Get-DemoMemberValue -InputObject $namedWorkspaces[0] -Name 'id')).ToLowerInvariant()
                if ($namedId -match $script:GuidPattern -and -not ($recordedWorkspace -and $namedId -eq $recordedWorkspace.ToLowerInvariant())) {
                    $itemList = Read-DemoHubFabricList -Uri ('{0}/workspaces/{1}/items' -f $script:FabricApiBaseUri, $namedId) -Token $fabricToken -MaxPages 10
                }
            }
            $notebookImport = Resolve-DemoRecoveredNotebookImport -WorkspaceName $workspace -Workspace $(if ($namedWorkspaces.Count -eq 1) { $namedWorkspaces[0] } else { $null }) -Found $namedWorkspaces.Count -Listed ([bool]$workspaceList.Succeeded) -RecordedId $recordedWorkspace -ResourceGroup ([string]$existing.ResourceGroup) -ItemList $itemList -Allowed @(Get-DemoFabricDemoItem -LakehouseName $lakehouse) -Notebook @(Get-DemoFabricNotebookName)
        }
        if ($recovered -and -not $WorkspaceName -and $Prefix -and $effectivePrefix -cne $defaultPrefix -and $workspaceSource -eq 'unknown') {
            & $unknownWorkspace
        }
        elseif (-not $workspaceList.Succeeded) {
            & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Warning' ('Your Fabric workspaces couldn''t be listed: {0}' -f $workspaceList.Error) @{ workspaceName = $workspace } 'deploy.ps1 finds or creates the workspace by name (ADR 0021).' $docs.Workspaces
        }
        else {
            $found = @(Select-DemoFabricNamed -Items $shared -Name $workspace)
            # What another demo environment's record changes here (Resolve-DemoFabricWorkspaceClaim, 2026-11-19).
            $claimStatus = if ($null -ne $claimOutcome) { [string]$claimOutcome.Status } else { '' }
            $claimNote = if ($claimStatus -eq 'Warning') { ' ' + [string]$claimOutcome.Note } else { '' }
            $claimFix = if ($claimStatus) { [string]$claimOutcome.Remediation } else { '' }
            $claimedBy = if ($null -ne $claimOutcome) { @($claimOutcome.ClaimedBy) } else { @() }
            $passOrWarn = if ($claimStatus) { 'Warning' } else { 'Pass' }
            $note = if ($workspaceNote) { ' ' + $workspaceNote } else { '' }
            if ($claimStatus -eq 'Manual action required') {
                # Kept as it's named, so deploy.ps1 stops before it creates anything there too (DEPLOY.FABRIC.SHARED).
                $workspaceExists = $found.Count -eq 1
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ([string]$claimOutcome.Note) ([ordered]@{ workspaceName = $workspace; recordedBy = $claimedBy }) $claimFix $docs.Workspaces
            }
            elseif ($found.Count -gt 1) {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ('More than one workspace named "{0}" is visible to you.' -f $workspace) @{ workspaceName = $workspace; matches = $found.Count } ('Run init.ps1 -Force -Prefix {0} -WorkspaceName with a name no other workspace uses.' -f $effectivePrefix) $docs.Workspaces
            }
            elseif ($found.Count -eq 1) {
                $workspaceExists = $true
                $notebooks = if ($null -ne $notebookImport -and $notebookImport.Import) { 'deploy.ps1 updates its notebooks, as an update does (fabric.importNotebooks true; INIT.EXISTING says why)' } else { 'deploy.ps1 adds only the notebooks that are missing' }
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' $passOrWarn ('The Fabric workspace "{0}" exists; the scripts use it, and {1}.{2}{3}' -f $workspace, $notebooks, $note, $claimNote) ([ordered]@{ workspaceName = $workspace; recordedBy = $claimedBy }) $claimFix $docs.Workspaces
            }
            elseif ($capacityChosen) {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' $passOrWarn ('The Fabric workspace "{0}" doesn''t exist yet: deploy.ps1 creates it on "{1}" with the lakehouse "{2}", and imports the notebooks (fabric.importNotebooks true). Creating it needs the Fabric tenant setting "Create workspaces" for you.{3}{4}' -f $workspace, $capacityChosen, $lakehouse, $note, $claimNote) ([ordered]@{ workspaceName = $workspace; capacityName = $capacityChosen; recordedBy = $claimedBy }) $claimFix 'https://learn.microsoft.com/fabric/admin/portal-workspace'
            }
            else {
                & $add 'INIT.FABRIC.WORKSPACE' 'fabric' 'fabric' 'Manual action required' ('The Fabric workspace "{0}" doesn''t exist yet, and no capacity is chosen to create it on.{1}' -f $workspace, $claimNote) @{ workspaceName = $workspace } 'Fix INIT.FABRIC.CAPACITY above, or create the workspace on an F or Trial capacity yourself and add a lakehouse named LH_DatabaseHub; then run init.ps1 -Force.' $docs.Workspaces
            }
        }
    }
    elseif ($recovered -and -not $WorkspaceName) {
        # Fabric couldn't be read, so the workspace it records can't be found. Another prefix's environment never gets the
        # default name, which is the default prefix's environment's; with an explicit -Prefix, the person names it.
        $workspaceSource = 'unknown'
        if ($effectivePrefix -cne $defaultPrefix) {
            $workspace = '{0} {1}' -f $defaultWorkspace, $effectivePrefix
            if ($Prefix) {
                & $unknownWorkspace
            }
        }
    }
    if ($recovered -and $null -eq $notebookImport) {
        # Fabric couldn't be read: the first run's rule, and why (Resolve-DemoRecoveredNotebookImport).
        $notebookImport = Resolve-DemoRecoveredNotebookImport -WorkspaceName $workspace -Listed $false
    }
    #endregion 6. Fabric

    #region 7. P6: the Microsoft Entra security group
    $groupId = $zeroGuid
    # A recovered environment keeps the group that administers its T3 and T4 (issue 60): the one its record names, or,
    # without a record, the one its DbHubT3AdminGroup tag names. Never a new one: that would change T3's and T4's
    # administrators.
    $keptGroupId = if ($recovered -and -not $AdminGroupObjectId -and -not $AdminGroupName) { [string](& $recoveredValue 't3AdminGroupObjectId') } else { '' }
    $keptGroupName = if ($recovered -and -not $keptGroupId -and -not $AdminGroupObjectId -and -not $AdminGroupName) { [string]$existing.GroupName } else { '' }
    $groupName = if ($AdminGroupName) { $AdminGroupName.Trim() } elseif ($keptGroupName) { $keptGroupName } else { '{0}-{1}-sql-admins' -f $effectivePrefix, $environment }
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
    $keptMissing = 'If it was deleted, create a security group you own (init.ps1 -Force -CreateAdminGroup -AdminGroupName <a new name> does), then run init.ps1 -Force -AdminGroupObjectId <its object ID>: deploy.ps1 then makes it T3''s and T4''s administrator.'
    if ($AdminGroupObjectId -or $keptGroupId) {
        $lookupId = if ($AdminGroupObjectId) { $AdminGroupObjectId } else { $keptGroupId }
        $read = Find-DemoEntraGroup -SubscriptionId $subscription -ObjectId $lookupId
        if ($read.Succeeded -and @($read.Groups).Count -eq 1) {
            $groupId = $lookupId.ToLowerInvariant()
            $groupName = [string](Get-DemoMemberValue -InputObject @($read.Groups)[0] -Name 'displayName')
            & $ownership $groupId $groupName $(if ($AdminGroupObjectId) { 'Using' } else { 'Keeping, as deployed,' })
        }
        elseif ($AdminGroupObjectId) {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('The group in -AdminGroupObjectId wasn''t found in the tenant ({0}).' -f $(if ($read.Error) { $read.Error } else { 'not found' })) @{} 'Check the object ID in the Microsoft Entra admin center (Groups), then run init.ps1 -Force again.' $docs.ListGroups
        }
        else {
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('The security group that administers T3 and T4 in {0}, as its deployment record names it, wasn''t found in the tenant ({1}), so no other group was taken in its place.' -f $existing.ResourceGroup, $(if ($read.Error) { $read.Error } else { 'not found' })) @{ groupObjectId = $keptGroupId } $keptMissing $docs.ListGroups
        }
    }
    elseif ($keptGroupName) {
        $read = Find-DemoEntraGroup -SubscriptionId $subscription -DisplayName $groupName
        $matched = @($read.Groups | Where-Object { [string]::Equals([string](Get-DemoMemberValue -InputObject $_ -Name 'displayName'), $groupName, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($read.Succeeded -and $matched.Count -eq 1) {
            $groupId = ([string](Get-DemoMemberValue -InputObject $matched[0] -Name 'id')).ToLowerInvariant()
            & $ownership $groupId $groupName 'Keeping, as deployed,'
        }
        else {
            $why = if (-not $read.Succeeded) { 'Microsoft Entra groups couldn''t be searched: {0}' -f $read.Error } elseif ($matched.Count -gt 1) { 'more than one group has that name' } else { 'no group has that name' }
            & $add 'INIT.P6.GROUP' 'preflight' 'tenant' 'Manual action required' ('The security group that administers T3 and T4 in {0}, "{1}" by its tag, couldn''t be taken ({2}), so no other group was taken in its place.' -f $existing.ResourceGroup, $groupName, $why) @{ groupDisplayName = $groupName } $keptMissing $docs.ListGroups
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
    # 2026-11-09 (user-directed): no question. A first deployment is one click, so T2 gets the default, JumpstartImage, which
    # needs nobody; -T2SqlInstallMode picks another mode on purpose.
    $mode = $T2SqlInstallMode
    if (-not $mode -and (& $recoveredValue 't2SqlInstallMode')) {
        # A recovered environment keeps the mode its T2 was deployed in (issue 60); the T2 host keeps a finished guest anyway.
        $mode = [string](& $recoveredValue 't2SqlInstallMode')
        Write-DemoLog -Message ('T2 keeps the mode it was deployed in: t2SqlInstallMode {0}, as {1} records it.{2}' -f $mode, $existing.ResourceGroup, $(if ($mode -ceq 'PaygWizard') { ' deploy.ps1 runs PaygWizard as JumpstartImage, with no setup wizard, and keeps a T2 guest whose SQL Server is set up as it is.' } else { '' }))
    }
    elseif (-not $mode) {
        $mode = 'JumpstartImage'
        Write-DemoLog -Message (Resolve-DemoInitCommandText -Text 'T2 gets SQL Server from Arc Jumpstart''s prebuilt SQL Server 2022 Standard guest (t2SqlInstallMode JumpstartImage, the default): unattended, so nobody signs in to a VM. To choose another mode on purpose, run init.ps1 -Force -T2SqlInstallMode Developer (T2 in Database Hub''s Estate only), or set ProductKey in the configuration (prerequisite P10).' -Prefix $effectivePrefix -DefaultPrefix $defaultPrefix -ConfigPath $fullPath)
    }
    else {
        Write-DemoLog -Message ('T2 gets SQL Server in t2SqlInstallMode {0}, as -T2SqlInstallMode asked.' -f $mode)
    }
    #endregion 8. T2

    #region 9. The configuration
    $zone = $TimeZone
    $zoneNote = ''
    if ($zone -and -not (Test-DemoWindowsTimeZoneId -Id $zone)) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('"{0}" isn''t a Windows time zone ID.' -f $zone) @{} 'Pass a Windows time zone ID, for example -TimeZone ''Eastern Standard Time'' (Get-TimeZone -ListAvailable lists them).' 'https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-time-zones'
        return (& $finish $false)
    }
    if (-not $zone -and (& $recoveredValue 'autoShutdownTimeZone')) {
        # A recovered environment keeps its schedule (issue 60), whatever this machine's time zone is.
        $zone = [string](& $recoveredValue 'autoShutdownTimeZone')
    }
    if (-not $zone) {
        $local = Get-DemoWindowsTimeZoneId
        $zone = if ($local.Id) { $local.Id } else { [string]$schemaDefaults['autoShutdownTimeZone'] }
        if ($local.IsUtc -or -not $local.Id) {
            $zoneNote = ' This machine''s time zone is {0}, so the VMs stop at {1} {0}; pass -TimeZone (for example ''Eastern Standard Time'') for your own.' -f $zone, $example['autoShutdownTime']
        }
    }
    $config = $example
    # A recovered environment's values first (issue 60): what's deployed. What you pass, and what this run resolves, go over
    # them below.
    if ($recovered) {
        foreach ($path in @($existing.Values.Keys)) {
            $parts = ([string]$path).Split('.')
            if ($parts.Count -eq 1) {
                $config[$path] = $existing.Values[$path]
                continue
            }
            if ($config[$parts[0]] -isnot [System.Collections.IDictionary]) {
                $config[$parts[0]] = [ordered]@{}
            }
            $config[$parts[0]][$parts[1]] = $existing.Values[$path]
        }
    }
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
    $config['environment'] = $environment
    $config['t2SqlInstallMode'] = $mode
    $config['t3AdminGroupObjectId'] = $groupId
    $config['owner'] = $ownerTag
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
    # A first run's rule: true only for a workspace that doesn't exist yet. A recovered environment's own workspace gets
    # true, as the update republishes its notebooks (issue 60, Resolve-DemoRecoveredNotebookImport).
    $fabric['importNotebooks'] = if ($null -ne $notebookImport) { [bool]$notebookImport.Import } else { -not $workspaceExists }
    $fabric['manageCapacity'] = [bool]$ManageCapacity
    $config['fabric'] = $fabric
    if ($controlWorkspace) {
        # The control notebook's workspace, as deployed; "DBHub Control", the name init.ps1 wrote before 2026-11-14, stays
        # only with "enabled": true (Get-DemoActivityControlSetting).
        if ($config['control'] -isnot [System.Collections.IDictionary]) {
            $config['control'] = [ordered]@{}
        }
        $config['control']['fabricWorkspaceName'] = $controlWorkspace
        if ($controlEnabled) {
            $config['control']['enabled'] = $true
        }
    }
    $repository = Get-DemoGitHubRepositoryName
    if ($repository -and $config['github'] -is [System.Collections.IDictionary]) {
        $config['github']['repository'] = $repository
    }

    # What the run found in the subscription (INIT.EXISTING, issue 60), with the values the file gets.
    $defaulted = [System.Collections.Generic.List[string]]::new()
    if ($recovered) {
        # The control's settings that were recovered: its workspace, and its custom roles' suffix (Get-DemoControlRoleSuffix).
        $controlKnown = @(@($(if ($controlWorkspace) { 'fabricWorkspaceName' }), $(if ([bool](Get-DemoMemberValue -InputObject $existing -Name 'RoleSuffixFound')) { 'roleNameSuffix' })) | Where-Object { $_ })
        foreach ($item in @($existing.Missing) + @($script:DemoUnrecordedSetting)) {
            $explicit = ($item -eq 'location' -and $Location) -or ($item -eq 'autoShutdownTimeZone' -and $TimeZone) -or ($item -eq 't2SqlInstallMode' -and $T2SqlInstallMode) -or ($item -eq 'ownerEmail' -and $OwnerEmail) -or ($item -eq 'fabric.lakehouseName' -and $LakehouseName) -or ($item -eq 'fabric.manageCapacity' -and $ManageCapacity) -or ($item -eq 't3AdminGroupObjectId' -and $groupId -ne $zeroGuid)
            $label = if ($item -eq 'control' -and $controlKnown.Count -gt 0) { 'control (all but its {0})' -f ($controlKnown -join ' and ') } else { $item }
            if (-not $explicit -and -not $defaulted.Contains($label)) {
                $defaulted.Add($label)
            }
        }
        if ($workspaceSource -eq 'unknown' -and -not $WorkspaceName) {
            # Not recorded, or Fabric couldn't be read: the name a first run gives this prefix's workspace.
            $defaulted.Add('fabric.workspaceName')
        }
    }
    $report = Get-DemoExistingEnvironmentReport -Existing $existing -Path $fullPath -GroupName $(if ($groupId -ne $zeroGuid) { $groupName } else { '' }) -WorkspaceName $workspace -WorkspaceSource $workspaceSource -ControlName $controlWorkspace -NotebookImport $notebookImport -Defaulted $defaulted.ToArray() -DryRun:$dryRun
    $results.Add($report.Result)
    # A workspace renamed because another environment records the one it would have had is an automatic change, so
    # deploy.ps1's start banner and status page say it too (2026-11-19).
    $runNote = (@([string]$report.Note, $(if ($null -ne $claimOutcome) { [string]$claimOutcome.Line } else { '' })) | Where-Object { $_ }) -join ' '
    $existingSummary = [pscustomobject]@{ Kind = [string]$existing.Kind; Prefix = $effectivePrefix; ResourceGroup = [string]$existing.ResourceGroup; Signal = [string]$existing.Signal; Note = $runNote }

    $json = $config | ConvertTo-Json -Depth 32
    $validationErrors = @()
    $valid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorVariable validationErrors -ErrorAction SilentlyContinue
    $written = @(@('subscriptionId', 'tenantId', $(if ($account) { 'azureAccount' }), 'prefix', $(if ($keptEnvironment) { 'environment' }), 't2SqlInstallMode', 't3AdminGroupObjectId', 'owner', 'ownerEmail', 'autoShutdownTimeZone', 'fabric') + @($(if ($recovered) { @($existing.Values.Keys | ForEach-Object { ([string]$_).Split('.')[0] }) })) + @($(if ($controlWorkspace) { 'control' })) | Where-Object { $_ } | Select-Object -Unique)
    $summary = 'subscription "{0}", region {1}, prefix {2}, network {3}, T2 {4}, the workspace "{5}" on "{6}", and the P6 group {7}' -f $chosen.Name, $config['location'], $effectivePrefix, $config['networkMode'], $mode, $workspace, $(if ($capacityChosen) { $capacityChosen } else { '(none yet)' }), $(if ($groupId -ne $zeroGuid) { '"' + $groupName + '"' } else { '(none yet)' })
    # What the run kept from the file it overwrites, so it's still that environment's (the final tests' F7).
    $keptWhat = @($(if ($keptPrefix) { 'the prefix ' + $keptPrefix }), $(if ($keptEnvironment) { 'the environment ' + $keptEnvironment }) | Where-Object { $_ }) -join ' and '
    $keptNote = if ($keptWhat) { ' {0} {1} from the configuration it {2}{3}, so the file is still for rg-{4}-{5}.' -f $(if ($dryRun) { 'It would keep' } else { 'It kept' }), $keptWhat, $(if ($dryRun) { 'overwrites' } else { 'overwrote' }), $(if ($keptPrefix) { ' (no -Prefix was given)' } else { '' }), $effectivePrefix, $environment } else { '' }
    if (-not $valid) {
        $details = ($validationErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique) -join '; '
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Fail' ('The configuration doesn''t match config/environment.schema.json, so it wasn''t written: {0}' -f $details) @{} 'Check the values you passed to init.ps1 and run it again.' $docs.Schema
        return (& $finish $false '' $config)
    }
    $backupPath = ''
    if ($dryRun -or -not $PSCmdlet.ShouldProcess($fullPath, 'Write the demo configuration')) {
        & $add 'INIT.CONFIG' 'preflight' 'repo' 'Not selected' ('What if: {0} would be written ({1}){2}, validated against the schema.{3}{4}' -f $fullPath, $summary, $(if ($exists -and -not $Force) { '; it exists, so init.ps1 needs -Force to replace it' } else { '' }), $zoneNote, $keptNote) ([ordered]@{ path = $fullPath; keys = @($written) }) '' ''
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
        $message = 'Wrote {0}: {1}. It''s Git-ignored and holds no secrets, and it matches the schema.{2}{3}{4}' -f $fullPath, $summary, $(if ($backupPath) { ' The old file is in ' + $backupPath + '.' } else { '' }), $zoneNote, $keptNote
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
    if ($mode -eq 'JumpstartImage') {
        $nextSteps.Add(('./scripts/deploy.ps1{0}      # a first deploy takes about 1.5 hours (91 minutes, measured on 2026-11-06) and keeps this PC awake; nothing needs you: the Insights app deploys with your az login too' -f $configArgument))
    }
    else {
        $nextSteps.Add(('./scripts/deploy.ps1{0}      # a first deploy takes about 1.5 to 2.5 hours and keeps this PC awake; nothing needs you: the Insights app deploys with your az login too' -f $configArgument))
    }
    $nextSteps.Add(('./scripts/grant-safety-stop.ps1{0}   # only when DONE asks for it: an Owner, once, for the nightly safety stop''s role' -f $configArgument))
    $nextSteps.Add(('./scripts/configure-fabric-app.ps1 -SignIn{0}   # only when deploy.ps1 says the Insights app wasn''t created: it deploys with your az login, and opens a browser sign-in only if Fabric refuses that' -f $configArgument))
    $nextSteps.Add(('Each session: ./scripts/start-demo.ps1{0}, then ./scripts/stop-demo.ps1 -SaveHistory{0}' -f $configArgument))
    #endregion Next steps

    $isWritten = @($results | Where-Object { $_.checkId -eq 'INIT.CONFIG' -and $_.status -eq 'Pass' }).Count -gt 0
    return (& $finish $isWritten $backupPath $config)
}
