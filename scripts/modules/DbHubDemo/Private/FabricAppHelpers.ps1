# Fabric App (preview) helpers for Phase 19b: the pinned settings, a redacting runner for the Rayfin CLI and npm, and
# the stage folder that the CLI deploys from. Internal; the public Fabric App functions call them and tests mock them.

function Get-DemoFabricAppSetting {
    <#
    .SYNOPSIS
    Returns the fabricApp block of config/versions.json: the pinned CLI version, item and connector names, and the
    documented tenant setting.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    $path = Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json'
    $versions = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $versions.ContainsKey('fabricApp')) {
        throw 'config/versions.json has no fabricApp block.'
    }
    return $versions['fabricApp']
}

function Protect-DemoRayfinText {
    <#
    .SYNOPSIS
    Redacts what the Rayfin CLI can print that must never reach a log: the app's publishable key (JSON field, env
    line, or bare value) and anything Protect-DemoText already covers.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $safe = $Text -replace '("publishableKey"\s*:\s*")[^"]*(")', '$1[REDACTED]$2'
    $safe = $safe -replace '(?i)(PUBLISHABLE_KEY\s*[=:]\s*)\S+', '$1[REDACTED]'
    $safe = $safe -replace '\bpk[-_][A-Za-z0-9_-]{8,}', '[REDACTED]'
    return (Protect-DemoText -Text $safe)
}

function Invoke-DemoFabricAppProcess {
    <#
    .SYNOPSIS
    Runs node, npm, or npx in a working directory with a time limit, and returns ExitCode, StdOut, and StdErr
    (redacted), Seconds, and TimedOut.

    .DESCRIPTION
    Start-DemoFabricAppProcess, then Receive-DemoFabricAppProcess: standard input is closed, so nothing can wait for a
    reply; when the time limit passes, the whole process tree is stopped and ExitCode is -1. Environment entries are set
    for the child only (null removes one), so the operator's session is never changed. Output is redacted with
    Protect-DemoRayfinText before anything else sees it. On Windows, npm and npx are batch files: they run through
    cmd.exe with fixed arguments that need no quoting.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('node', 'npm', 'npx')]
        [string] $Tool,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 600,

        [System.Collections.IDictionary] $Environment = @{}
    )

    $handle = Start-DemoFabricAppProcess -Tool $Tool -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -Environment $Environment
    return (Receive-DemoFabricAppProcess -Handle $handle)
}

function Start-DemoFabricAppProcess {
    <#
    .SYNOPSIS
    Starts node, npm, or npx in a working directory without waiting for it, and returns a handle for
    Receive-DemoFabricAppProcess (which waits at most -TimeoutSeconds from now) or Stop-DemoFabricAppProcess.
    Internal.

    .DESCRIPTION
    Standard input is closed, so nothing can wait for a reply, and its output is read as it comes. Environment entries
    are set for the child only (null removes one), so the operator's session is never changed. On Windows, npm and npx
    are batch files: they run through cmd.exe with fixed arguments that need no quoting. Throws when the tool isn't on
    PATH or doesn't start.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local process for its caller, which decides; nothing outside this machine changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('node', 'npm', 'npx')]
        [string] $Tool,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 600,

        [System.Collections.IDictionary] $Environment = @{}
    )

    $command = Get-Command -Name $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw ('{0} was not found on PATH. Install Node.js {1}, which includes npm.' -f $Tool, ((Get-DemoFabricAppSetting)['supportedNodeMajors'] -join ', '))
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    if ($command.Source -match '\.(cmd|bat)$') {
        foreach ($argument in $ArgumentList) {
            if ($argument -notmatch '^[A-Za-z0-9:=@._/\\-]+$') {
                throw ('Refusing to pass the argument "{0}" to {1} through cmd.exe.' -f $argument, $Tool)
            }
        }
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""{0}" {1}"' -f $command.Source, ($ArgumentList -join ' ')
    }
    else {
        $startInfo.FileName = $command.Source
        foreach ($argument in $ArgumentList) {
            $startInfo.ArgumentList.Add($argument)
        }
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            [void]$startInfo.Environment.Remove([string]$key)
        }
        else {
            $startInfo.Environment[[string]$key] = [string]$Environment[$key]
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $started = [System.DateTime]::UtcNow
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    catch {
        $process.Dispose()
        throw
    }
    [pscustomobject]@{
        Tool           = $Tool
        Process        = $process
        StdOutTask     = $stdoutTask
        StdErrTask     = $stderrTask
        StartedUtc     = $started
        TimeoutSeconds = $TimeoutSeconds
        Closed         = $false
    }
}

