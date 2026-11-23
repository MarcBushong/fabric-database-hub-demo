# F35, design (i) (2026-11-23): the history's kept values, worked out through Fabric's Livy API by the PC's scripts with this
# checkout's fabric/history/kept_value.py (Invoke-DemoHistoryKeptValue), so an environment whose workspace keeps an older
# NB_DatabaseHub_LiveActivity gets them with no decision. deploy.ps1's Fabric track runs it before the history model's step,
# which deploys the form of Snapshot Value that its answer allows (Get-DemoKeptValueForm), and deploy.ps1's end runs it
# again after the history snapshot (Invoke-DemoKeptValueEndStep); stop-demo.ps1 -SaveHistory and configure-fabric.ps1
# -RunLiveActivity run it after their saves. Its records are never a Fail or Manual action required, and never block DONE.

$script:KeptValueModulePath = 'fabric/history/kept_value.py'
# The step's JSON: every key is always there (the resolve module's interface, 2026-11-23).
$script:KeptValueJsonKeys = @('version', 'table', 'exists', 'missing', 'added', 'form', 'scope', 'read', 'resolved', 'pending', 'attempts', 'seconds', 'error')
$script:KeptValueStepCode = 'import json; print(json.dumps(kept_value_step(spark)))'
$script:KeptValueRunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'
# The command that also deploys the history model in the kept values' form: the Fabric track again, which a plain rerun skips
# once an earlier run recorded it.
$script:KeptValueTrackRunAgain = './scripts/deploy.ps1 -FromStage Fabric'
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
    row. Returns one DEPLOY.FABRIC.KEPTVALUE.END record, never a Fail or Manual action required. Internal.

    .DESCRIPTION
    Both deployment paths call it right after Invoke-DemoHistorySnapshotStep. Not selected, with the row Skipped, for
    -WhatIfRun, -SkipFabric, and a snapshot that saved nothing in this run (its outcome isn't Saved or SavedNotRefreshed):
    there's no new row to work out, and the Fabric track's step worked out the older ones. The history model isn't deployed
    again here: it reads the new kept values once Direct Lake updates it, which the snapshot's refresh, or Direct Lake's
    automatic updates, do. That needs the kept form: when this run's DEPLOY.FABRIC.KEPTVALUE (in -Result) didn't allow it,
    the model reads the release's form until the Fabric track runs again, so the step runs with -ModelOnRelease, and its
    fix is ./scripts/deploy.ps1 -FromStage Fabric, a Pass becoming a Warning (the review of c96f790a). A run whose Fabric
    track didn't run its step (a resume) keeps the model its earlier run deployed.
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
    $snapshot = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq 'DEPLOY.FABRIC.HISTORY' }) | Select-Object -Last 1
    $outcome = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $snapshot -Name 'evidence') -Name 'outcome')
    if ($outcome -notin 'Saved', 'SavedNotRefreshed') {
        return (& $skip 'The history snapshot saved nothing in this run (DEPLOY.FABRIC.HISTORY says why), so there were no new rows whose kept values to work out.')
    }
    $track = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -eq $script:KeptValueDeployCheckId }) | Select-Object -Last 1
    $modelOnRelease = $null -ne $track -and (Get-DemoKeptValueForm -Result $track) -cne 'Kept'
    $runAgain = if ($modelOnRelease) { $script:KeptValueTrackRunAgain } else { $script:KeptValueRunAgain }
    return (Invoke-DemoHistoryKeptValue -Config $Config -CheckId $script:KeptValueEndCheckId -TimeoutMinutes $TimeoutMinutes -ProgressPath $ProgressPath -ProgressId $script:KeptValueEndRowId -RunAgain $runAgain -ModelOnRelease:$modelOnRelease)
}

function Get-DemoKeptValueItem {
    <#
    .SYNOPSIS
    What DONE, NOT DONE, DEPLOY.SUMMARY, and the status page's Needs attention box say when deploy.ps1's kept-value steps
    didn't work (F35, 2026-11-23), as an item of Get-DemoNonBlockingItem (name, state Action needed, message, howTo), or
    $null. Pure. Internal.

    .DESCRIPTION
    The latest DEPLOY.FABRIC.KEPTVALUE or DEPLOY.FABRIC.KEPTVALUE.END that isn't Not selected, when it's a Warning. A Pass at
    the end settles the Fabric track's Warning only when that step allowed the kept form: otherwise this run's history model
    reads the release's form, and the track's Warning, whose fix is ./scripts/deploy.ps1 -FromStage Fabric, stays listed
    (the review of c96f790a). The end's step says so itself (ModelOnRelease); this keeps it so for any other caller.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $ids = @($script:KeptValueDeployCheckId, $script:KeptValueEndCheckId)
    $mine = @($Result | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'checkId') -in $ids })
    $latest = @($mine | Where-Object { [string]$_.status -ne 'Not selected' }) | Select-Object -Last 1
    $track = @($mine | Where-Object { [string]$_.checkId -eq $script:KeptValueDeployCheckId }) | Select-Object -Last 1
    $open = $null
    if ($null -ne $latest -and [string]$latest.status -eq 'Warning') {
        $open = $latest
    }
    elseif ($null -ne $track -and [string]$track.status -eq 'Warning' -and (Get-DemoKeptValueForm -Result $track) -cne 'Kept') {
        $open = $track
    }
    if ($null -eq $open) {
        return $null
    }
    return [ordered]@{
        name    = 'the history''s kept values (F35)'
        state   = 'Action needed'
        message = ConvertTo-DemoPlainText -Value $open.message
        howTo   = ConvertTo-DemoPlainText -Value (Get-DemoMemberValue -InputObject $open -Name 'remediation')
    }
}
