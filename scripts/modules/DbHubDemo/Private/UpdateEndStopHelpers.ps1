# deploy.ps1's stop at the end of an update (2026-11-19, the coordinator's decision for the owner, who can reverse it): an
# update leaves the demo as it found it. When the demo was stopped when the run began (the nightly stop, stop-demo.ps1, or
# a session's auto-stop had stopped it), a run that ends DONE stops again what it started, through stop-demo.ps1's own stop
# path (Stop-DemoEnvironment -SkipFabric). A new deployment, a demo that was running, a session that started meanwhile,
# and deploy.ps1 -KeepRunning keep it running, and DONE says what it bills an hour and until when. The stop never makes a
# run NOT DONE: its record, DEPLOY.ENDSTOP, is Pass, Warning, or Not selected, and the status page's EndStop row shows it.
# Sources (checked 2026-11-19):
# - Stop a VM to stop its compute billing (deallocated): https://learn.microsoft.com/azure/virtual-machines/states-billing
# - Stop an Azure Database for PostgreSQL flexible server: https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server
# - Migration assessment of SQL Server enabled by Azure Arc: https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment

$script:UpdateEndStopCheckId = 'DEPLOY.ENDSTOP'
$script:UpdateEndStopRowId = 'EndStop'
$script:UpdateEndStopDoc = 'https://learn.microsoft.com/azure/virtual-machines/states-billing'

function Get-DemoUpdateStopPlan {
    <#
    .SYNOPSIS
    Whether deploy.ps1's end stops what the run started (2026-11-19), from the run's results and its progress model. Pure.
    Internal.

    .DESCRIPTION
    It applies only to a run that ended DONE, updated an existing environment, and found its demo stopped: this run's
    DEPLOY.VMSTART (Wait-DemoStoppedStart) says the run started what was stopped, and no demo VM ran or was starting when
    it began. Returns Applies, Reason, Text (why not, as a sentence), Started (what this run started: VMs, and T4), and
    Running (the VMs that ran when it began). Reason is one of:
    - Stopped: Ctrl+C, before the run's end. WhatIf: a what-if. NotDone: the run didn't end DONE, so the next deploy.ps1
      needs what it started.
    - NewDeployment: no DEPLOY.VMSTART, and the progress model says this run created the VMs; it keeps running, so the
      person can look at it now.
    - NothingStopped: no DEPLOY.VMSTART otherwise, or nothing this run started: the demo was running when it began.
    - WasRunning: a demo VM was running, or starting, when the run began, so a session may use it.
    - KeepRunning: deploy.ps1 -KeepRunning, when the stop would apply otherwise.
    - Stop: it applies.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $Model = $null,

        [AllowEmptyString()]
        [string] $OutcomeKind = '',

        [switch] $KeepRunning,

        [switch] $Stopped
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $join = { param([string[]] $Items) if ($Items.Count -le 2) { $Items -join ' and ' } else { '{0}, and {1}' -f ($Items[0..($Items.Count - 2)] -join ', '), $Items[-1] } }
    $answer = { param([bool] $Applies, [string] $Reason, [string] $Text, [string[]] $Started, [string[]] $Running) [pscustomobject]@{ Applies = $Applies; Reason = $Reason; Text = $Text; Started = @($Started); Running = @($Running) } }
    # What the run found and started, from its own DEPLOY.VMSTART; the one a preflight Fail adds (afterPreflightFail) never
    # comes with a DONE.
    $vmStart = @($all | Where-Object { [string]$_.checkId -eq 'DEPLOY.VMSTART' -and [string]$_.status -ne 'Fail' }) | Select-Object -Last 1
    $started = [System.Collections.Generic.List[string]]::new()
    $running = [System.Collections.Generic.List[string]]::new()
    $starting = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $vmStart) {
        $evidence = Get-DemoMemberValue -InputObject $vmStart -Name 'evidence'
        $issued = Get-DemoMemberValue -InputObject $evidence -Name 'started'
        foreach ($name in @($issued)) {
            if ($name -and -not $started.Contains([string]$name)) {
                $started.Add([string]$name)
            }
        }
        if ([string](Get-DemoMemberValue -InputObject $evidence -Name 't4') -eq 'Pass' -and -not $started.Contains('T4')) {
            $started.Add('T4')
        }
        $found = Get-DemoMemberValue -InputObject $evidence -Name 'running'
        foreach ($name in @($found)) {
            if ($name) {
                $running.Add([string]$name)
            }
        }
        $before = Get-DemoMemberValue -InputObject $evidence -Name 'before'
        if ($before -is [System.Collections.IDictionary]) {
            foreach ($key in @($before.Keys)) {
                if ([string]$key -ne 'T4' -and [string]$before[$key] -eq 'starting') {
                    $starting.Add([string]$key)
                }
            }
        }
    }
    $startedList = $started.ToArray()
    $runningList = $running.ToArray()
    if ($Stopped) {
        return (& $answer $false 'Stopped' 'deploy.ps1 was stopped (Ctrl+C) before its end, so what it started keeps running: ./scripts/stop-demo.ps1 stops it now, and the next ./scripts/deploy.ps1 continues the run.' $startedList $runningList)
    }
    if ($OutcomeKind -eq 'WhatIf') {
        return (& $answer $false 'WhatIf' 'What if: nothing was started, so nothing is stopped at the end.' $startedList $runningList)
    }
    if ($OutcomeKind -ne 'Done') {
        return (& $answer $false 'NotDone' 'The run isn''t DONE, so what it started keeps running for the next ./scripts/deploy.ps1, which continues it: ./scripts/stop-demo.ps1 stops it now.' $startedList $runningList)
    }
    if ($null -eq $vmStart) {
        $run = Get-DemoMemberValue -InputObject $Model -Name 'run'
        $created = Get-DemoMemberValue -InputObject $run -Name 'startedVms'
        if (@(@($created) | Where-Object { $_ }).Count -gt 0) {
            return (& $answer $false 'NewDeployment' 'A new deployment keeps running, so you can look at it now.' $startedList $runningList)
        }
        return (& $answer $false 'NothingStopped' 'Nothing was stopped when this run began, so the demo keeps running, as the run found it.' $startedList $runningList)
    }
    if ($runningList.Count -gt 0 -or $starting.Count -gt 0) {
        $parts = @()
        if ($runningList.Count -gt 0) {
            $parts += '{0} {1} running' -f (& $join $runningList), $(if ($runningList.Count -eq 1) { 'was' } else { 'were' })
        }
        if ($starting.Count -gt 0) {
            $parts += '{0} {1} starting' -f (& $join $starting.ToArray()), $(if ($starting.Count -eq 1) { 'was' } else { 'were' })
        }
        return (& $answer $false 'WasRunning' ('{0} when this run began, so a session may use the demo, and it keeps running, as the run found it.' -f ($parts -join ', and ')) $startedList $runningList)
    }
    if ($startedList.Count -eq 0) {
        return (& $answer $false 'NothingStopped' 'This run started nothing that was stopped, so the demo stays as the run found it.' $startedList $runningList)
    }
    if ($KeepRunning) {
        return (& $answer $false 'KeepRunning' ('-KeepRunning: what this run started ({0}) keeps running.' -f (& $join $startedList)) $startedList $runningList)
    }
    return (& $answer $true 'Stop' '' $startedList $runningList)
}

