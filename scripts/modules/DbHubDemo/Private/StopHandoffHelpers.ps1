# stop-demo.ps1 during a Run all session (2026-11-22, the coordinator's decision for the owner, who can reverse it): the
# session's stop goes to the session control, as Stop now's does, so one stop path ends a session. The control's DbHub-Stop
# job (Scope All, -RequestedBy stop-demo.ps1) marks the stop begun, which keeps a re-check's export of the session's evidence
# apart from the stop's own on the T2 host, and saves the session's metrics and its stopped status, as Stop now does.
# stop-demo.ps1 waits for it, says what it did, and then does what it doesn't cover (Stop-DemoEnvironment). When the control
# can't take it, the stop goes on as before, with a Warning that names the risk. A Contributor may start the job; no role is
# assigned for it. Right before the job (review of f5972d2d), the session's auto-stop and its backup go, and the control's
# jobs are read again, so no second stop of the session starts beside this one, and the T2 host's password Run Command is
# waited for, which the T2 host may still be deleting.
# - Job - Create: https://learn.microsoft.com/rest/api/automation/job/create
# - Job - Get: https://learn.microsoft.com/rest/api/automation/job/get
# - Job - Get Output: https://learn.microsoft.com/rest/api/automation/job/get-output
# - Job - List By Automation Account: https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
# - Runbook - Get Content: https://learn.microsoft.com/rest/api/automation/runbook/get-content
# - Schedule - Get: https://learn.microsoft.com/rest/api/automation/schedule/get
# - Virtual Machine Run Commands - List By Virtual Machine:
#   https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine

$script:StopHandoffCheckId = 'STOP.CONTROL.SESSION'
$script:StopHandoffDoc = 'https://learn.microsoft.com/rest/api/automation/job/create'
# How stop-demo.ps1 tells that the published DbHub-Stop knows -RequestedBy (2026-11-22): the parameter's declaration, in
# automation/runbooks/DbHub-Stop.ps1 and in Invoke-DbHubStop, which must match.
$script:StopHandoffRunbookToken = "[ValidateSet('Auto-stop', 'stop-demo.ps1')]"

function Get-DemoStopHandoffSession {
    <#
    .SYNOPSIS
    Whether a Run all session runs now, for stop-demo.ps1's handoff (2026-11-22): Applies, Reason, SessionId (the demo
    resource group's DbHubSessionId tag), AutoStopUtc, and Error. Read-only; never throws. Internal.

    .DESCRIPTION
    Read from the session's busy marker (DbHubBusyBy session, while it's ahead), which its start sets and its stop clears, and
    from its own auto-stop, the one-time schedule dbhub-autostop that its start created:
    - NoSession: no session's busy marker is active, so nothing is read in the control.
    - Session: the marker is active, and the session's auto-stop is still to come: its stop goes to the control.
    - Ended: the marker is active, but the auto-stop is gone or its time has passed: the session's own stop began (Stop now,
      or its auto-stop) or ran.
    - StartDemo: the auto-stop to come is start-demo.ps1's, whose session has no re-check to keep apart.
    - Unknown: the auto-stop couldn't be read (Error says why).
    With -AutoStopCleared, this stop removed the session's auto-stop itself (Invoke-DemoStopHandoff, review of f5972d2d), so
    the marker alone tells: Session or NoSession.
    https://learn.microsoft.com/rest/api/automation/schedule/get
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [datetime] $NowUtc = [DateTime]::UtcNow,

        [switch] $AutoStopCleared
    )

    $now = if ($NowUtc.Kind -eq [System.DateTimeKind]::Local) { $NowUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc) }
    $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
    $session = [string](Get-DemoMemberValue -InputObject $tags -Name 'DbHubSessionId')
    if ($session -cnotmatch '^[0-9a-f]{32}$') {
        $session = ''
    }
    $answer = { param([bool] $Applies, [string] $Reason, [object] $AutoStopUtc, [string] $Problem) [pscustomobject]@{ Applies = $Applies; Reason = $Reason; SessionId = $session; AutoStopUtc = $AutoStopUtc; Error = $Problem } }
    $marker = ConvertTo-DemoBusyMarker -Tags $tags -NowUtc $now
    if (-not $marker.Active -or [string]$marker.By -ne 'session') {
        return (& $answer $false 'NoSession' $null '')
    }
    if ($AutoStopCleared) {
        return (& $answer $true 'Session' $null '')
    }
    try {
        $autoStop = Get-DemoActivityControlAutoStopState -Name (Get-DemoActivityControlName -Config $Config)
    }
    catch {
        return (& $answer $false 'Unknown' $null (Protect-DemoText -Text $_.Exception.Message))
    }
    if (-not $autoStop.Ok) {
        return (& $answer $false 'Unknown' $null ([string]$autoStop.Error))
    }
    if ($autoStop.Exists -and [bool]$autoStop.StartDemo) {
        return (& $answer $false 'StartDemo' $autoStop.StartUtc '')
    }
    if (-not $autoStop.Exists -or $null -eq $autoStop.StartUtc -or $autoStop.StartUtc -le $now) {
        return (& $answer $false 'Ended' $autoStop.StartUtc '')
    }
    return (& $answer $true 'Session' $autoStop.StartUtc '')
}

