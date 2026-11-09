# The .NET SDK that builds the workload runner (Publish-DemoWorkloadRunner, ADR 0010). Preflight checks it before anything
# is created (2026-11-09 live finding: a runtime-only dotnet first on PATH failed the Artifacts step about 15 minutes into a
# run), and since the owner's decision the same day ("Install it automatically"), deploy.ps1 installs the pinned SDK for
# the user when it finds none that global.json accepts (Initialize-DemoDotNetSdk): Microsoft's zip, checked against the
# SHA-512 in config/versions.json (dotnetSdkInstall), then dotnet.exe's Authenticode signature, then 'dotnet --version'
# in workload-generator, into %LOCALAPPDATA%\DbHubDemo\dotnet\<version>, with no prompt, no administrator rights, and no
# change to PATH. The build runs that dotnet by its full path (Resolve-DemoBuildDotNet).
# Sources (checked 2026-11-09):
# - global.json (version, rollForward, and the muxer's search from the current working directory):
#   https://learn.microsoft.com/dotnet/core/tools/global-json
# - dotnet --version and --list-sdks: https://learn.microsoft.com/dotnet/core/tools/dotnet
# - Install .NET on Windows (Program Files\dotnet by default; winget install Microsoft.DotNet.SDK.10; the manual install
#   from the zip): https://learn.microsoft.com/dotnet/core/install/windows
# - The dotnet-install scripts (%LocalAppData%\Microsoft\dotnet on Windows and $HOME/.dotnet on Linux and macOS, by
#   default): https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script
# - The release metadata the pins come from (releases.json, its files' url and hash):
#   https://learn.microsoft.com/dotnet/core/install/how-to-detect-installed-versions and
#   https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json
# - Get-AuthenticodeSignature: https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
# - ZipFile.ExtractToDirectory: https://learn.microsoft.com/dotnet/api/system.io.compression.zipfile.extracttodirectory
# - HttpClient (HttpCompletionOption.ResponseHeadersRead): https://learn.microsoft.com/dotnet/api/system.net.http.httpclient

function Get-DemoDotNetPath {
    <#
    .SYNOPSIS
    The dotnet first on PATH, as a full path, or an empty string when there's none. Internal; tests mock it.
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

function Format-DemoMegabyteText {
    # Bytes as whole megabytes (MiB), for a message: "287 MB". Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [long] $Bytes
    )

    return ('{0:N0} MB' -f [System.Math]::Round($Bytes / 1MB))
}

function Get-DemoDotNetSdkInstallRoot {
    # Where deploy.ps1 installs the pinned .NET SDK for the user: %LOCALAPPDATA%\DbHubDemo\dotnet, or the folder
    # DBHUB_DOTNET_INSTALL_ROOT names (a test, or a check against a temporary folder). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $override = [System.Environment]::GetEnvironmentVariable('DBHUB_DOTNET_INSTALL_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath($override)
    }
    $base = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) {
        return ''
    }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $base -ChildPath 'DbHubDemo/dotnet'))
}

function Get-DemoDotNetSdkPin {
    <#
    .SYNOPSIS
    The .NET SDK archive that deploy.ps1 installs on this machine (config/versions.json dotnetSdkInstall): Version, Rid,
    Url, FileName, SizeBytes (0 when it isn't pinned), Sha512, Root (Get-DemoDotNetSdkInstallRoot), and Folder
    (Root\<version>). $null where it installs none: not on Windows, an architecture without a pinned archive, or no
    per-user folder. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $RepositoryRoot = $script:RepoRoot
    )

    if (-not $IsWindows) {
        return $null
    }
    $rid = switch ([string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'win-x64' }
        'Arm64' { 'win-arm64' }
        default { '' }
    }
    $root = Get-DemoDotNetSdkInstallRoot
    if (-not $rid -or -not $root) {
        return $null
    }
    $versions = Get-Content -LiteralPath (Join-Path -Path $RepositoryRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $install = $versions['dotnetSdkInstall']
    if ($install -isnot [System.Collections.IDictionary] -or $install['files'] -isnot [System.Collections.IDictionary] -or -not $install['files'].Contains($rid)) {
        return $null
    }
    $file = $install['files'][$rid]
    $version = [string]$install['version']
    [pscustomobject]@{
        Version   = $version
        Rid       = $rid
        Url       = [string]$file['url']
        FileName  = [string]$file['fileName']
        SizeBytes = $(if ($file.Contains('sizeBytes')) { [long]$file['sizeBytes'] } else { [long]0 })
        Sha512    = ([string]$file['sha512']).ToLowerInvariant()
        Root      = $root
        Folder    = Join-Path -Path $root -ChildPath $version
    }
}

function Test-DemoDotNetSignature {
    # Whether -Path has a valid Authenticode signature from Microsoft Corporation (Get-AuthenticodeSignature, Windows):
    # Ok, Status, and Subject. Internal; tests mock it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    $subject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    [pscustomobject]@{
        Ok      = ([string]$signature.Status -eq 'Valid' -and $subject -match '(^|,\s*)O=Microsoft Corporation(\s*,|$)')
        Status  = [string]$signature.Status
        Subject = $subject
    }
}