function Get-DemoUpdateStopHoldText {
    # Why the stop at the end of an update leaves the demo running for a session (Get-DemoUpdateStopSession's answer), with
    # its auto-stop's time in the VMs' time zone. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Hold
    )

    $by = [string]$Hold.By
    if ($by -eq 'Unknown') {
        return ('Whether a session uses the demo couldn''t be read ({0}), so this run leaves it running: ./scripts/stop-demo.ps1 stops it when no session runs.' -f ([string]$Hold.Error).TrimEnd('.'))
    }
    $when = ''
    $untilUtc = Get-DemoMemberValue -InputObject $Hold -Name 'UntilUtc'
    if ($null -ne $untilUtc) {
        $shutdown = Get-DemoAutoShutdownSetting -Config $Config
        $when = ' at {0} ({1})' -f (Get-DemoBusyLocalTime -Utc ([datetime]$untilUtc) -Zone $shutdown.Zone).Text, $shutdown.TimeZoneId
    }
    if ($by -eq 'StartDemo') {
        if (-not $when) {
            # Its start, with no auto-stop (no session control role): DbHubStartDemoUtc (2026-11-19).
            return 'A start-demo.ps1 session started while this update ran, so the run leaves the demo running for it: ./scripts/stop-demo.ps1 stops it when the session ends, or the nightly stop does.'
        }
        return ('A start-demo.ps1 session uses the demo, so this run leaves it running: its auto-stop stops it{0}, or ./scripts/stop-demo.ps1 sooner.' -f $when)
    }
    if ($by -eq 'Session') {
        return 'A session from the control notebook (Run all) is starting or running (its busy marker is set), so this run leaves the demo running: the session''s auto-stop stops it.'
    }
    if ($by -eq 'Request') {
        return ('A request to the session control (Run all, or the Insights app''s Start) runs now ({0}), so this run leaves the demo running: the session''s auto-stop stops it, or ./scripts/stop-demo.ps1 once the request is done.' -f [string](Get-DemoMemberValue -InputObject $Hold -Name 'Detail'))
    }
    return ('A session from the control notebook (Run all, or the Insights app''s Start) uses the demo, so this run leaves it running: its auto-stop stops it{0}.' -f $when)
}

function Get-DemoLastNightlyStopUtc {
    <#
    .SYNOPSIS
    The last nightly stop at or before -BeforeUtc (2026-11-19, the re-review of the stop at the end of an update): the time
    the nightly safety stop and the VMs' auto-shutdown stop the demo, autoShutdownTime in its time zone, in UTC; $null for a
    time that isn't HHmm. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [datetime] $BeforeUtc
    )

    $shutdown = Get-DemoAutoShutdownSetting -Config $Config
    $before = if ($BeforeUtc.Kind -eq [System.DateTimeKind]::Local) { $BeforeUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($BeforeUtc, [System.DateTimeKind]::Utc) }
    # Each one from two days earlier up to -BeforeUtc: daylight saving time makes a day 23 or 25 hours long.
    $last = $null
    $next = Get-DemoDailyNextUtc -Time $shutdown.Time -Zone $shutdown.Zone -AfterUtc $before.AddDays(-2)
    while ($null -ne $next -and $next -le $before) {
        $last = $next
        $next = Get-DemoDailyNextUtc -Time $shutdown.Time -Zone $shutdown.Zone -AfterUtc $next
    }
    return $last
}