function Wait-DemoStopHandoffJob {
    <#
    .SYNOPSIS
    stop-demo.ps1's wait for the session control's jobs before its handoff (2026-11-22): a DbHub-Stop job (the session's
    auto-stop or its backup) or a DbHub-Control job (Run all's start, or the notebook's or the Insights app's Stop now) that's
    queued or running would stop the session, or start it, beside this stop, so it's waited for, up to -WaitSeconds, polling
    every -PollSeconds, and never stopped. Returns Ok, Error, Waited (seconds), Before (the jobs it found first), and Active
    (those still queued or running at the end), each with Runbook, Id, and Status. Internal.
    https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name,

        [ValidateRange(0, 3600)]
        [int] $WaitSeconds = 600,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 30
    )

    $control = $Name
    $runbooks = @($Name.StopRunbook, $Name.ControlRunbook)
    $read = {
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($runbook in $runbooks) {
            $jobs = Get-DemoActivityControlActiveJob -Name $control -Runbook $runbook
            if (-not $jobs.Ok) {
                return [pscustomobject]@{ Ok = $false; Error = [string]$jobs.Error; Jobs = @() }
            }
            foreach ($job in @($jobs.Jobs)) {
                $found.Add([pscustomobject]@{ Runbook = $runbook; Id = [string]$job.Id; Status = [string]$job.Status })
            }
        }
        return [pscustomobject]@{ Ok = $true; Error = ''; Jobs = $found.ToArray() }
    }
    $state = & $read
    $before = @($state.Jobs)
    $waited = 0
    while ($state.Ok -and @($state.Jobs).Count -gt 0 -and $waited -lt $WaitSeconds) {
        if ($waited -eq 0) {
            Write-DemoLog -Level Info -Message ('The session control''s job {0} is {1}: stop-demo.ps1 waits up to {2} minutes for it to finish, and never stops it.' -f (@($state.Jobs | ForEach-Object { '{0} ({1})' -f $_.Runbook, $_.Id }) -join ' and '), (@($state.Jobs | ForEach-Object { $_.Status } | Select-Object -Unique) -join ' and '), [Math]::Round($WaitSeconds / 60.0, 1))
        }
        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
        $state = & $read
    }
    return [pscustomobject]@{ Ok = $state.Ok; Error = $state.Error; Waited = $waited; Before = $before; Active = @($state.Jobs) }
}

