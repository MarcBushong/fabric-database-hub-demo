$script:HistoryFirstRunNotebook = 'NB_DatabaseHub_LiveActivity'
$script:HistoryFirstRunCheckId = 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY'
# A Direct Lake refresh whose source tables don't exist yet (live, 2026-11-19, #68: 0xC14700C7 "We cannot access the source
# Delta table"), or that Direct Lake can't see yet (0xC14700DF, Invoke-DemoSemanticModelRefresh).
$script:HistoryMissingTablePattern = '0xC14700C7|0xC14700DF|source Delta table|source tables either do not exist'
$script:HistoryRunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity, then ./scripts/configure-powerbi.ps1'

function Wait-DemoFabricNotebookJob {
    <#
    .SYNOPSIS
    Follows a Fabric job instance, the Location that Run On Demand Item Job returned, until it's Completed, Failed,
    Cancelled, or Deduped, or until -TimeoutMinutes of elapsed time pass, the reads included. Returns Status, State (the
    last job instance read), Seconds, and QueuedSeconds (how long it stayed NotStarted, so far when it still is). Internal.

    .DESCRIPTION
    A read that doesn't answer 200 is read again at the next poll. While the job is queued (NotStarted: the capacity runs
    other Spark jobs first) or running, the status page's -ProgressId row says so, with the minutes so far and the bound
    (#68), and the console says so every 5 minutes it stays queued.
    - Get Item Job Instance: https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/get-item-job-instance
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [Parameter(Mandatory)]
        [string] $Name,

        [ValidateRange(1, 180)]
        [int] $TimeoutMinutes = 30,

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ProgressId = '',

        # What the status page adds after the wait's line, such as what comes once the job completes.
        [AllowEmptyString()]
        [string] $ProgressNote = '',

        [string] $InitialStatus = 'NotStarted'
    )

    $started = Get-DemoUtcNow
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $status = $InitialStatus
    $state = $null
    $queuedSeconds = $null
    $shown = ''
    $logged = 0
    $maxPolls = [int][System.Math]::Ceiling($TimeoutMinutes * 60.0 / $PollSeconds)
    # Elapsed time bounds the polls too, the reads included: a read that keeps getting a transient status (HTTP 429 or
    # 5xx) pays its attempts and backoff on every poll (review of c7c86ec). A network error that lasts throws.
    for ($poll = 1; $poll -le $maxPolls; $poll++) {
        $remaining = ($deadline - (Get-DemoUtcNow)).TotalSeconds
        if ($remaining -le 0) {
            break
        }
        Start-Sleep -Seconds ([int][System.Math]::Max(1, [System.Math]::Min($PollSeconds, [System.Math]::Ceiling($remaining))))
        $read = Invoke-DemoFabricRequest -Method 'Get' -Uri $Location -Token $Token
        if ($read.StatusCode -ne 200) {
            continue
        }
        $state = $read.Body
        $status = [string](Get-DemoMemberValue -InputObject $state -Name 'status')
        $elapsed = (Get-DemoUtcNow) - $started
        if ($status -ne 'NotStarted' -and $null -eq $queuedSeconds) {
            $queuedSeconds = [int]$elapsed.TotalSeconds
        }
        if ($status -in 'Completed', 'Failed', 'Cancelled', 'Deduped') {
            break
        }
        $minutes = [int][System.Math]::Floor($elapsed.TotalMinutes)
        if ($ProgressPath -and $ProgressId) {
            $text = '{0} is {1} ({2} of at most {3} minutes).{4}' -f $Name, $(if ($status -eq 'NotStarted') { 'queued on the capacity' } else { 'running' }), $minutes, $TimeoutMinutes, $(if ($ProgressNote) { ' ' + $ProgressNote } else { '' })
            if ($text -ne $shown) {
                Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message $text
                $shown = $text
            }
        }
        if ($status -eq 'NotStarted' -and [int][System.Math]::Floor($minutes / 5) -gt $logged) {
            $logged = [int][System.Math]::Floor($minutes / 5)
            Write-DemoLog -Message ('{0} is still queued on the capacity after {1} minutes: the capacity runs other Spark jobs first. Waiting for it, for at most {2} minutes.' -f $Name, $minutes, $TimeoutMinutes)
        }
    }
    $seconds = [int]((Get-DemoUtcNow) - $started).TotalSeconds
    if ($null -eq $queuedSeconds) {
        $queuedSeconds = if ($status -eq 'NotStarted') { $seconds } else { 0 }
    }
    return [pscustomobject]@{ Status = $status; State = $state; Seconds = $seconds; QueuedSeconds = $queuedSeconds }
}

