# F35, design (i) (2026-11-23): the history's kept values, worked out through Fabric's Livy API by the PC's scripts with this
# checkout's fabric/history/kept_value.py (Invoke-DemoHistoryKeptValue), so an environment whose workspace keeps an older
# NB_DatabaseHub_LiveActivity gets them with no decision. deploy.ps1's Fabric track runs it before the history model's step,
# which deploys the form of Snapshot Value that its answer allows (Get-DemoKeptValueForm), and deploy.ps1's end runs it
# again after the history snapshot (Invoke-DemoKeptValueEndStep), and deploys the model in the kept form there when the
# track couldn't (design A); stop-demo.ps1 -SaveHistory and configure-fabric.ps1
# -RunLiveActivity run it after their saves. Its records are never a Fail or Manual action required, and never block DONE.

$script:KeptValueModulePath = 'fabric/history/kept_value.py'
# The step's JSON: every key is always there (the resolve module's interface, 2026-11-23).
$script:KeptValueJsonKeys = @('version', 'table', 'exists', 'missing', 'added', 'form', 'scope', 'read', 'resolved', 'pending', 'attempts', 'seconds', 'error')
$script:KeptValueStepCode = 'import json; print(json.dumps(kept_value_step(spark)))'
$script:KeptValueRunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'
# The command that also deploys the history model in the kept values' form: the Fabric track again, which a plain rerun skips
# once an earlier run recorded it.
$script:KeptValueTrackRunAgain = './scripts/deploy.ps1 -FromStage Fabric'
# What deploy.ps1's end says when this run's history model keeps the release's form although this checkout has the kept one,
# and it had no rows to work out, so it couldn't switch it (F35, design A): a plain deploy.ps1 runs the Fabric step again,
# as a full run after one whose tracks all finished, or as a resume, since the step didn't record its content as published
# (Test-DemoKeptFormPending).
$script:KeptValueNextDeployNote = 'This run''s history model keeps the release''s form, where overlapping saves can count twice, and the next ./scripts/deploy.ps1 works out the kept values and deploys the model in their form by itself.'
# The same as a fix line: the Fabric track's Warning gets it when deploy.ps1's end had no rows to work out, so the run's
# last lines don't ask for the Fabric track again while its end says the next deploy.ps1 does it (the re-check of 32e39e6a).
$script:KeptValueNextDeployFix = 'Nothing to do now: the next ./scripts/deploy.ps1 works out the history''s kept values and deploys the history model in their form by itself.'
# configure-powerbi.ps1's record of the form it deployed (the notebook and model's work): a Warning for the release's form,
# which deploy.ps1's end settles once it has deployed the kept one, with the history report's row (Fabric.Report).
$script:KeptValueFormCheckId = 'FABRIC.SEMANTICMODEL.FORM'
$script:KeptValueReportRowId = 'Fabric.Report'
$script:KeptValueFormSettled = 'Snapshot Value reads the kept values in telemetry_snapshots (F35): this run''s end deployed that form after its history snapshot, once every row''s kept value was worked out (DEPLOY.FABRIC.KEPTVALUE.END).'
# What that Warning says instead, Not selected with the next-deploy fix, when deploy.ps1's end had no rows to work out: no
# Warning asks for a step that the next deploy.ps1 takes by itself (design A, the re-check of 5411cca1).
$script:KeptValueFormWaits = 'Snapshot Value has the release''s form for now: this run''s end didn''t work out the history''s kept values (DEPLOY.FABRIC.KEPTVALUE.END: its history snapshot saved nothing, or there was no table), so the history''s totals can count a minute twice where saves at different intervals hold it (F35).'
# The history model and report's records (configure-powerbi.ps1 through Invoke-DemoPowerBIStage), which the history report's
# row shows, as the Fabric track's step sets it.
$script:KeptValueReportRecordPattern = '^(FABRIC\.(SEMANTICMODEL|REPORT)\.|FABRIC\.(IMPORT|READBACK)\.(SM|RPT)_|DEPLOY\.POWERBI$)'
# What the Fabric track's step can answer that a later deploy.ps1 fixes by itself: no history yet, or a session, a step, or the
# columns that a busy or slow capacity kept from working out. Only these point to the next deploy.ps1 when the end had no
# rows to work out; a refusal, a paused capacity, no token, or a bug keeps its own fix (the re-check of 5411cca1).
$script:KeptValueRerunOutcomes = @('NoTable', 'SessionFailed', 'TimedOut', 'Failed', 'NoColumns')
$script:KeptValueDeployCheckId = 'DEPLOY.FABRIC.KEPTVALUE'
$script:KeptValueEndCheckId = 'DEPLOY.FABRIC.KEPTVALUE.END'
$script:KeptValueTrackRowId = 'Fabric.KeptValues'
$script:KeptValueEndRowId = 'Fabric.HistoryKept'

