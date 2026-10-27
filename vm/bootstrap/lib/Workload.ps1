# The workload runner on the demo VMs (ADR 0010, Phase 13): the pinned .NET runtime, the runner package that
# Send-DemoWorkloadRunner delivers in Run Command chunks, the runner's setup, and the DbHubDemo-Workload
# scheduled task that hosts the activity profiles. Windows PowerShell 5.1. These functions are part of the
# DbHubDemo.Vm module, so the T2 host also runs them inside the guest over PowerShell Direct; none of them
# needs Initialize-DemoVmContext unless it says so.

function Get-DemoVmWorkloadSetting {
    <#
    .SYNOPSIS
    The workload part of settings.json: the runner's SHA-256 and chunk count, the activity profile and
    whether the VM sets it at boot (profileOnBoot, default false), the auto-shutdown schedule, and (on T1)
    T3's names.

    .DESCRIPTION
    The template writes these into the loader's settings (infra/modules/demo.bicep). Selected is true only
    when a runner was delivered (a SHA-256 and at least one chunk); otherwise the WorkloadRunner steps are
    Not selected.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Settings
    )

    $workload = $null
    if ($Settings.Contains('workload')) {
        $workload = $Settings['workload']
    }
    if ($null -eq $workload) {
        $workload = @{}
    }
    $sha = ''
    if ($workload.Contains('runnerSha256') -and $workload['runnerSha256']) {
        $sha = ([string]$workload['runnerSha256']).ToLowerInvariant()
    }
    $count = 0
    if ($workload.Contains('runnerChunkCount') -and $workload['runnerChunkCount']) {
        $count = [int]$workload['runnerChunkCount']
    }
    $activityProfile = 'baseline'
    if ($workload.Contains('activityProfile') -and $workload['activityProfile']) {
        $activityProfile = [string]$workload['activityProfile']
    }
    if ($activityProfile -notmatch '^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$') {
        throw ('settings.json has an invalid activity profile: {0}. Use off, baseline, business-day, or incident:<scenario>.' -f $activityProfile)
    }
    # activityProfileOnBoot (default false): set the profile at every boot. Off by default, so a VM that
    # starts doesn't keep T3's serverless database awake on its own (ADR 0016, R183).
    $profileOnBoot = $false
    if ($workload.Contains('profileOnBoot') -and $null -ne $workload['profileOnBoot']) {
        $profileOnBoot = ([string]$workload['profileOnBoot']) -eq 'True'
    }
    $shutdownTime = '1900'
    if ($workload.Contains('autoShutdownTime') -and $workload['autoShutdownTime']) {
        $shutdownTime = [string]$workload['autoShutdownTime']
    }
    if ($shutdownTime -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
        throw ('settings.json has an invalid auto-shutdown time: {0} (HHmm).' -f $shutdownTime)
    }
    $timeZone = 'UTC'
    if ($workload.Contains('autoShutdownTimeZone') -and $workload['autoShutdownTimeZone']) {
        $timeZone = [string]$workload['autoShutdownTimeZone']
    }

    $t3 = $null
    if ($Settings.Contains('t3') -and $null -ne $Settings['t3']) {
        $t3Settings = $Settings['t3']
        $fqdn = ''
        if ($t3Settings.Contains('serverFqdn')) {
            $fqdn = ([string]$t3Settings['serverFqdn']).ToLowerInvariant()
        }
        if ($fqdn -match '^[a-z0-9][a-z0-9.-]{1,252}$') {
            $databaseName = 'ContosoCare'
            if ($t3Settings.Contains('databaseName') -and $t3Settings['databaseName']) {
                $databaseName = [string]$t3Settings['databaseName']
            }
            $t3 = @{
                ServerName   = [string]$t3Settings['serverName']
                ServerFqdn   = $fqdn
                DatabaseName = $databaseName
            }
        }
    }

    # T4 (Phase 24, ADR 0019): the PostgreSQL flexible server that T1's identity drives as the role runnerRole.
    $t4 = $null
    if ($Settings.Contains('t4') -and $null -ne $Settings['t4']) {
        $t4Settings = $Settings['t4']
        $fqdn = ''
        if ($t4Settings.Contains('serverFqdn')) {
            $fqdn = ([string]$t4Settings['serverFqdn']).ToLowerInvariant()
        }
        if ($fqdn -match '^[a-z0-9][a-z0-9.-]{1,252}$') {
            $databaseName = 'contosocare'
            if ($t4Settings.Contains('databaseName') -and $t4Settings['databaseName']) {
                $databaseName = [string]$t4Settings['databaseName']
            }
            $runnerRole = 'contosocare_runner'
            if ($t4Settings.Contains('runnerRole') -and $t4Settings['runnerRole'] -match '^[a-z_][a-z0-9_]{0,62}$') {
                $runnerRole = [string]$t4Settings['runnerRole']
            }
            $t4 = @{
                ServerName   = [string]$t4Settings['serverName']
                ServerFqdn   = $fqdn
                DatabaseName = $databaseName
                RunnerRole   = $runnerRole
            }
        }
    }

    return @{
        Selected             = ($sha -match '^[0-9a-f]{64}$' -and $count -ge 1)
        RunnerSha256         = $sha
        RunnerChunkCount     = $count
        ActivityProfile      = $activityProfile
        ProfileOnBoot        = $profileOnBoot
        AutoShutdownTime     = $shutdownTime
        AutoShutdownTimeZone = $timeZone
        T3                   = $t3
        T4                   = $t4
    }
}

