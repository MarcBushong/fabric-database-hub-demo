# The .NET SDK that builds the workload runner (Publish-DemoWorkloadRunner, ADR 0010), checked in preflight before
# anything is created (2026-11-09 live finding: a runtime-only dotnet first on PATH failed the Artifacts step about 15
# minutes into a run, with the host's own "A compatible .NET SDK was not found" and a generic remediation).
# Sources (checked 2026-11-09):
# - global.json (version, rollForward, and the muxer's search from the current working directory):
#   https://learn.microsoft.com/dotnet/core/tools/global-json
# - dotnet --version and --list-sdks: https://learn.microsoft.com/dotnet/core/tools/dotnet
# - Install .NET on Windows (Program Files\dotnet by default; winget install Microsoft.DotNet.SDK.10):
#   https://learn.microsoft.com/dotnet/core/install/windows
# - The dotnet-install scripts (%LocalAppData%\Microsoft\dotnet on Windows and $HOME/.dotnet on Linux and macOS, by
#   default): https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script

function Get-DemoDotNetPath {
    <#
    .SYNOPSIS
    The dotnet that the workload runner's build runs (Invoke-DemoDotNet): the first one on PATH, as a full path, or an
    empty string when there's none. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $dotnet = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dotnet) {
        return ''
    }
    return [string]$dotnet.Source
}

function Test-DemoSamePath {
    # True when two file-system paths name the same place, compared the way this platform does (case-insensitive on
    # Windows), without a trailing separator. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [AllowEmptyString()]
        [string] $OtherPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($OtherPath)) {
        return $false
    }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $left = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $right = [System.IO.Path]::GetFullPath($OtherPath).TrimEnd([char[]]'\/')
    return [string]::Equals($left, $right, $comparison)
}

function Get-DemoDotNetCandidateFolder {
    <#
    .SYNOPSIS
    The well-known folders a .NET SDK is often installed in, besides the first dotnet on PATH: DOTNET_ROOT,
    %ProgramFiles%\dotnet (the installers and winget), %LOCALAPPDATA%\Microsoft\dotnet (dotnet-install.ps1's default),
    and ~/.dotnet (dotnet-install.sh's default). Returns Name and Folder for each one that's set, once each. Internal;
    tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $candidates = [System.Collections.Generic.List[object]]::new()
    $known = @(
        [pscustomobject]@{ Name = 'DOTNET_ROOT'; Base = [System.Environment]::GetEnvironmentVariable('DOTNET_ROOT'); Child = '' }
        [pscustomobject]@{ Name = '%ProgramFiles%\dotnet'; Base = [System.Environment]::GetEnvironmentVariable('ProgramFiles'); Child = 'dotnet' }
        [pscustomobject]@{ Name = '%LOCALAPPDATA%\Microsoft\dotnet'; Base = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA'); Child = 'Microsoft/dotnet' }
        [pscustomobject]@{ Name = '~/.dotnet'; Base = $HOME; Child = '.dotnet' }
    )
    foreach ($entry in $known) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Base)) {
            continue
        }
        $folder = if ($entry.Child) { Join-Path -Path ([string]$entry.Base) -ChildPath $entry.Child } else { [string]$entry.Base }
        try {
            $folder = [System.IO.Path]::GetFullPath($folder)
        }
        catch {
            continue
        }
        if (@($candidates | Where-Object { Test-DemoSamePath -Path $_.Folder -OtherPath $folder }).Count -eq 0) {
            $candidates.Add([pscustomobject]@{ Name = $entry.Name; Folder = $folder })
        }
    }
    return $candidates.ToArray()
}