function Get-DemoKeptValueCode {
    # This checkout's fabric/history/kept_value.py as text, which a Livy statement runs as it is, or '' when it isn't there,
    # or has no kept_value_step yet, as the groundwork's module hasn't: every step would then fail on a NameError (the review
    # of c96f790a). -Path reads another file. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Path = ''
    )

    if (-not $Path) {
        $Path = Join-Path -Path $script:RepoRoot -ChildPath $script:KeptValueModulePath
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $text.Contains('def kept_value_step(')) {
        return ''
    }
    return $text
}

function Get-DemoKeptValueForm {
    # The form of Snapshot Value that a record of Invoke-DemoHistoryKeptValue allows: Kept when its own Livy session's step
    # found telemetry_snapshots with all three F35 columns (evidence form Kept), otherwise '' (configure-powerbi.ps1 then
    # deploys the release's form, its default). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Result
    )

    $evidence = Get-DemoMemberValue -InputObject $Result -Name 'evidence'
    if ([string](Get-DemoMemberValue -InputObject $evidence -Name 'form') -ceq 'Kept') {
        return 'Kept'
    }
    return ''
}

function Test-DemoKeptFormDeployable {
    # Whether this checkout's scripts/configure-powerbi.ps1 can deploy the history model in the kept values' form (F35): it
    # declares -SnapshotValueForm, which the notebook and model's work adds. Without it the script has only the release's
    # form, so nothing waits for the kept one: no switch at deploy.ps1's end, and no Warning that the model reads the
    # release's form. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $scriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-powerbi.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return $false
    }
    try {
        return [bool](Get-Command -Name $scriptPath -ErrorAction Stop).Parameters.ContainsKey('SnapshotValueForm')
    }
    catch {
        return $false
    }
}

function Test-DemoKeptFormPending {
    # Whether the history model went out in the release's form although this checkout has the kept one (F35, design A,
    # approved 2026-11-23): -Result, the Fabric track's DEPLOY.FABRIC.KEPTVALUE, doesn't allow the kept form, for any reason
    # (no history yet, or a failure), and configure-powerbi.ps1 takes -SnapshotValueForm (Test-DemoKeptFormDeployable). The
    # Fabric step then doesn't record its content as published (DbHubFabricSha256), so the next deploy.ps1, a resume
    # included, runs it again; and deploy.ps1's end switches the model once it has worked out every row
    # (Invoke-DemoKeptValueEndStep). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    return ((Get-DemoKeptValueForm -Result $Result) -cne 'Kept' -and (Test-DemoKeptFormDeployable))
}

