# Phase 28 live finding (2026-10-29): Ctrl+C at the guided stop seemed to do nothing. PowerShell did stop deploy.ps1's
# loop, but its finally block then called Stop-Job on the T2 track, which waited for that track's own cleanup (minutes of
# Azure calls: the guided stop's Bastion removal and password rotation, Run Command deletes), and a finally block doesn't
# take a second Ctrl+C. These helpers make a stop take seconds: the stop is recorded, slow Azure cleanups are skipped
# (the next deploy.ps1 or stop-demo.ps1 does them), and the track processes end within a bounded time.

function Enable-DemoRunCancelWatch {
    <#
    .SYNOPSIS
    Records a Ctrl+C in this process from now on, without changing what Ctrl+C does, and clears an earlier record.
    Returns whether the watch is on; never throws. Internal.

    .DESCRIPTION
    A Console.CancelKeyPress handler that only notes the key press and leaves the event's Cancel as it is, so PowerShell
    goes on stopping the run as before; Test-DemoRunCancelled then tells finally blocks to skip their slow Azure
    cleanups. https://learn.microsoft.com/dotnet/api/system.console.cancelkeypress
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if ($null -eq ('DbHubDemo.RunCancel' -as [type])) {
            Add-Type -Namespace 'DbHubDemo' -Name 'RunCancel' -MemberDefinition @'
private static int requested;
private static int registered;
public static bool Requested { get { return System.Threading.Volatile.Read(ref requested) != 0; } }
public static void Reset() { System.Threading.Interlocked.Exchange(ref requested, 0); }
public static void Register() { if (System.Threading.Interlocked.Exchange(ref registered, 1) == 0) { System.Console.CancelKeyPress += OnCancel; } }
private static void OnCancel(object sender, System.ConsoleCancelEventArgs e) { System.Threading.Interlocked.Exchange(ref requested, 1); }
'@
        }
        $type = 'DbHubDemo.RunCancel' -as [type]
        $type::Register()
        $type::Reset()
        $script:DemoRunCancelWatch = $true
        return $true
    }
    catch {
        Write-DemoLog -Level Debug -Message ('Ctrl+C isn''t recorded in this session, so a stop may take longer: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Disable-DemoRunCancelWatch {
    # Ends the run's Ctrl+C record (Complete-DemoDeploymentRun), so a later command in the same PowerShell session never
    # reads an old Ctrl+C as its own. Internal.
    [CmdletBinding()]
    param()

    $script:DemoRunCancelWatch = $false
    $type = 'DbHubDemo.RunCancel' -as [type]
    if ($null -ne $type) {
        $type::Reset()
    }
}

function Test-DemoRunCancelled {
    <#
    .SYNOPSIS
    True once this run was stopped: Ctrl+C in this process while deploy.ps1 runs (Enable-DemoRunCancelWatch to
    Disable-DemoRunCancelWatch), or, in a track process, the cancel marker deploy.ps1 writes into the run's handoff
    directory before it stops the tracks (DBHUB_CANCEL_FILE). Finally blocks check it to skip slow Azure cleanups, which
    the next deploy.ps1 or stop-demo.ps1 does instead. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $type = 'DbHubDemo.RunCancel' -as [type]
    if ($script:DemoRunCancelWatch -and $null -ne $type -and [bool]$type::Requested) {
        return $true
    }
    $marker = [string]$env:DBHUB_CANCEL_FILE
    return [bool]($marker -and [System.IO.File]::Exists($marker))
}

function Get-DemoJobProcessId {
    # The process ID a job of deploy.ps1 reported first (DBHUB-PID, read by Receive-DemoDeploymentTrackOutput), or 0.
    # Internal.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job] $Job
    )

    $key = $Job.InstanceId.ToString()
    if ($script:DemoJobProcessId.ContainsKey($key)) {
        return [int]$script:DemoJobProcessId[$key]
    }
    return 0
}