function Get-DemoDotNetSdkRequirement {
    <#
    .SYNOPSIS
    What workload-generator/global.json asks of the .NET SDK: Version, RollForward (latestPatch when it doesn't say, as
    the SDK does), MajorMinor, Major, Path, and Text, which says it in words. Throws when the file can't be read.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $GeneratorPath
    )

    $path = Join-Path -Path $GeneratorPath -ChildPath 'global.json'
    $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $sdk = $json['sdk']
    $version = if ($sdk -is [System.Collections.IDictionary]) { [string]$sdk['version'] } else { '' }
    if ($version -notmatch '^(\d+)\.(\d+)\.(\d)\d*') {
        throw ('{0} pins no .NET SDK version (sdk.version).' -f $path)
    }
    $major = $Matches[1]
    $majorMinor = '{0}.{1}' -f $Matches[1], $Matches[2]
    $band = $Matches[3]
    $rollForward = if ($sdk.Contains('rollForward') -and [string]$sdk['rollForward']) { [string]$sdk['rollForward'] } else { 'latestPatch' }
    $accepted = switch ($rollForward) {
        'disable' { 'exactly {0}' -f $version }
        { $_ -in 'patch', 'latestPatch' } { '{0} or a later {1}.{2}xx patch' -f $version, $majorMinor, $band }
        { $_ -in 'feature', 'latestFeature' } { '{0} or any later {1} SDK' -f $version, $majorMinor }
        { $_ -in 'minor', 'latestMinor' } { '{0} or any later {1}.x SDK' -f $version, $major }
        default { '{0} or any later SDK' -f $version }
    }
    [pscustomobject]@{
        Version     = $version
        RollForward = $rollForward
        MajorMinor  = $majorMinor
        Major       = $major
        Path        = $path
        Text        = '{0} (rollForward {1})' -f $accepted, $rollForward
    }
}

function Get-DemoDotNetSdkInstallText {
    # The install step for the .NET SDK that -Requirement names, for this platform: winget or the installer on Windows,
    # Microsoft's download page or the dev container elsewhere. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Requirement
    )

    $download = 'https://dotnet.microsoft.com/download/dotnet/{0}' -f $Requirement.MajorMinor
    if ($IsWindows) {
        return ('install the .NET SDK {0} or later: winget install Microsoft.DotNet.SDK.{1} (winget upgrade Microsoft.DotNet.SDK.{1} when an older one came from winget), or the installer from {2}' -f $Requirement.Version, $Requirement.Major, $download)
    }
    return ('install the .NET SDK {0} or later from {1} (https://learn.microsoft.com/dotnet/core/install/), or use the repository''s dev container, which has it' -f $Requirement.Version, $download)
}