function Join-DemoVmPath {
    <#
    .SYNOPSIS
    Joins a path and a child name as strings, without PowerShell's drive provider.

    .DESCRIPTION
    Join-Path resolves the drive of its -Path on the machine that runs it, so it fails for a path that
    belongs to another machine: the T2 guest's C:\ProgramData\DbHubDemo computed on the host, or any C:\
    path in a Linux test run ("Cannot find drive"). A Windows path keeps its backslashes; any other path
    gets the local separator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $ChildPath
    )

    if (-not $ChildPath) {
        return $Path
    }
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    if ($Path -match '^[A-Za-z]:' -or $Path.Contains('\')) {
        $separator = '\'
    }
    return ($Path.TrimEnd('\', '/') + $separator + $ChildPath.TrimStart('\', '/'))
}

function Get-DemoVmWorkloadPath {
    <#
    .SYNOPSIS
    The workload's files under the state folder. With -RunnerSha256, also the runner's own folder, zip,
    and chunk folder (named by the first 12 hexadecimal digits of its SHA-256, like the bundle).

    .DESCRIPTION
    The paths are joined as strings (Join-DemoVmPath), because the T2 host also computes the guest's paths,
    whose drive doesn't exist on the host.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [AllowEmptyString()]
        [string] $RunnerSha256 = ''
    )

    $runnerRoot = Join-DemoVmPath -Path $Root -ChildPath 'runner'
    $downloads = Join-DemoVmPath -Path $Root -ChildPath 'downloads'
    $dotnet = Join-DemoVmPath -Path $Root -ChildPath 'dotnet'
    $paths = @{
        Root          = $Root
        Downloads     = $downloads
        DotNet        = $dotnet
        DotNetExe     = Join-DemoVmPath -Path $dotnet -ChildPath 'dotnet.exe'
        DotNetMarker  = Join-DemoVmPath -Path $dotnet -ChildPath '.runtime.json'
        RunnerRoot    = $runnerRoot
        Wrapper       = Join-DemoVmPath -Path $runnerRoot -ChildPath 'Start-DemoWorkload.ps1'
        InstallRecord = Join-DemoVmPath -Path $Root -ChildPath 'workload-install.json'
        T3Marker      = Join-DemoVmPath -Path $Root -ChildPath 't3-workload.json'
        T4Marker      = Join-DemoVmPath -Path $Root -ChildPath 't4-workload.json'
        BootMarker    = Join-DemoVmPath -Path $Root -ChildPath 'workload-boot.json'
        Logs          = Join-DemoVmPath -Path $Root -ChildPath 'logs'
        Runner        = ''
        RunnerDll     = ''
        RunnerMarker  = ''
        RunnerZip     = ''
        RunnerChunks  = ''
    }
    if ($RunnerSha256) {
        if ($RunnerSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'The runner SHA-256 must be 64 hexadecimal characters.'
        }
        $short = $RunnerSha256.Substring(0, 12).ToLowerInvariant()
        $paths.Runner = Join-DemoVmPath -Path $runnerRoot -ChildPath $short
        $paths.RunnerDll = Join-DemoVmPath -Path $paths.Runner -ChildPath 'ContosoCare.Workload.dll'
        $paths.RunnerMarker = Join-DemoVmPath -Path $paths.Runner -ChildPath '.complete'
        $paths.RunnerZip = Join-DemoVmPath -Path $downloads -ChildPath ('runner-{0}.zip' -f $short)
        $paths.RunnerChunks = Join-DemoVmPath -Path $downloads -ChildPath $short
    }
    return $paths
}

function Invoke-DemoVmFileRetry {
    <#
    .SYNOPSIS
    Runs a file operation and retries it while another process holds the file: an IOException or an
    UnauthorizedAccessException, for example while Microsoft Defender scans a file that was just written.
    Other errors, and the last failed attempt, are thrown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [object[]] $ArgumentList = @(),

        [ValidateRange(1, 30)]
        [int] $MaxAttempts = 10,

        [ValidateRange(0, 60)]
        [int] $DelaySeconds = 3,

        [string] $Activity = 'File operation'
    )

    for ($retryAttempt = 1; ; $retryAttempt++) {
        try {
            return (& $ScriptBlock @ArgumentList)
        }
        catch {
            $retryError = $_.Exception
            while ($null -ne $retryError.InnerException -and -not ($retryError -is [System.IO.IOException] -or $retryError -is [System.UnauthorizedAccessException])) {
                $retryError = $retryError.InnerException
            }
            $retryable = $retryError -is [System.IO.IOException] -or $retryError -is [System.UnauthorizedAccessException]
            if (-not $retryable -or $retryAttempt -ge $MaxAttempts) {
                throw
            }
            Write-DemoVmLog -Level 'Warning' -Message ('{0}: attempt {1} of {2} failed ({3}); retrying in {4} seconds.' -f $Activity, $retryAttempt, $MaxAttempts, $retryError.Message, $DelaySeconds)
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Expand-DemoVmVerifiedZip {
    <#
    .SYNOPSIS
    Verifies a zip against its pinned SHA-256 or SHA-512, extracts it into Destination, and writes a marker
    file with the hash last. Fails closed.

    .DESCRIPTION
    A hash mismatch deletes the zip and installs nothing. Entries are extracted one at a time with
    ZipFileExtensions.ExtractToFile, because Windows PowerShell 5.1's Expand-Archive accepts only the .zip
    extension (Phase 6 finding), and an entry that would land outside Destination stops the extraction.

    There's no staging folder to rename: Microsoft Defender scans freshly extracted executables, and renaming
    a folder while it scans them fails with "Access to the path is denied" (Phase 13 live finding, the .NET
    runtime on T1). So the marker is removed first and written last (Destination\MarkerName: the algorithm,
    the hash, MarkerData, and the time), and only a folder with the marker counts as installed. An existing
    Destination is removed first, with retries; files that are still held are extracted over instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ZipPath,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [AllowEmptyString()]
        [string] $ExpectedSha256 = '',

        [AllowEmptyString()]
        [string] $ExpectedSha512 = '',

        [string] $MarkerName = '.complete',

        [System.Collections.IDictionary] $MarkerData = @{}
    )

    if (-not $ExpectedSha256 -and -not $ExpectedSha512) {
        throw 'Expand-DemoVmVerifiedZip needs a pinned SHA-256 or SHA-512.'
    }
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw ('{0} does not exist.' -f $ZipPath)
    }
    if ($ExpectedSha512) {
        $algorithm = 'SHA512'
        $label = 'SHA-512'
        $expected = $ExpectedSha512.ToLowerInvariant()
        $actual = Get-DemoVmFileSha512 -Path $ZipPath
    }
    else {
        $algorithm = 'SHA256'
        $label = 'SHA-256'
        $expected = $ExpectedSha256.ToLowerInvariant()
        $actual = Get-DemoVmFileSha256 -Path $ZipPath
    }
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        throw ('{0} mismatch for {1}: expected {2}, got {3}. The file was deleted and nothing was installed (fail closed).' -f $label, (Split-Path -Path $ZipPath -Leaf), $expected, $actual)
    }

    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $markerPath = Join-Path -Path $Destination -ChildPath $MarkerName
    if (Test-Path -LiteralPath $markerPath) {
        Remove-Item -LiteralPath $markerPath -Force
    }
    if (Test-Path -LiteralPath $Destination) {
        try {
            Invoke-DemoVmFileRetry -Activity ('Removing {0}' -f $Destination) -MaxAttempts 5 -ScriptBlock {
                param($Path)
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            } -ArgumentList $Destination
        }
        catch {
            Write-DemoVmLog -Level 'Warning' -Message ('{0} could not be removed ({1}); extracting over it.' -f $Destination, $_.Exception.Message)
        }
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $rootPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $count = 0
    try {
        foreach ($entry in $archive.Entries) {
            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootPath, $entry.FullName))
            if (-not $target.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('The zip entry {0} would be extracted outside {1}, so the extraction stopped.' -f $entry.FullName, $Destination)
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if (-not (Test-Path -LiteralPath $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }
                continue
            }
            $folder = [System.IO.Path]::GetDirectoryName($target)
            if (-not (Test-Path -LiteralPath $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }
            Invoke-DemoVmFileRetry -Activity ('Extracting {0}' -f $entry.FullName) -ScriptBlock {
                param($Entry, $Path)
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Path, $true)
            } -ArgumentList $entry, $target
            $count++
        }
    }
    finally {
        $archive.Dispose()
    }

    # Earlier versions extracted into <Destination>.staging and renamed it.
    $staging = $Destination + '.staging'
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $marker = [ordered]@{
        schemaVersion = 1
        algorithm     = $algorithm
        hash          = $actual
        source        = (Split-Path -Path $ZipPath -Leaf)
        installedUtc  = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    foreach ($key in $MarkerData.Keys) {
        $marker[$key] = $MarkerData[$key]
    }
    Write-DemoVmJsonFile -Path $markerPath -InputObject $marker
    Write-DemoVmLog -Message ('Installed {0} into {1}: {2} file(s), {3} {4}.' -f (Split-Path -Path $ZipPath -Leaf), $Destination, $count, $label, $actual)
}

function Get-DemoVmDotNetPin {
    <#
    .SYNOPSIS
    The pinned .NET runtime (url, sha512, fileName, version) from the bundle manifest, which carries
    config/versions.json's dotnetRuntime (New-DemoBootstrapBundle).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [string] $BundleRoot = ''
    )

    if (-not $BundleRoot) {
        $BundleRoot = (Get-DemoVmContext).BundleRoot
    }
    $manifest = Read-DemoVmJsonFile -Path (Join-Path -Path $BundleRoot -ChildPath 'bundle-manifest.json')
    if ($null -eq $manifest -or -not $manifest.Contains('dotnetRuntime') -or $null -eq $manifest['dotnetRuntime']) {
        throw 'The bundle manifest has no dotnetRuntime pin; build the bundle from a repository whose config/versions.json pins it (New-DemoBootstrapBundle).'
    }
    $pin = $manifest['dotnetRuntime']
    if ([string]$pin['url'] -notmatch '^https://') {
        throw 'The dotnetRuntime pin has no HTTPS URL.'
    }
    if ([string]$pin['sha512'] -notmatch '^[0-9a-fA-F]{128}$') {
        throw 'The dotnetRuntime pin has no SHA-512.'
    }
    if ([string]$pin['fileName'] -notmatch '^[A-Za-z0-9._-]+\.zip$') {
        throw 'The dotnetRuntime pin has no zip file name.'
    }
    return $pin
}

