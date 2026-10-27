<#
.SYNOPSIS
Bootstrap loader for the demo VMs, embedded in a managed Run Command (ADR 0003).

.DESCRIPTION
Runs as SYSTEM through the managed Run Command DbHubDemo-Bootstrap (asyncExecution), on T1 (Role SqlVm) and
on the T2 host (Role ArcHost), or on the evaluation-only Azure VM arcsql01 (Role EvalArcVm, ADR 0006). Before the template deploys it, Send-DemoBootstrapBundle has written the
bundle zip in SHA-256-checked chunks to C:\ProgramData\DbHubDemo\downloads\<sha12>\ (chunk-001.bin plus
chunk-001.sha256, and so on), one chunk Run Command at a time. The loader:
1. Skips assembly when bundle\<sha12>\.complete exists (the same bundle is already installed).
2. Otherwise re-verifies every chunk against its .sha256 file and names any missing or bad chunk, joins
   them in order into bundle-<sha12>.zip.partial, and verifies the whole bundle's SHA-256. A mismatch fails
   closed: the joined file and the chunk folder are deleted and nothing is installed.
3. Renames the verified file to bundle-<sha12>.zip and extracts it with
   [System.IO.Compression.ZipFile]::ExtractToDirectory into a staging folder, which it moves to
   bundle\<sha12> and marks .complete. (Windows PowerShell 5.1's Expand-Archive accepts only a .zip
   extension, which is why the file is renamed before it's extracted.) The zip and the chunks are deleted.
4. Writes settings.json, restricts C:\ProgramData\DbHubDemo to SYSTEM and Administrators, registers the
   SYSTEM scheduled task DbHubDemo-Bootstrap (at startup and every 5 minutes), which runs the role's
   resumable state machine, starts it, and returns. Reboots happen in the task, never here.

Nothing here is secret: the parameters and the bundle hold no credentials (ADR 0009). Targets Windows
PowerShell 5.1. Keep this file small: Bicep embeds it with loadTextContent (96 KB limit). The template
Base64-encodes SettingsJson so its quotes survive the command line that Run Command builds; plain JSON is
accepted too.

.PARAMETER BundleSha256
SHA-256 of the bundle zip (64 hexadecimal characters).

.PARAMETER ChunkCount
Number of chunks Send-DemoBootstrapBundle delivered.

.PARAMETER Role
SqlVm, ArcHost, or EvalArcVm.

.PARAMETER SettingsJson
Non-secret settings as JSON, plain or Base64.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $BundleSha256 = '',
    [string] $ChunkCount = '',
    [string] $Role = '',
    [string] $SettingsJson = '',
    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest

$script:LoaderLogPath = $null
$script:LoaderConsole = $true
$script:LoaderTaskName = 'DbHubDemo-Bootstrap'

function Write-DemoLoaderLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string] $Level = 'Info'
    )

    $line = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level.ToUpperInvariant(), $Message
    if ($script:LoaderConsole) {
        [Console]::Out.WriteLine($line)
    }
    if ($script:LoaderLogPath) {
        try {
            [System.IO.File]::AppendAllText($script:LoaderLogPath, $line + [Environment]::NewLine, (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
        }
        catch {
            [Console]::Error.WriteLine('Could not write the loader log.')
        }
    }
}

function ConvertFrom-DemoLoaderValue {
    # Returns a JSON value that arrived either as plain text or as Base64-encoded UTF-8.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('{')) {
        return $trimmed
    }
    try {
        $bytes = [System.Convert]::FromBase64String($trimmed)
    }
    catch {
        throw 'The SettingsJson value is neither JSON nor Base64.'
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-DemoLoaderFileHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DemoLoaderChunkPath {
    # chunk-001.bin and chunk-001.sha256, written by the chunk Run Commands (New-DemoBootstrapChunk).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ChunkDirectory,

        [Parameter(Mandatory = $true)]
        [int] $Index
    )

    $name = 'chunk-{0:d3}' -f $Index
    return [pscustomobject]@{
        Data   = Join-Path -Path $ChunkDirectory -ChildPath ($name + '.bin')
        Sha256 = Join-Path -Path $ChunkDirectory -ChildPath ($name + '.sha256')
    }
}

function Assert-DemoLoaderChunk {
    # Every chunk must be present and match its .sha256 file; the error names each missing or bad index.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ChunkDirectory,

        [Parameter(Mandatory = $true)]
        [int] $ChunkCount
    )

    $missing = New-Object -TypeName 'System.Collections.Generic.List[int]'
    $bad = New-Object -TypeName 'System.Collections.Generic.List[int]'
    for ($index = 1; $index -le $ChunkCount; $index++) {
        $paths = Get-DemoLoaderChunkPath -ChunkDirectory $ChunkDirectory -Index $index
        if (-not (Test-Path -LiteralPath $paths.Data -PathType Leaf) -or -not (Test-Path -LiteralPath $paths.Sha256 -PathType Leaf)) {
            $missing.Add($index)
            continue
        }
        $expected = ([System.IO.File]::ReadAllText($paths.Sha256)).Trim().ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$' -or (Get-DemoLoaderFileHash -Path $paths.Data) -ne $expected) {
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
        throw ('The bundle in {0} is incomplete ({1} expected): {2}. Nothing was installed; send the bundle again with Send-DemoBootstrapBundle (deploy.ps1 -Resume).' -f $ChunkDirectory, $ChunkCount, ($parts -join '; '))
    }
}