function Set-DemoHistoryResultText {
    # Sets a record's status, message, and remediation in place, and keeps what it said before in its evidence
    # (earlierMessage), so the run's results and the status page show what happened in the end. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes in-memory results only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Message,

        [AllowEmptyString()]
        [string] $Remediation = ''
    )

    $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
    if ($null -ne $evidence -and -not [string](Get-DemoMemberValue -InputObject $evidence -Name 'earlierMessage')) {
        if ($evidence -is [System.Collections.IDictionary]) {
            $evidence['earlierMessage'] = [string](Get-DemoMemberValue -InputObject $Result -Name 'message')
        }
        else {
            Add-Member -InputObject $evidence -NotePropertyName 'earlierMessage' -NotePropertyValue ([string](Get-DemoMemberValue -InputObject $Result -Name 'message')) -Force
        }
    }
    foreach ($pair in @(@('status', $Status), @('message', $Message), @('remediation', $Remediation))) {
        if ($Result -is [System.Collections.IDictionary]) {
            $Result[$pair[0]] = $pair[1]
        }
        else {
            Add-Member -InputObject $Result -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
    }
}

function Get-DemoHistoryFirstRun {
    <#
    .SYNOPSIS
    The Fabric step's first history run (#68): configure-fabric.ps1 runs NB_DatabaseHub_LiveActivity once when it created
    the notebook or its lakehouse, so a first deployment's history model has tables to read; an update doesn't run it.
    Returns Result (its record), Completed, Pending (still queued or running when its wait ended, with the job's Location to
    follow), Location, and JobStatus; $null without one. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $run = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq $script:HistoryFirstRunCheckId }) | Select-Object -Last 1
    if ($null -eq $run) {
        return $null
    }
    $location = [string](Get-DemoMemberValue -InputObject $run.evidence -Name 'jobLocation')
    $jobStatus = [string](Get-DemoMemberValue -InputObject $run.evidence -Name 'status')
    $completed = [string]$run.status -eq 'Pass'
    $pending = -not $completed -and [bool]$location -and $jobStatus -in 'NotStarted', 'InProgress'
    return [pscustomobject]@{ Result = $run; Completed = $completed; Pending = $pending; Location = $location; JobStatus = $jobStatus }
}

function Set-DemoHistoryFirstRunWarning {
    # A first history run that failed, was cancelled, or wasn't started is a Warning in a deployment, never a Fail (#68):
    # deploy.ps1's history snapshot at the end of its run runs the notebook again and refreshes the history model. A paused
    # capacity stays Manual action required: its owner resumes it. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes in-memory results only.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $FirstRun
    )

    if ($null -eq $FirstRun -or $FirstRun.Completed -or [string]$FirstRun.Result.status -ne 'Fail') {
        return
    }
    $message = '{0} It was the first history run, so the history model has no tables yet: deploy.ps1''s history snapshot at the end of its run (DEPLOY.FABRIC.HISTORY) runs it again and refreshes the model.' -f ([string]$FirstRun.Result.message).TrimEnd()
    $remediation = 'Nothing to do now. If the history report stays empty after the run, open the notebook''s run in the workspace (Monitor hub) for what failed, then run {0}.' -f $script:HistoryRunAgain
    Set-DemoHistoryResultText -Result $FirstRun.Result -Status 'Warning' -Message $message -Remediation $remediation
}

function Set-DemoHistoryRefreshWaiting {
    <#
    .SYNOPSIS
    The history model's refresh while the first history run hadn't completed (#68; live, 2026-11-19: on a busy F4 the run
    was still queued after 10 minutes, the refresh found no scenario_runs table, and a first deployment ended NOT DONE).
    Its tables don't exist yet, so the refresh's Fail becomes a Warning that says what fills the model: with the run still
    queued or running, deploy.ps1 refreshes the model again once it completes (Invoke-DemoHistoryFirstRunFollowUp);
    otherwise its history snapshot at the end of the run does. Returns the record it changed, or $null: a refresh that
    passed, one that failed for another reason, and one after a first run that completed, or without one (an update), stay
    as they are. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes in-memory results only.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [AllowNull()]
        [object] $FirstRun,

        [int] $WaitMinutes = 45,

        [int] $FollowMinutes = 45
    )

    if ($null -eq $FirstRun -or $FirstRun.Completed) {
        return $null
    }
    $refresh = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'FABRIC.SEMANTICMODEL.REFRESH' -and [string]$_.status -eq 'Fail' }) | Select-Object -Last 1
    if ($null -eq $refresh -or [string]$refresh.message -notmatch $script:HistoryMissingTablePattern) {
        return $null
    }
    if ($FirstRun.Pending) {
        $message = 'The history model has no tables to read yet: {0}, the first history run, is still {1} after {2} minutes, so the model''s first refresh found none. deploy.ps1 refreshes it again once that run completes, for at most {3} more minutes.' -f $script:HistoryFirstRunNotebook, $(if ($FirstRun.JobStatus -eq 'NotStarted') { 'queued on the capacity' } else { 'running' }), $WaitMinutes, $FollowMinutes
        $remediation = 'Nothing to do: deploy.ps1 follows that run and refreshes the model when it completes.'
    }
    else {
        $message = 'The history model has no tables to read yet: {0}, the first history run, didn''t complete, so the model''s first refresh found none. deploy.ps1''s history snapshot at the end of its run (DEPLOY.FABRIC.HISTORY) runs it again and refreshes the model.' -f $script:HistoryFirstRunNotebook
        $remediation = 'Nothing to do now. If the history report stays empty after the run, run {0}.' -f $script:HistoryRunAgain
    }
    Set-DemoHistoryResultText -Result $refresh -Status 'Warning' -Message $message -Remediation $remediation
    return $refresh
}