function Test-DemoVmDotNetRuntime {
    # True when <Root>\dotnet holds exactly the pinned runtime (its marker records the pin's SHA-512).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Pin
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root
    if (-not (Test-Path -LiteralPath $paths.DotNetExe -PathType Leaf)) {
        return $false
    }
    $marker = Read-DemoVmJsonFile -Path $paths.DotNetMarker
    if ($null -eq $marker) {
        return $false
    }
    return ([string]$marker['hash'] -eq ([string]$Pin['sha512']).ToLowerInvariant() -and [string]$marker['version'] -eq [string]$Pin['version'])
}

function Install-DemoVmDotNetRuntime {
    <#
    .SYNOPSIS
    Downloads the pinned .NET runtime zip (retries that resume, SHA-512 checked, fail closed) to
    <Root>\downloads and extracts it to <Root>\dotnet. Returns the verified zip's path.

    .DESCRIPTION
    Uses Save-DemoVmDownload, so it needs Initialize-DemoVmContext (the hash cache). The zip stays in
    downloads: the T2 host copies it into the guest. A runtime in use is stopped first (Stop-DemoVmWorkload).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Pin
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root
    $zip = Join-Path -Path $paths.Downloads -ChildPath ([string]$Pin['fileName'])
    $sha512 = ([string]$Pin['sha512']).ToLowerInvariant()
    if (-not (Test-DemoVmFileHash -Path $zip -ExpectedSha512 $sha512)) {
        Save-DemoVmDownload -Uri ([string]$Pin['url']) -Path $zip -ExpectedSha512 $sha512 -Name 'dotnetRuntime' | Out-Null
    }
    if (-not (Test-DemoVmDotNetRuntime -Root $Root -Pin $Pin)) {
        Stop-DemoVmWorkload -Root $Root -Confirm:$false
        Expand-DemoVmVerifiedZip -ZipPath $zip -Destination $paths.DotNet -ExpectedSha512 $sha512 -MarkerName '.runtime.json' -MarkerData @{ version = [string]$Pin['version'] }
    }
    return $zip
}