function Get-DemoDotNetSdkStatus {
    <#
    .SYNOPSIS
    Whether the dotnet that builds the workload runner has a .NET SDK that workload-generator/global.json accepts, and
    the exact fix when it hasn't. Never throws. Internal.

    .DESCRIPTION
    Runs that dotnet (Get-DemoDotNetPath: the first on PATH, which Invoke-DemoDotNet runs) with --version in
    workload-generator, where global.json applies, so the SDK it resolves is the one 'dotnet publish' resolves there.
    When that fails, --list-sdks says which SDKs it has (none for a runtime-only install, which apps and Visual Studio
    leave behind). A dotnet in another well-known folder (Get-DemoDotNetCandidateFolder) whose --version passes there
    too is an alternative: it's installed, just not first on PATH. Returns Ok, Path, Version (the SDK it resolves),
    Sdks, ExitCode, Requirement (Get-DemoDotNetSdkRequirement), Alternatives (Name, Folder, Path, Version), Message
    (what's wrong), and Fix (the exact next step).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $RepositoryRoot = $script:RepoRoot
    )

    $generator = Join-Path -Path $RepositoryRoot -ChildPath 'workload-generator'
    $status = [pscustomobject]@{ Ok = $false; Path = ''; Version = ''; Sdks = @(); ExitCode = $null; Requirement = $null; Alternatives = @(); Message = ''; Fix = '' }
    try {
        $requirement = Get-DemoDotNetSdkRequirement -GeneratorPath $generator
    }
    catch {
        $status.Message = 'workload-generator/global.json couldn''t be read, so the .NET SDK the workload runner needs isn''t known: {0}' -f (Protect-DemoText -Text $_.Exception.Message)
        $status.Fix = 'Restore workload-generator/global.json from Git (git checkout -- workload-generator/global.json), then run ./scripts/deploy.ps1 again.'
        return $status
    }
    $status.Requirement = $requirement
    # The SDK a dotnet resolves in workload-generator, as 'dotnet publish' does there: its version, or '' with why not.
    $probe = {
        param([string] $DotNetPath)
        try {
            $run = Invoke-DemoDotNet -DotNetPath $DotNetPath -ArgumentList @('--version') -WorkingDirectory $generator
            $line = @(([string]$run.StdOut) -split '\r?\n' | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+' }) | Select-Object -Last 1
            [pscustomobject]@{ ExitCode = $run.ExitCode; Version = $(if ($run.ExitCode -eq 0 -and $line) { $line.Trim() } else { '' }) }
        }
        catch {
            [pscustomobject]@{ ExitCode = $null; Version = '' }
        }
    }
    $status.Path = Get-DemoDotNetPath
    $listed = $false
    if ($status.Path) {
        $own = & $probe $status.Path
        $status.ExitCode = $own.ExitCode
        if ($own.Version) {
            $status.Ok = $true
            $status.Version = $own.Version
            return $status
        }
        try {
            $list = Invoke-DemoDotNet -DotNetPath $status.Path -ArgumentList @('--list-sdks') -WorkingDirectory $generator
            if ($list.ExitCode -eq 0) {
                $listed = $true
                $status.Sdks = @(([string]$list.StdOut) -split '\r?\n' | ForEach-Object { if ($_.Trim() -match '^(\d+\.\d+\.\d+\S*)') { $Matches[1] } })
            }
        }
        catch {
            Write-DemoLog -Level Debug -Message ('dotnet --list-sdks couldn''t be read: {0}' -f $_.Exception.Message)
        }
    }
    $alternatives = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @(Get-DemoDotNetCandidateFolder)) {
        $executable = Join-Path -Path $candidate.Folder -ChildPath $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf) -or (Test-DemoSamePath -Path $executable -OtherPath $status.Path)) {
            continue
        }
        $other = & $probe $executable
        if ($other.Version) {
            $alternatives.Add([pscustomobject]@{ Name = $candidate.Name; Folder = $candidate.Folder; Path = $executable; Version = $other.Version })
        }
    }
    $status.Alternatives = $alternatives.ToArray()

    $install = Get-DemoDotNetSdkInstallText -Requirement $requirement
    if ($status.Path) {
        $has = if (-not $listed) {
            'no .NET SDK it can use here (dotnet --version: exit code {0})' -f $(if ($null -ne $status.ExitCode) { $status.ExitCode } else { 'none: it didn''t start' })
        }
        else {
            switch ($status.Sdks.Count) {
                0 { 'no .NET SDK, only runtimes' }
                1 { 'only the .NET SDK {0}' -f $status.Sdks[0] }
                default { 'only the .NET SDKs {0}' -f ($status.Sdks -join ', ') }
            }
        }
        $status.Message = 'The dotnet first on PATH, {0}, has {1}, and workload-generator/global.json needs {2}, so the workload runner can''t be built.' -f $status.Path, $has, $requirement.Text
    }
    else {
        $status.Message = 'No dotnet is on PATH, and workload-generator/global.json needs the .NET SDK {0}, so the workload runner can''t be built.' -f $requirement.Text
    }
    $retry = 'then run ./scripts/deploy.ps1 again'
    if ($status.Alternatives.Count -gt 0) {
        $found = $status.Alternatives[0]
        $status.Message += ' {0} has the .NET SDK {1}, which it accepts, but isn''t first on PATH.' -f $found.Folder, $found.Version
        $before = if ($status.Path) { ' before {0}' -f (Split-Path -Path $status.Path -Parent) } else { '' }
        $status.Fix = 'Put {0} first on PATH: in this terminal, $env:PATH = ''{1}{2}'' + $env:PATH, {3}; to keep it, move {0}{4} in your PATH settings. Or {5}.' -f $found.Folder, $found.Folder.Replace("'", "''"), [System.IO.Path]::PathSeparator, $retry, $before, $install
        return $status
    }
    $where = ''
    if ($IsWindows -and $status.Path) {
        $programFiles = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
        $systemFolder = if ($programFiles) { Join-Path -Path $programFiles -ChildPath 'dotnet' } else { '' }
        if ($systemFolder -and -not (Test-DemoSamePath -Path (Split-Path -Path $status.Path -Parent) -OtherPath $systemFolder)) {
            $where = ' The installer and winget put it in {0}, so make that folder come before {1} on PATH.' -f $systemFolder, (Split-Path -Path $status.Path -Parent)
        }
    }
    $status.Fix = '{0}{1}; then open a new terminal and run ./scripts/deploy.ps1 again.{2} Or deploy without the workload runner: ./scripts/deploy.ps1 -SkipRunner (the activity profiles are then Not selected).' -f $install.Substring(0, 1).ToUpperInvariant(), $install.Substring(1), $where
    return $status
}