function Join-DemoLoaderChunk {
    # Concatenates the chunks in order into one file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ChunkDirectory,

        [Parameter(Mandatory = $true)]
        [int] $ChunkCount,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $output = [System.IO.File]::Create($Path)
    try {
        for ($index = 1; $index -le $ChunkCount; $index++) {
            $bytes = [System.IO.File]::ReadAllBytes((Get-DemoLoaderChunkPath -ChunkDirectory $ChunkDirectory -Index $index).Data)
            $output.Write($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $output.Dispose()
    }
}

function Assert-DemoLoaderBundleHash {
    # Fails closed: a mismatch deletes the joined file and the chunks, so nothing from them can run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string] $ChunkDirectory
    )

    $actual = Get-DemoLoaderFileHash -Path $Path
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ChunkDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw ('Bundle SHA-256 mismatch: expected {0}, got {1}. The joined file and the chunks were deleted and nothing was installed.' -f $ExpectedSha256.ToLowerInvariant(), $actual)
    }
}

function Expand-DemoLoaderBundle {
    # ZipFile.ExtractToDirectory doesn't care about the file extension (Expand-Archive in 5.1 does).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ZipPath,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $staging = $Destination + '.staging'
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $staging)
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Move-Item -LiteralPath $staging -Destination $Destination
    [System.IO.File]::WriteAllText((Join-Path -Path $Destination -ChildPath '.complete'), [DateTime]::UtcNow.ToString('o'))
}

function Install-DemoLoaderBundle {
    <#
    .SYNOPSIS
    Assembles, verifies, and extracts the bundle from its chunks, once. Returns the bundle folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $BundleSha256,

        [Parameter(Mandatory = $true)]
        [int] $ChunkCount
    )

    $sha = $BundleSha256.ToLowerInvariant()
    $shortSha = $sha.Substring(0, 12)
    $bundlePath = [System.IO.Path]::Combine($Root, 'bundle', $shortSha)
    if (Test-Path -LiteralPath (Join-Path -Path $bundlePath -ChildPath '.complete')) {
        Write-DemoLoaderLog -Message ('Bundle {0} is already installed; the chunks are not needed.' -f $shortSha)
        return $bundlePath
    }
    $downloadDirectory = Join-Path -Path $Root -ChildPath 'downloads'
    $chunkDirectory = Join-Path -Path $downloadDirectory -ChildPath $shortSha
    Assert-DemoLoaderChunk -ChunkDirectory $chunkDirectory -ChunkCount $ChunkCount
    $partial = Join-Path -Path $downloadDirectory -ChildPath ('bundle-{0}.zip.partial' -f $shortSha)
    $zip = Join-Path -Path $downloadDirectory -ChildPath ('bundle-{0}.zip' -f $shortSha)
    Join-DemoLoaderChunk -ChunkDirectory $chunkDirectory -ChunkCount $ChunkCount -Path $partial
    Assert-DemoLoaderBundleHash -Path $partial -ExpectedSha256 $sha -ChunkDirectory $chunkDirectory
    Write-DemoLoaderLog -Message ('Bundle SHA-256 verified from {0} chunk(s): {1}.' -f $ChunkCount, $sha)
    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force
    }
    Move-Item -LiteralPath $partial -Destination $zip
    Expand-DemoLoaderBundle -ZipPath $zip -Destination $bundlePath
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $chunkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    return $bundlePath
}