function Test-DemoVmRunnerChunk {
    # True when every runner chunk from Send-DemoWorkloadRunner is on disk (each is checked again on assembly).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Sha256,

        [Parameter(Mandatory = $true)]
        [int] $ChunkCount
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root -RunnerSha256 $Sha256
    for ($index = 1; $index -le $ChunkCount; $index++) {
        $name = 'chunk-{0:d3}' -f $index
        foreach ($extension in @('.bin', '.sha256')) {
            if (-not (Test-Path -LiteralPath (Join-Path -Path $paths.RunnerChunks -ChildPath ($name + $extension)) -PathType Leaf)) {
                return $false
            }
        }
    }
    return $true
}

function Get-DemoVmRunnerZip {
    <#
    .SYNOPSIS
    Assembles the runner zip from its Run Command chunks once, the way the bootstrap loader assembles the
    bundle, and returns the verified zip's path. Fails closed.

    .DESCRIPTION
    Every chunk is checked against its .sha256 file first, and the error names each missing or bad chunk.
    The joined file is checked against the runner's SHA-256; a mismatch deletes it and the chunks, so nothing
    from them can run. The verified zip is kept as <Root>\downloads\runner-<sha12>.zip (the T2 host copies
    it into the guest), and the chunk folder is deleted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Sha256,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 999)]
        [int] $ChunkCount
    )

    $sha = $Sha256.ToLowerInvariant()
    $paths = Get-DemoVmWorkloadPath -Root $Root -RunnerSha256 $sha
    if (Test-Path -LiteralPath $paths.RunnerZip -PathType Leaf) {
        if ((Get-DemoVmFileSha256 -Path $paths.RunnerZip) -eq $sha) {
            return $paths.RunnerZip
        }
        Remove-Item -LiteralPath $paths.RunnerZip -Force
    }
    $missing = New-Object -TypeName 'System.Collections.Generic.List[int]'
    $bad = New-Object -TypeName 'System.Collections.Generic.List[int]'
    for ($index = 1; $index -le $ChunkCount; $index++) {
        $name = 'chunk-{0:d3}' -f $index
        $data = Join-Path -Path $paths.RunnerChunks -ChildPath ($name + '.bin')
        $hashFile = Join-Path -Path $paths.RunnerChunks -ChildPath ($name + '.sha256')
        if (-not (Test-Path -LiteralPath $data -PathType Leaf) -or -not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
            $missing.Add($index)
            continue
        }
        $expected = ([System.IO.File]::ReadAllText($hashFile)).Trim().ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$' -or (Get-DemoVmFileSha256 -Path $data) -ne $expected) {
            $bad.Add($index)
        }
    }
    if ($missing.Count -gt 0 -or $bad.Count -gt 0) {
        $parts = @()
        if ($missing.Count -gt 0) {
            $parts += ('missing chunk(s) {0}' -f ($missing -join ', '))
        }
        if ($bad.Count -gt 0) {
            $parts += ('chunk(s) {0} failed their SHA-256 check' -f ($bad -join ', '))
        }
        throw ('The workload runner in {0} is incomplete ({1} expected): {2}. Nothing was installed; send it again with Send-DemoWorkloadRunner (deploy.ps1 -Resume).' -f $paths.RunnerChunks, $ChunkCount, ($parts -join '; '))
    }

    $partial = $paths.RunnerZip + '.partial'
    $output = [System.IO.File]::Create($partial)
    try {
        for ($index = 1; $index -le $ChunkCount; $index++) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $paths.RunnerChunks -ChildPath ('chunk-{0:d3}.bin' -f $index)))
            $output.Write($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $output.Dispose()
    }
    $actual = Get-DemoVmFileSha256 -Path $partial
    if ($actual -ne $sha) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $paths.RunnerChunks -Recurse -Force -ErrorAction SilentlyContinue
        throw ('Workload runner SHA-256 mismatch: expected {0}, got {1}. The joined file and the chunks were deleted and nothing was installed (fail closed).' -f $sha, $actual)
    }
    Move-Item -LiteralPath $partial -Destination $paths.RunnerZip
    Remove-Item -LiteralPath $paths.RunnerChunks -Recurse -Force -ErrorAction SilentlyContinue
    Write-DemoVmLog -Message ('Workload runner {0} assembled from {1} chunk(s) and verified.' -f $sha.Substring(0, 12), $ChunkCount)
    return $paths.RunnerZip
}

