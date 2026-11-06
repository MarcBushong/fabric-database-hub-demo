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
5. Before it starts the task, stops a run of an earlier bundle's state machine that's still going, with the
   processes it started (Stop-DemoLoaderEarlierRun): the task starts no second run while one runs, and a run
   can last up to its 6-hour limit, so the new bundle would wait for it. A run of the same bundle goes on.

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
        throw ('The bundle in {0} is incomplete ({1} expected): {2}. Nothing was installed; the next ./scripts/deploy.ps1 sends the bundle again (Send-DemoBootstrapBundle), then runs this loader again.' -f $ChunkDirectory, $ChunkCount, ($parts -join '; '))
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

function Get-DemoLoaderBootstrapRun {
    # The bootstrap runs among -Process (Win32_Process records): a powershell.exe whose command line runs a role's state
    # machine from a bundle under -Root (bundle\<sha12>\vm\bootstrap\Invoke-*Bootstrap.ps1), as the task's action does.
    # Returns ProcessId, Bundle (the hash prefix), Script, and CreationDate for each. Pure.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Process = @(),

        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $bundleRoot = Join-Path -Path $Root.TrimEnd('\', '/') -ChildPath 'bundle'
    $pattern = '(?i)' + [regex]::Escape($bundleRoot) + '[\\/]([0-9a-f]{12})[\\/]vm[\\/]bootstrap[\\/](Invoke-(?:SqlVm|Host|EvalArcVm)Bootstrap\.ps1)'
    foreach ($item in @($Process)) {
        if ($null -eq $item -or [string]$item.Name -notin 'powershell.exe', 'pwsh.exe' -or -not [string]$item.CommandLine) {
            continue
        }
        $match = [regex]::Match([string]$item.CommandLine, $pattern)
        if ($match.Success) {
            [pscustomobject]@{
                ProcessId    = [int]$item.ProcessId
                Bundle       = $match.Groups[1].Value.ToLowerInvariant()
                Script       = $match.Groups[2].Value
                CreationDate = $item.CreationDate
            }
        }
    }
}

function Get-DemoLoaderProcessTree {
    # The processes that -Parent started, and the ones those started, among -Process (Win32_Process records), by
    # ParentProcessId while the parents still run; a process created before its parent never counts, so one that reused
    # an ID is never taken for a child. Pure.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Process = @(),

        [AllowEmptyCollection()]
        [object[]] $Parent = @()
    )

    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
    foreach ($item in @($Parent)) {
        if ($null -ne $item -and $seen.Add([int]$item.ProcessId)) {
            $queue.Enqueue($item)
        }
    }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($item in @($Process)) {
            if ($null -eq $item -or [int]$item.ParentProcessId -ne [int]$current.ProcessId -or $seen.Contains([int]$item.ProcessId)) {
                continue
            }
            if ($null -ne $current.CreationDate -and $null -ne $item.CreationDate -and [datetime]$item.CreationDate -lt [datetime]$current.CreationDate) {
                continue
            }
            [void]$seen.Add([int]$item.ProcessId)
            $queue.Enqueue($item)
            $item
        }
    }
}

function Test-DemoLoaderProcessMatch {
    # True while process -ProcessId runs and is the one -CreationDate names (within 2 seconds); a process that later got
    # the same ID doesn't match.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId,

        [AllowNull()]
        [object] $CreationDate
    )

    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        return $false
    }
    try {
        if ($process.HasExited) {
            return $false
        }
        if ($null -eq $CreationDate) {
            return $true
        }
        return ([System.Math]::Abs(($process.StartTime.ToUniversalTime() - ([datetime]$CreationDate).ToUniversalTime()).TotalSeconds) -le 2)
    }
    catch {
        return $false
    }
    finally {
        $process.Dispose()
    }
}

function Stop-DemoLoaderProcess {
    # Ends process -ProcessId when it's still the one -CreationDate names. True when it's gone or was ended.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId,

        [AllowNull()]
        [object] $CreationDate
    )

    if (-not (Test-DemoLoaderProcessMatch -ProcessId $ProcessId -CreationDate $CreationDate)) {
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess(('process {0}' -f $ProcessId), 'Stop an earlier bundle''s bootstrap run')) {
        return $false
    }
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        return $true
    }
    catch {
        return (-not (Test-DemoLoaderProcessMatch -ProcessId $ProcessId -CreationDate $CreationDate))
    }
}

