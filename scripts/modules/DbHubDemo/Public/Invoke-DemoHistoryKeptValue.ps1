function Invoke-DemoHistoryKeptValue {
    <#
    .SYNOPSIS
    F35 (i): works out the history's kept values through Fabric's Livy API, with this checkout's
    fabric/history/kept_value.py, and returns one ADR 0012 record that never blocks DONE (2026-11-23).

    .DESCRIPTION
    The history keeps every save at its own interval, so where saves overlap, a total over a period counts their minutes
    twice unless each row's share of its interval is worked out once (its kept value). The notebook works it out when it
    saves, where it's current; this step works it out from the PC with the code in this checkout, so an environment whose
    workspace keeps an older NB_DatabaseHub_LiveActivity gets it with no decision (fabric.importNotebooks stays as it is).
    deploy.ps1 runs it in its Fabric track and at its end, stop-demo.ps1 -SaveHistory and configure-fabric.ps1
    -RunLiveActivity after their saves.

    As whoever runs the script: the Azure CLI's Fabric token after the subscription guard (Get-DemoFabricToken), or -Token.
    1. The workspace and the lakehouse: resolved already in the configuration, or by name, read-only
       (Resolve-DemoKeptValueTarget).
    2. A Livy session in the lakehouse, on the workspace's starter pool, ready within -SessionTimeoutMinutes
       (Open-DemoLivySession).
    3. kept_value.py's text, as one statement (it only defines names), then kept_value_step(spark): it adds whichever of
       grain_minutes, kept_value, and resolved_at_utc telemetry_snapshots lacks, and works out every row not worked out
       yet (the first time, the whole history). Its JSON is the output's last line.
    4. The session is deleted, always (Close-DemoLivySession); one left behind ends by itself after 20 minutes idle.
    -TimeoutMinutes bounds all of it, on the module's clock (Get-DemoUtcNow): the step gets what the session's start and
    the module's load leave of it.

    The record (-CheckId) has evidence nonBlocking keptValue, outcome, form, the step's counts (step), and the session's
    states (session):
    - Pass: every row is worked out (outcome Done); with -SwitchModelForm, every row is worked out and the history model is
      deployed in their form (Switched).
    - Not selected: no history table yet (NoTable); the workspace or the lakehouse isn't there (NotResolved); this
      checkout's kept_value.py isn't there, or has no kept_value_step yet, as the groundwork's module hasn't (NoModule).
    - Warning: a paused or inactive capacity (CapacityPaused); no token (NoToken); Fabric's refusal of the session or of
      a statement, HTTP 401 or 403 (Refused); a session that wasn't ready in time or ended (SessionFailed); the module's
      load or kept_value_step raising (StepFailed); no time left (TimedOut); an answer without the step's JSON (NoAnswer);
      a table still without the columns (NoColumns); a step that stopped with rows left (Partial); with -ModelOnRelease,
      every row worked out while this run's history model doesn't read them (ModelOnRelease), or, with -SwitchModelForm,
      a deployment of the model in their form that didn't work (SwitchFailed); or an HTTP error past
      Invoke-DemoFabricRequest's retries, a statement Fabric cancelled, or any other error (Failed; evidence networkError
      for a network error).
    Each Warning says what didn't work, then until when the history's totals read as before F35: until a later run works
    out the rest; or, when this run's history model reads the release's form (-ModelOnRelease, or -DecidesModelForm with
    an answer that doesn't allow the kept form, when this checkout's configure-powerbi.ps1 has it), until the Fabric track
    runs again. Its fix ends with -RunAgain. NoTable says, with -DecidesModelForm, that deploy.ps1 deploys the model in the
    kept form once the history has rows, and with -ModelOnRelease, that the next ./scripts/deploy.ps1 does.
    Evidence form is the step's own answer, Kept when telemetry_snapshots has the three columns after it: only then does
    configure-powerbi.ps1 get -SnapshotValueForm Kept (Get-DemoKeptValueForm). With -ProgressPath and -ProgressId, the
    status page's row says what runs, then the outcome. It never throws but for a stop of the run (Ctrl+C).

    Sources: FabricLivyHelpers.ps1's (the Livy API, checked 2026-11-23), and
    https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works (the model reads a column only once the
    lakehouse has it).

    .PARAMETER Config
    Configuration from Get-DemoConfig, or the copy Resolve-DemoFabricConfig returned.

    .PARAMETER Token
    A Fabric REST API token you already have, as a SecureString.

    .PARAMETER CheckId
    The record's check ID: DEPLOY.FABRIC.KEPTVALUE, DEPLOY.FABRIC.KEPTVALUE.END, STOP.FABRIC.KEPTVALUE, or
    FABRIC.KEPTVALUE.

    .PARAMETER TimeoutMinutes
    How long the whole step may take: the session's start, kept_value.py's load, and kept_value_step. A first run over a
    long history takes minutes.

    .PARAMETER SessionTimeoutMinutes
    At most this much of -TimeoutMinutes for the Livy session to be ready; a busy capacity queues it.

    .PARAMETER ProgressPath
    The status page's model (deploy-progress.json); nothing without it.

    .PARAMETER ProgressId
    The status page's row for -ProgressPath.

    .PARAMETER RunAgain
    The command that runs the step again, for the Warnings' fix.

    .PARAMETER DecidesModelForm
    The history model's step that follows deploys the form this step's answer allows (deploy.ps1's Fabric track): when the
    answer doesn't allow the kept form, the Warnings say that the model reads the release's form until the Fabric track
    runs again.

    .PARAMETER ModelOnRelease
    This run's history model reads the release's form, since its Fabric-track step didn't allow the kept one (deploy.ps1's
    end, Invoke-DemoKeptValueEndStep): the Warnings say so, and a step that works out every row is a Warning too, since
    the model doesn't read them until the Fabric track runs again, unless -SwitchModelForm deploys it in their form.

    .PARAMETER SwitchModelForm
    With -ModelOnRelease, once every row is worked out, deploys the history model in the kept values' form by the Fabric
    track's own step (Invoke-DemoKeptValueModelSwitch): a Pass (Switched), or a Warning (SwitchFailed) that never blocks
    DONE. It runs after the step's deadline, within configure-powerbi.ps1's own limits (design A, approved 2026-11-23).

    .PARAMETER ConfigPath
    The configuration file configure-powerbi.ps1 reads for -SwitchModelForm; without it, a private copy of -Config.

    .PARAMETER PollSeconds
    Seconds between reads of the session and of the step.

    .EXAMPLE
    Invoke-DemoHistoryKeptValue -Config $config -CheckId 'FABRIC.KEPTVALUE'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'FABRIC.KEPTVALUE',

        [ValidateRange(1, 240)]
        [int] $TimeoutMinutes = 15,

        [ValidateRange(1, 60)]
        [int] $SessionTimeoutMinutes = 10,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ProgressId = '',

        [AllowEmptyString()]
        [string] $RunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity',

        [switch] $DecidesModelForm,

        [switch] $ModelOnRelease,

        [switch] $SwitchModelForm,

        [AllowEmptyString()]
        [string] $ConfigPath = '',

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 5
    )

    $started = Get-DemoUtcNow
    $deadline = $started.AddMinutes($TimeoutMinutes)
    # What's left of -TimeoutMinutes, in whole seconds: one deadline for the whole step, the session's start and the module's
    # load included (the review of c96f790a: the load had 300 seconds of its own).
    $left = { [int][System.Math]::Floor(($deadline - (Get-DemoUtcNow)).TotalSeconds) }
    $evidence = [ordered]@{ nonBlocking = 'keptValue'; outcome = ''; form = '' }
    $showRow = [bool]($ProgressPath -and $ProgressId)
    # Read here: PSReviewUnusedParameter doesn't count a use in $record, a scriptblock. The model's form follows only when this
    # checkout's configure-powerbi.ps1 has the kept one; without it, no run of the track changes the model.
    $modelFollows = [bool]$DecidesModelForm -and (Test-DemoKeptFormDeployable)
    $asBefore = 'Until a later run works them out, the history''s totals read as before F35, where overlapping saves can count twice.'
    $modelBefore = 'This run''s history model reads the release''s form, so its totals read as before F35, where overlapping saves can count twice, until the Fabric track runs again.'
    # Not $later: variable names ignore case, so $record's -Later switch would hide it.
    $laterFix = 'Nothing to do now: a later deploy.ps1, stop-demo.ps1 -SaveHistory, or configure-fabric.ps1 -RunLiveActivity works them out; to do it now, run {0}.' -f $RunAgain
    $modelLaterFix = 'Run {0}: it works out what''s left and deploys the history model in the kept values'' form.' -f $RunAgain
    $bugFix = 'Run {0}; if it fails the same way, it''s a bug: open an issue with this record.' -f $RunAgain
    $capacityFix = Get-DemoFabricCapacityResumeFix -Then ('run {0}.' -f $RunAgain)
    $refusedFix = 'Check that your account has Contributor or higher on the demo''s workspace, and that a Fabric administrator allows the Livy API in the tenant settings; then run {0}.' -f $RunAgain
    $timedOut = @{ Status = 'Warning'; Outcome = 'TimedOut'; Message = ('Working out the history''s kept values didn''t finish in {0} minutes, so it was stopped; the rows it finished keep theirs.' -f $TimeoutMinutes); Later = $true }
    $record = {
        param([string] $Status, [string] $Outcome, [string] $Message, [string] $Remediation = '', [switch] $Later)
        $evidence['outcome'] = $Outcome
        $evidence['seconds'] = [int]((Get-DemoUtcNow) - $started).TotalSeconds
        if ($Status -eq 'Warning') {
            # Until when the history reads as before F35: until a later run works out the rest, or, when this run's history
            # model reads the release's form, until the Fabric track runs again (the review of c96f790a).
            $onRelease = [bool]$ModelOnRelease -or ($modelFollows -and [string]$evidence['form'] -cne 'Kept')
            $Message = '{0} {1}' -f $Message, $(if ($onRelease) { $modelBefore } else { $asBefore })
            if ($Later) {
                $tail = if ($onRelease) { $modelLaterFix } else { $laterFix }
                $Remediation = if ($Remediation) { '{0} {1}' -f $Remediation, $tail } else { $tail }
            }
        }
        $item = New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $script:LivySessionDoc
        if ($showRow) {
            $rowState = switch ($Status) { 'Pass' { 'Done' } 'Not selected' { 'Skipped' } default { 'Action needed' } }
            $rowText = if ($Status -eq 'Warning' -and $Remediation) { '{0} {1}' -f $Message, $Remediation } else { $Message }
            Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State $rowState -Status $Status -Message $rowText -MaxLength 1200
        }
        if ($Status -eq 'Warning') {
            # The console says so at once, and that the run goes on.
            Write-DemoLog -Level Warning -Message ('{0} (doesn''t block DONE): {1} {2}' -f $CheckId, $Message, $Remediation)
        }
        return $item
    }
    # A statement that gave no answer, as the record's arguments. An HTTP answer past Invoke-DemoFabricRequest's retries is
    # Fabric's, never the code's own error, which only raising is (the review of c96f790a).
    $notAnswered = {
        param([pscustomobject] $Run, [string] $Raised)
        $why = if ($Run.ErrorName) { '{0}: {1}' -f $Run.ErrorName, $Run.ErrorValue } else { [string]$Run.ErrorValue }
        if ([string]$Run.Status -eq 'TimedOut') {
            return $timedOut
        }
        if ([string]$Run.Status -eq 'Error') {
            return @{ Status = 'Warning'; Outcome = 'StepFailed'; Message = ('{0} ({1}), so the history''s kept values weren''t worked out.' -f $Raised, $why); Remediation = $bugFix }
        }
        if ([string]$Run.Status -eq 'Cancelled') {
            return @{ Status = 'Warning'; Outcome = 'Failed'; Message = 'Fabric cancelled a statement in the Livy session, so the history''s kept values weren''t worked out.'; Later = $true }
        }
        switch (Get-DemoLivyFailureKind -StatusCode ([int]$Run.StatusCode) -ErrorText ([string]$Run.ErrorValue)) {
            'CapacityInactive' {
                return @{ Status = 'Warning'; Outcome = 'CapacityPaused'; Message = ('The workspace''s capacity is paused or inactive, so the history''s kept values weren''t worked out ({0}).' -f $why); Remediation = $capacityFix }
            }
            'Refused' {
                return @{ Status = 'Warning'; Outcome = 'Refused'; Message = ('Fabric refused a statement in the Livy session that works out the history''s kept values ({0}).' -f $why); Remediation = $refusedFix }
            }
        }
        return @{ Status = 'Warning'; Outcome = 'Failed'; Message = ('Fabric''s Livy API didn''t run a statement in the session that works out the history''s kept values ({0}).' -f $why); Later = $true }
    }

    try {
        $code = Get-DemoKeptValueCode
        if (-not $code) {
            return (& $record 'Not selected' 'NoModule' ('This checkout''s {0} has no kept_value_step, or isn''t there, so the history''s kept values weren''t worked out.' -f $script:KeptValueModulePath))
        }
        if ($null -eq $Token) {
            try {
                $Token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
            }
            catch {
                return (& $record 'Warning' 'NoToken' ('No Fabric token, so the history''s kept values weren''t worked out: {0}.' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.', ' ')) ("Sign in once with 'az login --tenant <tenantId>', then run {0}." -f $RunAgain))
            }
        }
        $target = Resolve-DemoKeptValueTarget -Config $Config -Token $Token
        if ($target.Paused) {
            return (& $record 'Warning' 'CapacityPaused' 'The workspace''s capacity is paused or inactive, so the history''s kept values weren''t worked out.' $capacityFix)
        }
        if (-not $target.Resolved) {
            return (& $record 'Not selected' 'NotResolved' ('The Fabric workspace or lakehouse isn''t there, so the history''s kept values weren''t worked out. {0}' -f $target.Why).Trim())
        }
        $sessionSeconds = [System.Math]::Min($SessionTimeoutMinutes * 60, (& $left))
        if ($sessionSeconds -lt 10) {
            return (& $record @timedOut)
        }

        if ($showRow) {
            Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message ('Working out the history''s kept values through Livy: a Spark session in the lakehouse, about 1 to 3 minutes (the first time, the whole history), at most {0} minutes. It doesn''t block DONE.' -f $TimeoutMinutes)
        }
        Write-DemoLog -Message ('{0}: working out the history''s kept values through Livy (F35), a Spark session in the demo''s lakehouse, with this checkout''s fabric/history/kept_value.py.' -f $CheckId)
        $session = $null
        $answer = $null
        try {
            $open = Open-DemoLivySession -WorkspaceId $target.WorkspaceId -LakehouseId $target.LakehouseId -Token $Token -Name ('dbhub-keptvalue-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)) -TimeoutSeconds $sessionSeconds -PollSeconds $PollSeconds
            $evidence['session'] = [ordered]@{ status = [string]$open.Status; states = @($open.States); secondsToReady = [int]$open.Seconds }
            if ([string]$open.Status -eq 'Idle') {
                $session = $open.Session
            }
            elseif ([string]$open.Status -eq 'CapacityInactive') {
                $answer = @{ Status = 'Warning'; Outcome = 'CapacityPaused'; Message = ('The workspace''s capacity is paused or inactive, so the history''s kept values weren''t worked out ({0}).' -f $open.Error); Remediation = $capacityFix }
            }
            elseif ([string]$open.Status -eq 'Refused') {
                $answer = @{ Status = 'Warning'; Outcome = 'Refused'; Message = ('Fabric refused the Livy session that works out the history''s kept values ({0}).' -f $open.Error); Remediation = $refusedFix }
            }
            else {
                $answer = @{ Status = 'Warning'; Outcome = 'SessionFailed'; Message = ('The Livy session that works out the history''s kept values didn''t start: {0}.' -f ([string]$open.Error).TrimEnd('.', ' ')); Remediation = ('Run {0} in a few minutes: a busy capacity queues a Spark session.' -f $RunAgain) }
            }
            # The module's load, then the step, each with what's left of the one deadline.
            do {
                if ($null -eq $session) {
                    break
                }
                $remaining = & $left
                if ($remaining -lt 10) {
                    $answer = $timedOut
                    break
                }
                $load = Invoke-DemoLivyStatement -Session $session -Code $code -TimeoutSeconds $remaining -PollSeconds ([System.Math]::Min($PollSeconds, 3))
                $evidence['load'] = [ordered]@{ status = [string]$load.Status; seconds = [int]$load.Seconds }
                if ($load.Status -ne 'Ok') {
                    $answer = & $notAnswered $load 'kept_value.py didn''t load in the Livy session'
                    break
                }
                $remaining = & $left
                if ($remaining -lt 10) {
                    $answer = $timedOut
                    break
                }
                $step = Invoke-DemoLivyStatement -Session $session -Code $script:KeptValueStepCode -TimeoutSeconds $remaining -PollSeconds $PollSeconds
                $evidence['run'] = [ordered]@{ status = [string]$step.Status; seconds = [int]$step.Seconds }
                if ($step.Status -ne 'Ok') {
                    $answer = & $notAnswered $step 'kept_value_step failed in the Livy session'
                    break
                }
                $json = ConvertFrom-DemoLivyJsonLine -Text $step.Output
                # Assigned apart: an if that yields @() assigns $null, whose Count StrictMode refuses.
                $absent = @()
                if ($null -ne $json) {
                    $absent = @($script:KeptValueJsonKeys | Where-Object { $null -eq $json.PSObject.Properties[$_] })
                }
                if ($null -eq $json -or $absent.Count -gt 0) {
                    $excerpt = ([string]$step.Output).Trim()
                    if ($excerpt.Length -gt 300) {
                        $excerpt = '...' + $excerpt.Substring($excerpt.Length - 300)
                    }
                    $evidence['output'] = $excerpt
                    $what = if ($null -eq $json) { 'didn''t end with its JSON' } else { 'lacked {0}' -f ($absent -join ', ') }
                    $answer = @{ Status = 'Warning'; Outcome = 'NoAnswer'; Message = ('kept_value_step''s answer {0}, so whether the history''s kept values were worked out is unknown.' -f $what); Remediation = ('Run {0}; if it answers the same way, it''s a bug: open an issue with this record.' -f $RunAgain) }
                    break
                }
                $answer = $json
            } while ($false)
        }
        finally {
            # Deleted whatever happened here, a stop of the run included; Open-DemoLivySession deleted one that wasn't idle.
            if ($null -ne $session) {
                $closed = Close-DemoLivySession -Session $session
                $evidence['session']['deleted'] = [bool]$closed.Deleted
                if (-not $closed.Deleted) {
                    Write-DemoLog -Level Warning -Message ('The Livy session wasn''t deleted ({0}); it ends by itself after 20 minutes idle.' -f $closed.Error)
                }
            }
        }
        if ($answer -is [System.Collections.IDictionary]) {
            return (& $record @answer)
        }

        # The step's own answer, every key checked above: its counts, and the form it allows.
        $stepError = [string]$answer.error
        $resolved = [long]$answer.resolved
        $pending = [long]$answer.pending
        $added = @(@($answer.added) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $missing = @(@($answer.missing) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $form = [string]$answer.form
        if ($form -in 'Kept', 'Release') {
            $evidence['form'] = $form
        }
        $evidence['step'] = [ordered]@{
            scope    = [string]$answer.scope
            missing  = $missing
            added    = $added
            read     = [long]$answer.read
            resolved = $resolved
            pending  = $pending
            attempts = [long]$answer.attempts
            seconds  = $answer.seconds
            error    = $stepError
        }
        if ($answer.exists -ne $true) {
            # With no history yet, as on a first deployment whose first history run hasn't saved any: never a Warning, and
            # what deploys the model in the kept form once there is (design A, approved 2026-11-23).
            $noTableTail = if ($ModelOnRelease) { $script:KeptValueNextDeployNote } elseif ($modelFollows) { 'The history model gets the release''s form for now, and deploy.ps1 deploys it in the kept values'' form once the history has rows: at this run''s end, after its history snapshot, or else the next ./scripts/deploy.ps1.' } else { 'The history model keeps the release''s form until there is.' }
            return (& $record 'Not selected' 'NoTable' ('The lakehouse has no history yet (no telemetry_snapshots table), so there were no kept values to work out. {0}' -f $noTableTail))
        }
        $addedText = if ($added.Count -gt 0) { '; it added {0} to telemetry_snapshots' -f ($added -join ', ') } else { '' }
        if ($form -cne 'Kept') {
            return (& $record 'Warning' 'NoColumns' ('telemetry_snapshots still lacks {0}{1}, so the history''s kept values weren''t worked out.' -f $(if ($missing.Count -gt 0) { $missing -join ', ' } else { 'F35''s columns' }), $(if ($stepError) { ' ({0})' -f $stepError } else { '' })) -Later)
        }
        if ($stepError -or $pending -gt 0) {
            return (& $record 'Warning' 'Partial' ('The history''s kept values are only partly worked out: {0:N0} rows this time{1}, {2:N0} still to do{3}.' -f $resolved, $addedText, $pending, $(if ($stepError) { ' ({0})' -f $stepError } else { '' })) -Later)
        }
        if ($ModelOnRelease) {
            if ($SwitchModelForm) {
                # Every row is worked out, so the model gets their form now, by the Fabric track's own step, rather than a
                # Warning that asks for the track again (design A, approved 2026-11-23). Never a Fail: the script's records
                # stay out of the run's results, and this record says what happened.
                if ($showRow) {
                    Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message 'Deploying the history model in the kept values'' form, by the Fabric track''s own step (configure-powerbi.ps1). It doesn''t block DONE.'
                }
                Write-DemoLog -Message ('{0}: every row''s kept value is worked out, and this run''s Fabric track deployed the history model in the release''s form, so it''s deployed in the kept values'' form now (configure-powerbi.ps1).' -f $CheckId)
                $deployKept = Invoke-DemoKeptValueModelSwitch -Config $Config -ConfigPath $ConfigPath
                $evidence['modelSwitch'] = $deployKept.Evidence
                if ($deployKept.Switched) {
                    return (& $record 'Pass' 'Switched' ('Worked out the history''s kept values: {0:N0} rows this time{1}, none left, and deployed the history model in their form (this run''s Fabric track had deployed the release''s).' -f $resolved, $addedText))
                }
                return (& $record 'Warning' 'SwitchFailed' ('The history''s kept values are worked out, {0:N0} rows this time{1}, with none left, but deploying the history model in their form didn''t work: {2}.' -f $resolved, $addedText, $deployKept.Why) $bugFix)
            }
            # Every row is worked out, but this run's history model reads the release's form: its Fabric-track step didn't
            # allow the kept one, and the model doesn't read them until the Fabric track runs again (the review of c96f790a).
            return (& $record 'Warning' 'ModelOnRelease' ('The history''s kept values are worked out, {0:N0} rows this time{1}, with none left, but the history model doesn''t read them yet.' -f $resolved, $addedText) -Later)
        }
        if ($resolved -gt 0) {
            return (& $record 'Pass' 'Done' ('Worked out the history''s kept values: {0:N0} rows this time{1}, none left.' -f $resolved, $addedText))
        }
        return (& $record 'Pass' 'Done' ('The history''s kept values were already worked out: nothing was left to do{0}.' -f $addedText))
    }
    catch {
        # A stop of the run goes through; anything else is this step's own failure, which never blocks DONE.
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $network = Test-DemoNetworkFailure -Exception $_.Exception
        $evidence['networkError'] = [bool]$network
        return (& $record 'Warning' 'Failed' ('Working out the history''s kept values stopped: {0}.' -f (Get-DemoExceptionText -Exception $_.Exception).TrimEnd('.', ' ')) $(if ($network) { Get-DemoNetworkErrorNote } else { '' }) -Later)
    }
}