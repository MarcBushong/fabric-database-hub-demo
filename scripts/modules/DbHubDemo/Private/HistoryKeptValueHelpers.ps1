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
    Returns Switched (none of the script's records is a Fail or Manual action required), Why (the first such record's check
    ID, status, and message, or the error), and Evidence (switched, the records' count by status, and those that didn't
    pass). The records stay out of the run's results, so a Fail among them never blocks DONE; the end's record says what
    happened. Only a stop of the run throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyString()]
        [string] $ConfigPath = ''
    )

    try {
        $records = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $ConfigPath -SnapshotValueForm 'Kept' | Where-Object { $null -ne $_ })
    }
    catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $text = (Get-DemoExceptionText -Exception $_.Exception).TrimEnd('.', ' ')
        return [pscustomobject]@{ Switched = $false; Why = $text; Evidence = [ordered]@{ switched = $false; records = 0; error = $text } }
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
    return [pscustomobject]@{
        Switched = -not $why
        Why      = $why
        Evidence = [ordered]@{
            switched  = -not $why
            records   = $records.Count
            statuses  = $counts
            notPassed = @($records | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | ForEach-Object { '{0} {1}' -f [string]$_.checkId, [string]$_.status })
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
      it has worked out every row, it deploys the model in the kept form by the Fabric track's own step, a Pass (Switched),
      and a Warning from the track's step becomes a Pass that keeps what it said in its evidence (earlierMessage), with its
      row Done. A switch that doesn't work is one Warning (SwitchFailed), as are the step's own failures, which say that
      the model reads the release's form.
    - With no rows to work out (a snapshot that saved nothing, or still no history table), it's Not selected, never a
      Warning, and says that the next ./scripts/deploy.ps1 deploys the model in the kept form by itself: a full run after
      one whose tracks all finished, or a resume, which runs the Fabric step again since it didn't record its content as
      published.
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
    $snapshot = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'DEPLOY.FABRIC.HISTORY' }) | Select-Object -Last 1
    $outcome = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $snapshot -Name 'evidence') -Name 'outcome')
    if ($outcome -notin 'Saved', 'SavedNotRefreshed') {
        $message = 'The history snapshot saved nothing in this run (DEPLOY.FABRIC.HISTORY says why), so there were no new rows whose kept values to work out.'
        if ($waits) {
            $message = '{0} {1}' -f $message, $script:KeptValueNextDeployNote
        }
        return (& $skip $message)
    }
    $runAgain = if ($waits) { $script:KeptValueTrackRunAgain } else { $script:KeptValueRunAgain }
    $kept = Invoke-DemoHistoryKeptValue -Config $Config -CheckId $script:KeptValueEndCheckId -TimeoutMinutes $TimeoutMinutes -ProgressPath $ProgressPath -ProgressId $script:KeptValueEndRowId -RunAgain $runAgain -ModelOnRelease:$waits -SwitchModelForm:$waits -ConfigPath $ConfigPath
    $switched = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $kept -Name 'evidence') -Name 'outcome') -eq 'Switched'
    if ($waits -and $switched -and [string]$track.status -eq 'Warning') {
        # The model reads the kept values now, so the track's Warning, whose fix was the Fabric track again, is settled; its
        # evidence keeps what it said (design A, as the #68 follow-up settles the first history run's).
        $why = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $track -Name 'evidence') -Name 'outcome')
        Set-DemoHistoryResultText -Result $track -Status 'Pass' -Message ('This step didn''t work out the history''s kept values{0}, but this run''s end did, after its history snapshot, and deployed the history model in their form (DEPLOY.FABRIC.KEPTVALUE.END).' -f $(if ($why) { ' ({0})' -f $why } else { '' }))
        Set-DemoProgressStep -Path $ProgressPath -Id $script:KeptValueTrackRowId -State 'Done' -Status 'Pass' -Message ([string]$track.message) -MaxLength 1200
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
