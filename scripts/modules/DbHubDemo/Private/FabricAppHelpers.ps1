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
    Runs node or npm in a working directory with a time limit, and returns ExitCode, StdOut, and StdErr (redacted).

    .DESCRIPTION
    Standard input is closed, so nothing can wait for a reply; when the time limit passes, the whole process tree is
    stopped and ExitCode is -1. Environment entries are set for the child only (null removes one), so the operator's
    session is never changed. Output is redacted with Protect-DemoRayfinText before anything else sees it.
    On Windows, npm is a batch file: it runs through cmd.exe with fixed arguments that need no quoting.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('node', 'npm')]
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
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose -Message ('The {0} process had already exited.' -f $Tool)
            }
            $null = $process.WaitForExit(15000)
            return [pscustomobject]@{
                ExitCode = -1
                StdOut   = ''
                StdErr   = ('{0} did not finish within {1} seconds and was stopped.' -f $Tool, $TimeoutSeconds)
            }
        }
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = (Protect-DemoRayfinText -Text ([string]$stdoutTask.GetAwaiter().GetResult()).TrimEnd())
            StdErr   = (Protect-DemoRayfinText -Text ([string]$stderrTask.GetAwaiter().GetResult()).TrimEnd())
        }
    }
    finally {
        $process.Dispose()
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
    $data = $null
    $text = [string]$run.StdOut
    $start = $text.IndexOf('{')
    if ($start -ge 0) {
        try {
            $data = $text.Substring($start) | ConvertFrom-Json -AsHashtable -Depth 64
        }
        catch {
            $data = $null
        }
    }
    [pscustomobject]@{
        ExitCode = $run.ExitCode
        StdOut   = $run.StdOut
        StdErr   = $run.StdErr
        Data     = $data
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