function Invoke-DemoKeptValueModelSwitch {
    <#
    .SYNOPSIS
    The history model in the kept values' form, by the Fabric track's own step (Invoke-DemoPowerBIStage -SnapshotValueForm
    Kept: configure-powerbi.ps1's model, its refresh and data check, and the report), for deploy.ps1's end once its step
    has worked out every row while this run's track deployed the release's form (F35, design A, approved 2026-11-23).
    Internal.

    .DESCRIPTION
    Returns Switched (none of the script's records is a Fail or Manual action required), KeptDeployed (the model reads the
    kept form: Switched, or the script imported it in that form, FABRIC.SEMANTICMODEL.FORM Pass, and something after the
    import didn't work, its refresh, data check, or report), Why (the first record that is a Fail or Manual action required,
    with its check ID, status, and message, or the error), and Evidence (switched, keptDeployed, the records' count by status,
    and those that didn't pass). The records stay out of the run's results, so a Fail among them never blocks DONE; the
    end's record says what happened. With KeptDeployed, the status page's history-report row (Fabric.Report, -ProgressPath)
    shows this deployment as the Fabric track's own step shows its own, but never Failed (the re-check of 32e39e6a). Only a
    stop of the run throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $ProgressPath = ''
    )

    try {
        $records = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $ConfigPath -SnapshotValueForm 'Kept' | Where-Object { $null -ne $_ })
    }
    catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $text = (Get-DemoExceptionText -Exception $_.Exception).TrimEnd('.', ' ')
        return [pscustomobject]@{ Switched = $false; KeptDeployed = $false; Why = $text; Evidence = [ordered]@{ switched = $false; keptDeployed = $false; records = 0; error = $text } }
    }
    $counts = [ordered]@{}
    foreach ($item in $records) {
        $counts[[string]$item.status] = 1 + [int]$counts[[string]$item.status]
    }
    $failed = @($records | Where-Object { [string]$_.status -in 'Fail', 'Manual action required' })
    $why = ''
    if ($failed.Count -gt 0) {
        $why = Protect-DemoText -Text ('{0} ({1}): {2}' -f [string]$failed[0].checkId, [string]$failed[0].status, ([string]$failed[0].message).TrimEnd('.', ' '))
    }
    elseif ($records.Count -eq 0) {
        $why = 'configure-powerbi.ps1 returned no results'
    }
    $switched = -not $why
    $formPass = @($records | Where-Object { [string]$_.checkId -eq $script:KeptValueFormCheckId -and [string]$_.status -eq 'Pass' })
    $keptDeployed = $switched -or ($formPass.Count -gt 0)
    if ($keptDeployed) {
        # The history report's row, as the Fabric track's step sets it from its records: this deployment replaced that one.
        $worst = Get-DemoWorstStatus -Status @($records | ForEach-Object { [string]$_.status })
        if ($worst -in 'Fail', 'Manual action required') {
            $worst = 'Warning'
        }
        $firstOpen = @($records | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | Select-Object -First 1)
        Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueReportRowId -State $(if ($worst) { ConvertTo-DemoProgressState -Status $worst } else { 'Done' }) -Status $worst -Message $(if ($firstOpen.Count -gt 0) { [string]$firstOpen[0].message } else { '' })
    }
    return [pscustomobject]@{
        Switched     = $switched
        KeptDeployed = $keptDeployed
        Why          = $why
        Evidence     = [ordered]@{
            switched     = $switched
            keptDeployed = $keptDeployed
            records      = $records.Count
            statuses     = $counts
            notPassed    = @($records | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | ForEach-Object { '{0} {1}' -f [string]$_.checkId, [string]$_.status })
        }
    }
}

function Resolve-DemoKeptValueTarget {
    <#
    .SYNOPSIS
    The workspace and the lakehouse a kept-value step works in: fabric.workspaceId and fabric.lakehouseId when they're
    resolved already (a GUID other than the all-zero placeholder), otherwise by name, read-only (Resolve-DemoFabricConfig
    without -Create). Returns WorkspaceId, LakehouseId, Resolved, Paused (Fabric refused the lakehouse list because the
    capacity is paused or inactive), and Why. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [securestring] $Token
    )

    $fabric = Get-DemoMemberValue -InputObject $Config -Name 'fabric'
    $workspaceId = [string](Get-DemoMemberValue -InputObject $fabric -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $fabric -Name 'lakehouseId')
    if ((Test-DemoFabricIdOverride -Value $workspaceId) -and (Test-DemoFabricIdOverride -Value $lakehouseId)) {
        return [pscustomobject]@{ WorkspaceId = $workspaceId; LakehouseId = $lakehouseId; Resolved = $true; Paused = $false; Why = '' }
    }
    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $Token -Confirm:$false
    if ($resolution.Resolved) {
        $resolvedFabric = Get-DemoMemberValue -InputObject $resolution.Config -Name 'fabric'
        return [pscustomobject]@{
            WorkspaceId = [string](Get-DemoMemberValue -InputObject $resolvedFabric -Name 'workspaceId')
            LakehouseId = [string](Get-DemoMemberValue -InputObject $resolvedFabric -Name 'lakehouseId')
            Resolved    = $true
            Paused      = $false
            Why         = ''
        }
    }
    $paused = @($resolution.Results | Where-Object { (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'evidence') -Name 'capacityInactive') -eq $true }).Count -gt 0
    $why = (@($resolution.Results | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | ForEach-Object { '{0}: {1}' -f [string]$_.checkId, [string]$_.message }) -join ' ').Trim()
    return [pscustomobject]@{ WorkspaceId = ''; LakehouseId = ''; Resolved = $false; Paused = $paused; Why = $why }
}