function Stop-DemoProcessTree {
    <#
    .SYNOPSIS
    Ends one of deploy.ps1's own job processes and every process it started (Process.Kill with entireProcessTree), and
    waits up to 5 seconds for it to go. Only a PowerShell process, so a process ID that was reused never ends anything
    else. Returns whether it's gone; never throws. Internal.
    https://learn.microsoft.com/dotnet/api/system.diagnostics.process.kill
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Ends only this run''s own job processes, while deploy.ps1 stops.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $ProcessId
    )

    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch {
        return $true
    }
    try {
        if ($process.ProcessName -notmatch '^(pwsh|powershell)$') {
            return $false
        }
        $process.Kill($true)
        return $process.WaitForExit(5000)
    }
    catch {
        Write-DemoLog -Level Debug -Message ('Process {0} couldn''t be ended: {1}' -f $ProcessId, $_.Exception.Message)
        try {
            return $process.HasExited
        }
        catch {
            return $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Stop-DemoRunJob {
    <#
    .SYNOPSIS
    Ends deploy.ps1's background jobs within seconds, whatever they're doing, and removes those that have ended. Returns
    the names of the jobs whose processes it had to end. Never throws. Internal.

    .DESCRIPTION
    The running jobs get Stop-Job together, from a separate PowerShell instance, so this process waits at most
    -GraceSeconds: a track process that has the run's cancel marker skips its slow Azure cleanups and stops in about a
    second. A job that's still running then has its process ended, with every process it started, by the process ID
    it reported first (DBHUB-PID; Stop-DemoProcessTree). Such a job isn't removed: PowerShell takes about a minute to
    notice that its process is gone, and nothing waits for that.
    https://learn.microsoft.com/powershell/module/microsoft.powershell.core/stop-job
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops only this run''s own jobs, while deploy.ps1 stops.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Job = @(),

        [ValidateRange(0, 60)]
        [int] $GraceSeconds = 3
    )

    $all = @($Job | Where-Object { $_ -is [System.Management.Automation.Job] })
    $active = @('NotStarted', 'Running', 'Stopping', 'Suspending', 'Suspended', 'Blocked', 'Disconnected')
    $running = @($all | Where-Object { [string]$_.State -in $active })
    $ended = [System.Collections.Generic.List[string]]::new()
    if ($running.Count -gt 0) {
        foreach ($item in $running) {
            # Reads what the job wrote, its process ID first among it, before the stop.
            try {
                $null = Receive-DemoDeploymentTrackOutput -Job $item
            }
            catch {
                Write-DemoLog -Level Debug -Message ('{0}''s output couldn''t be read: {1}' -f $item.Name, $_.Exception.Message)
            }
        }
        # One Stop-Job per job, each from its own PowerShell instance: Stop-Job with several jobs stops them one after
        # another, so a job whose cleanup takes minutes would hold the others back.
        $stoppers = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $running) {
            try {
                $stopper = [powershell]::Create()
                $null = $stopper.AddCommand('Stop-Job').AddParameter('Job', $item).AddParameter('ErrorAction', 'SilentlyContinue')
                $stoppers.Add([pscustomobject]@{ PowerShell = $stopper; Async = $stopper.BeginInvoke() })
            }
            catch {
                Write-DemoLog -Level Debug -Message ('{0} couldn''t be asked to stop: {1}' -f $item.Name, $_.Exception.Message)
            }
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $GraceSeconds -and @($running | Where-Object { [string]$_.State -in $active }).Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
        foreach ($item in @($running | Where-Object { [string]$_.State -in $active })) {
            $processId = Get-DemoJobProcessId -Job $item
            if ($processId -gt 0 -and (Stop-DemoProcessTree -ProcessId $processId)) {
                $ended.Add([string]$item.Name)
            }
        }
        foreach ($entry in $stoppers) {
            # A stop still waiting for a job whose process was ended finishes on its own thread later.
            if ($entry.Async.IsCompleted) {
                $entry.PowerShell.Dispose()
            }
        }
    }
    foreach ($item in $all) {
        if ([string]$item.State -notin $active) {
            Remove-Job -Job $item -Force -ErrorAction SilentlyContinue
        }
    }
    return $ended.ToArray()
}