function Get-DemoUpdateStopSession {
    <#
    .SYNOPSIS
    Whether a session uses the demo now, for the stop at the end of an update (2026-11-19; the review of the stop, findings
    1, 3, and 6). Returns Held, By (Control, StartDemo, Session, Request, Unknown, or ''), UntilUtc, Detail, Ignored (the
    time of a start-demo.ps1 auto-stop left from before -SinceUtc, or $null), and Error. Read-only; never throws. Internal.

    .DESCRIPTION
    Read before the end waits, again right before the stop, and in the stop before its first change and before T2's guest
    and the VMs (Stop-DemoEnvironment -UpdateEnd), so a session that starts meanwhile isn't cut off:
    - Get-DemoT4ReplicaHold: a pending auto-stop of Run all, the Insights app's Start, or start-demo.ps1, or a start-demo.ps1
      session's mark on T4's read replica. A start-demo.ps1 auto-stop from a session that started before -SinceUtc (when
      this run began, and found the demo stopped), with a nightly stop between (Get-DemoLastNightlyStopUtc), is left over:
      the nightly stop or the VMs' auto-shutdown ended that session without removing it, so it doesn't count (Ignored), and
      the stop removes it. With no nightly stop between, it counts (the re-review of 2026-11-19).
    - The resource group's tags: Run all's busy marker (DbHubBusyBy session, while it's ahead), and DbHubStartDemoUtc,
      which start-demo.ps1 sets as it starts and again once it has asked for the VMs' starts: one after -SinceUtc is a
      session that began while this run went on, with or without an auto-stop (no session control role).
    - A DbHub-Control job that's queued or running: Run all, or a request from the Insights app, on its way.
    Anything that can't be read keeps the demo running too: Held, By Unknown.
    https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $SinceUtc = $null,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $now = if ($NowUtc.Kind -eq [System.DateTimeKind]::Local) { $NowUtc.ToUniversalTime() } else { [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc) }
    $since = if ($null -ne $SinceUtc) { ConvertTo-DemoUtcDateTime -Value $SinceUtc } else { $null }
    $ignored = $null
    $answer = { param([bool] $Held, [string] $By, [object] $UntilUtc, [string] $Detail, [string] $Problem) [pscustomobject]@{ Held = $Held; By = $By; UntilUtc = $UntilUtc; Detail = $Detail; Ignored = $ignored; Error = $Problem } }
    $problems = [System.Collections.Generic.List[string]]::new()
    $tags = $null
    try {
        $tags = Get-DemoMemberValue -InputObject (Get-DemoDeploymentState -Config $Config) -Name 'Tags'
    }
    catch {
        $problems.Add(('the resource group''s tags couldn''t be read ({0})' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.')))
    }
    $deploymentId = [string](Get-DemoMemberValue -InputObject $tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    $hold = Get-DemoT4ReplicaHold -Config $Config -DeploymentId $deploymentId -StartDemoSinceUtc $since -NowUtc $now
    $ignored = Get-DemoMemberValue -InputObject $hold -Name 'Ignored'
    if ([bool]$hold.Held -and [string]$hold.By -ne 'Unknown') {
        return (& $answer $true ([string]$hold.By) $hold.UntilUtc '' '')
    }
    if ([bool]$hold.Held) {
        $problems.Add([string]$hold.Error)
    }
    if ($null -ne $tags) {
        $names = Get-DemoDeploymentStateTagName
        $started = ConvertTo-DemoUtcDateTime -Value ([string](Get-DemoMemberValue -InputObject $tags -Name $names['StartDemoUtc']))
        if ($null -ne $started -and $null -ne $since -and $started -ge $since) {
            return (& $answer $true 'StartDemo' $null ('start-demo.ps1 started at {0}' -f (ConvertTo-DemoBusyTimeText -Utc $started)) '')
        }
        $marker = ConvertTo-DemoBusyMarker -Tags $tags -NowUtc $now
        if ($marker.Active -and [string]$marker.By -eq 'session') {
            return (& $answer $true 'Session' $null '' '')
        }
    }
    try {
        $name = Get-DemoActivityControlName -Config $Config
        $jobs = Get-DemoActivityControlActiveJob -Name $name -Runbook $name.ControlRunbook
        if (-not $jobs.Ok) {
            $problems.Add(('the session control''s {0} jobs couldn''t be read ({1})' -f $name.ControlRunbook, ([string]$jobs.Error).TrimEnd('.')))
        }
        elseif (@($jobs.Jobs).Count -gt 0) {
            return (& $answer $true 'Request' $null ((@($jobs.Jobs) | ForEach-Object { '{0} job {1} {2}' -f $name.ControlRunbook, $_.Id, $_.Status }) -join '; ') '')
        }
    }
    catch {
        $problems.Add(('the session control''s jobs couldn''t be read ({0})' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.')))
    }
    if ($problems.Count -gt 0) {
        return (& $answer $true 'Unknown' $null '' (Protect-DemoText -Text ((@($problems) | Where-Object { $_ }) -join '; ')))
    }
    return (& $answer $false '' $null '' '')
}

function Get-DemoUpdateStopSessionName {
    # Who a session that uses the demo is, in a few words (Get-DemoUpdateStopSession's By). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $By
    )

    switch ($By) {
        'StartDemo' { return 'a start-demo.ps1 session' }
        'Request' { return 'a request to the session control' }
        'Unknown' { return 'maybe a session (it couldn''t be read)' }
    }
    return 'a session from the control notebook (Run all, or the Insights app''s Start)'
}

function New-DemoUpdateStopSessionResult {
    <#
    .SYNOPSIS
    STOP.SESSION (2026-11-19, the review's finding 1): Stop-DemoEnvironment -UpdateEnd found a session that uses the demo, so
    the stop ended there. -Stage Before, before its first change: Not selected, nothing was stopped. -Stage During, before
    T2's guest and the VMs: a Warning, because the demo's activity is off already, with how to start the session again.
    Pure. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [ValidateSet('Before', 'During')]
        [string] $Stage,

        [switch] $ReplicaDeleting
    )

    $text = Get-DemoUpdateStopHoldText -Config $Config -Hold $Session
    $untilUtc = Get-DemoMemberValue -InputObject $Session -Name 'UntilUtc'
    $evidence = [ordered]@{ stage = $Stage; by = [string]$Session.By; untilUtc = $(if ($null -ne $untilUtc) { ConvertTo-DemoBusyTimeText -Utc ([datetime]$untilUtc) } else { '' }); detail = [string](Get-DemoMemberValue -InputObject $Session -Name 'Detail'); error = [string](Get-DemoMemberValue -InputObject $Session -Name 'Error') }
    if ($Stage -eq 'Before') {
        return (New-DemoResult -CheckId 'STOP.SESSION' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('{0} Nothing was stopped.' -f $text) -Evidence $evidence -DocUrl $script:UpdateEndStopDoc)
    }
    $message = '{0} The stop at the end of this update ended there, before T2''s guest and the VMs, which keep running, but it had turned the demo''s activity off already{1}.' -f $text, $(if ($ReplicaDeleting) { ' and asked for T4''s read replica to be deleted' } else { '' })
    $fix = 'For the session, run ./scripts/stop-demo.ps1, then start it again (Run all in NB_DatabaseHub_Control, or ./scripts/start-demo.ps1), so it runs with its activity; with no session, ./scripts/stop-demo.ps1 stops the demo now.'
    return (New-DemoResult -CheckId 'STOP.SESSION' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $fix -DocUrl $script:UpdateEndStopDoc)
}

function Resolve-DemoUpdateStopNightly {
    <#
    .SYNOPSIS
    Stop-DemoEnvironment -UpdateEnd's last step (2026-11-19, the review's findings 2 and 4): it settles the nightly stop
    (Resolve-DemoBusyNightlyStop) only once the VMs, T4 and its read replica, and T5's container are stopped, so a stop cut
    short (Ctrl+C) or one that failed leaves tonight's stop in place (DEPLOY.NIGHTLYSTOP), which stops what still runs. T5's
    container counts as stopped once STOP.T5 deleted it, found it gone, or kept it on purpose (outcome Kept: its lifecycle
    keeps it between sessions, so the nightly stop wouldn't delete it either); a delete that failed is a Warning, which
    leaves tonight's stop to delete it (the re-review of 2026-11-19). Not while Run all's busy marker says a session started
    meanwhile. Returns STOP.NIGHTLYSTOP, or nothing. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $t5Left = {
        param([object] $Item)
        [string]$Item.status -in 'Fail', 'Warning' -and [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Item -Name 'evidence') -Name 'outcome') -ne 'Kept'
    }
    $left = @($Result | Where-Object { $null -ne $_ -and (([string]$_.checkId -like 'STOP.VM_*' -and [string]$_.status -ne 'Pass') -or ([string]$_.checkId -in 'STOP.T4.STOP', 'STOP.T4.REPLICA' -and [string]$_.status -in 'Fail', 'Warning') -or ([string]$_.checkId -eq 'STOP.T5' -and (& $t5Left $_))) })
    if ($left.Count -gt 0) {
        Write-DemoLog -Message ('Tonight''s nightly stop stays as it is, because not all of the demo stopped ({0}).' -f ((@($left) | ForEach-Object { [string]$_.checkId }) -join ', '))
        return @()
    }
    try {
        $state = Get-DemoDeploymentState -Config $Config
        $marker = ConvertTo-DemoBusyMarker -Tags (Get-DemoMemberValue -InputObject $state -Name 'Tags')
        if ($marker.Active -and [string]$marker.By -eq 'session') {
            return @()
        }
        return @(Resolve-DemoBusyNightlyStop -Config $Config -State $state -Purpose Stop -Confirm:$false)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The nightly stop wasn''t settled after the stop at the end of this update: {0}. ./scripts/stop-demo.ps1 or the next ./scripts/deploy.ps1 settles it.' -f (Protect-DemoText -Text $_.Exception.Message))
        return @()
    }
}

function Wait-DemoUpdateStopWork {
    <#
    .SYNOPSIS
    Waits, at most -WaitMinutes in all, for work this run started that still needs a host it's about to deallocate
    (2026-11-19). Returns Seconds, Done (what it waited for and saw end), Left (what still ran, with where it goes on),
    and T2UploadedAt (when T2's first migration assessment uploaded, as it waited for it; '' otherwise), which the ending
    reads to deploy the Insights app once more with T2's readiness (F18, Complete-DemoInsightsAppMigration). Never throws.
    Internal.

    .DESCRIPTION
    - A bootstrap pass (vm/health/README.md): after an update's new bundle, a host's pass checks every step again, Arc
      onboarding included, and writes health.json only when a step converges or the pass ends. One that's still running
      (the health read's generationPending, InProgress, or RebootPending) is waited for; one cut off goes on at the VM's
      next start, which runs its bootstrap again.
    - T2's first migration assessment (T2.ARC.MIGRATIONASSESSMENT): the T2 track turns it on and starts its first run, which
      uploads about 6 minutes after its start (live, 2026-11-18), and only while T2's guest runs. When none has uploaded and
      none was started (Azure refuses a start until the Azure extension for SQL Server has the setting), it's started once
      more first. Then the upload is waited for (Get-DemoArcState). One that doesn't upload in time starts again at the next
      ./scripts/deploy.ps1 or ./scripts/configure-arc.ps1, which start a run while none has uploaded.
    The history snapshot needs neither host: it reads the telemetry already collected, in Fabric, and the stop never pauses
    the Fabric capacity (Stop-DemoEnvironment -SkipFabric).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [string[]] $VmName = @(),

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 15,

        [ValidateRange(1, 600)]
        [int] $PollSeconds = 60
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $done = [System.Collections.Generic.List[string]]::new()
    $left = [System.Collections.Generic.List[string]]::new()
    $poll = $PollSeconds
    $remaining = { [int][System.Math]::Max(0, $WaitMinutes * 60 - $clock.Elapsed.TotalSeconds) }
    $pause = { Start-Sleep -Seconds ([System.Math]::Max(1, [System.Math]::Min($poll, (& $remaining)))) }
    $minutesText = { param([double] $Seconds) if ($Seconds -lt 90) { 'about a minute' } else { 'about {0} minutes' -f [int][System.Math]::Round($Seconds / 60) } }

    # 1. A bootstrap pass on a VM the stop deallocates.
    $passRunning = { param([object] $Read) $null -ne $Read -and ([bool](Get-DemoMemberValue -InputObject $Read -Name 'generationPending') -or [string](Get-DemoMemberValue -InputObject $Read -Name 'state') -in 'InProgress', 'RebootPending') }
    $passText = {
        param([object] $Read)
        $step = [string](Get-DemoMemberValue -InputObject $Read -Name 'currentStep')
        '{0}{1}' -f [string](Get-DemoMemberValue -InputObject $Read -Name 'state'), $(if ($step) { ', step {0}' -f $step } else { '' })
    }
    foreach ($vm in @($VmName | Where-Object { $_ -and $_ -ne 'T4' } | Select-Object -Unique)) {
        $health = $null
        try {
            $health = Get-DemoVmHealth -Config $Config -VmName $vm -View Summary
        }
        catch {
            Write-DemoLog -Level Warning -Message ('{0}''s health couldn''t be read before the stop at the end of this update, so it''s stopped without that check: {1}' -f $vm, (Protect-DemoText -Text $_.Exception.Message))
            continue
        }
        if (-not (& $passRunning $health)) {
            continue
        }
        $since = $clock.Elapsed.TotalSeconds
        while ((& $passRunning $health) -and (& $remaining) -gt 0) {
            Write-DemoLog -Message ('{0} still runs its bootstrap pass ({1}); the stop at the end of this update waits for it, at most {2} minutes in all.' -f $vm, (& $passText $health), $WaitMinutes)
            & $pause
            try {
                $again = Get-DemoVmHealth -Config $Config -VmName $vm -View Summary
                if ($null -ne $again) {
                    $health = $again
                }
            }
            catch {
                Write-DemoLog -Level Warning -Message ('{0}''s health couldn''t be read again: {1}' -f $vm, (Protect-DemoText -Text $_.Exception.Message))
            }
        }
        if (& $passRunning $health) {
            $left.Add(('{0}''s bootstrap pass ({1}) was still running, so it goes on when {0} starts again (./scripts/start-demo.ps1 or Run all)' -f $vm, (& $passText $health)))
        }
        else {
            $done.Add(('{0}''s bootstrap pass, which ended after {1}' -f $vm, (& $minutesText ($clock.Elapsed.TotalSeconds - $since))))
        }
    }

    # 2. T2's first migration assessment, while T2's host runs.
    $t2UploadedAt = ''
    $hostVm = Get-DemoHostVmName -Config $Config
    $assessment = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'T2.ARC.MIGRATIONASSESSMENT' }) | Select-Object -Last 1
    $evidence = Get-DemoMemberValue -InputObject $assessment -Name 'evidence'
    $pending = $hostVm -in $VmName -and [bool](Get-DemoMemberValue -InputObject $evidence -Name 'enabled') -and -not [string](Get-DemoMemberValue -InputObject $evidence -Name 'uploadedAt')
    if ($pending) {
        $runStarted = [string](Get-DemoMemberValue -InputObject $evidence -Name 'runStarted')
        $resumes = 'the next ./scripts/deploy.ps1 or ./scripts/configure-arc.ps1 starts it again'
        $since = $clock.Elapsed.TotalSeconds
        $uploaded = ''
        $problem = ''
        # A result's evidence went through JSON, which turns an ISO 8601 time into a DateTime.
        $timeText = { param([object] $Value) if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$Value } }
        if (-not $runStarted) {
            # Azure refused its start in the T2 track (the extension didn't have the setting yet): once more now.
            try {
                $again = Invoke-DemoArcMigrationAssessmentRetry -Config $Config -WaitMinutes 0
                $againEvidence = Get-DemoMemberValue -InputObject $again -Name 'evidence'
                $runStarted = [string](Get-DemoMemberValue -InputObject $againEvidence -Name 'runStarted')
                $uploaded = & $timeText (Get-DemoMemberValue -InputObject $againEvidence -Name 'uploadedAt')
                if (-not $runStarted -and -not $uploaded) {
                    $problem = [string](Get-DemoMemberValue -InputObject $again -Name 'message')
                }
            }
            catch {
                $problem = Protect-DemoText -Text $_.Exception.Message
            }
        }
        while (-not $uploaded -and $runStarted) {
            try {
                $arc = Get-DemoArcState -Config $Config
                $info = Get-DemoArcInstanceInfo -Instance @($arc.HostedInstances) -MinimumCores $arc.Target.Setting.MinimumCoresPerOse
                if ($null -ne $info -and [string]$info.MigrationAssessment.UploadedAt) {
                    $uploaded = & $timeText $info.MigrationAssessment.UploadedAt
                    break
                }
            }
            catch {
                Write-DemoLog -Level Warning -Message ('T2''s migration assessment couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
            }
            if ((& $remaining) -le 0) {
                break
            }
            Write-DemoLog -Message ('T2''s first migration assessment runs on {0} and hasn''t uploaded yet; the stop at the end of this update waits for it, at most {1} minutes in all.' -f $hostVm, $WaitMinutes)
            & $pause
        }
        if ($uploaded) {
            $t2UploadedAt = $uploaded
            $done.Add(('T2''s first migration assessment, which uploaded at {0} after {1}' -f $uploaded, (& $minutesText ($clock.Elapsed.TotalSeconds - $since))))
        }
        elseif ($runStarted) {
            $left.Add(('T2''s first migration assessment hadn''t uploaded after {0}, so it may not finish; {1}' -f (& $minutesText ($clock.Elapsed.TotalSeconds - $since)), $resumes))
        }
        else {
            $left.Add(('T2''s first migration assessment didn''t start{0}; {1}' -f $(if ($problem) { ' ({0})' -f $problem.TrimEnd('.') } else { '' }), $resumes))
        }
    }
    return [pscustomobject]@{ Seconds = [int]$clock.Elapsed.TotalSeconds; Done = $done.ToArray(); Left = $left.ToArray(); T2UploadedAt = $t2UploadedAt }
}

function Get-DemoRunningHourlyCost {
    <#
    .SYNOPSIS
    What the demo bills an hour while it runs (2026-11-19), for DONE's line when it keeps running: the cost estimate's running
    hour (Get-DemoCostEstimate, from the Azure Retail Prices API at run time; ADR 0016: no hard-coded prices), with the
    subscription's Defender for Cloud plans, less T4's read replica, which a deployment deletes at its end unless -WithReplica,
    and less Ask's chat relay, which bills only while someone uses the chat (the estimate counts it for every running hour,
    an upper bound). Returns Hourly (USD, or $null when it couldn't be priced) and Error. Never throws. Internal.
    https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State = $null,

        [switch] $WithReplica
    )

    try {
        $effective = Resolve-DemoEffectiveConfig -Config $Config -State $State
        $mode = [string](Get-DemoMemberValue -InputObject $State -Name 'NetworkMode')
        if ($mode -notin 'public', 'private') {
            $mode = (Resolve-DemoNetworkMode -ConfiguredMode $(if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }) -PolicyUnknown).EffectiveMode
        }
        $parameters = @{ Config = $effective; NetworkMode = $mode }
        $free = Get-DemoMemberValue -InputObject $State -Name 'T3UseFreeLimit'
        if ($null -ne $free) {
            $parameters['T3UseFreeLimit'] = [bool]$free
        }
        try {
            $parameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId ([string]$Config['subscriptionId']))
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans couldn''t be read, so the hourly price leaves them out: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        }
        $parameters['T5FreeTier'] = Get-DemoT5FreeTierStatus -Config $Config
        # The run's state, when it has one, so the lifecycle isn't read again.
        $parameters['T5ContainerLifecycle'] = $(if ($null -ne $State) { Get-DemoT5CostLifecycle -Config $Config -State $State } else { Get-DemoT5CostLifecycle -Config $Config })
        $estimate = Get-DemoCostEstimate @parameters
        $hourly = [double]$estimate.HourlyRunning
        $replica = Get-DemoMemberValue -InputObject $estimate -Name 'T4ReplicaHourly'
        if (-not $WithReplica -and $null -ne $replica) {
            $hourly -= [double]$replica
        }
        # Get-DemoMemberValue returns the components whole: assigned first, then each is its own item.
        $components = Get-DemoMemberValue -InputObject $estimate -Name 'Components'
        foreach ($component in @($components)) {
            if ([string](Get-DemoMemberValue -InputObject $component -Name 'Basis') -eq 'running' -and [string](Get-DemoMemberValue -InputObject $component -Name 'Name') -like 'Ask relay*') {
                $hourly -= [double](Get-DemoMemberValue -InputObject $component -Name 'Cost')
            }
        }
        return [pscustomobject]@{ Hourly = [System.Math]::Round([System.Math]::Max(0.0, $hourly), 2); Error = '' }
    }
    catch {
        return [pscustomobject]@{ Hourly = $null; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
}

function Get-DemoUpdateStopNightly {
    <#
    .SYNOPSIS
    The nightly stop that ends a demo the run's end leaves running (2026-11-19): Utc ($null when unknown), Text ("the
    nightly stop at 21:35 (Pacific Standard Time), which waited for this run", or "the nightly stop at 19:00 tomorrow
    (Pacific Standard Time)"), and Deferred. Pure. Internal.

    .DESCRIPTION
    The deferred pass that waited for this run (DEPLOY.NIGHTLYSTOP) while it's there: the stop at the end removes it only
    once everything is stopped, and then its STOP.NIGHTLYSTOP (in -StopResult) says so (the review's finding 4).
    Otherwise the next nightly stop at autoShutdownTime in its time zone, with "tomorrow" when it's tomorrow there.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [object[]] $StopResult = @(),

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $shutdown = Get-DemoAutoShutdownSetting -Config $Config
    $nightly = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.NIGHTLYSTOP' -and [string]$_.status -eq 'Warning' }) | Select-Object -Last 1
    $evidence = Get-DemoMemberValue -InputObject $nightly -Name 'evidence'
    $deferred = [string](Get-DemoMemberValue -InputObject $evidence -Name 'stopsAt')
    $removed = $false
    $pass = [string]$script:BusyMarkerSetting['deferredSchedule']
    foreach ($item in @($StopResult | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'STOP.NIGHTLYSTOP' })) {
        # Get-DemoMemberValue returns the list whole: assigned first, then each item is its own.
        $done = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name 'done'
        if (@(@($done) | Where-Object { ([string]$_).Contains($pass) }).Count -gt 0) {
            $removed = $true
        }
    }
    if ($deferred -and -not $removed) {
        $utc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $evidence -Name 'stopsAtUtc')
        return [pscustomobject]@{ Utc = $utc; Text = ('the nightly stop at {0} ({1}), which waited for this run' -f $deferred, $shutdown.TimeZoneId); Deferred = $true }
    }
    try {
        $next = Get-DemoNextShutdownUtc -Config $Config -NowUtc $NowUtc
        return [pscustomobject]@{ Utc = $next; Text = ('the nightly stop at {0}' -f (Get-DemoAutoStopClockText -Config $Config -Utc $next -NowUtc $NowUtc)); Deferred = $false }
    }
    catch {
        return [pscustomobject]@{ Utc = $null; Text = ('the nightly stop at {0} ({1})' -f (Format-DemoClockText -Clock $shutdown.Time), $shutdown.TimeZoneId); Deferred = $false }
    }
}

function Get-DemoUpdateStopUntilText {
    # Until when the demo runs when the run's end leaves it running (2026-11-19): Get-DemoUpdateStopNightly's Text. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowEmptyCollection()]
        [object[]] $StopResult = @(),

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    return (Get-DemoUpdateStopNightly -Config $Config -Result $Result -StopResult $StopResult -NowUtc $NowUtc).Text
}

function Get-DemoUpdateStopOtherwiseText {
    # "Otherwise <until> stops it.", with the comma that closes "..., which waited for this run". Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Until
    )

    return ('Otherwise {0}{1} stops it.' -f $Until, $(if ($Until -match ', which [^,]+$') { ',' } else { '' }))
}

function Get-DemoUpdateStopBillingLine {
    # DONE's line when the run's end leaves the demo running (2026-11-19): what it bills an hour, until when, how to stop it
    # now, and why it keeps running. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $HourlyUsd = $null,

        [AllowEmptyString()]
        [string] $PriceError = '',

        [Parameter(Mandatory)]
        [string] $Until,

        [AllowEmptyString()]
        [string] $Why = ''
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $rate = if ($null -ne $HourlyUsd) {
        [string]::Format($culture, 'about {0:N2} USD an hour at list prices (./scripts/estimate-cost.ps1 has the detail)', [double]$HourlyUsd)
    }
    else {
        'by the hour (its list price couldn''t be read{0}; ./scripts/estimate-cost.ps1 shows it)' -f $(if ($PriceError) { ': {0}' -f $PriceError.TrimEnd('.') } else { '' })
    }
    return ('The demo runs and bills {0} until {1}; ./scripts/stop-demo.ps1 stops it now. {2}' -f $rate, $Until, $Why).Trim()
}

function Invoke-DemoUpdateEndStop {
    <#
    .SYNOPSIS
    deploy.ps1's stop at the end of an update (2026-11-19): once a run that found its demo stopped ends DONE, what it
    started is stopped again through stop-demo.ps1's stop path. Returns Result (DEPLOY.ENDSTOP), Stopped, and Line (DONE's
    line about what bills, '' unless DONE), and shows it on the status page's EndStop row. Never a Fail, never NOT DONE.
    Internal.

    .DESCRIPTION
    1. Get-DemoUpdateStopPlan: Not selected (the row Skipped, with why) for a run stopped (Ctrl+C), a what-if, NOT DONE, a
       new deployment, a demo that was running or starting when the run began, nothing started, and -KeepRunning. These
       make no Azure call but DONE's, which reads the running hour's list price for its line (Get-DemoRunningHourlyCost).
    2. A session that uses the demo now keeps it running (Get-DemoUpdateStopSession: a pending auto-stop of Run all, the
       Insights app's Start, or start-demo.ps1; a start-demo.ps1 session's mark on T4's read replica, or its start since
       -RunStartedUtc; Run all's busy marker; or a request to the session control on its way): Not selected, with its
       auto-stop's time. When that can't be read, the demo keeps running too.
    3. Wait-DemoUpdateStopWork: work this run started that still needs a host the stop deallocates, on each demo VM that
       runs now, at most -WorkWaitMinutes. Then the session check again (the review's finding 1).
    4. Stop-DemoEnvironment -SkipFabric -UpdateEnd, as stop-demo.ps1 runs it, without the history save and the capacity
       pause (this run took its own history snapshot): the profiles off, T3's Database Agent hold released, the T2 guest
       shut down, both VMs deallocated, T4 stopped (its read replica is gone already: DEPLOY.T4.REPLICA.END), T5's container
       deleted, a pending auto-stop removed, and the nightly stop settled last, once everything is stopped. It checks for a
       session again before its first change and before T2's guest and the VMs (STOP.SESSION).
    5. DEPLOY.ENDSTOP: Pass when the VMs, T4, and T5's container were stopped; a Warning with ./scripts/stop-demo.ps1 as the
       fix when one of them wasn't, or the stop threw (Stopped $false, so DONE keeps the nightly stop's note); a Warning
       when a session started while the stop ran, after its last check, with how to start it again.
    -Progress gets the phase (Checking, Waiting, Stopping, Stopped) and what was started, so a Ctrl+C that cuts the stop
    short is recorded with what it may have left (Complete-DemoUpdateEndStopInterrupted). -NowUtc fixes the clock the texts
    use.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $Model = $null,

        [AllowNull()]
        [object] $State = $null,

        [AllowEmptyString()]
        [string] $OutcomeKind = '',

        [switch] $KeepRunning,

        [switch] $Stopped,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(0, 60)]
        [int] $WorkWaitMinutes = 15,

        [ValidateRange(1, 600)]
        [int] $PollSeconds = 60,

        [AllowNull()]
        [object] $RunStartedUtc = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $Progress = $null,

        [AllowNull()]
        [object] $NowUtc = $null
    )

    $plan = Get-DemoUpdateStopPlan -Result $Result -Model $Model -OutcomeKind $OutcomeKind -KeepRunning:$KeepRunning -Stopped:$Stopped
    $join = { param([string[]] $Items) if ($Items.Count -le 2) { $Items -join ' and ' } else { '{0}, and {1}' -f ($Items[0..($Items.Count - 2)] -join ', '), $Items[-1] } }
    $done = $OutcomeKind -eq 'Done'
    $startedText = & $join @($plan.Started)
    if ($null -eq $Progress) {
        $Progress = @{}
    }
    $Progress['Phase'] = ''
    $Progress['Started'] = $startedText
    $fixedNow = if ($null -ne $NowUtc) { ConvertTo-DemoUtcDateTime -Value $NowUtc } else { $null }
    $clock = { if ($null -ne $fixedNow) { $fixedNow } else { [DateTime]::UtcNow } }
    $finish = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '', [bool] $WasStopped = $false, [string] $Line = '')
        $Evidence['reason'] = [string]$plan.Reason
        $Evidence['started'] = @($plan.Started)
        $Evidence['running'] = @($plan.Running)
        $item = New-DemoResult -CheckId $script:UpdateEndStopCheckId -Area 'infra' -Target 'subscription' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $script:UpdateEndStopDoc
        $rowState = if ($Status -eq 'Not selected') { 'Skipped' } else { 'Done' }
        Set-DemoProgressStep -Path $ProgressPath -Id $script:UpdateEndStopRowId -State $rowState -Status $Status -Message $(if ($Remediation) { '{0} {1}' -f $Message, $Remediation } else { $Message }) -MaxLength 1200
        if ($Status -eq 'Warning') {
            Write-DemoLog -Level Warning -Message ('{0} {1}' -f $Message, $Remediation)
        }
        return [pscustomobject]@{ Result = $item; Stopped = $WasStopped; Line = $(if ($done) { $Line } else { '' }); Plan = $plan }
    }
    # DONE's line when the demo keeps running: its running hour's list price, and until when.
    $billing = {
        param([string] $Why, [string] $Until = '')
        $price = Get-DemoRunningHourlyCost -Config $Config -State $State
        $untilText = if ($Until) { $Until } else { Get-DemoUpdateStopUntilText -Config $Config -Result $Result -NowUtc (& $clock) }
        return [pscustomobject]@{ Line = (Get-DemoUpdateStopBillingLine -HourlyUsd $price.Hourly -PriceError $price.Error -Until $untilText -Why $Why); Hourly = $price.Hourly }
    }

    $tags = Get-DemoMemberValue -InputObject $State -Name 'Tags'
    $deploymentId = if ($tags -is [System.Collections.IDictionary] -and [string]$tags['deploymentId'] -match '^[a-z0-9]{6}$') { [string]$tags['deploymentId'] } else { '' }
    # A session's end, as until when the demo runs (2026-11-19): its auto-stop, in the VMs' time zone, or the nightly stop
    # for a start-demo.ps1 session when that comes first, because such a session sets no busy marker.
    $sessionUntil = {
        param([object] $Hold)
        $untilUtc = Get-DemoMemberValue -InputObject $Hold -Name 'UntilUtc'
        if ($null -eq $Hold -or -not [bool]$Hold.Held -or [string]$Hold.By -eq 'Unknown' -or $null -eq $untilUtc) {
            return ''
        }
        $untilUtc = ConvertTo-DemoUtcDateTime -Value $untilUtc
        $now = & $clock
        if ([string]$Hold.By -eq 'StartDemo') {
            $nightly = Get-DemoUpdateStopNightly -Config $Config -Result $Result -NowUtc $now
            if ($null -ne $nightly.Utc -and $nightly.Utc -lt $untilUtc) {
                return $nightly.Text
            }
        }
        return ('the session''s end at {0}' -f (Get-DemoAutoStopClockText -Config $Config -Utc $untilUtc -NowUtc $now))
    }
    # A session that uses the demo keeps it running: Not selected, with why, what it bills, and until when.
    $held = {
        param([object] $Session, [string] $Extra = '', [System.Collections.IDictionary] $More = $null)
        $text = '{0}{1}' -f (Get-DemoUpdateStopHoldText -Config $Config -Hold $Session), $Extra
        $plan.Reason = $(if ([string]$Session.By -eq 'Unknown') { 'SessionUnknown' } else { 'Session' })
        $untilUtc = Get-DemoMemberValue -InputObject $Session -Name 'UntilUtc'
        $evidence = [ordered]@{ heldBy = [string]$Session.By; heldUntilUtc = $(if ($null -ne $untilUtc) { ConvertTo-DemoBusyTimeText -Utc (ConvertTo-DemoUtcDateTime -Value $untilUtc) } else { '' }); heldDetail = [string](Get-DemoMemberValue -InputObject $Session -Name 'Detail') }
        if ($null -ne $More) {
            foreach ($key in @($More.Keys)) {
                $evidence[$key] = $More[$key]
            }
        }
        $billed = & $billing $text (& $sessionUntil $Session)
        $evidence['hourlyUsd'] = $billed.Hourly
        return (& $finish 'Not selected' $text $evidence '' $false $billed.Line)
    }

    if (-not $plan.Applies) {
        $evidence = [ordered]@{}
        $line = ''
        if ($done) {
            # A demo that was running may be a session's, whose auto-stop ends it before the nightly stop.
            $until = ''
            if ($plan.Reason -in 'WasRunning', 'NothingStopped') {
                $until = & $sessionUntil (Get-DemoT4ReplicaHold -Config $Config -DeploymentId $deploymentId)
            }
            $billed = & $billing $plan.Text $until
            $line = $billed.Line
            $evidence['hourlyUsd'] = $billed.Hourly
        }
        return (& $finish 'Not selected' $plan.Text $evidence '' $false $line)
    }

    $Progress['Phase'] = 'Checking'
    $session = Get-DemoUpdateStopSession -Config $Config -SinceUtc $RunStartedUtc -NowUtc (& $clock)
    if ([bool]$session.Held) {
        return (& $held $session)
    }
    # A start-demo.ps1 auto-stop left from before this run (the review's finding 3): the stop removes it.
    $leftOver = ''
    $ignored = Get-DemoMemberValue -InputObject $session -Name 'Ignored'
    if ($null -ne $ignored) {
        $leftOver = ' A start-demo.ps1 auto-stop from before this run (due {0}) was left over, because the nightly stop had ended its session, so the stop removed it.' -f (Get-DemoAutoStopClockText -Config $Config -Utc (ConvertTo-DemoUtcDateTime -Value $ignored) -NowUtc (& $clock))
    }

    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Stop what this run started ({0}), as it found the demo' -f $startedText))) {
        return (& $finish 'Not selected' ('What if: what this run started ({0}) would be stopped at its end.' -f $startedText) ([ordered]@{}))
    }
    $runningText = 'Stopping what this update started ({0}), as it found the demo: about 5 to 10 minutes. ./scripts/deploy.ps1 -KeepRunning leaves it running.' -f $startedText
    Set-DemoProgressStep -Path $ProgressPath -Id $script:UpdateEndStopRowId -State 'Running' -Message $runningText -MaxLength 1200
    Write-DemoLog -Message $runningText

    # Work on each demo VM that runs now (the review's finding 5): the stop deallocates both, so a host this run didn't start
    # itself (one it created again) and one with no power state are waited for too.
    $Progress['Phase'] = 'Waiting'
    $vms = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($plan.Started | Where-Object { $_ -and $_ -ne 'T4' })) {
        if (-not $vms.Contains([string]$vm)) {
            $vms.Add([string]$vm)
        }
    }
    foreach ($vm in @('sqlvm01', (Get-DemoHostVmName -Config $Config))) {
        if ($vms.Contains($vm)) {
            continue
        }
        $power = ''
        try {
            $power = [string](Get-DemoVmPowerState -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $vm)
        }
        catch {
            Write-DemoLog -Level Debug -Message ('{0}''s power state couldn''t be read, so the stop at the end waits for its work too: {1}' -f $vm, (Protect-DemoText -Text $_.Exception.Message))
        }
        if (-not $power -or $power -in 'PowerState/running', 'PowerState/starting') {
            $vms.Add($vm)
        }
    }
    $work = Wait-DemoUpdateStopWork -Config $Config -Result $Result -VmName $vms.ToArray() -WaitMinutes $WorkWaitMinutes -PollSeconds $PollSeconds
    # When T2's first migration assessment uploaded as the stop waited, the ending deploys the Insights app once more with
    # T2's readiness (F18, Complete-DemoInsightsAppMigration).
    $evidence = [ordered]@{ waitedSeconds = [int]$work.Seconds; waitedOn = $vms.ToArray(); waitedFor = @($work.Done); left = @($work.Left); t2AssessmentUploadedAt = [string](Get-DemoMemberValue -InputObject $work -Name 'T2UploadedAt') }
    $workText = ''
    if (@($work.Done).Count -gt 0) {
        $workText += ' It waited first for {0}.' -f (& $join @($work.Done))
    }
    if (@($work.Left).Count -gt 0) {
        $workText += ' Not finished: {0}.' -f (@($work.Left) -join '; ')
    }
    # A session that started while the end waited keeps the demo running (the review's finding 1).
    $session = Get-DemoUpdateStopSession -Config $Config -SinceUtc $RunStartedUtc -NowUtc (& $clock)
    if ([bool]$session.Held) {
        return (& $held $session $workText $evidence)
    }

    $Progress['Phase'] = 'Stopping'
    $stop = @()
    $thrown = ''
    try {
        $stop = @(Stop-DemoEnvironment -Config $Config -SkipFabric -UpdateEnd -RunStartedUtc $RunStartedUtc -Confirm:$false)
    }
    catch {
        $thrown = Protect-DemoText -Text $_.Exception.Message
    }
    $Progress['Phase'] = 'Stopped'
    $evidence['stop'] = @($stop | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ checkId = [string]$_.checkId; status = [string]$_.status } })
    # A session the stop itself found (STOP.SESSION): before its first change, nothing was stopped; before T2's guest and the
    # VMs, they keep running, but the activity is off already.
    $guard = @($stop | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'STOP.SESSION' }) | Select-Object -Last 1
    if ($null -ne $guard) {
        $guardEvidence = Get-DemoMemberValue -InputObject $guard -Name 'evidence'
        $found = [pscustomobject]@{ Held = $true; By = [string](Get-DemoMemberValue -InputObject $guardEvidence -Name 'by'); UntilUtc = (ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $guardEvidence -Name 'untilUtc')); Detail = [string](Get-DemoMemberValue -InputObject $guardEvidence -Name 'detail'); Error = [string](Get-DemoMemberValue -InputObject $guardEvidence -Name 'error') }
        if ([string]$guard.status -eq 'Not selected') {
            return (& $held $found $workText $evidence)
        }
        $evidence['heldBy'] = $found.By
        $message = '{0}{1}' -f [string]$guard.message, $workText
        $fix = [string]$guard.remediation
        return (& $finish 'Warning' $message $evidence $fix $false ('{0} {1}' -f $message, $fix))
    }
    $failed = [System.Collections.Generic.List[string]]::new()
    $stoppedParts = [System.Collections.Generic.List[string]]::new()
    $kept = ''
    $deallocated = @($stop | Where-Object { [string]$_.checkId -like 'STOP.VM_*' -and [string]$_.status -eq 'Pass' } | ForEach-Object { ([string]$_.checkId).Substring(8).ToLowerInvariant() })
    if ($deallocated.Count -gt 0) {
        $stoppedParts.Add(('{0} {1} deallocated' -f (& $join $deallocated), $(if ($deallocated.Count -eq 1) { 'is' } else { 'are' })))
    }
    foreach ($item in @($stop | Where-Object { $null -ne $_ })) {
        $id = [string]$item.checkId
        $status = [string]$item.status
        $outcome = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name 'outcome')
        if ($id -like 'STOP.VM_*' -and $status -ne 'Pass') {
            $failed.Add(('{0}: {1}' -f $id, [string]$item.message))
        }
        elseif ($id -in 'STOP.T4.STOP', 'STOP.T4.REPLICA' -and $status -in 'Fail', 'Warning') {
            $failed.Add(('{0}: {1}' -f $id, [string]$item.message))
        }
        elseif ($id -eq 'STOP.T4.STOP' -and $status -eq 'Pass') {
            $stoppedParts.Add('T4 is stopped')
        }
        elseif ($id -eq 'STOP.T5' -and $outcome -eq 'Kept') {
            $kept = ' T5''s container stays between sessions (STOP.T5 says why).'
        }
        elseif ($id -eq 'STOP.T5' -and $status -in 'Fail', 'Warning') {
            $failed.Add(('{0}: {1}' -f $id, [string]$item.message))
        }
        elseif ($id -eq 'STOP.T5' -and $status -eq 'Pass' -and $outcome -eq 'Deleted') {
            $stoppedParts.Add('T5''s container is deleted')
        }
        elseif ($id -eq 'PREFLIGHT.GUARD.CONTEXT' -and $status -eq 'Fail') {
            $failed.Add(('{0}: {1}' -f $id, [string]$item.message))
        }
    }
    if ($thrown) {
        $failed.Add(('the stop failed: {0}' -f $thrown))
    }
    $stopNow = './scripts/stop-demo.ps1'
    $evidence['failed'] = $failed.ToArray()
    if ($failed.Count -gt 0) {
        # Not all stopped (the review's finding 4): Stopped is $false, so DONE keeps the nightly stop's note, and the time
        # comes from what the stop did to tonight's stop (it settles it only once everything is stopped).
        $until = Get-DemoUpdateStopUntilText -Config $Config -Result $Result -StopResult $stop -NowUtc (& $clock)
        $message = 'The stop at the end of this update didn''t stop all of what the run started ({0}): {1}.{2}{3}' -f $startedText, ($failed -join '; '), $workText, $leftOver
        $fix = 'Run {0}: it stops what still runs. {1}' -f $stopNow, (Get-DemoUpdateStopOtherwiseText -Until $until)
        return (& $finish 'Warning' $message $evidence $fix $false ('{0} {1}' -f $message, $fix))
    }
    $partsText = if ($stoppedParts.Count -gt 0) { & $join $stoppedParts.ToArray() } else { 'what it started is stopped' }
    # A session that started while the stop ran, after its last check (the review's finding 1): said, never silently undone.
    $after = Get-DemoUpdateStopSession -Config $Config -SinceUtc $RunStartedUtc -NowUtc (& $clock)
    if ([bool]$after.Held -and [string]$after.By -ne 'Unknown') {
        $evidence['startedMeanwhile'] = [string]$after.By
        $message = 'Stopped at the end, as this run found the demo: {0}.{1} But {2} started while the stop ran, after its last check, so the stop may have cut it off.{3}{4}' -f $partsText, $kept, (Get-DemoUpdateStopSessionName -By ([string]$after.By)), $workText, $leftOver
        $fix = 'Start the session again: Run all in NB_DatabaseHub_Control, or ./scripts/start-demo.ps1.'
        return (& $finish 'Warning' $message $evidence $fix $true ('{0} {1}' -f $message, $fix))
    }
    $message = 'Stopped at the end, as this run found the demo: {0}, so only what bills while the demo is stopped is left (./scripts/estimate-cost.ps1 shows it).{1}{2}{3}' -f $partsText, $kept, $workText, $leftOver
    $line = '{0} Start a session with Run all in NB_DatabaseHub_Control, or ./scripts/start-demo.ps1; ./scripts/deploy.ps1 -KeepRunning leaves the demo running after an update.' -f $message
    return (& $finish 'Pass' $message $evidence '' $true $line)
}