function Test-DemoVmRunnerPackage {
    # True when <Root>\runner\<sha12> holds the extracted runner with its marker.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root -RunnerSha256 $Sha256
    if (-not (Test-Path -LiteralPath $paths.RunnerDll -PathType Leaf)) {
        return $false
    }
    $marker = Read-DemoVmJsonFile -Path $paths.RunnerMarker
    return ($null -ne $marker -and [string]$marker['hash'] -eq $Sha256.ToLowerInvariant())
}

function Remove-DemoVmOldRunner {
    # Keeps the current runner folder and the newest previous one, like the loader keeps bundles.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $KeepSha256
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root -RunnerSha256 $KeepSha256
    $keep = Split-Path -Path $paths.Runner -Leaf
    $old = @(Get-ChildItem -LiteralPath $paths.RunnerRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9a-f]{12}$' -and $_.Name -ne $keep } |
            Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -Skip 1)
    foreach ($folder in $old) {
        if ($PSCmdlet.ShouldProcess($folder.FullName, 'Remove an old workload runner')) {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-DemoVmProcessArgument {
    # Quotes one argument for a Windows command line (the CommandLineToArgvW rules).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = New-Object -TypeName 'System.Text.StringBuilder'
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
            [void]$builder.Append([char]'"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', 2 * $backslashes)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-DemoVmRunnerProcess {
    <#
    .SYNOPSIS
    Runs 'dotnet.exe <runner dll> <arguments>' and waits for it. The only process call in the workload
    functions; tests mock it.

    .DESCRIPTION
    Standard output and error are read asynchronously, so a chatty runner can't block on a full pipe. A run
    that outlives TimeoutSeconds is killed and reported as an error. Output is redacted. The runner never
    takes a secret on its command line: T1 and T2 use Windows authentication and T3 a managed identity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DotNetExe,

        [Parameter(Mandatory = $true)]
        [string] $RunnerDll,

        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,

        [ValidateRange(10, 86400)]
        [int] $TimeoutSeconds = 1800
    )

    $all = @($RunnerDll) + @($ArgumentList)
    $commandLine = (@($all | ForEach-Object { ConvertTo-DemoVmProcessArgument -Argument $_ }) -join ' ')
    $info = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo'
    $info.FileName = $DotNetExe
    $info.Arguments = $commandLine
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = Split-Path -Path $RunnerDll -Parent
    $info.EnvironmentVariables['DOTNET_ROOT'] = Split-Path -Path $DotNetExe -Parent
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
            }
            catch {
                Write-DemoVmLog -Level 'Warning' -Message ('The runner could not be stopped: {0}' -f $_.Exception.Message)
            }
            throw ('The runner ({0}) did not finish within {1} seconds and was stopped.' -f ($ArgumentList -join ' '), $TimeoutSeconds)
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut   = Protect-DemoVmText -Text ([string]$stdout.Result)
            StdErr   = Protect-DemoVmText -Text ([string]$stderr.Result)
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-DemoVmRunnerJson {
    # Reads the runner's --json output: an array of ADR 0012 result records. Returns an empty array otherwise.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return , @()
    }
    $start = $Text.IndexOf('[')
    $end = $Text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) {
        return , @()
    }
    try {
        $records = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }
    catch {
        return , @()
    }
    return , @($records | Where-Object { $null -ne $_ })
}

function Get-DemoVmRunnerOutcome {
    <#
    .SYNOPSIS
    Turns a runner result (exit code and --json records) into one ADR 0012 status and a short message.

    .DESCRIPTION
    Exit code 0 is Pass, or Warning when a record warns; 2 is Manual action required; anything else is Fail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Run,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    $records = ConvertFrom-DemoVmRunnerJson -Text $Run.StdOut
    $statuses = @($records | ForEach-Object { [string]$_.status })
    if ($Run.ExitCode -eq 0) {
        $status = 'Pass'
        if ($statuses -contains 'Warning') {
            $status = 'Warning'
        }
    }
    elseif ($Run.ExitCode -eq 2) {
        $status = 'Manual action required'
    }
    else {
        $status = 'Fail'
    }
    $notable = @($records | Where-Object { [string]$_.status -ne 'Pass' } | ForEach-Object { '{0}: {1}' -f $_.status, $_.message })
    if ($notable.Count -eq 0 -and $status -ne 'Fail') {
        $message = '{0}: {1} ({2} check(s) passed).' -f $Label, $status, $records.Count
    }
    elseif ($notable.Count -gt 0) {
        $message = '{0}: {1}. {2}' -f $Label, $status, ($notable -join ' | ')
    }
    else {
        $detail = ([string]$Run.StdErr).Trim()
        if (-not $detail) {
            $detail = ([string]$Run.StdOut).Trim()
        }
        if ($detail.Length -gt 600) {
            $detail = $detail.Substring($detail.Length - 600)
        }
        $message = '{0} failed with exit code {1}: {2}' -f $Label, $Run.ExitCode, $detail
    }
    return [pscustomobject]@{
        Status   = $status
        ExitCode = $Run.ExitCode
        Message  = Protect-DemoVmText -Text $message
        Records  = $records
    }
}