function Test-DemoLoaderLockFree {
    # True when no bootstrap run holds bootstrap.lock: Enter-DemoVmLock opens it exclusively, and the operating system
    # closes that handle when the run's process ends. This opens it the same way and closes it at once.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $true
    }
    try {
        $stream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList @($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $true
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException -and $exception -isnot [System.IO.IOException]) {
            $exception = $exception.InnerException
        }
        return ($exception -isnot [System.IO.IOException] -or $exception -is [System.IO.FileNotFoundException])
    }
}

function Test-DemoLoaderTaskIdle {
    # True when the task reports no running instance, so Start-ScheduledTask isn't ignored (MultipleInstances IgnoreNew).
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $task = Get-ScheduledTask -TaskName $script:LoaderTaskName -ErrorAction SilentlyContinue
    return ($null -eq $task -or [string]$task.State -ne 'Running')
}

function Stop-DemoLoaderEarlierRun {
    <#
    .SYNOPSIS
    Stops a bootstrap run that still runs an earlier bundle's state machine, with the processes it started, so the task
    starts the new bundle at once (live finding, 2026-11-06). Returns Stopped (the earlier runs), Children (the processes
    they had started), Same (runs of this bundle, left alone), Ready, and Text (one line for the Run Command's output;
    empty when nothing was stopped).

    .DESCRIPTION
    The task ignores a new instance while one runs (MultipleInstances IgnoreNew) and ends one only after 6 hours, and
    registering it again doesn't stop the one that runs, so the new bundle waited for the old run, live for a 34 GiB
    download. The runs are found by their command line (Win32_Process): the role's Invoke-*Bootstrap.ps1 under
    -Root\bundle\<sha12>. A run of this bundle is left alone: its next pass takes the new generation. An earlier one is
    stopped as a restart stops it (the nightly stop, the watchdog, the task's time limit), which the resumable state
    machine is built for (ADR 0003): its lock goes with its process; state.json and the other records are replaced
    whole from a temporary file, so they hold the old or the new content; a step left Running runs again from its check,
    and the new generation checks every step again; downloads keep their .partial files and resume. The processes it
    started are found while it still runs, by their parent process ID, and stopped after it, so none goes on with work
    that the new run does again; the guest's own processes aren't the host's. A process is stopped only while its ID and
    start time still match. Ready is true once they've ended, the lock is free, and the task is idle, within
    -TimeoutSeconds; otherwise the task's next pass starts the new run once they have.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $BundleSha256,

        [ValidateRange(1, 600)]
        [int] $TimeoutSeconds = 60
    )

    $shortSha = $BundleSha256.Substring(0, 12).ToLowerInvariant()
    $result = [pscustomobject]@{ Stopped = @(); Children = @(); Same = @(); Ready = $true; Text = '' }
    try {
        $processes = @(Get-CimInstance -ClassName 'Win32_Process' -ErrorAction Stop)
    }
    catch {
        Write-DemoLoaderLog -Level 'Warning' -Message ('The running processes couldn''t be read ({0}), so no earlier bundle''s bootstrap run was looked for: one that still runs ends on its own, and the new run starts at the task''s next pass after it.' -f $_.Exception.Message)
        return $result
    }
    $runs = @(Get-DemoLoaderBootstrapRun -Process $processes -Root $Root | Where-Object { $_.ProcessId -ne $PID })
    $result.Same = @($runs | Where-Object { $_.Bundle -eq $shortSha })
    $earlier = @($runs | Where-Object { $_.Bundle -ne $shortSha })
    if ($earlier.Count -eq 0) {
        if ($result.Same.Count -gt 0) {
            Write-DemoLoaderLog -Message ('A bootstrap run of bundle {0} is in progress (process {1}); it goes on, and its next pass takes the new generation.' -f $shortSha, (@($result.Same | ForEach-Object { $_.ProcessId }) -join ', '))
        }
        return $result
    }
    $children = @(Get-DemoLoaderProcessTree -Process $processes -Parent $earlier)
    $result.Stopped = $earlier
    $result.Children = $children
    $old = (@($earlier | ForEach-Object { $_.Bundle }) | Select-Object -Unique) -join ', '
    $ids = (@($earlier | ForEach-Object { $_.ProcessId }) -join ', ')
    $childText = if ($children.Count -gt 0) { ', and the {0} process(es) it started ({1})' -f $children.Count, ((@($children | ForEach-Object { [string]$_.Name }) | Select-Object -Unique) -join ', ') } else { '' }
    Write-DemoLoaderLog -Message ('Bundle {0}''s bootstrap run is still going (process {1}): it''s stopped{2}, so bundle {3}''s run starts now instead of after it (the task starts no second run while one runs). Its steps are resumable: the new run checks each one again (ADR 0003).' -f $old, $ids, $childText, $shortSha)
    # The run first, so it starts nothing more; then what it started.
    $failed = New-Object -TypeName 'System.Collections.Generic.List[int]'
    foreach ($item in @($earlier) + @($children)) {
        if (-not (Stop-DemoLoaderProcess -ProcessId ([int]$item.ProcessId) -CreationDate $item.CreationDate)) {
            $failed.Add([int]$item.ProcessId)
        }
    }
    $lockPath = Join-Path -Path $Root -ChildPath 'bootstrap.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $startedByTask = $false
    while ($true) {
        $alive = @(@($earlier) + @($children) | Where-Object { Test-DemoLoaderProcessMatch -ProcessId ([int]$_.ProcessId) -CreationDate $_.CreationDate })
        if ($alive.Count -eq 0) {
            if ((Test-DemoLoaderLockFree -Path $lockPath) -and (Test-DemoLoaderTaskIdle)) {
                $result.Ready = $true
                break
            }
            # The task's own 5-minute trigger may already have started the new bundle's run, which holds the lock.
            try {
                $startedByTask = @(Get-DemoLoaderBootstrapRun -Process @(Get-CimInstance -ClassName 'Win32_Process' -ErrorAction Stop) -Root $Root | Where-Object { $_.Bundle -eq $shortSha }).Count -gt 0
            }
            catch {
                $startedByTask = $false
            }
            if ($startedByTask) {
                $result.Ready = $true
                break
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            $result.Ready = $false
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($result.Ready) {
        Write-DemoLoaderLog -Message ('Bundle {0}''s run has ended{1}.' -f $old, $(if ($startedByTask) { ', and the task''s own trigger has already started bundle ' + $shortSha + '''s run' } else { ', and the bootstrap lock is free' }))
        $result.Text = 'stopped bundle {0}''s bootstrap run, which was still going (process {1}){2}; bundle {3}''s run starts now.' -f $old, $ids, $childText, $shortSha
    }
    else {
        $still = if ($failed.Count -gt 0) { 'process(es) {0} couldn''t be stopped' -f ($failed -join ', ') } else { 'the run hasn''t ended, the bootstrap lock is still held, or the task still reports a run' }
        Write-DemoLoaderLog -Level 'Warning' -Message ('Bundle {0}''s run was stopped, but after {1} seconds {2}; bundle {3}''s run starts at the task''s next pass once it has.' -f $old, $TimeoutSeconds, $still, $shortSha)
        $result.Text = 'stopped bundle {0}''s bootstrap run, which was still going (process {1}){2}, but after {3} seconds {4}; bundle {5}''s run starts at the task''s next pass once it has.' -f $old, $ids, $childText, $TimeoutSeconds, $still, $shortSha
    }
    return $result
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

    # Registered first, so a run the task starts from here on runs this bundle; registering it doesn't stop a run that
    # runs an earlier one, which is stopped next, before the old bundle folders go (live finding, 2026-11-06).
    Register-DemoLoaderTask -ScriptPath $scriptPath -StateRoot $Root
    $takeover = Stop-DemoLoaderEarlierRun -Root $Root -BundleSha256 $sha
    Remove-DemoLoaderOldBundle -BundleDirectory $bundleDirectory -Keep $shortSha
    Invoke-DemoLoaderTask
    Write-DemoLoaderLog -Message ('Scheduled task {0} registered and started (generation {1}). The state machine continues in the background; progress is in state.json and health.json.' -f $script:LoaderTaskName, $generation)

    [pscustomobject]@{
        Role         = $Role
        BundleSha256 = $sha
        BundlePath   = $bundlePath
        ScriptPath   = $scriptPath
        TaskName     = $script:LoaderTaskName
        Generation   = $generation
        TookOver     = [string]$takeover.Text
    }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $loaderResult = Invoke-DemoBootstrapLoader -BundleSha256 $BundleSha256 -ChunkCount $ChunkCount -Role $Role -SettingsJson $SettingsJson -Root $Root
        [Console]::Out.WriteLine(('DbHubDemo loader finished: role {0}, bundle {1}.' -f $loaderResult.Role, $loaderResult.BundleSha256.Substring(0, 12)))
        if ($loaderResult.TookOver) {
            # deploy.ps1 reads this line from the Run Command's output (Invoke-DemoBootstrapLoaderRun).
            [Console]::Out.WriteLine('DbHubDemo loader took over: ' + $loaderResult.TookOver)
        }
        exit 0
    }
    catch {
        $message = $_.Exception.Message
        Write-DemoLoaderLog -Level 'Error' -Message $message
        [Console]::Error.WriteLine('DbHubDemo loader failed: ' + $message)
        exit 1
    }
}
