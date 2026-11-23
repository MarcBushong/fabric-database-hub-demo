# First-run helpers (Phase 26b, ADR 0023): init.ps1 and Initialize-DemoConfig, and the Rayfin CLI's interactive sign-in
# for configure-fabric-app.ps1 -SignIn. Internal; tests mock them.

function Invoke-DemoRayfinInteractive {
    <#
    .SYNOPSIS
    Runs the stage's pinned Rayfin CLI attached to this console, so a person can answer it (its browser sign-in), and
    returns its exit code. Internal; tests mock it.

    .DESCRIPTION
    Start-Process -NoNewWindow -Wait gives the CLI this console's input and output, which a sign-in needs; its output
    isn't captured or logged. The CLI's telemetry is off, and an ambient RAYFIN_TOKEN and a BROWSER the CLI can't start
    are removed, for the child only (Start-Process -Environment; Get-DemoRayfinSignInEnvironment), so the operator's
    session doesn't change. Sources (checked 2026-10-27):
    https://learn.microsoft.com/fabric/apps/cli-reference and
    https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $NodePath,

        [Parameter(Mandatory)]
        [string] $CliPath,

        [Parameter(Mandatory)]
        [ValidateScript({ @($_ | Where-Object { $_ -notmatch '^[A-Za-z0-9:=@._/-]+$' }).Count -eq 0 })]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    $arguments = @(('"{0}"' -f $CliPath.Replace('"', ''))) + $ArgumentList
    $environment = Get-DemoRayfinSignInEnvironment -WorkingDirectory $WorkingDirectory
    $process = Start-Process -FilePath $NodePath -ArgumentList $arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru -Environment $environment -WhatIf:$false
    return [int]$process.ExitCode
}

function Get-DemoAzProfileSubscription {
    <#
    .SYNOPSIS
    Lists the subscriptions in the Azure CLI's profile with 'az account list'. The one documented exception to
    "every Azure CLI call goes through Invoke-DemoAz after the subscription guard" (ADR 0023). Internal.

    .DESCRIPTION
    init.ps1 has no configured subscription yet, so it can't run the guard before it knows which subscription to
    check. This is its only Azure CLI call before the guard: 'az account list --output json' reads the subscriptions
    that the Azure CLI's own sign-in cached in its profile. It's read-only and local (no --refresh, so no network
    call), it never signs in, and it never changes the default subscription ('az account set' is never run).
    Everything after the user picks a subscription goes through Assert-DemoAzContext and Invoke-DemoAz.

    Returns Installed (the Azure CLI is on PATH), SignedIn (the profile lists at least one enabled subscription),
    Error, and Subscriptions: SubscriptionId, Name, TenantId, Account (user.name), AccountType (user.type),
    IsDefault, and State.
    Source: https://learn.microsoft.com/cli/azure/account#az-account-list (checked 2026-10-27).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(5, 300)]
        [int] $TimeoutSeconds = 60
    )

    $answer = {
        param([bool] $Installed, [bool] $SignedIn, [string] $Problem, [object[]] $Items)
        [pscustomobject]@{ Installed = $Installed; SignedIn = $SignedIn; Error = $Problem; Subscriptions = @($Items) }
    }
    try {
        $listed = Invoke-DemoAzCli -ArgumentList @('account', 'list', '--output', 'json') -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return (& $answer $false $false (Protect-DemoText -Text $_.Exception.Message) @())
    }
    if ($listed.ExitCode -ne 0) {
        return (& $answer $true $false (Protect-DemoText -Text ([string]$listed.StdErr).Trim()) @())
    }
    $parsed = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$listed.StdOut)) {
        try {
            $parsed = @([string]$listed.StdOut | ConvertFrom-Json -Depth 16)
        }
        catch {
            return (& $answer $true $false 'The Azure CLI''s subscription list couldn''t be read.' @())
        }
    }
    $items = foreach ($entry in $parsed) {
        $id = ([string](Get-DemoMemberValue -InputObject $entry -Name 'id')).ToLowerInvariant()
        $tenant = ([string](Get-DemoMemberValue -InputObject $entry -Name 'tenantId')).ToLowerInvariant()
        $state = [string](Get-DemoMemberValue -InputObject $entry -Name 'state')
        if ($id -notmatch $script:GuidPattern -or $tenant -notmatch $script:GuidPattern -or ($state -and $state -ne 'Enabled')) {
            continue
        }
        $user = Get-DemoMemberValue -InputObject $entry -Name 'user'
        [pscustomobject]@{
            SubscriptionId = $id
            Name           = [string](Get-DemoMemberValue -InputObject $entry -Name 'name')
            TenantId       = $tenant
            Account        = [string](Get-DemoMemberValue -InputObject $user -Name 'name')
            AccountType    = [string](Get-DemoMemberValue -InputObject $user -Name 'type')
            IsDefault      = [bool](Get-DemoMemberValue -InputObject $entry -Name 'isDefault')
            State          = $(if ($state) { $state } else { 'Enabled' })
        }
    }
    $items = @($items | Sort-Object -Property @{ Expression = { -not $_.IsDefault } }, Name, SubscriptionId)
    $problem = if ($items.Count -eq 0) { 'The Azure CLI profile has no enabled subscription: no one is signed in, or the account can''t see a subscription.' } else { '' }
    return (& $answer $true ($items.Count -gt 0) $problem $items)
}