function Receive-DemoFabricAppProcess {
    <#
    .SYNOPSIS
    Waits for a process Start-DemoFabricAppProcess started, at most until its time limit from its start, and returns
    ExitCode, StdOut, and StdErr (redacted), Seconds (how long it ran), and TimedOut. Internal.

    .DESCRIPTION
    When the time limit passes, the whole process tree is stopped, ExitCode is -1, TimedOut is true, and StdErr says so;
    the output it had written is dropped. The handle is closed afterwards, so it's read once; a second read throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Handle
    )

    if ([bool]$Handle.Closed) {
        throw ('The {0} process was already read or stopped.' -f $Handle.Tool)
    }
    $process = $Handle.Process
    try {
        $left = $Handle.StartedUtc.AddSeconds($Handle.TimeoutSeconds) - [System.DateTime]::UtcNow
        $milliseconds = [int][System.Math]::Max(0, [System.Math]::Min([double][int]::MaxValue, $left.TotalMilliseconds))
        if (-not $process.WaitForExit($milliseconds)) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose -Message ('The {0} process had already exited.' -f $Handle.Tool)
            }
            $null = $process.WaitForExit(15000)
            return [pscustomobject]@{
                ExitCode = -1
                StdOut   = ''
                StdErr   = ('{0} did not finish within {1} seconds and was stopped.' -f $Handle.Tool, $Handle.TimeoutSeconds)
                Seconds  = [int]$Handle.TimeoutSeconds
                TimedOut = $true
            }
        }
        $process.WaitForExit()
        $ended = try { $process.ExitTime.ToUniversalTime() } catch { [System.DateTime]::UtcNow }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = (Protect-DemoRayfinText -Text ([string]$Handle.StdOutTask.GetAwaiter().GetResult()).TrimEnd())
            StdErr   = (Protect-DemoRayfinText -Text ([string]$Handle.StdErrTask.GetAwaiter().GetResult()).TrimEnd())
            Seconds  = [int][System.Math]::Max(0, [System.Math]::Round(($ended - $Handle.StartedUtc).TotalSeconds))
            TimedOut = $false
        }
    }
    finally {
        $Handle.Closed = $true
        $process.Dispose()
    }
}

function Stop-DemoFabricAppProcess {
    # Ends a process Start-DemoFabricAppProcess started when it still runs, with every process it started, and closes its
    # handle without reading it. Never throws. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Ends only a local process its caller started and no longer needs.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Handle
    )

    if ($null -eq $Handle -or [bool](Get-DemoMemberValue -InputObject $Handle -Name 'Closed')) {
        return
    }
    $process = Get-DemoMemberValue -InputObject $Handle -Name 'Process'
    try {
        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill($true)
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('A local process couldn''t be ended: {0}' -f $_.Exception.Message)
    }
    finally {
        $Handle.Closed = $true
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-DemoRayfinCliPath {
    <#
    .SYNOPSIS
    Returns the entry script of the Rayfin CLI that the stage's npm ci installed (the version package-lock.json pins),
    or an empty string when it isn't installed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath
    )

    $package = Join-Path -Path $StagePath -ChildPath 'node_modules/@microsoft/rayfin-cli/package.json'
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        return ''
    }
    $manifest = Get-Content -LiteralPath $package -Raw | ConvertFrom-Json -AsHashtable
    $bin = $manifest['bin']
    $relative = if ($bin -is [System.Collections.IDictionary]) { [string]$bin['rayfin'] } else { [string]$bin }
    if (-not $relative) {
        return ''
    }
    $entry = Join-Path -Path (Split-Path -Path $package -Parent) -ChildPath $relative
    if (Test-Path -LiteralPath $entry -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($entry)
    }
    return ''
}