function Invoke-DemoKeptValueEndStep {
    <#
    .SYNOPSIS
    deploy.ps1's end (F35, 2026-11-23): after the history snapshot (DEPLOY.FABRIC.HISTORY), the kept values of the rows it
    saved, and of any other row not worked out yet (Invoke-DemoHistoryKeptValue), on the status page's Fabric.HistoryKept
    row, and the history model in the kept values' form when this run's Fabric track couldn't deploy it so. Returns one
    DEPLOY.FABRIC.KEPTVALUE.END record, never a Fail or Manual action required. Internal.

    .DESCRIPTION
    Both deployment paths call it right after Invoke-DemoHistorySnapshotStep. Not selected, with the row Skipped, for
    -WhatIfRun, -SkipFabric, and a snapshot that saved nothing in this run (its outcome isn't Saved or SavedNotRefreshed):
    there's no new row to work out, and the Fabric track's step worked out the older ones. The history model reads the new
    kept values once Direct Lake updates it (the snapshot's refresh, or Direct Lake's automatic updates), when it has their
    form.

    When this run's DEPLOY.FABRIC.KEPTVALUE (in -Result) didn't allow that form, for any reason (no history yet, as on a
    first deployment whose first history run hadn't saved any, or a failure), and this checkout's configure-powerbi.ps1 has
    it, the model waits for it (Test-DemoKeptFormPending; design A, approved 2026-11-23):
    - The step runs with -ModelOnRelease and -SwitchModelForm, and -RunAgain ./scripts/deploy.ps1 -FromStage Fabric. Once
      it has worked out every row, it deploys the model in the kept form by the Fabric track's own step, a Pass (Switched).
      Once the model reads that form (Switched, or a SwitchFailed whose import of the kept form passed), what this run's
      track said about the release's form is settled, each keeping what it said in its evidence (earlierMessage): a
      Warning from the track's step becomes a Pass, with its row Done, and so does every FABRIC.SEMANTICMODEL.FORM Warning
      from its model step (configure-powerbi.ps1's record of the release's form; #68's follow-up adds one too), with
      evidence form Kept. The switch shows the history report's row (Fabric.Report) itself (the re-check of 32e39e6a). A
      switch that doesn't work is one Warning (SwitchFailed), as are the step's own failures, which say that the model
      reads the release's form.
    - With no rows to work out (a snapshot that saved nothing, or still no history table), it's Not selected, never a
      Warning, and says that the next ./scripts/deploy.ps1 deploys the model in the kept form by itself: a full run after
      one whose tracks all finished, or a resume, which runs the Fabric step again since it cleared its record of the
      content it published. Nothing else then says Warning about it either, when the track's step answered what a later run
      fixes by itself (NoTable, SessionFailed, TimedOut, Failed, or NoColumns; the re-check of 5411cca1): a Warning from
      the track's step and every FABRIC.SEMANTICMODEL.FORM Warning of the release's form become Not selected, each with
      that as its fix and what it said kept in its evidence (earlierMessage), on their rows too: the track's step's, and the
      history report's (Fabric.Report). A refusal, a paused capacity, no token, or a bug at the track (Refused,
      CapacityPaused, NoToken, StepFailed, NoAnswer) keeps its own fix, and those Warnings stay. So do a Livy failure at
      both the track and the end, and a switch that doesn't work.
    A run whose Fabric track didn't run its step (a resume) keeps the model its earlier run deployed. -ConfigPath goes to
    configure-powerbi.ps1 for the switch.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [object[]] $Result = @(),

        [switch] $SkipFabric,

        [switch] $WhatIfRun,

        [AllowEmptyString()]
        [string] $ProgressPath = '',

        [AllowEmptyString()]
        [string] $ConfigPath = '',

        [ValidateRange(1, 240)]
        [int] $TimeoutMinutes = 15
    )

    $skip = {
        param([string] $Message)
        Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueEndRowId -State 'Skipped' -Status 'Not selected' -Message $Message -MaxLength 1200
        New-DemoResult -CheckId $script:KeptValueEndCheckId -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $Message -Evidence ([ordered]@{ nonBlocking = 'keptValue'; outcome = 'NotSelected' }) -DocUrl $script:LivySessionDoc
    }
    if ($WhatIfRun) {
        return (& $skip 'What if: nothing ran. A deployment works out the kept values of its history snapshot at its end, through Livy.')
    }
    if ($SkipFabric) {
        return (& $skip 'The Fabric track was skipped (-SkipFabric), so the history''s kept values weren''t worked out.')
    }
    $track = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $script:KeptValueDeployCheckId }) | Select-Object -Last 1
    $waits = $null -ne $track -and (Test-DemoKeptFormPending -Result $track)
    # With no rows to work out, nothing that waits for the kept form stays a Warning when a later run fixes it by itself: the
    # next ./scripts/deploy.ps1 deploys it (design A; the re-checks of 32e39e6a and 5411cca1). The Fabric track's Warning,
    # and configure-powerbi.ps1's of the release's form, become Not selected with that as their fix, keeping what they said.
    # Any other answer at the track keeps its own fix, as a Warning, and so does the release's form.
    $settleNoRows = {
        if (-not $waits) {
            return
        }
        $trackOutcome = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $track -Name 'evidence') -Name 'outcome')
        if ($trackOutcome -notin $script:KeptValueRerunOutcomes) {
            return
        }
        if ([string]$track.status -eq 'Warning') {
            Set-DemoHistoryResultText -Result $track -Status 'Not selected' -Message ('This step didn''t work out the history''s kept values ({0}), and this run''s end didn''t work them out either (its history snapshot saved nothing, or there was no table), so this run''s history model keeps the release''s form for now, where overlapping saves can count twice.' -f $trackOutcome) -Remediation $script:KeptValueNextDeployFix
            Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueTrackRowId -State 'Skipped' -Status 'Not selected' -Message ('{0} {1}' -f [string]$track.message, $script:KeptValueNextDeployFix) -MaxLength 1200
        }
        $forms = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $script:KeptValueFormCheckId -and [string]$_.status -eq 'Warning' })
        foreach ($form in $forms) {
            Set-DemoHistoryResultText -Result $form -Status 'Not selected' -Message $script:KeptValueFormWaits -Remediation $script:KeptValueNextDeployFix
        }
        if ($forms.Count -gt 0) {
            # The history report's row, from the history model and report's records as the track's step sets it; a form
            # record means the model's import passed.
            $report = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -match $script:KeptValueReportRecordPattern })
            $worst = Get-DemoWorstStatus -Status (@('Pass') + @($report | ForEach-Object { [string]$_.status }))
            $firstOpen = @($report | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | Select-Object -First 1)
            $text = if ($firstOpen.Count -gt 0) { [string]$firstOpen[0].message } else { '{0} {1}' -f $script:KeptValueFormWaits, $script:KeptValueNextDeployFix }
            Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueReportRowId -State (ConvertTo-DemoProgressState -Status $worst) -Status $worst -Message $text -MaxLength 1200
        }
    }
    $snapshot = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'DEPLOY.FABRIC.HISTORY' }) | Select-Object -Last 1
    $outcome = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $snapshot -Name 'evidence') -Name 'outcome')
    if ($outcome -notin 'Saved', 'SavedNotRefreshed') {
        $message = 'The history snapshot saved nothing in this run (DEPLOY.FABRIC.HISTORY says why), so there were no new rows whose kept values to work out.'
        if ($waits) {
            $message = '{0} {1}' -f $message, $script:KeptValueNextDeployNote
            & $settleNoRows
        }
        return (& $skip $message)
    }
    $runAgain = if ($waits) { $script:KeptValueTrackRunAgain } else { $script:KeptValueRunAgain }
    $kept = Invoke-DemoHistoryKeptValue -Config $Config -CheckId $script:KeptValueEndCheckId -TimeoutMinutes $TimeoutMinutes -ProgressPath $ProgressPath -ProgressId $script:KeptValueEndRowId -RunAgain $runAgain -ModelOnRelease:$waits -SwitchModelForm:$waits -ConfigPath $ConfigPath
    $keptEvidence = Get-DemoMemberValue -InputObject $kept -Name 'evidence'
    if ($waits -and [string](Get-DemoMemberValue -InputObject $keptEvidence -Name 'outcome') -eq 'NoTable') {
        & $settleNoRows
    }
    $readsKept = $waits -and [bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $keptEvidence -Name 'modelSwitch') -Name 'keptDeployed')
    if ($readsKept) {
        if ([string]$track.status -eq 'Warning') {
            # The model reads the kept values now, so the track's Warning, whose fix was the Fabric track again, is settled; its
            # evidence keeps what it said (design A, as the #68 follow-up settles the first history run's).
            $why = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $track -Name 'evidence') -Name 'outcome')
            Set-DemoHistoryResultText -Result $track -Status 'Pass' -Message ('This step didn''t work out the history''s kept values{0}, but this run''s end did, after its history snapshot, and deployed the history model in their form (DEPLOY.FABRIC.KEPTVALUE.END).' -f $(if ($why) { ' ({0})' -f $why } else { '' }))
            Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueTrackRowId -State 'Done' -Status 'Pass' -Message ([string]$track.message) -MaxLength 1200
        }
        # And what the track's model step said of the release's form (configure-powerbi.ps1), whose fix was deploy.ps1 again;
        # #68's follow-up says it once more (the re-check of 32e39e6a).
        foreach ($form in @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $script:KeptValueFormCheckId -and [string]$_.status -eq 'Warning' })) {
            Set-DemoHistoryResultText -Result $form -Status 'Pass' -Message $script:KeptValueFormSettled
            $formEvidence = Get-DemoMemberValue -InputObject $form -Name 'evidence'
            if ($formEvidence -is [System.Collections.IDictionary]) {
                $formEvidence['form'] = 'Kept'
            }
            elseif ($null -ne $formEvidence) {
                Add-Member -InputObject $formEvidence -NotePropertyName 'form' -NotePropertyValue 'Kept' -Force
            }
        }
    }
    return $kept
}