function Test-DemoInteractiveSession {
    <#
    .SYNOPSIS
    True when a person can answer a prompt here: not in CI (CI, GITHUB_ACTIONS, TF_BUILD), not a non-interactive
    host, and standard input isn't redirected. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    foreach ($name in 'CI', 'GITHUB_ACTIONS', 'TF_BUILD') {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if ($value -and $value -notin 'false', '0') {
            return $false
        }
    }
    if (-not [System.Environment]::UserInteractive) {
        return $false
    }
    try {
        if ([System.Console]::IsInputRedirected) {
            return $false
        }
    }
    catch {
        return $false
    }
    return $true
}

function Read-DemoChoice {
    <#
    .SYNOPSIS
    Shows numbered options and returns the index the person picks; Enter picks -Default. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [Parameter(Mandatory)]
        [string[]] $Option,

        [ValidateRange(0, 999)]
        [int] $Default = 0
    )

    if ($Default -ge $Option.Count) {
        $Default = 0
    }
    Write-Information -MessageData '' -InformationAction Continue
    Write-Information -MessageData $Title -InformationAction Continue
    for ($i = 0; $i -lt $Option.Count; $i++) {
        Write-Information -MessageData ('  {0}) {1}' -f ($i + 1), $Option[$i]) -InformationAction Continue
    }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $answer = ([string](Read-Host -Prompt ('Choose 1-{0} (Enter for {1})' -f $Option.Count, ($Default + 1)))).Trim()
        if (-not $answer) {
            return $Default
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Option.Count) {
            return ($number - 1)
        }
        Write-Information -MessageData ('Enter a number from 1 to {0}.' -f $Option.Count) -InformationAction Continue
    }
    return $Default
}

function Get-DemoWindowsTimeZoneId {
    <#
    .SYNOPSIS
    This machine's time zone as a Windows time zone ID (what the VMs' auto-shutdown schedule takes): the local ID on
    Windows, converted from the IANA ID elsewhere. Internal.

    .DESCRIPTION
    Returns Id ('' when it can't be converted) and IsUtc. Source:
    https://learn.microsoft.com/dotnet/api/system.timezoneinfo.trygetwindowsid (checked 2026-10-27).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $local = [System.TimeZoneInfo]::Local
    $id = [string]$local.Id
    if (-not $IsWindows) {
        $windowsId = $null
        if ([System.TimeZoneInfo]::TryConvertIanaIdToWindowsId($id, [ref]$windowsId)) {
            $id = [string]$windowsId
        }
        elseif ($id -in 'UTC', 'Etc/UTC', 'Etc/UCT', 'Universal', 'Zulu') {
            $id = 'UTC'
        }
        else {
            $id = ''
        }
    }
    [pscustomobject]@{ Id = $id; IsUtc = ($id -eq 'UTC') }
}

function Test-DemoWindowsTimeZoneId {
    <#
    .SYNOPSIS
    True when -Id is a Windows time zone ID this machine knows, for example 'Eastern Standard Time'. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Id
    )

    if (-not $Id) {
        return $false
    }
    if ($IsWindows) {
        try {
            $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($Id)
            return $true
        }
        catch {
            return $false
        }
    }
    $iana = $null
    return ($Id -eq 'UTC' -or [System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($Id, [ref]$iana))
}