function Invoke-DemoRayfinCli {
    <#
    .SYNOPSIS
    Runs the stage's pinned Rayfin CLI with node and returns ExitCode, StdOut, StdErr (all redacted), and Data (the
    parsed JSON output, or null).

    .DESCRIPTION
    Every Rayfin CLI call in the module goes through this function so tests can mock it. The CLI's telemetry is
    turned off for the child (RAYFIN_TELEMETRY_OPTOUT=1) and an ambient RAYFIN_TOKEN is removed, so the CLI uses only
    the operator's own cached sign-in. With --json the CLI never opens a browser: a missing or expired sign-in fails
    instead (https://learn.microsoft.com/fabric/apps/cli-reference).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 600
    )

    $cli = Get-DemoRayfinCliPath -StagePath $StagePath
    if (-not $cli) {
        throw ('The Rayfin CLI isn''t installed in {0}. Run scripts/configure-fabric-app.ps1 without -SkipInstall first.' -f $StagePath)
    }
    $environment = @{ RAYFIN_TELEMETRY_OPTOUT = '1'; RAYFIN_TOKEN = $null; NO_COLOR = '1' }
    $run = Invoke-DemoFabricAppProcess -Tool 'node' -ArgumentList (@($cli) + $ArgumentList) -WorkingDirectory $StagePath -TimeoutSeconds $TimeoutSeconds -Environment $environment
    [pscustomobject]@{
        ExitCode = $run.ExitCode
        StdOut   = $run.StdOut
        StdErr   = $run.StdErr
        Data     = (ConvertFrom-DemoRayfinOutput -Text ([string]$run.StdOut))
    }
}

function ConvertFrom-DemoRayfinOutput {
    <#
    .SYNOPSIS
    The JSON a Rayfin CLI command printed with --json, from its first '{' on (anything before it, such as npm's
    warnings, is skipped), as a hashtable; $null when there's none or it doesn't parse. Internal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    $value = [string]$Text
    $start = $value.IndexOf('{')
    if ($start -lt 0) {
        return $null
    }
    try {
        return ($value.Substring($start) | ConvertFrom-Json -AsHashtable -Depth 64)
    }
    catch {
        return $null
    }
}

function Get-DemoFabricAppDeploymentRecord {
    <#
    .SYNOPSIS
    Reads the active deployment that 'rayfin up' recorded in the stage (rayfin/.deployments.json): item name and ID,
    workspace, hosting URL, and the portal deep link. Never returns the publishable key. Null when there is none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath
    )

    $path = Join-Path -Path $StagePath -ChildPath 'rayfin/.deployments.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $registry = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        return $null
    }
    $deployments = $registry['deployments']
    $active = [string]$registry['active']
    if (-not ($deployments -is [System.Collections.IDictionary]) -or -not $active -or -not $deployments.Contains($active)) {
        return $null
    }
    $record = $deployments[$active]
    [pscustomobject]@{
        ItemName    = [string]$record['itemName']
        ItemId      = [string]$record['fabricItemId']
        WorkspaceId = [string]$record['fabricWorkspaceId']
        TenantId    = [string]$record['fabricTenantId']
        HostingUrl  = [string]$record['hostingUrl']
        ItemUrl     = [string]$record['fabricDeepLink']
    }
}

function Get-DemoFabricAppFileHash {
    <#
    .SYNOPSIS
    SHA-256 of a file as lowercase hex, or an empty string when the file doesn't exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Set-DemoFabricAppEnvValue {
    <#
    .SYNOPSIS
    Sets KEY=value lines in a dotenv file, keeping every other line (rayfin up writes its own RAYFIN_PUBLIC_* lines
    to the same file).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Values
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            $lines.Add([string]$line)
        }
    }
    foreach ($key in @($Values.Keys | Sort-Object)) {
        if ($key -notmatch '^[A-Z][A-Z0-9_]*$') {
            throw ('Invalid environment variable name: {0}' -f $key)
        }
        $value = [string]$Values[$key]
        if ($value -match '[\r\n]') {
            throw ('The value of {0} has a line break.' -f $key)
        }
        $entry = '{0}={1}' -f $key, $value
        $index = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^\s*{0}\s*=' -f [regex]::Escape([string]$key))) {
                $index = $i
                break
            }
        }
        if ($index -ge 0) {
            $lines[$index] = $entry
        }
        else {
            $lines.Add($entry)
        }
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write environment values')) {
        $parent = Split-Path -Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