function Invoke-DemoHistoryFirstRunFollowUp {
    <#
    .SYNOPSIS
    Follows a first history run that was still queued or running when its wait ended (#68), for at most -FollowMinutes
    more, with the status page's Fabric.Report row saying so. Once it completes, the history model's step runs again
    (Invoke-DemoPowerBIStage), in the form the Fabric track's kept-value step allowed (-SnapshotValueForm, F35), so the
    model is refreshed with the run's tables, and its records are returned. Otherwise
    nothing more runs, and the refresh's Warning (-RefreshWarning) and the run's record say what fills the model:
    deploy.ps1's history snapshot at the end of its run. Never a Fail of its own. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [AllowNull()]
        [object] $FirstRun,

        [AllowNull()]
        [object] $RefreshWarning,

        [ValidateRange(1, 180)]
        [int] $FollowMinutes = 45,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 30,

        [ValidateSet('', 'Kept')]
        [string] $SnapshotValueForm = ''
    )

    if ($null -eq $FirstRun -or -not $FirstRun.Pending) {
        return @()
    }
    $name = $script:HistoryFirstRunNotebook
    $snapshot = 'deploy.ps1''s history snapshot at the end of its run (DEPLOY.FABRIC.HISTORY) runs it again and refreshes the model'
    try {
        $token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
        $wait = Wait-DemoFabricNotebookJob -Location $FirstRun.Location -Token $token -Name $name -TimeoutMinutes $FollowMinutes -PollSeconds $PollSeconds -ProgressPath $ProgressPath -ProgressId 'Fabric.Report' -ProgressNote 'The history model refreshes once it completes.' -InitialStatus $FirstRun.JobStatus
    }
    catch {
        $wait = [pscustomobject]@{ Status = 'Unread'; State = $null; Seconds = 0; QueuedSeconds = 0; Error = (Get-DemoExceptionText -Exception $_.Exception) }
    }
    $minutes = [int][System.Math]::Ceiling($wait.Seconds / 60.0)
    if ($wait.Status -eq 'Completed') {
        Write-DemoLog -Message ('{0}, the first history run, completed after another {1} minutes, so the history model is refreshed now.' -f $name, $minutes)
        Set-DemoHistoryResultText -Result $FirstRun.Result -Status 'Pass' -Message ('{0}, the first history run, completed once the capacity ran it, {1} minutes after its first wait ended; deploy.ps1 then refreshed the history model.' -f $name, $minutes)
        $again = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $ConfigPath -SnapshotValueForm $SnapshotValueForm)
        $refreshed = @($again | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'FABRIC.SEMANTICMODEL.REFRESH' -and [string]$_.status -eq 'Pass' }).Count -gt 0
        if ($null -ne $RefreshWarning) {
            $tail = if ($refreshed) { 'It completed {0} minutes later, and deploy.ps1 refreshed the model then.' -f $minutes } else { 'It completed {0} minutes later; the model''s refresh after it is the FABRIC.SEMANTICMODEL.REFRESH that follows.' -f $minutes }
            Set-DemoHistoryResultText -Result $RefreshWarning -Status 'Warning' -Message ('The history model had no tables to read at first: {0}, the first history run, was still queued on the capacity when its wait ended. {1}' -f $name, $tail) -Remediation 'Nothing to do.'
        }
        return $again
    }
    $why = switch ($wait.Status) {
        'NotStarted' { 'is still queued on the capacity after another {0} minutes' -f $minutes }
        'InProgress' { 'still runs after another {0} minutes' -f $minutes }
        'Unread' { 'couldn''t be followed ({0})' -f $wait.Error }
        default {
            $reason = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $wait.State -Name 'failureReason') -Name 'message')
            'ended {0}{1}' -f ([string]$wait.Status).ToLowerInvariant(), $(if ($reason) { ': ' + (Protect-DemoText -Text $reason) } else { '' })
        }
    }
    Write-DemoLog -Level Warning -Message ('{0}, the first history run, {1}; {2}.' -f $name, $why, $snapshot)
    Set-DemoHistoryResultText -Result $FirstRun.Result -Status 'Warning' -Message ('{0}, the first history run, {1}; {2}.' -f $name, $why, $snapshot) -Remediation ('Nothing to do now. If the history report stays empty after the run, run {0}.' -f $script:HistoryRunAgain)
    if ($null -ne $RefreshWarning) {
        Set-DemoHistoryResultText -Result $RefreshWarning -Status 'Warning' -Message ('The history model has no tables to read yet: {0}, the first history run, {1}. {2}.' -f $name, $why, $snapshot) -Remediation ('Nothing to do now. If the history report stays empty after the run, run {0}.' -f $script:HistoryRunAgain)
    }
    return @()
}
