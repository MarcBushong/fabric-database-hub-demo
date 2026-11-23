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
$script:KeptValueDeployCheckId = 'DEPLOY.FABRIC.KEPTVALUE'
$script:KeptValueEndCheckId = 'DEPLOY.FABRIC.KEPTVALUE.END'
$script:KeptValueTrackRowId = 'Fabric.KeptValues'
$script:KeptValueEndRowId = 'Fabric.HistoryKept'

function Get-DemoKeptValueCode {
    # This checkout's fabric/history/kept_value.py as text, which a Livy statement runs as it is, or '' when it isn't there.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $path = Join-Path -Path $script:RepoRoot -ChildPath $script:KeptValueModulePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
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
    automatic updates, do.
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
    return (Invoke-DemoHistoryKeptValue -Config $Config -CheckId $script:KeptValueEndCheckId -TimeoutMinutes $TimeoutMinutes -ProgressPath $ProgressPath -ProgressId $script:KeptValueEndRowId -RunAgain $script:KeptValueRunAgain)
}

function Get-DemoKeptValueItem {
    <#
    .SYNOPSIS
    What DONE, NOT DONE, DEPLOY.SUMMARY, and the status page's Needs attention box say when deploy.ps1's kept-value steps
    didn't work (F35, 2026-11-23): the latest DEPLOY.FABRIC.KEPTVALUE or DEPLOY.FABRIC.KEPTVALUE.END that isn't Not selected,
    when it's a Warning, as an item of Get-DemoNonBlockingItem (name, state Action needed, message, howTo), or $null. A
    Warning from the Fabric track that the end's step settled (a Pass) isn't listed. Pure. Internal.
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