function Wait-DemoStopHandoffHostPassword {
    <#
    .SYNOPSIS
    stop-demo.ps1's wait for the T2 host's password Run Command before its handoff's job (review of f5972d2d). The host
    password's rotation, right before the handoff, runs its own Run Command, DbHubDemo-HostPassword, and waits for its
    delete 180 seconds at most (not at all under a fresh name), while the T2 host's deletes took 6 to 11 minutes on
    2026-11-13. The host takes one Run Command at a time, so the stop's export of T2's evidence could run beside that
    delete. This waits, up to -WaitSeconds, polling every -PollSeconds, until the host lists none of them less than an hour
    old: by the time at the end of a fresh name, or else by its instance view's start; one whose age isn't known counts.
    Returns Waited (seconds), Left (the names still listed), and Result: $null, or a Warning (STOP.CONTROL.HOSTPASSWORD)
    when the wait reached its bound or the host's Run Commands couldn't be read. Read-only. Internal.
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 3600)]
        [int] $WaitSeconds = 720,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20
    )

    $vm = Get-DemoHostVmName -Config $Config
    $read = {
        $list = Get-DemoVmRunCommandLeftover -Config $Config -VmName $vm -IncludeDeleting
        if (-not $list.Ok) {
            return [pscustomobject]@{ Ok = $false; Error = [string]$list.Error; Names = @() }
        }
        $now = [DateTime]::UtcNow
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $recent = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($list.Items)) {
            $name = [string]$item.Name
            if ($name -cne 'DbHubDemo-HostPassword' -and -not $name.StartsWith('DbHubDemo-HostPassword-', [System.StringComparison]::Ordinal)) {
                continue
            }
            $at = $null
            $stamp = [DateTime]::MinValue
            if ($name -match '-(\d{14})$' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$stamp)) {
                $at = $stamp
            }
            elseif ($null -ne (Get-DemoMemberValue -InputObject $item -Name 'StartUtc')) {
                $at = [datetime]$item.StartUtc
            }
            if ($null -eq $at -or $at.AddHours(1) -gt $now) {
                $recent.Add($name)
            }
        }
        return [pscustomobject]@{ Ok = $true; Error = ''; Names = $recent.ToArray() }
    }
    $state = & $read
    $polls = 0
    $maxPolls = [int][Math]::Ceiling($WaitSeconds / [double]$PollSeconds)
    while ($state.Ok -and @($state.Names).Count -gt 0 -and $polls -lt $maxPolls) {
        if ($polls -eq 0) {
            Write-DemoLog -Level Info -Message ('{0} still lists {1} from the host password''s rotation: stop-demo.ps1 waits up to {2} minutes for its delete before the stop exports T2''s evidence there, since the T2 host takes one Run Command at a time.' -f $vm, (@($state.Names) -join ' and '), [Math]::Round($WaitSeconds / 60.0, 1))
        }
        Start-Sleep -Seconds $PollSeconds
        $polls++
        $state = & $read
    }
    $waited = $polls * $PollSeconds
    $doc = 'https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine'
    $after = 'Nothing to do: what the export couldn''t fetch there stays on the VMs, STOP.RCA.PENDING says so, and the next session''s start fetches it.'
    $evidence = [ordered]@{ vmName = $vm; waitedSeconds = $waited; left = @($state.Names) }
    $result = $null
    if (-not $state.Ok) {
        $result = New-DemoResult -CheckId 'STOP.CONTROL.HOSTPASSWORD' -Area 'workload' -Target 'T2' -Status 'Warning' -Message ('{0}''s Run Commands couldn''t be read ({1}), so whether it''s still deleting the host password''s DbHubDemo-HostPassword isn''t known: the stop''s export of T2''s evidence may run beside that delete, since the T2 host takes one Run Command at a time.' -f $vm, (Protect-DemoText -Text $state.Error)) -Evidence $evidence -Remediation $after -DocUrl $doc
    }
    elseif (@($state.Names).Count -gt 0) {
        $result = New-DemoResult -CheckId 'STOP.CONTROL.HOSTPASSWORD' -Area 'workload' -Target 'T2' -Status 'Warning' -Message ('{0} still listed {1} from the host password''s rotation after {2} minutes, so the stop''s export of T2''s evidence may run beside its delete: the T2 host takes one Run Command at a time.' -f $vm, (@($state.Names) -join ' and '), [Math]::Round($waited / 60.0, 1)) -Evidence $evidence -Remediation $after -DocUrl $doc
    }
    elseif ($polls -gt 0) {
        Write-DemoLog -Level Info -Message ('{0}''s host password Run Command was deleted after about {1} seconds; the stop goes on.' -f $vm, $waited)
    }
    return [pscustomobject]@{ Waited = $waited; Left = @($state.Names); Result = $result }
}