function Test-DemoConfigPathIgnored {
    <#
    .SYNOPSIS
    True when init.ps1 may write the configuration to -Path: outside the repository, or inside it on a path Git
    ignores (config/demo.config.json, config/*.local.json, out/). A tracked path is refused, so real IDs never land
    in a file Git would commit. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $full = Resolve-DemoUserPath -Path $Path
    $root = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        return $true
    }
    $relative = $full.Substring($root.Length + 1).Replace('\', '/')
    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $git.Source -C $root check-ignore -q -- $relative 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        if ($LASTEXITCODE -eq 1) {
            return $false
        }
    }
    return ($relative -ieq 'config/demo.config.json' -or $relative -match '(?i)^config/[^/]+\.local\.json$' -or $relative -match '(?i)^out/')
}

function Get-DemoGitHubRepositoryName {
    <#
    .SYNOPSIS
    owner/repo from the clone's origin remote when it's on github.com, or ''. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) {
        return ''
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $url = [string](& $git.Source -C $script:RepoRoot remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    if ($url.Trim() -match '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$') {
        return ('{0}/{1}' -f $Matches[1], $Matches[2])
    }
    return ''
}

function Find-DemoEntraGroup {
    <#
    .SYNOPSIS
    Finds Microsoft Entra security groups by display name, or one group by object ID, through Microsoft Graph with a
    token the subscription guard verified. Internal.

    .DESCRIPTION
    Returns Succeeded, StatusCode, Error, and Groups (id, displayName, securityEnabled). Sources (checked 2026-10-27):
    https://learn.microsoft.com/graph/api/group-list and https://learn.microsoft.com/graph/api/group-get.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [AllowEmptyString()]
        [string] $DisplayName = '',

        [AllowEmptyString()]
        [string] $ObjectId = ''
    )

    $graph = 'https://graph.microsoft.com/v1.0'
    $uri = if ($ObjectId) {
        '{0}/groups/{1}?$select=id,displayName,securityEnabled' -f $graph, $ObjectId
    }
    else {
        # OData string literals double their single quotes.
        '{0}/groups?$filter={1}&$select=id,displayName,securityEnabled' -f $graph, [uri]::EscapeDataString(("displayName eq '{0}'" -f $DisplayName.Replace("'", "''")))
    }
    $read = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri $uri
    if ($read.ExitCode -ne 0) {
        return [pscustomobject]@{ Succeeded = $false; StatusCode = [int]$read.StatusCode; Error = [string]$read.StdErr; Groups = @() }
    }
    $body = [string]$read.StdOut | ConvertFrom-Json -Depth 16
    # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
    $value = if ($ObjectId) { $body } else { Get-DemoMemberValue -InputObject $body -Name 'value' }
    $groups = @($value)
    return [pscustomobject]@{ Succeeded = $true; StatusCode = [int]$read.StatusCode; Error = ''; Groups = @($groups | Where-Object { $null -ne $_ }) }
}

function Test-DemoEntraGroupOwner {
    <#
    .SYNOPSIS
    True when -OwnerId is among the group's owners (Microsoft Graph, List group owners); $null when they can't be
    read. Internal. Source: https://learn.microsoft.com/graph/api/group-list-owners (checked 2026-10-27).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $GroupId,

        [Parameter(Mandatory)]
        [string] $OwnerId
    )

    $read = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri ('https://graph.microsoft.com/v1.0/groups/{0}/owners?$select=id' -f $GroupId)
    if ($read.ExitCode -ne 0) {
        return $null
    }
    $value = Get-DemoMemberValue -InputObject ([string]$read.StdOut | ConvertFrom-Json -Depth 16) -Name 'value'
    $owners = @($value)
    $ids = @($owners | Where-Object { $null -ne $_ } | ForEach-Object { ([string](Get-DemoMemberValue -InputObject $_ -Name 'id')).ToLowerInvariant() })
    return ($ids -contains $OwnerId.ToLowerInvariant())
}

function New-DemoEntraSecurityGroup {
    <#
    .SYNOPSIS
    Creates a Microsoft Entra security group with the caller as its owner, through Microsoft Graph with a token the
    subscription guard verified, then makes sure the caller is listed as an owner. Internal.

    .DESCRIPTION
    These are the documented REST calls behind 'az ad group create' and 'az ad group owner add'; 'az ad' itself isn't
    used, because it calls Microsoft Graph with the Azure CLI's default account, which can be in another tenant
    (Invoke-DemoAz refuses it). An administrator who creates a security group isn't made its owner automatically, so
    the create request names the caller in owners@odata.bind, and Add owner runs when the owners don't list the caller
    afterwards. Returns Status (Created, Forbidden, or Failed), GroupId, StatusCode, and Error.
    Sources (checked 2026-10-27):
    - Create group: https://learn.microsoft.com/graph/api/group-post-groups
    - Add owners: https://learn.microsoft.com/graph/api/group-post-owners
    - Who can create groups: https://learn.microsoft.com/entra/identity/users/groups-self-service-management
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,63}$')]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $OwnerId,

        [ValidateSet('User', 'ServicePrincipal')]
        [string] $OwnerType = 'User',

        [string] $Description = 'Microsoft Entra administrators of T3 and T4 in the Fabric Database Hub demo (prerequisite P6). Created by init.ps1.'
    )

    $graph = 'https://graph.microsoft.com/v1.0'
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create a Microsoft Entra security group owned by you')) {
        return [pscustomobject]@{ Status = 'Skipped'; GroupId = ''; StatusCode = 0; Error = '' }
    }
    $collection = if ($OwnerType -eq 'ServicePrincipal') { 'servicePrincipals' } else { 'users' }
    $body = [ordered]@{
        displayName           = $DisplayName
        description           = $Description
        mailEnabled           = $false
        mailNickname          = $DisplayName
        securityEnabled       = $true
        'owners@odata.bind'   = @(('{0}/{1}/{2}' -f $graph, $collection, $OwnerId.ToLowerInvariant()))
    } | ConvertTo-Json -Depth 4 -Compress
    $created = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'POST' -Uri ('{0}/groups' -f $graph) -Body $body
    if ($created.ExitCode -ne 0) {
        $status = if ([int]$created.StatusCode -eq 403 -or [string]$created.StdErr -match '(?i)Authorization_RequestDenied|Insufficient privileges') { 'Forbidden' } else { 'Failed' }
        return [pscustomobject]@{ Status = $status; GroupId = ''; StatusCode = [int]$created.StatusCode; Error = [string]$created.StdErr }
    }
    $groupId = ([string](Get-DemoMemberValue -InputObject ([string]$created.StdOut | ConvertFrom-Json -Depth 16) -Name 'id')).ToLowerInvariant()
    if ($groupId -notmatch $script:GuidPattern) {
        return [pscustomobject]@{ Status = 'Failed'; GroupId = ''; StatusCode = [int]$created.StatusCode; Error = 'Microsoft Graph didn''t return the new group''s ID.' }
    }
    if ((Test-DemoEntraGroupOwner -SubscriptionId $SubscriptionId -GroupId $groupId -OwnerId $OwnerId) -ne $true) {
        $reference = [ordered]@{ '@odata.id' = ('{0}/directoryObjects/{1}' -f $graph, $OwnerId.ToLowerInvariant()) } | ConvertTo-Json -Compress
        $added = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'POST' -Uri ('{0}/groups/{1}/owners/$ref' -f $graph, $groupId) -Body $reference
        if ($added.ExitCode -ne 0 -and [string]$added.StdErr -notmatch '(?i)already exist') {
            return [pscustomobject]@{ Status = 'OwnerMissing'; GroupId = $groupId; StatusCode = [int]$added.StatusCode; Error = [string]$added.StdErr }
        }
    }
    return [pscustomobject]@{ Status = 'Created'; GroupId = $groupId; StatusCode = [int]$created.StatusCode; Error = '' }
}

function Get-DemoSignedInUser {
    <#
    .SYNOPSIS
    The signed-in user from Microsoft Graph (/me) with a token the subscription guard verified: object ID, user
    principal name, mail, and display name. $null when it can't be read (for example a service principal). Internal.
    Source: https://learn.microsoft.com/graph/api/user-get (checked 2026-10-27).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $read = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName'
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return $null
    }
    $me = [string]$read.StdOut | ConvertFrom-Json -Depth 8
    [pscustomobject]@{
        ObjectId          = ([string](Get-DemoMemberValue -InputObject $me -Name 'id')).ToLowerInvariant()
        UserPrincipalName = [string](Get-DemoMemberValue -InputObject $me -Name 'userPrincipalName')
        Mail              = [string](Get-DemoMemberValue -InputObject $me -Name 'mail')
        DisplayName       = [string](Get-DemoMemberValue -InputObject $me -Name 'displayName')
    }
}

function Get-DemoConfigFileIdentity {
    <#
    .SYNOPSIS
    The prefix and environment a configuration file holds, for an init.ps1 run that overwrites it (2026-11-19, the final
    tests' F7): Prefix and Environment, each empty unless config/environment.schema.json allows it, and Read, false when
    the file isn't a JSON object. Reads only the file. Internal.

    .DESCRIPTION
    Without them, init.ps1 -Force with no -Prefix wrote the example's prefix, dbhub, over a second environment's file, so
    the next deploy.ps1 updated the first environment.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $identity = [pscustomobject]@{ Read = $false; Prefix = ''; Environment = '' }
    try {
        $held = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
    }
    catch {
        # Not JSON: nothing is kept, and the run goes on as for a file without a prefix.
        return $identity
    }
    if ($held -isnot [System.Collections.IDictionary]) {
        return $identity
    }
    $identity.Read = $true
    if ([string]$held['prefix'] -cmatch '^[a-z][a-z0-9]{2,7}$') {
        $identity.Prefix = [string]$held['prefix']
    }
    if ([string]$held['environment'] -cmatch '^[a-z][a-z0-9]{1,7}$') {
        $identity.Environment = [string]$held['environment']
    }
    return $identity
}

function Resolve-DemoInitCommandText {
    <#
    .SYNOPSIS
    A text init.ps1 prints (a result's remediation, a next step, a line it logs) with every command it tells you to run
    written for this run (2026-11-19, from the final tests' F5): each init.ps1 command as ./scripts/init.ps1 with the run's
    -Prefix when that isn't the default and the command names none, then, through Resolve-DemoDeployCommandText, which NOT
    DONE uses, the run's -ConfigPath on every ./scripts/*.ps1 and deploy.ps1 command. Pure. Internal.

    .DESCRIPTION
    Without them, a fix that said "init.ps1 -Force ..." wrote the default prefix's configuration, in config/demo.config.json,
    for a second environment, and the next deploy.ps1 updated the first one. An init.ps1 mention is a command when ./scripts/
    comes before it, when "run" comes right before it, or when a parameter follows it; "init.ps1's" and other mentions in
    passing stay as they are. A command's own parameters run to the end of its clause (a period, comma, colon, semicolon,
    or parenthesis outside quotes), where -Prefix is looked for, so the text can go through again unchanged. A run with
    the default prefix and the default configuration file changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [AllowEmptyString()]
        [string] $Prefix = '',

        [string] $DefaultPrefix = 'dbhub',

        [AllowEmptyString()]
        [string] $ConfigPath = ''
    )

    if (-not $Text) {
        return [string]$Text
    }
    $command = Get-DemoDeployCommand -ConfigPath $ConfigPath
    $addPrefix = [bool]$Prefix -and $Prefix -cne $DefaultPrefix
    if (-not $addPrefix -and $command -eq './scripts/deploy.ps1') {
        return $Text
    }
    $source = $Text
    $rewritten = [regex]::Replace($Text, '(?<![\w./\\-])(?<path>(?:\./)?scripts/)?init\.ps1(?![\w''])', {
            param($Match)
            $before = $source.Substring(0, $Match.Index)
            $after = $source.Substring($Match.Index + $Match.Length)
            if (-not ($Match.Groups['path'].Success -or $after -match '^[ ]+-[A-Za-z]' -or $before -match '(?i)\brun\s+$')) {
                return $Match.Value
            }
            $named = $after -match '^(?:"[^"]*"|[^.;:,()"])*?\s-Prefix\b'
            return ('./scripts/init.ps1{0}' -f $(if ($addPrefix -and -not $named) { ' -Prefix ' + $Prefix } else { '' }))
        })
    return [string](Resolve-DemoDeployCommandText -Text $rewritten -Command $command).Text
}

function Get-DemoInitialMonthlyCeiling {
    <#
    .SYNOPSIS
    The hard monthly ceiling init.ps1 writes for a new configuration (decision 8b, 2026-11-20): the region's worst-case month
    for a Contributor's new deployment, which preflight checks against it (PREFLIGHT.COST.MONTHLY), with 4% headroom for
    list-price changes, as 415 has over West US 3's, rounded up to the next 5 USD, and never below Floor, the example
    configuration's 415. Before, every new configuration got 415, which fits a Contributor's first deployment only in West
    US 3 and East US 2: Central US and North Europe got a Warning, and UK South, West Europe, Japan East, and Australia East
    failed preflight. Returns Ceiling (whole USD), WorstCase, Priced, DefenderIncluded, and Note, the sentence INIT.CONFIG
    adds. Never throws: when the prices can't be read, Ceiling is Floor, and Note says why. Internal.

    .DESCRIPTION
    The worst case is preflight's for a Contributor's first deployment (Get-DemoCostEstimate), at list prices from the Azure
    Retail Prices API, read now (ADR 0016): with the subscription's Defender for Cloud plans (Get-DemoDefenderPlan; left out,
    and said, when they can't be read); T4's 7-day automatic restart for the rest of the month, since no nightly safety stop is
    in place before an Owner's grant; T5's container all month, which only stop-demo.ps1 deletes then; and neither free offer
    (T3's or T5's), an upper bound.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $SubscriptionId = '',

        [double] $Floor = 415
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parameters = @{ Config = $Config; PriceCache = @{}; T5ContainerLifecycle = 'AlwaysOn'; T5ManualDeleteOnly = $true }
    $plansError = ''
    if ($SubscriptionId) {
        try {
            $parameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId $SubscriptionId)
        }
        catch {
            $plansError = Protect-DemoText -Text $_.Exception.Message
        }
    }
    $fallback = {
        param([string] $Why)
        [pscustomobject]@{ Ceiling = [int]$Floor; WorstCase = $null; Priced = $false; DefenderIncluded = $false; Note = [string]::Format($culture, 'The monthly ceiling is {0:N0} USD, the example''s: this region''s worst case couldn''t be priced now ({1}); preflight.ps1 prices it, and when it''s over, its Fail names the ceiling to set.', $Floor, $Why.TrimEnd('.')) }
    }
    try {
        $estimate = Get-DemoCostEstimate @parameters
    }
    catch {
        return (& $fallback (Protect-DemoText -Text $_.Exception.Message))
    }
    $worst = [double]$estimate.MonthlyWorstCase
    if (-not ($worst -gt 0)) {
        return (& $fallback 'the Azure Retail Prices API gave no prices')
    }
    $ceiling = [System.Math]::Max($Floor, [System.Math]::Ceiling($worst * 1.04 / 5) * 5)
    $defender = [bool]$estimate.DefenderIncluded
    $basis = if ($defender) { 'with your subscription''s Defender for Cloud plans' } elseif ($plansError) { 'without your subscription''s Defender for Cloud plans, which couldn''t be read: ' + $plansError.TrimEnd('.') } else { 'without Defender for Cloud plans' }
    $note = if ($ceiling -le $Floor) {
        [string]::Format($culture, 'The monthly ceiling is {0:N0} USD, the default: it holds this region''s worst case for a Contributor''s new deployment, {1:N2} USD a month (list prices from the Azure Retail Prices API, read now, {2}).', $ceiling, $worst, $basis)
    }
    else {
        [string]::Format($culture, 'The monthly ceiling is {0:N0} USD, not the default {1:N0}: this region''s worst case for a Contributor''s new deployment is {2:N2} USD a month (list prices from the Azure Retail Prices API, read now, {3}), with 4% headroom, rounded up to 5 USD.', $ceiling, $Floor, $worst, $basis)
    }
    $missing = @(@(Get-DemoMemberValue -InputObject $estimate -Name 'MissingPrices') | Where-Object { $_ })
    if ($missing.Count -gt 0) {
        $note += ' Some prices were missing ({0}), so preflight.ps1 checks it again.' -f ($missing -join ', ')
    }
    return [pscustomobject]@{ Ceiling = [int]$ceiling; WorstCase = [System.Math]::Round($worst, 2); Priced = $true; DefenderIncluded = $defender; Note = $note }
}