function Invoke-DemoVmRunnerSetup {
    <#
    .SYNOPSIS
    Runs the runner's idempotent 'setup' for one target (the demo objects from 110 and 120) and returns its
    outcome (Get-DemoVmRunnerOutcome).

    .DESCRIPTION
    T1 and T2 connect locally with Windows authentication; T3 needs -Server, the logical server's FQDN, and
    uses the VM's managed identity. -GrantWindowsLogin maps a service identity to contosocare_runner (T1 and
    T2 only), for example NT AUTHORITY\SYSTEM in a T2 guest whose setup wizard made only the guest
    Administrator a sysadmin.

    T4 (Phase 24, ADR 0019) needs -Server, the flexible server's FQDN, and -User, the Microsoft Entra
    administrator role (the P6 group's display name) that the VM's managed identity signs in as through its
    group membership. -IncludeBaseSchema and -SeedScale create and seed the schema (T4 has no bootstrap of
    its own), and -GrantEntraObjectId creates -RunnerRole for that object ID (T1's identity) with the demo's
    rights. No token or password passes through here: the runner asks the VM's identity for its own token.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DotNetExe,

        [Parameter(Mandatory = $true)]
        [string] $RunnerDll,

        [Parameter(Mandatory = $true)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [AllowEmptyString()]
        [string] $Server = '',

        [AllowEmptyString()]
        [string] $GrantWindowsLogin = '',

        [AllowEmptyString()]
        [string] $User = '',

        [switch] $IncludeBaseSchema,

        [ValidateRange(0, 50)]
        [int] $SeedScale = 0,

        [AllowEmptyString()]
        [string] $GrantEntraObjectId = '',

        [AllowEmptyString()]
        [string] $RunnerRole = '',

        [ValidateRange(60, 86400)]
        [int] $TimeoutSeconds = 1800
    )

    $arguments = @('setup', '--target', $Target, '--json')
    if ($Server) {
        $arguments += @('--server', $Server)
    }
    if ($GrantWindowsLogin) {
        $arguments += @('--grant-windows-login', $GrantWindowsLogin)
    }
    if ($User) {
        $arguments += @('--user', $User)
    }
    if ($IncludeBaseSchema) {
        $arguments += '--include-base-schema'
    }
    if ($SeedScale -gt 0) {
        $arguments += @('--seed-scale', [string]$SeedScale)
    }
    if ($GrantEntraObjectId) {
        $arguments += @('--grant-entra-object-id', $GrantEntraObjectId)
    }
    if ($RunnerRole) {
        $arguments += @('--runner-role', $RunnerRole)
    }
    $run = Invoke-DemoVmRunnerProcess -DotNetExe $DotNetExe -RunnerDll $RunnerDll -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds
    $outcome = Get-DemoVmRunnerOutcome -Run $run -Label ('setup --target {0}' -f $Target)
    Write-DemoVmLog -Message $outcome.Message
    return $outcome
}

function Get-DemoVmNextShutdown {
    <#
    .SYNOPSIS
    The next daily auto-shutdown after NowUtc, as a DateTimeOffset and as the ISO 8601 text that the
    runner's --not-after takes (for example 2026-10-20T19:00:00-07:00).

    .DESCRIPTION
    Time is HHmm in the Windows time zone TimeZoneId, the same values as the DevTest Labs schedule
    (autoShutdownTime and autoShutdownTimeZone). Daylight saving time is honored; a time that doesn't exist
    on a spring-forward day moves one hour later. An unknown time zone falls back to UTC with a warning.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^([01][0-9]|2[0-3])[0-5][0-9]$')]
        [string] $Time,

        [string] $TimeZoneId = 'UTC',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    try {
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Time zone {0} was not found; the auto-shutdown time is read as UTC.' -f $TimeZoneId)
        $zone = [System.TimeZoneInfo]::Utc
    }
    $now = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $localNow = [DateTime]::SpecifyKind([System.TimeZoneInfo]::ConvertTimeFromUtc($now, $zone), [System.DateTimeKind]::Unspecified)
    $candidate = $localNow.Date.AddHours([int]$Time.Substring(0, 2)).AddMinutes([int]$Time.Substring(2, 2))
    if ($candidate -le $localNow) {
        $candidate = $candidate.AddDays(1)
    }
    if ($zone.IsInvalidTime($candidate)) {
        $candidate = $candidate.AddHours(1)
    }
    $offset = $zone.GetUtcOffset($candidate)
    $result = New-Object -TypeName 'System.DateTimeOffset' -ArgumentList $candidate, $offset
    return [pscustomobject]@{
        Time        = $result
        Iso         = $result.ToString("yyyy-MM-dd'T'HH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
        MinutesLeft = [System.Math]::Round(($result.UtcDateTime - $now).TotalMinutes, 1)
        TimeZone    = $zone.Id
    }
}

function Set-DemoVmActivityProfile {
    <#
    .SYNOPSIS
    Sets one target's activity profile with 'ContosoCare.Workload profile set', ending before NotAfter
    (the next auto-shutdown). A running 'profile run' host picks it up within its poll interval.

    .DESCRIPTION
    T1 and T2 keep the profile in demo.activity_profile in their ContosoCare database. T3's lives in
    C:\ProgramData\DbHubDemo\activity.json on T1, so setting it never wakes the serverless database, and
    T4's in activity-t4.json next to it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DotNetExe,

        [Parameter(Mandatory = $true)]
        [string] $RunnerDll,

        [Parameter(Mandatory = $true)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $NotAfter,

        [AllowEmptyString()]
        [string] $Server = '',

        [string] $RequestedBy = 'DbHubDemo-Workload'
    )

    if (-not $PSCmdlet.ShouldProcess($Target, ('Set the activity profile to {0}' -f $Name))) {
        return
    }
    $arguments = @('profile', 'set', '--target', $Target, '--name', $Name, '--requested-by', $RequestedBy, '--json')
    if ($Name -ne 'off') {
        $arguments += @('--not-after', $NotAfter)
    }
    if ($Server) {
        $arguments += @('--server', $Server)
    }
    $run = Invoke-DemoVmRunnerProcess -DotNetExe $DotNetExe -RunnerDll $RunnerDll -ArgumentList $arguments -TimeoutSeconds 300
    $outcome = Get-DemoVmRunnerOutcome -Run $run -Label ('profile set --target {0} --name {1}' -f $Target, $Name)
    Write-DemoVmLog -Message $outcome.Message
    return $outcome
}

function Get-DemoVmWorkloadTaskDefinition {
    <#
    .SYNOPSIS
    The DbHubDemo-Workload task's definition, as plain values: what Register-DemoVmWorkloadTask registers.
    Pure, so tests can check it on any operating system.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $TaskName = 'DbHubDemo-Workload'
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root
    return [pscustomobject]@{
        TaskName           = $TaskName
        Execute            = 'powershell.exe'
        Argument           = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f $paths.Wrapper, $Root
        StartupDelay       = 'PT2M'
        UserId             = 'SYSTEM'
        ExecutionTimeLimit = New-TimeSpan -Hours 13
        RestartCount       = 3
        RestartInterval    = New-TimeSpan -Minutes 5
        Description        = 'Fabric Database Hub demo: hosts the ContosoCare activity profiles until the next auto-shutdown (ADR 0010).'
    }
}

function Register-DemoVmWorkloadTask {
    <#
    .SYNOPSIS
    Registers the SYSTEM scheduled task DbHubDemo-Workload, which runs Start-DemoWorkload.ps1 two minutes
    after startup, so the activity profiles come back after every start (ADR 0010).

    .DESCRIPTION
    The wrapper applies the configured activity profile once per boot and then hosts 'profile run' until two
    minutes before the next auto-shutdown. The task ignores new instances while one runs, restarts a failed
    run up to three times, and stops after 13 hours at most (Get-DemoVmWorkloadTaskDefinition).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $TaskName = 'DbHubDemo-Workload'
    )

    $definition = Get-DemoVmWorkloadTaskDefinition -Root $Root -TaskName $TaskName
    $action = New-ScheduledTaskAction -Execute $definition.Execute -Argument $definition.Argument
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = $definition.StartupDelay
    $principal = New-ScheduledTaskPrincipal -UserId $definition.UserId -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit $definition.ExecutionTimeLimit -RestartCount $definition.RestartCount -RestartInterval $definition.RestartInterval -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $definition.TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings `
        -Description $definition.Description -Force | Out-Null
    Write-DemoVmLog -Message ('Registered the scheduled task {0}.' -f $definition.TaskName)
}

function Test-DemoVmWorkloadTask {
    # True when DbHubDemo-Workload exists and runs this state folder's wrapper.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $TaskName = 'DbHubDemo-Workload'
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return $false
    }
    $wrapper = (Get-DemoVmWorkloadPath -Root $Root).Wrapper
    return (@($task.Actions | Where-Object { [string]$_.Arguments -like ('*"{0}"*' -f $wrapper) }).Count -gt 0)
}

function Stop-DemoVmWorkload {
    <#
    .SYNOPSIS
    Stops the DbHubDemo-Workload task and any runner process that uses this state folder's .NET runtime.

    .DESCRIPTION
    Used before the runtime or the runner is replaced. A runner stopped this way ends its sessions when the
    process exits: SQL Server rolls back their transactions, and the next start records the runs as
    TimedOut (demo.usp_recover_stale_runs).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $TaskName = 'DbHubDemo-Workload'
    )

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'Stop the workload runner')) {
        return
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    $dotnet = (Get-DemoVmWorkloadPath -Root $Root).DotNet
    # A prefix match on either separator: the processes' paths are the VM's, and a Linux test uses '/'.
    $prefix = $dotnet.TrimEnd('\', '/')
    $processes = @(Get-CimInstance -ClassName 'Win32_Process' -Filter "Name = 'dotnet.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $executable = [string]$_.ExecutablePath
                $executable.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $executable.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)
            })
    foreach ($process in $processes) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        Write-DemoVmLog -Message ('Stopped runner process {0}.' -f $process.ProcessId)
    }
}

function Start-DemoVmWorkload {
    # Starts DbHubDemo-Workload now (it also starts at every boot).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $TaskName = 'DbHubDemo-Workload'
    )

    if ($PSCmdlet.ShouldProcess($TaskName, 'Start the workload runner')) {
        Start-ScheduledTask -TaskName $TaskName
        Write-DemoVmLog -Message ('Started the scheduled task {0}.' -f $TaskName)
    }
}

function Write-DemoVmWorkloadInstall {
    <#
    .SYNOPSIS
    Writes workload-install.json, which Start-DemoWorkload.ps1, the control script, and the health detail
    read: the runner and runtime paths, the targets, the activity profile, and the auto-shutdown schedule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Record
    )

    Write-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Root).InstallRecord -InputObject $Record -Redact
}

function New-DemoVmWorkloadRecord {
    <#
    .SYNOPSIS
    Builds the workload-install.json record for one VM (or the T2 guest).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Workload,

        [Parameter(Mandatory = $true)]
        [ValidateSet('T1', 'T2')]
        [string] $PrimaryTarget,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $DotNetPin
    )

    $paths = Get-DemoVmWorkloadPath -Root $Root -RunnerSha256 $Workload.RunnerSha256
    $t3 = $null
    if ($PrimaryTarget -eq 'T1' -and $null -ne $Workload.T3) {
        $t3 = [ordered]@{ serverName = $Workload.T3.ServerName; serverFqdn = $Workload.T3.ServerFqdn; databaseName = $Workload.T3.DatabaseName }
    }
    $t4 = $null
    if ($PrimaryTarget -eq 'T1' -and $Workload.Contains('T4') -and $null -ne $Workload.T4) {
        $t4 = [ordered]@{ serverName = $Workload.T4.ServerName; serverFqdn = $Workload.T4.ServerFqdn; databaseName = $Workload.T4.DatabaseName; runnerRole = $Workload.T4.RunnerRole }
    }
    return [ordered]@{
        schemaVersion        = 1
        primaryTarget        = $PrimaryTarget
        runnerSha256         = $Workload.RunnerSha256
        runnerDll            = $paths.RunnerDll
        dotnetExe            = $paths.DotNetExe
        dotnetVersion        = [string]$DotNetPin['version']
        dotnetSha512         = ([string]$DotNetPin['sha512']).ToLowerInvariant()
        activityProfile      = $Workload.ActivityProfile
        profileOnBoot        = [bool]$Workload.ProfileOnBoot
        autoShutdownTime     = $Workload.AutoShutdownTime
        autoShutdownTimeZone = $Workload.AutoShutdownTimeZone
        t3                   = $t3
        t4                   = $t4
        setup                = [ordered]@{}
        installedUtc         = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Test-DemoVmWorkloadRecord {
    # True when workload-install.json matches the wanted runner, runtime, profile, schedule, and T3 and T4 servers.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Record,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Expected
    )

    if ($null -eq $Record) {
        return $false
    }
    foreach ($key in @('primaryTarget', 'runnerSha256', 'dotnetVersion', 'dotnetSha512', 'activityProfile', 'autoShutdownTime', 'autoShutdownTimeZone')) {
        if ([string]$Record[$key] -ne [string]$Expected[$key]) {
            return $false
        }
    }
    if ((([string]$Record['profileOnBoot']) -eq 'True') -ne (([string]$Expected['profileOnBoot']) -eq 'True')) {
        return $false
    }
    $wantedT3 = ''
    if ($null -ne $Expected['t3']) {
        $wantedT3 = [string]$Expected['t3']['serverFqdn']
    }
    $recordedT3 = ''
    if ($Record.Contains('t3') -and $null -ne $Record['t3']) {
        $recordedT3 = [string]$Record['t3']['serverFqdn']
    }
    if ($wantedT3 -ne $recordedT3) {
        return $false
    }
    $wantedT4 = ''
    if ($Expected.Contains('t4') -and $null -ne $Expected['t4']) {
        $wantedT4 = [string]$Expected['t4']['serverFqdn']
    }
    $recordedT4 = ''
    if ($Record.Contains('t4') -and $null -ne $Record['t4']) {
        $recordedT4 = [string]$Record['t4']['serverFqdn']
    }
    if ($wantedT4 -ne $recordedT4) {
        return $false
    }
    $setup = $Record['setup']
    if ($null -eq $setup -or -not $setup.Contains($Expected['primaryTarget'])) {
        return $false
    }
    return ([string]$setup[$Expected['primaryTarget']]['status'] -in @('Pass', 'Warning'))
}

function Test-DemoVmT3Enabled {
    # True when Enable-DemoT3Workload recorded that T1's identity set up T3 (t3-workload.json).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $ServerFqdn
    )

    $marker = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Root).T3Marker
    return ($null -ne $marker -and [string]$marker['serverFqdn'] -eq $ServerFqdn.ToLowerInvariant())
}

function Test-DemoVmT4Enabled {
    # True when Enable-DemoT4Workload recorded that T1's identity set up T4 (t4-workload.json).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $ServerFqdn
    )

    $marker = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $Root).T4Marker
    return ($null -ne $marker -and [string]$marker['serverFqdn'] -eq $ServerFqdn.ToLowerInvariant())
}

function Test-DemoVmNameResolve {
    # True when a host name resolves. T3's name stops resolving when stop-demo.ps1 -RemoveT3 deletes it.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $HostName
    )

    try {
        return (@([System.Net.Dns]::GetHostAddresses($HostName)).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-DemoVmWorkloadHealth {
    <#
    .SYNOPSIS
    Workload facts for health.json: the installed runner and runtime, setup results, whether T3 is enabled,
    and the task's state. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $TaskName = 'DbHubDemo-Workload'
    )

    $detail = [ordered]@{ installed = $false }
    try {
        $paths = Get-DemoVmWorkloadPath -Root $Root
        $record = Read-DemoVmJsonFile -Path $paths.InstallRecord
        if ($null -ne $record) {
            $detail.installed = $true
            $detail.runnerSha256 = [string]$record['runnerSha256']
            $detail.dotnetVersion = [string]$record['dotnetVersion']
            $detail.activityProfile = [string]$record['activityProfile']
            $detail.profileOnBoot = (([string]$record['profileOnBoot']) -eq 'True')
            $detail.setup = $record['setup']
            $detail.installedUtc = $record['installedUtc']
        }
        $marker = Read-DemoVmJsonFile -Path $paths.T3Marker
        if ($null -ne $marker) {
            $detail.t3Enabled = [ordered]@{ serverFqdn = [string]$marker['serverFqdn']; enabledUtc = $marker['enabledUtc'] }
        }
        $t4Marker = Read-DemoVmJsonFile -Path $paths.T4Marker
        if ($null -ne $t4Marker) {
            $detail.t4Enabled = [ordered]@{ serverFqdn = [string]$t4Marker['serverFqdn']; enabledUtc = $t4Marker['enabledUtc'] }
        }
        $boot = Read-DemoVmJsonFile -Path $paths.BootMarker
        if ($null -ne $boot) {
            $detail.profileApplied = $boot
        }
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $detail.taskState = [string]$task.State
        }
        else {
            $detail.taskState = 'NotRegistered'
        }
    }
    catch {
        $detail.error = Protect-DemoVmText -Text $_.Exception.Message
    }
    return $detail
}