function Test-DemoStopHandoffRunbook {
    <#
    .SYNOPSIS
    Whether the session control's published DbHub-Stop knows -RequestedBy (2026-11-22): its content has the parameter's
    declaration. Returns Current ($true, $false, or $null when it couldn't be read) and Error. An older one stops a session
    for stop-demo.ps1 all the same, as its auto-stop. Read-only; never throws. Internal.
    https://learn.microsoft.com/rest/api/automation/runbook/get-content
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    try {
        $url = Get-DemoActivityControlUrl -Id ('{0}/runbooks/{1}/content' -f $Name.AutomationAccountId, $Name.StopRunbook) -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Automation/automationAccounts')
        $read = Invoke-DemoActivityControlArm -SubscriptionId $Name.SubscriptionId -Method get -Url $url
    }
    catch {
        return [pscustomobject]@{ Current = $null; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
    if (-not $read.Ok) {
        return [pscustomobject]@{ Current = $null; Error = [string]$read.Error }
    }
    # A runbook's content is PowerShell, not JSON, so it comes back as text.
    $text = if ($read.Value -is [string]) { [string]$read.Value } else { '' }
    return [pscustomobject]@{ Current = $text.Contains($script:StopHandoffRunbookToken); Error = '' }
}

function ConvertTo-DemoStopHandoffResult {
    <#
    .SYNOPSIS
    STOP.CONTROL.SESSION and the stop's RCA lines (STOP.RCA.EXPORT, STOP.RCA.CAPTURE.<target>, STOP.RCA.PENDING) from the
    result line of the DbHub-Stop job that stopped a Run all session for stop-demo.ps1 (2026-11-22). Pass when it stopped
    everything, a Warning with what it couldn't; its RCA lines with their status, Info as Pass, and never a Fail, since
    evidence never fails a stop. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Line,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [AllowEmptyString()]
        [string] $JobId = '',

        [ValidateRange(0, 86400)]
        [int] $Seconds = 0,

        [bool] $Current = $true,

        [AllowEmptyString()]
        [string] $RunbookError = ''
    )

    $texts = { param([object] $Value) @(@($Value) | Where-Object { $null -ne $_ -and [string]$_ } | ForEach-Object { Protect-DemoText -Text ([string]$_) }) }
    $done = @(& $texts $Line['done'])
    $failed = @(& $texts $Line['failed'])
    $who = if ($SessionId) { 'A Run all session ({0})' -f $SessionId.Substring(0, 8) } else { 'A Run all session' }
    $took = if ($Seconds -lt 90) { 'about a minute' } else { 'about {0} minutes' -f [int][Math]::Round($Seconds / 60.0, [System.MidpointRounding]::AwayFromZero) }
    # Only a DbHub-Stop that knows -RequestedBy is known to keep its export apart from the re-checks (review of f5972d2d):
    # an older one may be from before that fence (242a3ef7).
    $apart = if ($Current) { ', which keeps the stop''s export of the session''s evidence apart from the session''s re-checks' } else { '' }
    $message = '{0} was running, so its stop went to the session control, as Stop now''s does{1}: its DbHub-Stop job {2} took {3}: {4}.' -f $who, $apart, $JobId, $took, $(if ($done.Count) { $done -join ', ' } else { 'nothing to stop' })
    if ($failed.Count -gt 0) {
        $message += ' It couldn''t: {0}; stop-demo.ps1 stops what''s left below.' -f ($failed -join ', ')
    }
    $message += ' The activity profiles weren''t set to off, and T2''s guest wasn''t shut down first: the VMs'' deallocation ends both, as with Stop now.'
    $lines = @(@($Line['rcaLines']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['step'] -match '^RCA(\.[A-Za-z0-9_-]+)+$' })
    $rca = $Line['rca']
    if ($lines.Count -eq 0 -and $rca -is [System.Collections.IDictionary] -and [string]$rca['message']) {
        $message += ' The evidence''s export: {0}' -f (Protect-DemoText -Text ([string]$rca['message']))
    }
    if (-not $Current) {
        if ($RunbookError) {
            $message += ' The published DbHub-Stop''s content couldn''t be read ({0}), so its job ran without -RequestedBy, as the session''s auto-stop: its status says the auto-stop stopped it, and whether its export of the session''s evidence was kept apart from the session''s re-checks isn''t known. ./scripts/deploy.ps1 republishes the runbooks; from then on, it is.' -f (Protect-DemoText -Text $RunbookError).TrimEnd('.')
        }
        else {
            $message += ' Its status says the session''s auto-stop stopped it, and its export of the session''s evidence may have run beside a re-check''s: the published DbHub-Stop is from before 2026-11-22. ./scripts/deploy.ps1 republishes it; from then on, the stop''s export is kept apart from the session''s re-checks.'
        }
    }
    $evidence = [ordered]@{ sessionId = $SessionId; jobId = $JobId; seconds = $Seconds; status = [string]$Line['status']; done = $done; failed = $failed; t5Status = [string]$Line['t5Status']; runbookCurrent = $Current; runbookError = $RunbookError }
    $status = if ($failed.Count -gt 0) { 'Warning' } else { 'Pass' }
    $fix = if ($failed.Count -gt 0) { './scripts/status.ps1 shows what still runs; ./scripts/stop-demo.ps1 again stops it.' } else { '' }
    New-DemoResult -CheckId $script:StopHandoffCheckId -Area 'workload' -Target 'subscription' -Status $status -Message $message -Evidence $evidence -Remediation $fix -DocUrl $script:StopHandoffDoc
    foreach ($item in $lines) {
        $step = [string]$item['step']
        $checkId = 'STOP.{0}' -f $step.ToUpperInvariant().Replace('-', '_')
        $target = 'subscription'
        if ($step -match '^RCA\.CAPTURE\.(T[1-5])') {
            $target = $Matches[1]
        }
        $lineStatus = if ([string]$item['status'] -in 'Warning', 'Fail') { 'Warning' } else { 'Pass' }
        New-DemoResult -CheckId $checkId -Area 'workload' -Target $target -Status $lineStatus -Message (Protect-DemoText -Text ([string]$item['message'])) -Remediation (Protect-DemoText -Text ([string]$item['fix'])) -DocUrl $script:RcaRunCommandDoc
    }
}

function Invoke-DemoStopHandoff {
    <#
    .SYNOPSIS
    stop-demo.ps1's handoff of a Run all session's stop to the session control (2026-11-22). Returns Outcome (None, Stopped,
    Fallback, or Running), Results (STOP.CONTROL.SESSION, the stop's RCA lines, and STOP.CONTROL.HOSTPASSWORD when it
    applies; nothing with None, until the wait for the host password's Run Command), State (the demo resource group's
    state, read again after the control's stop), PostgresHistory (T4's and its replica's metrics, read with -SaveHistory
    before the stop deletes the replica), T3, TuningRelease (the Database Agent beat's hold, released through T3 from T1
    before the stop deallocates it), and AutoStop (STOP.CONTROL.AUTOSTOP, once this removed the session's auto-stop, which
    stop-demo.ps1 then reports instead of removing it again). Internal.

    .DESCRIPTION
    - None: no Run all session runs (Get-DemoStopHandoffSession), or its own stop began or ran; stop-demo.ps1 stops the demo
      itself, as before. A job of the control's that's queued or running is waited for first (Wait-DemoStopHandoffJob), up to
      -JobWaitMinutes, so this stop never runs beside it.
    - Stopped: the control's DbHub-Stop job (Scope All, Job - Create) stopped the session, as its auto-stop does, with
      -RequestedBy stop-demo.ps1 when the published runbook knows it (Test-DemoStopHandoffRunbook); its result line
      (Get-DemoSafetyStopJobResult) gives STOP.CONTROL.SESSION and the stop's RCA lines (ConvertTo-DemoStopHandoffResult).
      A job that completed with a result that can't be read, read twice, is Stopped too, with a Warning that says so.
      stop-demo.ps1 then does what that stop doesn't cover: Bastion and the host password come first, and after it, the VMs',
      T4's, and T5's container's stops are confirmed, the nightly stop is settled, the history is saved with -SaveHistory, and
      the Fabric capacity is paused, as before.
    - Fallback: the control couldn't take it (its state or jobs couldn't be read, the job couldn't be created, or it ended
      without stopping the session): a Warning that names the risk, and stop-demo.ps1 stops the demo itself, as before.
    - Running: a stop job of the control's, this one or the session's own, is still running after the wait: a Warning, and
      stop-demo.ps1 stops nothing under it.
    Right before the job (review of f5972d2d): the T2 host's password Run Command is waited for, up to
    -HostPasswordWaitMinutes (Wait-DemoStopHandoffHostPassword); the session's auto-stop and its backup are removed
    (Clear-DemoActivityControlAutoStop), so neither starts a second stop while this job is queued or runs; and the
    control's jobs and the session's busy marker are read again, so a stop that started meanwhile goes first, and a session
    it stopped is None. The runbook keeps one stop's part of the session either way (Resolve-DbHubStopClaim).
    https://learn.microsoft.com/rest/api/automation/job/create
    https://learn.microsoft.com/rest/api/automation/job/get
    https://learn.microsoft.com/rest/api/automation/job/get-output
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [switch] $SaveHistory,

        [ValidateRange(15, 10080)]
        [int] $SaveHistoryWindowMinutes = 720,

        [ValidateRange(1, 120)]
        [int] $WaitMinutes = 40,

        [ValidateRange(0, 60)]
        [int] $JobWaitMinutes = 10,

        [ValidateRange(0, 60)]
        [int] $HostPasswordWaitMinutes = 12,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20
    )

    $answer = [pscustomobject]@{ Outcome = 'None'; Results = @(); State = $State; PostgresHistory = $null; T3 = $null; TuningRelease = $null; AutoStop = $null }
    $session = Get-DemoStopHandoffSession -Config $Config -State $State
    if ($session.Reason -in 'NoSession', 'StartDemo') {
        return $answer
    }
    $name = Get-DemoActivityControlName -Config $Config
    $who = { if ($session.SessionId) { 'A Run all session ({0})' -f $session.SessionId.Substring(0, 8) } else { 'A Run all session' } }
    $evidence = [ordered]@{ sessionId = $session.SessionId; reason = [string]$session.Reason; jobId = ''; account = $name.AutomationAccount }
    # What every outcome after it reports too: STOP.CONTROL.HOSTPASSWORD.
    $notes = [System.Collections.Generic.List[object]]::new()
    $fallback = {
        param([string] $Why)
        $answer.Outcome = 'Fallback'
        $message = '{0} runs, but its stop couldn''t go to the session control ({1}), so stop-demo.ps1 stops the demo itself, as before 2026-11-22: the stop isn''t marked begun, so a re-check that''s exporting the session''s evidence goes on beside this stop''s own export on the T2 host, which takes one Run Command at a time, and the control doesn''t save the session''s metrics or say it stopped.' -f (& $who), $Why.TrimEnd('.')
        Write-DemoLog -Level Warning -Message $message
        $answer.Results = @($notes.ToArray()) + @(New-DemoResult -CheckId $script:StopHandoffCheckId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('While a session runs, Stop now in {0} stops it through the session control; ./scripts/status.ps1 says whether the control answers (STATUS.CONTROL).' -f $name.Notebook) -DocUrl $script:StopHandoffDoc)
        return $answer
    }
    $running = {
        param([string] $Job, [string] $Status, [int] $Seconds)
        $answer.Outcome = 'Running'
        $evidence['jobId'] = $Job
        $message = '{0} was running, and the session control''s stop job {1} is still {2} after {3} minutes, so stop-demo.ps1 stops nothing under it: the job goes on and stops the demo.' -f (& $who), $Job, $Status, [int][Math]::Round($Seconds / 60.0)
        Write-DemoLog -Level Warning -Message $message
        $answer.Results = @($notes.ToArray()) + @(New-DemoResult -CheckId $script:StopHandoffCheckId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('Run ./scripts/stop-demo.ps1 again once it has finished (the Automation account {0}, Process Automation > Jobs): it does the rest.' -f $name.AutomationAccount) -DocUrl 'https://learn.microsoft.com/rest/api/automation/job/get')
        return $answer
    }
    if ($session.Reason -eq 'Unknown') {
        return (& $fallback ('whether the session still runs couldn''t be read there: {0}' -f $session.Error))
    }
    # A job of the control's that's queued or running now goes first: the session's auto-stop, Stop now, or Run all's start.
    $jobs = Wait-DemoStopHandoffJob -Name $name -WaitSeconds ($JobWaitMinutes * 60) -PollSeconds $PollSeconds
    if (-not $jobs.Ok) {
        return (& $fallback ('its jobs couldn''t be read: {0}' -f $jobs.Error))
    }
    $stopJob = @($jobs.Active | Where-Object { $_.Runbook -eq $name.StopRunbook }) | Select-Object -First 1
    if ($null -ne $stopJob) {
        return (& $running $stopJob.Id $stopJob.Status $jobs.Waited)
    }
    if (@($jobs.Before).Count -gt 0) {
        # What ran first may have stopped the session, or started it.
        $State = Get-DemoDeploymentState -Config $Config
        $answer.State = $State
        $session = Get-DemoStopHandoffSession -Config $Config -State $State
        $evidence['reason'] = [string]$session.Reason
        if ($session.Reason -eq 'Unknown') {
            return (& $fallback ('whether the session still runs couldn''t be read there: {0}' -f $session.Error))
        }
    }
    if ($session.Reason -ne 'Session') {
        if ($session.Reason -eq 'Ended') {
            Write-DemoLog -Message 'The Run all session''s own stop began or ran already, so stop-demo.ps1 stops what''s left itself.'
        }
        return $answer
    }

    # Before the control's stop deallocates the VMs and deletes T4's read replica: the replica's metrics, for -SaveHistory,
    # and the Database Agent beat's hold on T3, released through T3 from T1 (Invoke-DemoT3AutoTuningRelease), as before.
    if ($SaveHistory -and (Test-DemoT4Enabled -Config $Config) -and (Test-DemoT4ReplicaSetUp -State $State)) {
        $answer.PostgresHistory = Get-DemoPostgresHistoryCapture -Config $Config -WindowMinutes $SaveHistoryWindowMinutes
    }
    $deploymentId = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $State -Name 'Tags') -Name 'deploymentId')
    $answer.T3 = Get-DemoT3State -Config $Config -DeploymentId $deploymentId
    $answer.TuningRelease = Invoke-DemoT3AutoTuningRelease -Config $Config -T3 $answer.T3 -DeploymentId $deploymentId

    $runbook = Test-DemoStopHandoffRunbook -Name $name
    $parameters = [ordered]@{ Scope = 'All' }
    if ($runbook.Current -eq $true) {
        $parameters['RequestedBy'] = 'stop-demo.ps1'
    }
    if (-not $PSCmdlet.ShouldProcess($name.StopRunbook, ('Stop the Run all session through the session control''s {0} job' -f $name.StopRunbook))) {
        $answer.Results = @(New-DemoResult -CheckId $script:StopHandoffCheckId -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} runs, and its stop would go to the session control''s {1} job.' -f (& $who), $name.StopRunbook) -Evidence $evidence -DocUrl $script:StopHandoffDoc)
        return $answer
    }
    # The host password's rotation, right before the handoff, ran its own Run Command, which the T2 host may still be
    # deleting (review of f5972d2d).
    $hostWait = Wait-DemoStopHandoffHostPassword -Config $Config -WaitSeconds ($HostPasswordWaitMinutes * 60) -PollSeconds $PollSeconds
    if ($null -ne $hostWait.Result) {
        $notes.Add($hostWait.Result)
    }
    # Right before the job (review of f5972d2d): the session's auto-stop and its backup go, so neither starts a second stop
    # while this job is queued or runs; then the control's jobs and the session's marker are read again, so a stop that
    # started meanwhile goes first, and a session it stopped is left to it.
    $answer.AutoStop = Clear-DemoActivityControlAutoStop -Config $Config -Confirm:$false
    $again = Wait-DemoStopHandoffJob -Name $name -WaitSeconds ($JobWaitMinutes * 60) -PollSeconds $PollSeconds
    if (-not $again.Ok) {
        return (& $fallback ('its jobs couldn''t be read: {0}' -f $again.Error))
    }
    $stopJob = @($again.Active | Where-Object { $_.Runbook -eq $name.StopRunbook }) | Select-Object -First 1
    if ($null -ne $stopJob) {
        return (& $running $stopJob.Id $stopJob.Status $again.Waited)
    }
    $State = Get-DemoDeploymentState -Config $Config
    $answer.State = $State
    $session = Get-DemoStopHandoffSession -Config $Config -State $State -AutoStopCleared
    $evidence['reason'] = [string]$session.Reason
    if ($session.Reason -ne 'Session') {
        Write-DemoLog -Message 'The Run all session''s own stop ran meanwhile, so stop-demo.ps1 stops what''s left itself.'
        $answer.Results = $notes.ToArray()
        return $answer
    }
    $jobName = [guid]::NewGuid().ToString()
    $url = Get-DemoActivityControlUrl -Id ('{0}/jobs/{1}' -f $name.AutomationAccountId, $jobName) -ApiVersion (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Automation/automationAccounts')
    $created = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method put -Url $url -Body ([ordered]@{ properties = [ordered]@{ runbook = [ordered]@{ name = $name.StopRunbook }; parameters = $parameters } })
    if (-not $created.Ok) {
        return (& $fallback ('its {0} job couldn''t be created: {1}' -f $name.StopRunbook, $created.Error))
    }
    $properties = Get-DemoMemberValue -InputObject $created.Value -Name 'properties'
    $jobId = [string](Get-DemoMemberValue -InputObject $properties -Name 'jobId')
    if (-not $jobId) {
        $jobId = $jobName
    }
    $evidence['jobId'] = $jobId
    $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
    Write-DemoLog -Message ('{0} runs: its stop goes to the session control, as Stop now''s does (job {1}); stop-demo.ps1 waits up to {2} minutes for it.' -f (& $who), $jobId, $WaitMinutes)
    $exception = ''
    $polls = 0
    $maxPolls = [int][Math]::Ceiling($WaitMinutes * 60.0 / $PollSeconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($status -notin $script:T4StopJobEndedStatuses -and $polls -lt $maxPolls) {
        Start-Sleep -Seconds $PollSeconds
        $polls++
        $read = Invoke-DemoActivityControlArm -SubscriptionId $name.SubscriptionId -Method get -Url $url
        if ($read.Ok) {
            $properties = Get-DemoMemberValue -InputObject $read.Value -Name 'properties'
            $status = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
            $exception = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $properties -Name 'exception'))
        }
    }
    $seconds = [int][Math]::Max($watch.Elapsed.TotalSeconds, $polls * $PollSeconds)
    if ($status -notin $script:T4StopJobEndedStatuses) {
        return (& $running $jobId $(if ($status) { $status } else { 'not read' }) $seconds)
    }
    $line = Get-DemoSafetyStopJobResult -Name $name -JobName $jobName
    if ($null -eq $line -and $status -eq 'Completed') {
        # A job's output can come a little after its end (review of f5972d2d): read once more.
        Start-Sleep -Seconds $PollSeconds
        $line = Get-DemoSafetyStopJobResult -Name $name -JobName $jobName
    }
    if ($null -eq $line -and $status -eq 'Completed') {
        # It ran to its end, so it's the control's stop all the same: what it did is confirmed below.
        $answer.Outcome = 'Stopped'
        $took = if ($seconds -lt 90) { 'about a minute' } else { 'about {0} minutes' -f [int][Math]::Round($seconds / 60.0, [System.MidpointRounding]::AwayFromZero) }
        $message = '{0} was running, so its stop went to the session control, as Stop now''s does: its DbHub-Stop job {1} completed after {2}, but ended without a readable result, so what it stopped isn''t known here: stop-demo.ps1 confirms each stop below.' -f (& $who), $jobId, $took
        Write-DemoLog -Level Warning -Message $message
        $answer.Results = @($notes.ToArray()) + @(New-DemoResult -CheckId $script:StopHandoffCheckId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation ('Its output is in the Automation account {0} (Process Automation > Jobs, the job {1}, Output); ./scripts/status.ps1 shows what still runs.' -f $name.AutomationAccount, $jobId) -DocUrl 'https://learn.microsoft.com/rest/api/automation/job/get-output')
        $answer.State = Get-DemoDeploymentState -Config $Config
        return $answer
    }
    $lineStatus = [string](Get-DemoMemberValue -InputObject $line -Name 'status')
    if ($lineStatus -notin 'Stopped', 'Partial') {
        $why = if ($null -ne $line) { 'its job {0} ended {1}: {2}' -f $jobId, $(if ($lineStatus) { $lineStatus } else { $status }), (Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $line -Name 'message'))) } else { 'its job {0} ended {1} with no result{2}' -f $jobId, $status, $(if ($exception) { ': ' + $exception } else { '' }) }
        return (& $fallback $why)
    }
    $answer.Outcome = 'Stopped'
    $answer.Results = @($notes.ToArray()) + @(ConvertTo-DemoStopHandoffResult -Line $line -SessionId $session.SessionId -JobId $jobId -Seconds $seconds -Current ($runbook.Current -eq $true) -RunbookError $(if ($null -eq $runbook.Current) { [string]$runbook.Error } else { '' }))
    $answer.State = Get-DemoDeploymentState -Config $Config
    return $answer
}