function ConvertTo-DemoFabricAppInstant {
    <#
    .SYNOPSIS
    A time from the history model (UTC without a zone, as text or as the DateTime that ConvertFrom-Json makes of
    it) as yyyy-MM-ddTHH:mm:ssZ, or '' when it's blank or not a time. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    $instant = $null
    if ($Value -is [datetime]) {
        $instant = if ($Value.Kind -eq [System.DateTimeKind]::Local) { $Value.ToUniversalTime() } else { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
    }
    elseif ([string]$Value -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?$') {
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            $instant = $parsed
        }
    }
    if ($null -eq $instant) {
        return ''
    }
    return $instant.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Find-DemoFabricAppTenantSetting {
    # The tenant setting among -Item (Tenants - List Tenant Settings) that one of config/versions.json's
    # fabricApp.tenantSettings names: by settingName when one is recorded, otherwise by its title or an alternate title
    # (newer portals say "Semantic Model" for "Dataset"). $null when none does. Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Item = @(),

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Setting
    )

    $name = [string]$Setting['settingName']
    if ($name) {
        $byName = @($Item | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'settingName') -ieq $name }) | Select-Object -First 1
        if ($null -ne $byName) {
            return $byName
        }
    }
    $titles = @(@([string]$Setting['title']) + @($Setting['alternateTitles'] | Where-Object { $_ } | ForEach-Object { [string]$_ }))
    return (@($Item | Where-Object { $null -ne $_ -and $titles -contains [string](Get-DemoMemberValue -InputObject $_ -Name 'title') }) | Select-Object -First 1)
}

