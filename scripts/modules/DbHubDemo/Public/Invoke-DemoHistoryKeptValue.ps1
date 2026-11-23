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
    3. kept_value.py's text, as one statement (it only defines names), then kept_value_step(spark), within -TimeoutMinutes:
       it adds whichever of grain_minutes, kept_value, and resolved_at_utc telemetry_snapshots lacks, and works out every
       row not worked out yet (the first time, the whole history). Its JSON is the output's last line.
    4. The session is deleted, always (Close-DemoLivySession); one left behind ends by itself after 20 minutes idle.

    The record (-CheckId) has evidence nonBlocking keptValue, outcome, form, the step's counts (step), and the session's
    states (session):
    - Pass: every row is worked out (outcome Done).
    - Not selected: no history table yet (NoTable); the workspace or the lakehouse isn't there (NotResolved); this
      checkout has no kept_value.py (NoModule).
    - Warning, which says what didn't work, that the history's totals read as before F35 until a later run works them
      out, and how to run it again (-RunAgain): a paused or inactive capacity (CapacityPaused), no token (NoToken), a
      refused session (Refused), a session that wasn't ready or ended (SessionFailed), a statement that failed or ran out
      of time (StepFailed, TimedOut), an answer without the step's JSON (NoAnswer), a table still without the columns
      (NoColumns), or a step that stopped with rows left (Partial).
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
    How long kept_value_step may run. A first run over a long history takes minutes.

    .PARAMETER SessionTimeoutMinutes
    How long the Livy session may take to be ready; a busy capacity queues it.

    .PARAMETER ProgressPath
    The status page's model (deploy-progress.json); nothing without it.

    .PARAMETER ProgressId
    The status page's row for -ProgressPath.

    .PARAMETER RunAgain
    The command that runs the step again, for the Warnings' fix.

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

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 5
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $evidence = [ordered]@{ nonBlocking = 'keptValue'; outcome = ''; form = '' }
    $showRow = [bool]($ProgressPath -and $ProgressId)
    $asBefore = 'Until a later run works them out, the history''s totals read as before F35, where overlapping saves can count twice.'
    $later = 'Nothing to do now: a later deploy.ps1, stop-demo.ps1 -SaveHistory, or configure-fabric.ps1 -RunLiveActivity works them out; to do it now, run {0}.' -f $RunAgain
    $record = {
        param([string] $Status, [string] $Outcome, [string] $Message, [string] $Remediation = '')
        $evidence['outcome'] = $Outcome
        $evidence['seconds'] = [int]$watch.Elapsed.TotalSeconds
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

    try {
        $code = Get-DemoKeptValueCode
        if (-not $code) {
            return (& $record 'Not selected' 'NoModule' ('This checkout has no {0}, so the history''s kept values weren''t worked out.' -f $script:KeptValueModulePath))
        }
        if ($null -eq $Token) {
            try {
                $Token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
            }
            catch {
                return (& $record 'Warning' 'NoToken' ('No Fabric token, so the history''s kept values weren''t worked out: {0}. {1}' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.', ' '), $asBefore) ("Sign in once with 'az login --tenant <tenantId>', then run {0}." -f $RunAgain))
            }
        }
        $target = Resolve-DemoKeptValueTarget -Config $Config -Token $Token
        if ($target.Paused) {
            return (& $record 'Warning' 'CapacityPaused' ('The workspace''s capacity is paused or inactive, so the history''s kept values weren''t worked out. {0}' -f $asBefore) (Get-DemoFabricCapacityResumeFix -Then ('run {0}.' -f $RunAgain)))
        }
        if (-not $target.Resolved) {
            return (& $record 'Not selected' 'NotResolved' ('The Fabric workspace or lakehouse isn''t there, so the history''s kept values weren''t worked out. {0}' -f $target.Why).Trim())
        }

        if ($showRow) {
            Set-DemoProgressStep -Path $ProgressPath -Id $ProgressId -State 'Running' -Message 'Working out the history''s kept values through Livy: a Spark session in the lakehouse, about 1 to 3 minutes (the first time, the whole history). It doesn''t block DONE.'
        }
        Write-DemoLog -Message ('{0}: working out the history''s kept values through Livy (F35), a Spark session in the demo''s lakehouse, with this checkout''s fabric/history/kept_value.py.' -f $CheckId)
        $open = Open-DemoLivySession -WorkspaceId $target.WorkspaceId -LakehouseId $target.LakehouseId -Token $Token -Name ('dbhub-keptvalue-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)) -TimeoutSeconds ($SessionTimeoutMinutes * 60) -PollSeconds $PollSeconds
        $evidence['session'] = [ordered]@{ status = [string]$open.Status; states = @($open.States); secondsToReady = [int]$open.Seconds }
        switch ([string]$open.Status) {
            'Idle' {
                break
            }
            'CapacityInactive' {
                return (& $record 'Warning' 'CapacityPaused' ('The workspace''s capacity is paused or inactive, so the history''s kept values weren''t worked out ({0}). {1}' -f $open.Error, $asBefore) (Get-DemoFabricCapacityResumeFix -Then ('run {0}.' -f $RunAgain)))
            }
            'Refused' {
                return (& $record 'Warning' 'Refused' ('Fabric refused the Livy session that works out the history''s kept values ({0}). {1}' -f $open.Error, $asBefore) ('Check that your account has Contributor or higher on the demo''s workspace, and that a Fabric administrator allows the Livy API in the tenant settings; then run {0}.' -f $RunAgain))
            }
            default {
                return (& $record 'Warning' 'SessionFailed' ('The Livy session that works out the history''s kept values didn''t start: {0}. {1}' -f $open.Error, $asBefore) ('Run {0} in a few minutes: a busy capacity queues a Spark session.' -f $RunAgain))
            }
        }

        $answer = $null
        try {
            $load = Invoke-DemoLivyStatement -Session $open.Session -Code $code -TimeoutSeconds 300 -PollSeconds ([System.Math]::Min($PollSeconds, 3))
            $evidence['load'] = [ordered]@{ status = [string]$load.Status; seconds = [int]$load.Seconds }
            if ($load.Status -ne 'Ok') {
                $why = if ($load.ErrorName) { '{0}: {1}' -f $load.ErrorName, $load.ErrorValue } else { $load.ErrorValue }
                $answer = @('Warning', 'StepFailed', ('kept_value.py didn''t load in the Livy session ({0}), so the history''s kept values weren''t worked out. {1}' -f $why, $asBefore), ('Run {0}; if it fails the same way, it''s a bug: open an issue with this record.' -f $RunAgain))
            }
            else {
                $step = Invoke-DemoLivyStatement -Session $open.Session -Code $script:KeptValueStepCode -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds
                $evidence['run'] = [ordered]@{ status = [string]$step.Status; seconds = [int]$step.Seconds }
                $json = if ($step.Status -eq 'Ok') { ConvertFrom-DemoLivyJsonLine -Text $step.Output } else { $null }
                # Assigned apart: an if that yields @() assigns $null, whose Count StrictMode refuses.
                $absent = @()
                if ($null -ne $json) {
                    $absent = @($script:KeptValueJsonKeys | Where-Object { $null -eq $json.PSObject.Properties[$_] })
                }
                if ($step.Status -eq 'TimedOut') {
                    $answer = @('Warning', 'TimedOut', ('Working out the history''s kept values didn''t finish in {0} minutes, so it was stopped; the rows it finished keep theirs. {1}' -f $TimeoutMinutes, $asBefore), $later)
                }
                elseif ($step.Status -ne 'Ok') {
                    $why = if ($step.ErrorName) { '{0}: {1}' -f $step.ErrorName, $step.ErrorValue } else { $step.ErrorValue }
                    $answer = @('Warning', 'StepFailed', ('kept_value_step failed in the Livy session ({0}), so the history''s kept values weren''t worked out. {1}' -f $why, $asBefore), ('Run {0}; if it fails the same way, it''s a bug: open an issue with this record.' -f $RunAgain))
                }
                elseif ($null -eq $json -or $absent.Count -gt 0) {
                    $excerpt = ([string]$step.Output).Trim()
                    if ($excerpt.Length -gt 300) {
                        $excerpt = '...' + $excerpt.Substring($excerpt.Length - 300)
                    }
                    $evidence['output'] = $excerpt
                    $what = if ($null -eq $json) { 'didn''t end with its JSON' } else { 'lacked {0}' -f ($absent -join ', ') }
                    $answer = @('Warning', 'NoAnswer', ('kept_value_step''s answer {0}, so whether the history''s kept values were worked out is unknown. {1}' -f $what, $asBefore), ('Run {0}; if it answers the same way, it''s a bug: open an issue with this record.' -f $RunAgain))
                }
                else {
                    $answer = $json
                }
            }
        }
        finally {
            $closed = Close-DemoLivySession -Session $open.Session
            $evidence['session']['deleted'] = [bool]$closed.Deleted
            if (-not $closed.Deleted) {
                Write-DemoLog -Level Warning -Message ('The Livy session wasn''t deleted ({0}); it ends by itself after 20 minutes idle.' -f $closed.Error)
            }
        }
        if ($answer -is [array]) {
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
            return (& $record 'Not selected' 'NoTable' 'The lakehouse has no history yet (no telemetry_snapshots table), so there were no kept values to work out. The history model keeps the release''s form until there is.')
        }
        $addedText = if ($added.Count -gt 0) { '; it added {0} to telemetry_snapshots' -f ($added -join ', ') } else { '' }
        if ($form -cne 'Kept') {
            return (& $record 'Warning' 'NoColumns' ('telemetry_snapshots still lacks {0}{1}, so the history''s kept values weren''t worked out, and the history model keeps the release''s form. {2}' -f $(if ($missing.Count -gt 0) { $missing -join ', ' } else { 'F35''s columns' }), $(if ($stepError) { ' ({0})' -f $stepError } else { '' }), $asBefore) $later)
        }
        if ($stepError -or $pending -gt 0) {
            return (& $record 'Warning' 'Partial' ('The history''s kept values are only partly worked out: {0:N0} rows this time{1}, {2:N0} still to do{3}. {4}' -f $resolved, $addedText, $pending, $(if ($stepError) { ' ({0})' -f $stepError } else { '' }), $asBefore) $later)
        }
        if ($resolved -gt 0) {
            return (& $record 'Pass' 'Done' ('Worked out the history''s kept values: {0:N0} rows this time{1}, none left (F35: overlapping saves count once).' -f $resolved, $addedText))
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
        return (& $record 'Warning' 'Failed' ('Working out the history''s kept values stopped: {0}. {1}' -f (Get-DemoExceptionText -Exception $_.Exception).TrimEnd('.', ' '), $asBefore) $(if ($network) { '{0} {1}' -f (Get-DemoNetworkErrorNote), $later } else { $later }))
    }
}