function Complete-DemoUpdateEndStopInterrupted {
    <#
    .SYNOPSIS
    The stop at the end of an update, cut short by Ctrl+C (2026-11-19, the review's finding 2). deploy.ps1 runs its ending in
    a finally block, where a pipeline stop skips everything but nested finally blocks, so Complete-DemoDeploymentRun calls
    this from its own and goes on with the ending. Returns what Invoke-DemoUpdateEndStop returns (Result, DEPLOY.ENDSTOP as a
    Warning; Stopped $false; Line) and shows it on the status page's EndStop row. No Azure call: the stop settles the
    nightly stop last, once everything is stopped (Stop-DemoEnvironment -UpdateEnd), so tonight's stop is still in place.
    Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $Progress = $null,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    try {
        $phase = if ($null -ne $Progress) { [string]$Progress['Phase'] } else { '' }
        $started = if ($null -ne $Progress) { [string]$Progress['Started'] } else { '' }
        $what = if ($started) { 'what this run started ({0})' -f $started } else { 'what this run started' }
        $until = Get-DemoUpdateStopUntilText -Config $Config -Result $Result -NowUtc $NowUtc
        $otherwise = Get-DemoUpdateStopOtherwiseText -Until $until
        if ($phase -in 'Stopping', 'Stopped') {
            $message = 'deploy.ps1 was stopped (Ctrl+C) during the stop at its end, so part of {0} may be stopped already (its activity, T2''s guest, a VM), and the rest still runs and bills.' -f $what
            $fix = 'Run ./scripts/stop-demo.ps1: it stops the rest now. To demo instead, run ./scripts/start-demo.ps1 or Run all in NB_DatabaseHub_Control, which start it all again. {0}' -f $otherwise
        }
        elseif ($phase -eq 'Waiting') {
            $message = 'deploy.ps1 was stopped (Ctrl+C) while the stop at its end waited for work on the hosts, so nothing was stopped: {0} keeps running and billing.' -f $what
            $fix = 'Run ./scripts/stop-demo.ps1 to stop it now. {0}' -f $otherwise
        }
        else {
            $message = 'deploy.ps1 was stopped (Ctrl+C) at its end, before anything was stopped, so the demo keeps running and billing as it is.'
            $fix = 'Run ./scripts/stop-demo.ps1 to stop it now. {0}' -f $otherwise
        }
        $item = New-DemoResult -CheckId $script:UpdateEndStopCheckId -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence ([ordered]@{ reason = 'Interrupted'; phase = $phase; started = $started }) -Remediation $fix -DocUrl $script:UpdateEndStopDoc
        $line = '{0} {1}' -f $message, $fix
        Set-DemoProgressStep -Path $ProgressPath -Id $script:UpdateEndStopRowId -State 'Done' -Status 'Warning' -Message $line -MaxLength 1200
        Write-DemoLog -Level Warning -Message $line
        return [pscustomobject]@{ Result = $item; Stopped = $false; Line = $line; Plan = $null }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The stop at the end of this run, cut short, wasn''t recorded: {0}' -f $_.Exception.Message)
        return $null
    }
}