function Test-DemoDotNetSdkInstall {
    <#
    .SYNOPSIS
    Whether -Folder holds a usable copy of the pinned SDK (-Pin): its dotnet.exe exists, has a valid Authenticode
    signature from Microsoft Corporation, and its 'dotnet --version' in workload-generator, where global.json applies,
    prints the pinned version. Returns Ok, Path, Version, and Detail (why not). Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Pin,

        [Parameter(Mandatory)]
        [string] $Folder,

        [string] $RepositoryRoot = $script:RepoRoot
    )

    $executable = Join-Path -Path $Folder -ChildPath 'dotnet.exe'
    $result = [pscustomobject]@{ Ok = $false; Path = $executable; Version = ''; Detail = '' }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        $result.Detail = 'it has no dotnet.exe'
        return $result
    }
    try {
        $signature = Test-DemoDotNetSignature -Path $executable
        if (-not $signature.Ok) {
            $result.Detail = 'dotnet.exe''s Authenticode signature isn''t a valid one from Microsoft Corporation (status {0}{1})' -f $signature.Status, $(if ($signature.Subject) { ', signer {0}' -f $signature.Subject } else { '' })
            return $result
        }
        $run = Invoke-DemoDotNet -DotNetPath $executable -ArgumentList @('--version') -WorkingDirectory (Join-Path -Path $RepositoryRoot -ChildPath 'workload-generator')
        $line = @(([string]$run.StdOut) -split '\r?\n' | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+' }) | Select-Object -Last 1
        $printed = if ($line) { $line.Trim() } else { '' }
        if ($run.ExitCode -ne 0 -or $printed -ne $Pin.Version) {
            $result.Detail = '''dotnet --version'' in workload-generator answered {0} (exit code {1}), not {2}' -f $(if ($printed) { $printed } else { 'nothing' }), $run.ExitCode, $Pin.Version
            return $result
        }
        $result.Ok = $true
        $result.Version = $printed
    }
    catch {
        $result.Detail = 'it couldn''t be checked: {0}' -f (Protect-DemoText -Text $_.Exception.Message)
    }
    return $result
}

function Get-DemoDotNetSdkInstall {
    <#
    .SYNOPSIS
    The pinned SDK that deploy.ps1 installed for the user earlier, when it's complete and verified: its folder has the
    record Install-DemoDotNetSdk writes last (dbhub-sdk.json), for the pinned version and archive, and it passes
    Test-DemoDotNetSdkInstall again. Returns Ok, Path, Version, Folder, and Detail. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Pin,

        [string] $RepositoryRoot = $script:RepoRoot
    )

    $result = [pscustomobject]@{ Ok = $false; Path = ''; Version = ''; Folder = ''; Detail = '' }
    if ($null -eq $Pin) {
        $result.Detail = 'deploy.ps1 installs no SDK on this platform'
        return $result
    }
    $result.Folder = $Pin.Folder
    $record = Join-Path -Path $Pin.Folder -ChildPath 'dbhub-sdk.json'
    if (-not (Test-Path -LiteralPath $record -PathType Leaf)) {
        $result.Detail = $(if (Test-Path -LiteralPath $Pin.Folder) { 'an install that didn''t finish (no record)' } else { 'not installed' })
        return $result
    }
    try {
        $data = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$data['version'] -ne $Pin.Version -or ([string]$data['sha512']).ToLowerInvariant() -ne $Pin.Sha512) {
            $result.Detail = 'its record is for another archive'
            return $result
        }
    }
    catch {
        $result.Detail = 'its record can''t be read'
        return $result
    }
    $check = Test-DemoDotNetSdkInstall -Pin $Pin -Folder $Pin.Folder -RepositoryRoot $RepositoryRoot
    $result.Path = $check.Path
    if (-not $check.Ok) {
        $result.Detail = $check.Detail
        return $result
    }
    $result.Ok = $true
    $result.Version = $check.Version
    return $result
}

function Get-DemoDotNetSdkStatus {
    <#
    .SYNOPSIS
    Whether the workload runner's build has a .NET SDK that workload-generator/global.json accepts, which dotnet that is,
    and the exact fix when there's none. Never throws. Internal.

    .DESCRIPTION
    Runs the dotnet first on PATH (Get-DemoDotNetPath) with --version in workload-generator, where global.json applies,
    so the SDK it resolves is the one 'dotnet publish' resolves there. When that fails, the SDK deploy.ps1 installed for
    the user (Get-DemoDotNetSdkInstall) counts, verified again. When neither works, --list-sdks says which SDKs the dotnet
    on PATH has (none for a runtime-only install, which apps and Visual Studio leave behind), and a dotnet in another
    well-known folder (Get-DemoDotNetCandidateFolder) whose --version passes there is named as an alternative. Returns
    Ok, Source (PATH, Installed, or ''), Path (the dotnet the build runs), FirstOnPath, Version (the SDK it resolves),
    Sdks, ExitCode, Requirement (Get-DemoDotNetSdkRequirement), Pin (Get-DemoDotNetSdkPin: what deploy.ps1 would install,
    or $null), Alternatives (Name, Folder, Path, Version), Message (what's wrong), and Fix (the exact next step).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $RepositoryRoot = $script:RepoRoot
    )

    $generator = Join-Path -Path $RepositoryRoot -ChildPath 'workload-generator'
    $status = [pscustomobject]@{ Ok = $false; Source = ''; Path = ''; FirstOnPath = ''; Version = ''; Sdks = @(); ExitCode = $null; Requirement = $null; Pin = $null; Alternatives = @(); Message = ''; Fix = '' }
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
    $status.FirstOnPath = Get-DemoDotNetPath
    if ($status.FirstOnPath) {
        $own = & $probe $status.FirstOnPath
        $status.ExitCode = $own.ExitCode
        if ($own.Version) {
            $status.Ok = $true
            $status.Source = 'PATH'
            $status.Path = $status.FirstOnPath
            $status.Version = $own.Version
            return $status
        }
    }
    # The SDK deploy.ps1 installed for the user (2026-11-09), never on PATH: the build runs it by its full path.
    try {
        $status.Pin = Get-DemoDotNetSdkPin -RepositoryRoot $RepositoryRoot
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The .NET SDK that deploy.ps1 installs couldn''t be read from config/versions.json: {0}' -f $_.Exception.Message)
    }
    $installed = Get-DemoDotNetSdkInstall -Pin $status.Pin -RepositoryRoot $RepositoryRoot
    if ($installed.Ok) {
        $status.Ok = $true
        $status.Source = 'Installed'
        $status.Path = $installed.Path
        $status.Version = $installed.Version
        return $status
    }
    $listed = $false
    if ($status.FirstOnPath) {
        try {
            $list = Invoke-DemoDotNet -DotNetPath $status.FirstOnPath -ArgumentList @('--list-sdks') -WorkingDirectory $generator
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
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf) -or (Test-DemoSamePath -Path $executable -OtherPath $status.FirstOnPath)) {
            continue
        }
        $other = & $probe $executable
        if ($other.Version) {
            $alternatives.Add([pscustomobject]@{ Name = $candidate.Name; Folder = $candidate.Folder; Path = $executable; Version = $other.Version })
        }
    }
    $status.Alternatives = $alternatives.ToArray()

    if ($status.FirstOnPath) {
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
        $status.Message = 'The dotnet first on PATH, {0}, has {1}, and workload-generator/global.json needs {2}, so the workload runner can''t be built.' -f $status.FirstOnPath, $has, $requirement.Text
    }
    else {
        $status.Message = 'No dotnet is on PATH, and workload-generator/global.json needs the .NET SDK {0}, so the workload runner can''t be built.' -f $requirement.Text
    }
    $install = Get-DemoDotNetSdkInstallText -Requirement $requirement
    # deploy.ps1 installs the pinned SDK itself where it can (2026-11-09), so that comes first.
    $automatic = ''
    if ($null -ne $status.Pin) {
        $download = if ($status.Pin.SizeBytes -gt 0) { 'a {0} download' -f (Format-DemoMegabyteText -Bytes $status.Pin.SizeBytes) } else { 'a download' }
        $automatic = 'Run ./scripts/deploy.ps1: before it creates anything, it installs the .NET SDK {0} for you in {1} ({2}, with no administrator rights and no change to PATH) and builds with it. ' -f $status.Pin.Version, $status.Pin.Folder, $download
    }
    $retry = 'then run ./scripts/deploy.ps1 again'
    if ($status.Alternatives.Count -gt 0) {
        $found = $status.Alternatives[0]
        $status.Message += ' {0} has the .NET SDK {1}, which it accepts, but isn''t first on PATH.' -f $found.Folder, $found.Version
        $before = if ($status.FirstOnPath) { ' before {0}' -f (Split-Path -Path $status.FirstOnPath -Parent) } else { '' }
        $status.Fix = '{0}{1}ut {2} first on PATH: in this terminal, $env:PATH = ''{3}{4}'' + $env:PATH, {5}; to keep it, move {2}{6} in your PATH settings. Or {7}.' -f $automatic, $(if ($automatic) { 'Or p' } else { 'P' }), $found.Folder, $found.Folder.Replace("'", "''"), [System.IO.Path]::PathSeparator, $retry, $before, $install
        return $status
    }
    $where = ''
    if ($IsWindows -and $status.FirstOnPath) {
        $programFiles = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
        $systemFolder = if ($programFiles) { Join-Path -Path $programFiles -ChildPath 'dotnet' } else { '' }
        if ($systemFolder -and -not (Test-DemoSamePath -Path (Split-Path -Path $status.FirstOnPath -Parent) -OtherPath $systemFolder)) {
            $where = ' The installer and winget put it in {0}, so make that folder come before {1} on PATH.' -f $systemFolder, (Split-Path -Path $status.FirstOnPath -Parent)
        }
    }
    $manual = '{0}{1}; then open a new terminal and run ./scripts/deploy.ps1 again.{2}' -f $install.Substring(0, 1).ToUpperInvariant(), $install.Substring(1), $where
    if ($automatic) {
        $manual = 'Or {0}' -f $manual.Substring(0, 1).ToLowerInvariant() + $manual.Substring(1)
    }
    $status.Fix = '{0}{1} Or deploy without the workload runner: ./scripts/deploy.ps1 -SkipRunner (the activity profiles are then Not selected).' -f $automatic, $manual
    return $status
}

function Resolve-DemoBuildDotNet {
    <#
    .SYNOPSIS
    The full path of the dotnet that builds the workload runner (Get-DemoDotNetSdkStatus): the first on PATH when it has
    an SDK that workload-generator/global.json accepts, otherwise the SDK deploy.ps1 installed for the user. Throws, with
    what's wrong and the fix, when there's neither. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $RepositoryRoot = $script:RepoRoot
    )

    $status = Get-DemoDotNetSdkStatus -RepositoryRoot $RepositoryRoot
    if (-not $status.Ok) {
        throw ('{0} {1}' -f $status.Message, $status.Fix)
    }
    if ($status.Source -eq 'Installed') {
        Write-DemoLog -Message ('Building the workload runner with the .NET SDK {0} that deploy.ps1 installed for you: {1}.' -f $status.Version, $status.Path)
    }
    return $status.Path
}

function Test-DemoDotNetSdk {
    <#
    .SYNOPSIS
    PREFLIGHT.TOOLS.DOTNETSDK: whether the workload runner's build has a .NET SDK that workload-generator/global.json
    accepts (Get-DemoDotNetSdkStatus). Internal.

    .DESCRIPTION
    Pass, with the SDK's version, for the dotnet first on PATH or the SDK deploy.ps1 installed for the user. Without
    either: a Warning where deploy.ps1 installs the pinned SDK itself (Windows, 2026-11-09), saying it will, before it
    creates anything; a Fail before anything is created elsewhere, saying which dotnet ran, which SDKs it has, what
    global.json needs, and the exact fix.
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
        source          = $status.Source
        sdkVersion      = $status.Version
        requiredVersion = $(if ($status.Requirement) { $status.Requirement.Version } else { '' })
        rollForward     = $(if ($status.Requirement) { $status.Requirement.RollForward } else { '' })
    }
    if ($status.Ok) {
        $message = if ($status.Source -eq 'Installed') {
            'The .NET SDK {0} that deploy.ps1 installed for you builds the workload runner: {1}, by its full path, checked again (Microsoft''s signature and global.json, which needs {2}).' -f $status.Version, $status.Path, $status.Requirement.Text
        }
        else {
            'The .NET SDK {0} builds the workload runner: {1}, first on PATH, resolves it in workload-generator, whose global.json needs {2}.' -f $status.Version, $status.Path, $status.Requirement.Text
        }
        return (New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl 'https://learn.microsoft.com/dotnet/core/tools/global-json')
    }
    $evidence['dotnetPath'] = $status.FirstOnPath
    $evidence['installedSdks'] = @($status.Sdks)
    $evidence['exitCode'] = $status.ExitCode
    $evidence['alternatives'] = @($status.Alternatives | ForEach-Object { [ordered]@{ folder = $_.Folder; sdkVersion = $_.Version } })
    if ($null -ne $status.Pin) {
        # deploy.ps1 installs it before it creates anything (Initialize-DemoDotNetSdk), so this is only a heads-up.
        $evidence['installFolder'] = $status.Pin.Folder
        $evidence['installVersion'] = $status.Pin.Version
        return (New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status 'Warning' -Message $status.Message -Evidence $evidence -Remediation $status.Fix -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'PREFLIGHT.TOOLS.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status 'Fail' -Message $status.Message -Evidence $evidence -Remediation $status.Fix -DocUrl $docUrl)
}

function Invoke-DemoDotNetSdkDownload {
    <#
    .SYNOPSIS
    Downloads -Url (HTTPS only) to -Path, calling -OnProgress with the bytes so far and the total (0 when the server
    doesn't say), and returns the bytes written. Throws on an HTTP error, a broken connection, or a download that gets no
    data for -StallSeconds; the caller removes the file. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [string] $Path,

        [scriptblock] $OnProgress = $null,

        [ValidateRange(10, 3600)]
        [int] $StallSeconds = 120
    )

    if (-not $Url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Only an HTTPS download is allowed: {0}' -f $Url)
    }
    $client = [System.Net.Http.HttpClient]::new()
    # The client's timeout covers the response's headers; each read of its body has its own (a stalled download).
    $client.Timeout = [System.TimeSpan]::FromSeconds($StallSeconds)
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw ('{0} answered HTTP {1} for {2}.' -f ([uri]$Url).Host, [int]$response.StatusCode, ([uri]$Url).AbsolutePath)
            }
            $total = if ($null -ne $response.Content.Headers.ContentLength) { [long]$response.Content.Headers.ContentLength } else { [long]0 }
            $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $target = [System.IO.File]::Create($Path)
            $stall = [System.Threading.CancellationTokenSource]::new()
            $done = [long]0
            try {
                $buffer = [byte[]]::new(1MB)
                while ($true) {
                    $stall.CancelAfter([System.TimeSpan]::FromSeconds($StallSeconds))
                    try {
                        $read = $source.ReadAsync($buffer, 0, $buffer.Length, $stall.Token).GetAwaiter().GetResult()
                    }
                    catch {
                        if ($_.Exception.GetBaseException() -is [System.OperationCanceledException]) {
                            throw ('The download stalled: no data for {0} seconds after {1:N0} bytes.' -f $StallSeconds, $done)
                        }
                        throw
                    }
                    if ($read -le 0) {
                        break
                    }
                    $target.Write($buffer, 0, $read)
                    $done += $read
                    if ($null -ne $OnProgress) {
                        & $OnProgress $done $total
                    }
                }
            }
            finally {
                $stall.Dispose()
                $target.Dispose()
                $source.Dispose()
            }
            if ($total -gt 0 -and $done -ne $total) {
                throw ('The download ended after {0:N0} of {1:N0} bytes.' -f $done, $total)
            }
            return $done
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $client.Dispose()
    }
}

function Install-DemoDotNetSdk {
    <#
    .SYNOPSIS
    Installs the pinned .NET SDK (-Pin, Get-DemoDotNetSdkPin) for the user into -Pin.Folder, and returns Path, Version,
    Folder, Seconds, Bytes, and Reused. Throws, saying what failed, after removing what it downloaded and extracted.
    Internal.

    .DESCRIPTION
    No prompt, no administrator rights, and nothing on PATH or in the registry changes: only the per-user folder
    (Get-DemoDotNetSdkInstallRoot). One install at a time (a lock file in that folder); another deploy.ps1 that's
    installing is waited for, at most 30 minutes, and what it installed is used. In order:
    1. What an install that didn't finish left is removed: the '.partial-' download and extract folders, and the
       version's folder when it has no record or doesn't pass Test-DemoDotNetSdkInstall.
    2. Microsoft's zip is downloaded (Invoke-DemoDotNetSdkDownload), with its size and progress on the console and the
       status page's .NET SDK row (-ProgressPath, DotNetSdk), and its SHA-512 must be the pin's; otherwise it's deleted
       and this throws.
    3. It's extracted into a '.partial-' folder (ZipFile.ExtractToDirectory), whose dotnet.exe must have a valid
       Authenticode signature from Microsoft Corporation and whose 'dotnet --version' in workload-generator must print
       the pinned version (Test-DemoDotNetSdkInstall). Then the folder is renamed to the version, and its record
       (dbhub-sdk.json) is written last, so only a complete, verified install is ever used.
    4. The zip is deleted, and so are earlier versions this function installed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Pin,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [string] $RepositoryRoot = $script:RepoRoot,

        [ValidateRange(0, 120)]
        [int] $LockWaitMinutes = 30
    )

    if (-not $PSCmdlet.ShouldProcess($Pin.Folder, ('Install the .NET SDK {0} for this user' -f $Pin.Version))) {
        return
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # The status page's .NET SDK row, which the download's progress updates too.
    $row = @{ Path = $ProgressPath; Id = 'DotNetSdk'; State = 'Running'; MaxLength = 1200 }
    $say = {
        param([string] $Text)
        Write-DemoLog -Message $Text
        Set-DemoProgressStep @row -Message $Text
    }
    $null = [System.IO.Directory]::CreateDirectory($Pin.Root)
    $lockPath = Join-Path -Path $Pin.Root -ChildPath 'install.lock'
    $lock = $null
    $deadline = [System.DateTime]::UtcNow.AddMinutes($LockWaitMinutes)
    $waited = $false
    while ($null -eq $lock) {
        try {
            $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            if ($_.Exception.GetBaseException() -isnot [System.IO.IOException] -or [System.DateTime]::UtcNow -ge $deadline) {
                throw ('The .NET SDK''s install folder {0} stayed locked by another install for {1} minutes: {2}' -f $Pin.Root, $LockWaitMinutes, $_.Exception.GetBaseException().Message)
            }
            if (-not $waited) {
                $waited = $true
                & $say ('Another deploy.ps1 is installing the .NET SDK {0} into {1}; waiting for it.' -f $Pin.Version, $Pin.Root)
            }
            Start-Sleep -Seconds 5
        }
    }
    $archive = ''
    $staging = ''
    try {
        $existing = Get-DemoDotNetSdkInstall -Pin $Pin -RepositoryRoot $RepositoryRoot
        if ($existing.Ok) {
            return [pscustomobject]@{ Path = $existing.Path; Version = $existing.Version; Folder = $Pin.Folder; Seconds = [int]$watch.Elapsed.TotalSeconds; Bytes = [long]0; Reused = $true }
        }
        # 1. What an install that didn't finish, or a copy that no longer passes, left.
        foreach ($leftover in @(Get-ChildItem -LiteralPath $Pin.Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.partial-*' })) {
            Write-DemoLog -Message ('Removing {0}, which an install that didn''t finish left.' -f $leftover.FullName)
            Remove-Item -LiteralPath $leftover.FullName -Recurse -Force
        }
        if (Test-Path -LiteralPath $Pin.Folder) {
            Write-DemoLog -Message ('Removing {0} and installing it again: {1}.' -f $Pin.Folder, $existing.Detail)
            Remove-Item -LiteralPath $Pin.Folder -Recurse -Force
        }
        # 2. The download, its size and progress said as it goes, and its SHA-512.
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $archive = Join-Path -Path $Pin.Root -ChildPath ('.partial-{0}-{1}' -f $suffix, $Pin.FileName)
        $size = if ($Pin.SizeBytes -gt 0) { Format-DemoMegabyteText -Bytes $Pin.SizeBytes } else { 'its size unknown until it starts' }
        & $say ('Installing the .NET SDK {0} for the workload runner, for you only, into {1}: downloading {2} ({3}) from Microsoft. No administrator rights, and nothing on PATH changes.' -f $Pin.Version, $Pin.Folder, $Pin.FileName, $size)
        $progress = @{ Next = 10; Last = [System.Diagnostics.Stopwatch]::StartNew() }
        $report = {
            param([long] $Done, [long] $Total)
            $percent = if ($Total -gt 0) { [int][System.Math]::Floor(100 * $Done / $Total) } else { -1 }
            if (($percent -ge $progress.Next -and $percent -lt 100) -or ($percent -lt 0 -and $progress.Last.Elapsed.TotalSeconds -ge 15)) {
                $text = if ($percent -ge 0) { 'Downloading the .NET SDK {0}: {1} of {2} ({3}%).' -f $Pin.Version, (Format-DemoMegabyteText -Bytes $Done), (Format-DemoMegabyteText -Bytes $Total), $percent } else { 'Downloading the .NET SDK {0}: {1} so far.' -f $Pin.Version, (Format-DemoMegabyteText -Bytes $Done) }
                & $say $text
                if ($percent -ge 0) {
                    $progress.Next = ([int][System.Math]::Floor($percent / 10) + 1) * 10
                }
                $progress.Last.Restart()
            }
        }
        $bytes = Invoke-DemoDotNetSdkDownload -Url $Pin.Url -Path $archive -OnProgress $report
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant()
        if ($hash -ne $Pin.Sha512) {
            throw ('{0}''s SHA-512 isn''t the one config/versions.json pins from Microsoft''s release metadata (got {1}..., expected {2}...), so it was deleted and nothing was installed.' -f $Pin.FileName, $hash.Substring(0, 16), $Pin.Sha512.Substring(0, 16))
        }
        # 3. Extracted beside the version's folder, checked, then renamed, with its record last.
        $staging = Join-Path -Path $Pin.Root -ChildPath ('.partial-{0}-{1}' -f $suffix, $Pin.Version)
        & $say ('Downloaded {0} and checked its SHA-512; extracting it.' -f (Format-DemoMegabyteText -Bytes $bytes))
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)
        $check = Test-DemoDotNetSdkInstall -Pin $Pin -Folder $staging -RepositoryRoot $RepositoryRoot
        if (-not $check.Ok) {
            throw ('The extracted .NET SDK {0} failed its check, so it was deleted: {1}.' -f $Pin.Version, $check.Detail)
        }
        [System.IO.Directory]::Move($staging, $Pin.Folder)
        $staging = ''
        $record = [ordered]@{
            version     = $Pin.Version
            rid         = $Pin.Rid
            url         = $Pin.Url
            sha512      = $Pin.Sha512
            installedBy = 'deploy.ps1 (Initialize-DemoDotNetSdk)'
            installedAt = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        [System.IO.File]::WriteAllText((Join-Path -Path $Pin.Folder -ChildPath 'dbhub-sdk.json'), (($record | ConvertTo-Json) + "`n"), [System.Text.UTF8Encoding]::new($false))
        # 4. The zip, and earlier versions this function installed: each renamed to a '.partial-' name first, so one that a
        # running dotnet still holds stays whole, and what a removal leaves is removed by the next install.
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        $archive = ''
        foreach ($folder in @(Get-ChildItem -LiteralPath $Pin.Root -Directory -Force -ErrorAction SilentlyContinue)) {
            $older = $null
            if ($folder.Name -notlike '.partial-*' -and [System.Version]::TryParse($folder.Name, [ref]$older) -and $older -lt [System.Version]$Pin.Version -and (Test-Path -LiteralPath (Join-Path -Path $folder.FullName -ChildPath 'dbhub-sdk.json') -PathType Leaf)) {
                $retired = Join-Path -Path $Pin.Root -ChildPath ('.partial-{0}-old-{1}' -f $suffix, $folder.Name)
                try {
                    [System.IO.Directory]::Move($folder.FullName, $retired)
                    Write-DemoLog -Message ('Removing the .NET SDK {0} that deploy.ps1 installed earlier: {1}.' -f $folder.Name, $folder.FullName)
                    Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-DemoLog -Level Debug -Message ('The .NET SDK {0} that deploy.ps1 installed earlier stays for now (in use): {1}' -f $folder.Name, $_.Exception.Message)
                }
            }
        }
        return [pscustomobject]@{ Path = (Join-Path -Path $Pin.Folder -ChildPath 'dotnet.exe'); Version = $check.Version; Folder = $Pin.Folder; Seconds = [int]$watch.Elapsed.TotalSeconds; Bytes = [long]$bytes; Reused = $false }
    }
    finally {
        foreach ($leftover in @($archive, $staging) | Where-Object { $_ }) {
            Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue
        }
        $lock.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-DemoDotNetSdk {
    <#
    .SYNOPSIS
    Before anything is created, makes sure the workload runner's build has a .NET SDK that workload-generator/global.json
    accepts, and returns DEPLOY.DOTNETSDK; it keeps the status page's .NET SDK row (DotNetSdk) up to date. Never throws.
    Internal.

    .DESCRIPTION
    The owner, 2026-11-09: "Install it automatically" (one click after az login). In order:
    - The dotnet first on PATH has such an SDK: Pass, and nothing is installed.
    - The pinned SDK that this installed for the user earlier is complete and passes its checks again: Pass, reused,
      with nothing downloaded.
    - Otherwise, on Windows, the pinned SDK is installed now, with no prompt and no administrator rights
      (Install-DemoDotNetSdk): Pass with its time and size, or a Fail that says what failed and that nothing was created,
      after removing what the install left. The build then runs it by its full path (Resolve-DemoBuildDotNet).
    - Elsewhere (no pinned archive for this platform): a Fail with the manual fix (Get-DemoDotNetSdkStatus).
    -WhatIf installs nothing: Not selected.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [string] $RepositoryRoot = $script:RepoRoot
    )

    $row = {
        param([string] $State, [string] $Status, [string] $Text)
        Set-DemoProgressStep -Path $ProgressPath -Id 'DotNetSdk' -State $State -Status $Status -Message $Text -MaxLength 1200
    }
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '')
        New-DemoResult -CheckId 'DEPLOY.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl 'https://learn.microsoft.com/dotnet/core/install/windows'
    }
    & $row 'Running' '' 'Checking the .NET SDK the workload runner''s build needs.'
    $status = Get-DemoDotNetSdkStatus -RepositoryRoot $RepositoryRoot
    if ($status.Ok) {
        $text = if ($status.Source -eq 'Installed') {
            'Reusing the .NET SDK {0} that deploy.ps1 installed for you in {1}: checked again (Microsoft''s signature, and global.json), nothing downloaded.' -f $status.Version, (Split-Path -Path $status.Path -Parent)
        }
        else {
            'The dotnet first on PATH, {0}, has the .NET SDK {1}, which global.json accepts: nothing to install.' -f $status.Path, $status.Version
        }
        Write-DemoLog -Message $text
        & $row 'Done' 'Pass' $text
        return (& $result 'Pass' $text ([ordered]@{ dotnetPath = $status.Path; sdkVersion = $status.Version; source = $status.Source; installed = $false }))
    }
    if ($null -eq $status.Requirement) {
        Write-DemoLog -Level Warning -Message $status.Message
        & $row 'Failed' 'Fail' $status.Message
        return (& $result 'Fail' $status.Message ([ordered]@{ dotnetPath = $status.FirstOnPath }) $status.Fix)
    }
    if ($null -eq $status.Pin) {
        $text = '{0} deploy.ps1 installs the .NET SDK by itself only on Windows.' -f $status.Message
        Write-DemoLog -Level Warning -Message $text
        & $row 'Failed' 'Fail' $text
        return (& $result 'Fail' $text ([ordered]@{ dotnetPath = $status.FirstOnPath; installedSdks = @($status.Sdks); requiredVersion = $status.Requirement.Version }) $status.Fix)
    }
    if (-not $PSCmdlet.ShouldProcess($status.Pin.Folder, ('Install the .NET SDK {0} for this user' -f $status.Pin.Version))) {
        & $row 'Skipped' 'Not selected' 'What if: nothing is installed.'
        return (& $result 'Not selected' ('What if: the .NET SDK {0} would be installed for you in {1}.' -f $status.Pin.Version, $status.Pin.Folder) ([ordered]@{ installFolder = $status.Pin.Folder }))
    }
    Write-DemoLog -Message ('{0} So deploy.ps1 installs the pinned .NET SDK {1} for you, before it creates anything.' -f $status.Message, $status.Pin.Version)
    try {
        $installed = Install-DemoDotNetSdk -Pin $status.Pin -ProgressPath $ProgressPath -RepositoryRoot $RepositoryRoot -Confirm:$false
        $text = if ($installed.Reused) {
            'Reusing the .NET SDK {0} that another deploy.ps1 installed for you in {1} meanwhile.' -f $installed.Version, $installed.Folder
        }
        else {
            'Installed the .NET SDK {0} for you in {1} in {2} s ({3} download): Microsoft''s SHA-512, its signature, and global.json checked. The workload runner builds with it; nothing on PATH changed.' -f $installed.Version, $installed.Folder, $installed.Seconds, (Format-DemoMegabyteText -Bytes $installed.Bytes)
        }
        Write-DemoLog -Level Success -Message $text
        & $row 'Done' 'Pass' $text
        return (& $result 'Pass' $text ([ordered]@{ dotnetPath = $installed.Path; sdkVersion = $installed.Version; source = 'Installed'; installed = (-not $installed.Reused); installFolder = $installed.Folder; seconds = $installed.Seconds; downloadBytes = $installed.Bytes; firstOnPath = $status.FirstOnPath }))
    }
    catch {
        $why = Protect-DemoText -Text $_.Exception.Message
        $text = 'The .NET SDK {0} that the workload runner needs couldn''t be installed for you, so nothing was created: {1}' -f $status.Pin.Version, $why
        Write-DemoLog -Level Error -Message $text
        & $row 'Failed' 'Fail' $text
        $fix = 'Run ./scripts/deploy.ps1 again: it removes what this install left and starts over (a network error usually passes). Or {0}, then run it again; or deploy without the workload runner: ./scripts/deploy.ps1 -SkipRunner.' -f (Get-DemoDotNetSdkInstallText -Requirement $status.Requirement)
        return (& $result 'Fail' $text ([ordered]@{ installFolder = $status.Pin.Folder; installVersion = $status.Pin.Version; firstOnPath = $status.FirstOnPath }) $fix)
    }
}

function Test-DemoDotNetSdkFailure {
    # True when a build error says the .NET SDK is missing, or isn't one global.json accepts: the dotnet host's own
    # words (exit code -2147450725 is 0x8000809B, the host's SDK resolution failure), Invoke-DemoDotNet's, or
    # Resolve-DemoBuildDotNet's. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    return ($Text -match '(?i)compatible \.NET SDK was not found|No \.NET SDKs were found|\.NET SDK \(dotnet\) was not found on PATH|exit code -2147450725\b|0x8000809B|so the workload runner can''t be built')
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
    return 'The build''s dotnet has no .NET SDK that workload-generator/global.json accepts (PREFLIGHT.TOOLS.DOTNETSDK says which it needs). Run ./scripts/deploy.ps1 again, which installs it for you on Windows, or install it yourself (docs/prerequisites.md); or deploy without the workload runner: ./scripts/deploy.ps1 -SkipRunner.'
}