function Get-DemoKeptValueItem {
    <#
    .SYNOPSIS
    What DONE, NOT DONE, DEPLOY.SUMMARY, and the status page's Needs attention box say when deploy.ps1's kept-value steps
    didn't work (F35, 2026-11-23), as an item of Get-DemoNonBlockingItem (name, state Action needed, message, howTo), or
    $null. Pure. Internal.

    .DESCRIPTION
    The latest DEPLOY.FABRIC.KEPTVALUE or DEPLOY.FABRIC.KEPTVALUE.END that isn't Not selected, when it's a Warning. A Pass at
    the end settles the Fabric track's Warning: when the track's step didn't allow the kept form and this checkout has it,
    the end reaches a Pass only by deploying the model in that form, which also turns the track's Warning into a Pass
    (Invoke-DemoKeptValueEndStep; design A, approved 2026-11-23, after the review of c96f790a); without that form in this
    checkout, no run of the track changes the model. A first deployment with no history yet has no Warning here: the track's
    step and the end's are Not selected.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $ids = @($script:KeptValueDeployCheckId, $script:KeptValueEndCheckId)
    $latest = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -in $ids -and [string]$_.status -ne 'Not selected' }) | Select-Object -Last 1
    if ($null -eq $latest -or [string]$latest.status -ne 'Warning') {
        return $null
    }
    return [ordered]@{
        name    = 'the history''s kept values (F35)'
        state   = 'Action needed'
        message = ConvertTo-DemoPlainText -Value $latest.message
        howTo   = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $latest -Name 'remediation')
    }
}