function Test-DemoFabricAppTenantSetting {
    <#
    .SYNOPSIS
    Preflight's look at the two Fabric tenant settings the Insights app needs, P12 and P13: one result,
    PREFLIGHT.FABRIC.APPSETTINGS, that never stops the run or keeps it from DONE (2026-11-05). Internal.

    .DESCRIPTION
    The Insights app is part of every deployment, and it isn't created, or its queries fail, while "Fabric Apps
    (preview)" (P12) or "Dataset Execute Queries REST API" (P13; the history report's data check uses it too) is off. So
    preflight says so at the start, while a Fabric administrator can still turn them on before the app's step. The only
    documented way to read tenant settings is the Fabric admin API, Tenants - List Tenant Settings
    (https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings), which needs a Fabric administrator.
    It's read once, through the Phase 12 Fabric REST helpers (Get-DemoHubFabricAccess, Read-DemoHubFabricList), and each
    setting is matched as configure-fabric-app.ps1 -FabricAdmin matches it (Find-DemoFabricAppTenantSetting).
    - Both read, and on for the organization: Pass.
    - One read as off, or on only for security groups, or not read (no token, not a Fabric administrator, not found):
      a Warning, with the portal steps. The app's own step still checks both by creating the app and running its
      queries (FABRIC.APP.TENANTSETTING, FABRIC.APP.EXECUTEQUERIES).
    Never a Fail or Manual action required: the app never blocks DONE. The evidence says which case it is:
    checkedThroughApi, statusCode, settingsRead, on, off, groupsOnly, and notFound (titles only).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 10
    )

    $settings = @((Get-DemoFabricAppSetting)['tenantSettings'])
    $named = (@($settings | ForEach-Object { '"{0}"' -f [string]$_['title'] }) -join ' and ')
    $steps = ('A Fabric administrator opens the Fabric admin portal, selects Tenant settings, sets {0} to Enabled for the entire organization (or for security groups that include you and every viewer of the app), and selects Apply. Changes can take a few minutes; the Insights app''s step later in the run checks them again.' -f $named)
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '')
        New-DemoResult -CheckId 'PREFLIGHT.FABRIC.APPSETTINGS' -Area 'preflight' -Target 'tenant' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl 'https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings'
    }
    $unread = {
        param([string] $Why, [System.Collections.IDictionary] $Evidence)
        & $result 'Warning' ('Couldn''t read the Fabric tenant settings the Insights app needs, {0} ({1}). The app isn''t created, or its queries fail, while one is off; that doesn''t keep the run from DONE.' -f $named, $Why) $Evidence ('Nothing to do when they''re on. Otherwise: {0}' -f $steps)
    }

    $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId']) -Token $Token
    if (-not $access.Token) {
        return (& $unread (([string]$access.Error) -replace '^No Fabric token is available without interaction:\s*', 'no Fabric token: ').TrimEnd('.') ([ordered]@{ checkedThroughApi = $false }))
    }
    $list = Read-DemoHubFabricList -Uri ('{0}/admin/tenantsettings' -f (Get-DemoHubSetting)['fabric']['apiBaseUrl']) -Token $access.Token -MaxPages $MaxPages
    if (-not $list.Succeeded) {
        $why = if ($list.StatusCode -in 401, 403) { 'needs a Fabric administrator; HTTP {0}' -f $list.StatusCode } elseif ($list.StatusCode -eq 0) { 'the Fabric admin API didn''t answer: {0}' -f ([string]$list.Error).TrimEnd('.') } else { 'the Fabric admin API answered {0}' -f ([string]$list.Error).TrimEnd('.') }
        return (& $unread $why ([ordered]@{ checkedThroughApi = $true; statusCode = $list.StatusCode }))
    }
    $items = @($list.Items)
    $on = [System.Collections.Generic.List[string]]::new()
    $off = [System.Collections.Generic.List[string]]::new()
    $groupsOnly = [System.Collections.Generic.List[string]]::new()
    $notFound = [System.Collections.Generic.List[string]]::new()
    foreach ($setting in $settings) {
        $title = [string]$setting['title']
        $found = Find-DemoFabricAppTenantSetting -Item $items -Setting $setting
        # Only an explicit enabled value is read: one the answer doesn't have counts as not found, never "off".
        $enabledValue = if ($null -ne $found) { Get-DemoMemberValue -InputObject $found -Name 'enabled' } else { $null }
        if ($null -eq $enabledValue -or [string]$enabledValue -notin 'True', 'False') {
            $notFound.Add($title)
            continue
        }
        if ([string]$enabledValue -eq 'False') {
            $off.Add($title)
            continue
        }
        # Assign before enumerating: Get-DemoMemberValue returns an array as one object.
        $groupsValue = Get-DemoMemberValue -InputObject $found -Name 'enabledSecurityGroups'
        $groups = @(@($groupsValue) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        if ($groups.Count -gt 0) {
            $groupsOnly.Add(('{0} (only for {1})' -f $title, ($groups -join ', ')))
            continue
        }
        $on.Add($title)
    }
    $evidence = [ordered]@{ checkedThroughApi = $true; statusCode = 200; settingsRead = $items.Count; on = $on.ToArray(); off = $off.ToArray(); groupsOnly = $groupsOnly.ToArray(); notFound = $notFound.ToArray() }
    if ($off.Count -eq 0 -and $groupsOnly.Count -eq 0 -and $notFound.Count -eq 0) {
        return (& $result 'Pass' ('The Fabric tenant settings the Insights app needs are on for the organization: {0} (read through the Fabric admin API).' -f $named) $evidence)
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($off.Count -gt 0) {
        $parts.Add(('off: {0}' -f ($off -join ', ')))
    }
    if ($groupsOnly.Count -gt 0) {
        $parts.Add(('on only for security groups, which must include you and every viewer: {0}' -f ($groupsOnly -join '; ')))
    }
    if ($notFound.Count -gt 0) {
        $parts.Add(('not found among the {0} settings the admin API returned (the preview may have renamed it): {1}' -f $items.Count, ($notFound -join ', ')))
    }
    return (& $result 'Warning' ('The Fabric tenant settings the Insights app needs aren''t all on for the organization ({0}). The app isn''t created, or its queries fail, while one is off; that doesn''t keep the run from DONE.' -f ($parts -join '; ')) $evidence $steps)
}