function Test-DemoDotNetSdk {
    <#
    .SYNOPSIS
    PREFLIGHT.TOOLS.DOTNETSDK: Pass when the dotnet that builds the workload runner has a .NET SDK that
    workload-generator/global.json accepts, with its version; Fail before anything is created otherwise, saying which
    dotnet ran, which SDKs it has, what global.json needs, and the exact fix (Get-DemoDotNetSdkStatus). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $RepositoryRoot = $script:RepoRoot
    )

    $status = Get-DemoDotNetSdkStatus -RepositoryRoot $RepositoryRoot
    $docUrl = if ($IsWindows) { 'https://learn.microsoft.com/dotnet/core/install/windows' } elseif ($IsMacOS) { 'https://learn.microsoft.com/dotnet/core/install/macos' } else { 'https://learn.microsoft.com/dotnet/core/install/linux' }
    $evidence = [ordered]@{
        dotnetPath      = $status.Path
        sdkVersion      = $status.Version
        requiredVersion = $(if ($status.Requirement) { $status.Requirement.Version } else { '' })
        rollForward     = $(if ($status.Requirement) { $status.Requirement.RollForward } else { '' })
    }
    if ($status.Ok) {
        $message = 'The .NET SDK {0} builds the workload runner: {1}, first on PATH, resolves it in workload-generator, whose global.json needs {2}.' -f $status.Version, $status.Path, $status.Requirement.Text
        return (New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl 'https://learn.microsoft.com/dotnet/core/tools/global-json')
    }
    $evidence['installedSdks'] = @($status.Sdks)
    $evidence['exitCode'] = $status.ExitCode
    $evidence['alternatives'] = @($status.Alternatives | ForEach-Object { [ordered]@{ folder = $_.Folder; sdkVersion = $_.Version } })
    return (New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status 'Fail' -Message $status.Message -Evidence $evidence -Remediation $status.Fix -DocUrl $docUrl)
}

function Test-DemoDotNetSdkFailure {
    # True when a build error says the .NET SDK is missing, or isn't one global.json accepts: the dotnet host's own
    # words (exit code -2147450725 is 0x8000809B, the host's SDK resolution failure) or Invoke-DemoDotNet's. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    return ($Text -match '(?i)compatible \.NET SDK was not found|No \.NET SDKs were found|\.NET SDK \(dotnet\) was not found on PATH|exit code -2147450725\b|0x8000809B')
}

function Get-DemoArtifactBuildRemediation {
    <#
    .SYNOPSIS
    DEPLOY.ARTIFACTS.BUILD's remediation for a build that failed with -Message: when the .NET SDK was the cause
    (Test-DemoDotNetSdkFailure), the same diagnosis and fix as PREFLIGHT.TOOLS.DOTNETSDK (Get-DemoDotNetSdkStatus,
    read again now); otherwise the generic step. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Message
    )

    $generic = 'Run New-DemoBootstrapBundle and Publish-DemoWorkloadRunner yourself to see the error (the runner needs the .NET SDK, or use -SkipRunner).'
    if (-not (Test-DemoDotNetSdkFailure -Text $Message)) {
        return $generic
    }
    try {
        $status = Get-DemoDotNetSdkStatus
        if (-not $status.Ok -and $status.Fix) {
            return ('{0} {1}' -f $status.Message, $status.Fix)
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The .NET SDK couldn''t be checked again: {0}' -f $_.Exception.Message)
    }
    return 'The build''s dotnet has no .NET SDK that workload-generator/global.json accepts (PREFLIGHT.TOOLS.DOTNETSDK says which it needs). Install that SDK (docs/prerequisites.md), then run ./scripts/deploy.ps1 again; or deploy without the workload runner: ./scripts/deploy.ps1 -SkipRunner.'
}