function Protect-DemoLoaderFolder {
    # SYSTEM and Administrators only, by well-known SID so it works on any OS language. The ACL is set on the
    # folder only: '/grant' with '/T' strips the inherited entries from files and leaves them with an empty
    # ACL that nobody can read. Children then inherit, and '/reset' repairs any child whose ACL isn't
    # inherited (for example one damaged by an earlier '/T' run).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # icacls can write to stderr even when it succeeds; with 'Stop', Windows PowerShell 5.1 would end the loader on
    # that line, so the exit code decides.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q 2>&1 | ForEach-Object { [string]$_ })
        $icaclsExitCode = $LASTEXITCODE
        if ($icaclsExitCode -eq 0 -and (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $output = @(& icacls.exe (Join-Path -Path $Path -ChildPath '*') /reset /T /C /Q 2>&1 | ForEach-Object { [string]$_ })
            $icaclsExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($icaclsExitCode -ne 0) {
        throw ('icacls failed with exit code {0} for {1}: {2}' -f $icaclsExitCode, $Path, ($output -join ' '))
    }
}

function Register-DemoLoaderTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScriptPath,

        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f $ScriptPath, $StateRoot
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup)
        (New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:LoaderTaskName -Action $action -Trigger $triggers -Principal $principal -Settings $taskSettings `
        -Description 'Fabric Database Hub demo: resumable bootstrap state machine (ADR 0003).' -Force | Out-Null
}

function Invoke-DemoLoaderTask {
    [CmdletBinding()]
    param()

    Start-ScheduledTask -TaskName $script:LoaderTaskName
}

function Remove-DemoLoaderOldBundle {
    # Keeps the current bundle and the newest previous one, for rollback.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BundleDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Keep
    )

    $old = @(Get-ChildItem -LiteralPath $BundleDirectory -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $Keep } | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -Skip 1)
    foreach ($folder in $old) {
        if ($PSCmdlet.ShouldProcess($folder.FullName, 'Remove old bundle')) {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-DemoBootstrapLoader {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $BundleSha256,

        [AllowEmptyString()]
        [string] $ChunkCount,

        [AllowEmptyString()]
        [string] $Role,

        [AllowEmptyString()]
        [string] $SettingsJson,

        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $ErrorActionPreference = 'Stop'
    if ($Role -notin @('SqlVm', 'ArcHost', 'EvalArcVm')) {
        throw 'Role must be SqlVm, ArcHost, or EvalArcVm.'
    }
    if ($BundleSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'BundleSha256 must be 64 hexadecimal characters.'
    }
    $count = 0
    if (-not [int]::TryParse([string]$ChunkCount, [ref]$count) -or $count -lt 1) {
        throw 'ChunkCount must be a positive whole number.'
    }
    $sha = $BundleSha256.ToLowerInvariant()
    $shortSha = $sha.Substring(0, 12)
    $settingsText = ConvertFrom-DemoLoaderValue -Value $SettingsJson
    $settings = $null
    if ($settingsText) {
        $settings = $settingsText | ConvertFrom-Json
    }

    $bundleDirectory = Join-Path -Path $Root -ChildPath 'bundle'
    $logDirectory = Join-Path -Path $Root -ChildPath 'logs'
    foreach ($directory in @($Root, $bundleDirectory, (Join-Path -Path $Root -ChildPath 'downloads'), $logDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    Protect-DemoLoaderFolder -Path $Root
    $script:LoaderLogPath = Join-Path -Path $logDirectory -ChildPath 'loader.log'
    Write-DemoLoaderLog -Message ('Loader started: role {0}, bundle {1}, {2} chunk(s).' -f $Role, $shortSha, $count)

    $bundlePath = Install-DemoLoaderBundle -Root $Root -BundleSha256 $sha -ChunkCount $count
    $scriptName = 'Invoke-SqlVmBootstrap.ps1'
    if ($Role -eq 'ArcHost') {
        $scriptName = 'Invoke-HostBootstrap.ps1'
    }
    elseif ($Role -eq 'EvalArcVm') {
        $scriptName = 'Invoke-EvalArcVmBootstrap.ps1'
    }
    $scriptPath = [System.IO.Path]::Combine($bundlePath, 'vm', 'bootstrap', $scriptName)
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw ('The bundle has no vm/bootstrap/{0}.' -f $scriptName)
    }

    $merged = [ordered]@{}
    if ($null -ne $settings) {
        foreach ($property in $settings.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }
    $generation = '{0}-{1}' -f $shortSha, [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $merged['role'] = $Role
    $merged['bundleSha256'] = $sha
    $merged['bundlePath'] = $bundlePath
    $merged['generation'] = $generation
    $merged['loaderRunUtc'] = [DateTime]::UtcNow.ToString('o')
    $settingsPath = Join-Path -Path $Root -ChildPath 'settings.json'
    [System.IO.File]::WriteAllText($settingsPath, ($merged | ConvertTo-Json -Depth 10), (New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false))
    Protect-DemoLoaderFolder -Path $Root
    Remove-DemoLoaderOldBundle -BundleDirectory $bundleDirectory -Keep $shortSha

    Register-DemoLoaderTask -ScriptPath $scriptPath -StateRoot $Root
    Invoke-DemoLoaderTask
    Write-DemoLoaderLog -Message ('Scheduled task {0} registered and started (generation {1}). The state machine continues in the background; progress is in state.json and health.json.' -f $script:LoaderTaskName, $generation)

    [pscustomobject]@{
        Role         = $Role
        BundleSha256 = $sha
        BundlePath   = $bundlePath
        ScriptPath   = $scriptPath
        TaskName     = $script:LoaderTaskName
        Generation   = $generation
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $loaderResult = Invoke-DemoBootstrapLoader -BundleSha256 $BundleSha256 -ChunkCount $ChunkCount -Role $Role -SettingsJson $SettingsJson -Root $Root
        [Console]::Out.WriteLine(('DbHubDemo loader finished: role {0}, bundle {1}.' -f $loaderResult.Role, $loaderResult.BundleSha256.Substring(0, 12)))
        exit 0
    }
    catch {
        $message = $_.Exception.Message
        Write-DemoLoaderLog -Level 'Error' -Message $message
        [Console]::Error.WriteLine('DbHubDemo loader failed: ' + $message)
        exit 1
    }
}
