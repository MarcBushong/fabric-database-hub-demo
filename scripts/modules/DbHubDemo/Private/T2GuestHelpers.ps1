# T2's guest on an existing host, on deploy.ps1's side (ADR 0006, amendment of 2026-11-09). The T2 host decides, because
# only it can see the guest (vm/bootstrap/HostSteps.ps1, the GuestSource step): in JumpstartImage mode it rebuilds a guest
# built in PaygWizard mode whose SQL Server setup was never finished, and keeps a guest whose SQL Server is set up in the
# mode it was built in. deploy.ps1 follows what the host reports: it deletes the old guest's Arc resources in Azure when the
# host and Azure both show they're the old guest's (Get-DemoT2RebuildArcDecision), cleans up what an earlier guided stop
# left open, says so on the console and the status page, and records the guest's mode
# (DbHubT2InstallMode). PaygWizard is retired from the one-click deployment (2026-11-09, user-directed): a configuration's
# PaygWizard runs as JumpstartImage (Get-DemoConfig), and no run builds a guest that waits for the setup wizard.
# Sources (checked 2026-11-09):
# - Delete SQL Server enabled by Azure Arc resources, the instances before the machine:
#   https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc
# - Machines - Delete: https://learn.microsoft.com/rest/api/hybridcompute/machines/delete

$script:T2InstallModes = @('JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer')

function Get-DemoT2InstallModeSource {
    # Where the run's t2SqlInstallMode comes from (2026-11-09): configuration (the file names it), default (it doesn't), or
    # legacy (the file says PaygWizard, the default an older init.ps1 wrote, so the run uses JumpstartImage; Get-DemoConfig).
    # Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $source = if ($Config.Contains('t2SqlInstallModeSource')) { [string]$Config['t2SqlInstallModeSource'] } else { '' }
    if ($source -in 'default', 'legacy') {
        return $source
    }
    return 'configuration'
}

function Get-DemoT2LegacyModeText {
    # The one line a run prints, and its status page shows, when the configuration says PaygWizard, which deploy.ps1 runs as
    # JumpstartImage (t2SqlInstallModeSource legacy, 2026-11-09). '' otherwise. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ((Get-DemoT2InstallModeSource -Config $Config) -ne 'legacy') {
        return ''
    }
    if ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm') {
        return 't2SqlInstallMode PaygWizard in your configuration (the default init.ps1 wrote before 2026-11-05) is retired: the one-click deployment has no SQL Server setup wizard, and t2Mode EvaluationOnlyAzureVm can''t use Arc Jumpstart''s image instead, so preflight stops (PREFLIGHT.T2.MODE). Set t2SqlInstallMode to ProductKey or Developer.'
    }
    return 't2SqlInstallMode PaygWizard in your configuration (the default init.ps1 wrote before 2026-11-05) is ignored: T2 comes from Arc Jumpstart''s image (JumpstartImage), with no setup wizard and no sign-in to a VM, and a T2 guest whose SQL Server is already set up is kept as it is. To drop this note, set t2SqlInstallMode to JumpstartImage.'
}

function Get-DemoT4IgnoredText {
    # The one line a run prints, and its status page shows, when the configuration sets t4Enabled false, which deploy.ps1
    # ignores: T4 is part of every deployment (t4EnabledIgnored, 2026-11-09). '' otherwise. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if (-not ($Config.Contains('t4EnabledIgnored') -and $Config['t4EnabledIgnored'] -eq $true)) {
        return ''
    }
    return 't4Enabled false in your configuration is ignored: T4 (Azure Database for PostgreSQL) is part of every deployment, and DONE needs it. To drop this note, remove t4Enabled from your configuration.'
}

function Get-DemoT2GuestInstallMode {
    # The T2 guest's own install mode: the resource group's record (DbHubT2InstallMode, from the host's report), else the
    # run's t2SqlInstallMode (2026-11-09). A golden capture tags its snapshot with it, so a kept PaygWizard guest's snapshot
    # says PaygWizard, with its evaluation's end. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State
    )

    $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'T2InstallMode')
    if ($recorded -cin $script:T2InstallModes) {
        return $recorded
    }
    $mode = [string]$Config['t2SqlInstallMode']
    if ($mode -cin $script:T2InstallModes) {
        return $mode
    }
    return 'JumpstartImage'
}

function Get-DemoT2RebuildText {
    # The console's and the status page's words for a rebuild of an unfinished guest, with the measured time (the live test of
    # 2026-11-06: T2's host build with the image took about 27 minutes, the 34.1 GiB download about 11 at about 51 MiB/s, and
    # Arc onboarding about 33). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $OldMode = ''
    )

    $mode = if ($OldMode) { $OldMode } else { 'PaygWizard' }
    return ('archost01''s guest arcsql01 was built in {0} mode, and its SQL Server setup was never finished, so it had nothing to keep: archost01 deleted it and makes T2 again from Arc Jumpstart''s image (t2SqlInstallMode JumpstartImage), with no step for a person. That takes about 27 minutes, measured on 2026-11-06, including the 34 GiB download at about 51 MiB/s, then about 33 for Arc onboarding. T1, T3, T4, Fabric, and archost01 itself are untouched.' -f $mode)
}

function Get-DemoT2RebuildArcDecision {
    <#
    .SYNOPSIS
    What deploy.ps1 does with arcsql01's Arc machine after the T2 host deleted an unfinished guest (2026-11-09): Action None
    (no machine), Delete, or Keep, with Reason. Delete only on evidence that it's the old guest's: it isn't Connected, so no
    agent checks in as it, or it's still Connected but Azure created it before the rebuild started (systemData.createdAt),
    so the new guest, made afterwards, can't be the one. Anything else keeps it: configure-arc.ps1 deletes a disconnected
    machine, with its SQL Server instances, before it onboards the new guest. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Machine,

        [AllowNull()]
        [object] $RebuildUtc
    )

    $decide = { param([string] $Action, [string] $Reason) [pscustomobject]@{ Action = $Action; Reason = $Reason } }
    if ($null -eq $Machine) {
        return (& $decide 'None' 'the old guest had no Arc machine left')
    }
    $status = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Machine -Name 'properties') -Name 'status')
    if ($status -ne 'Connected') {
        return (& $decide 'Delete' ('it''s {0}, so no guest checks in as it' -f $(if ($status) { $status } else { 'without a status' })))
    }
    $created = ConvertTo-DemoUtcDate -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Machine -Name 'systemData') -Name 'createdAt')
    $started = ConvertTo-DemoUtcDate -Value $RebuildUtc
    if ($null -ne $created -and $null -ne $started -and $created -lt $started) {
        return (& $decide 'Delete' ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, 'it''s still Connected, but Azure created it at {0:yyyy-MM-dd HH:mm} UTC, before the rebuild started at {1:yyyy-MM-dd HH:mm} UTC, so it''s the old guest''s', $created, $started)))
    }
    return (& $decide 'Keep' 'it''s Connected, and nothing shows that it''s the old guest''s, so it may be the new guest''s')
}

function Complete-DemoT2GuestRebuild {
    <#
    .SYNOPSIS
    deploy.ps1's side of a rebuilt T2 guest (2026-11-09). When the host's health reports the rebuild of an unfinished guest
    (guestRebuild Removing or Removed, read from its record; Done once the new guest passed ArcOnboarding ends it) and the
    new guest isn't known to be onboarded (rebuildArcNew isn't true): the console and the status page say what happens and
    how long it takes, and what an earlier guided stop left open goes (Clear-DemoGuidedStopLeftover: on-demand Bastion, a
    handed-over host password). The old guest's Arc resources in Azure go, its SQL Server instances first, then the
    machine (Remove-DemoArcStaleResource, as destroy.ps1 deletes them), only when the host positively says the new guest
    isn't onboarded (rebuildArcNew false) and the machine is the old guest's (Get-DemoT2RebuildArcDecision); when the host
    couldn't tell (null), nothing in Azure is deleted. Returns DEPLOY.T2.REBUILD (a Warning: nothing to do, but worth
    knowing) with the cleanup's results, or nothing when there's no rebuild to follow up. Never throws. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Health,

        [string] $ProgressPath = ''
    )

    $state = [string](Get-DemoMemberValue -InputObject $Health -Name 'guestRebuild')
    if ($state -notin 'Removing', 'Removed') {
        return @()
    }
    # Three-state (vm/health/Get-DemoHealth.ps1): true once the new guest is onboarded, which ends the follow-up; null when
    # the host couldn't tell, which deletes nothing in Azure.
    $arcNew = Get-DemoMemberValue -InputObject $Health -Name 'rebuildArcNew'
    if ($arcNew -is [bool] -and $arcNew) {
        return @()
    }
    if (-not $PSCmdlet.ShouldProcess('arcsql01', 'Follow up the rebuild of its guest, and delete the old guest''s Arc resources')) {
        return @()
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $oldMode = [string](Get-DemoMemberValue -InputObject $Health -Name 'rebuildMode')
    $text = Get-DemoT2RebuildText -OldMode $oldMode
    Write-DemoLog -Level Warning -Message ('T2: {0}' -f $text)
    Set-DemoProgressStep -Path $ProgressPath -Id 'T2.HostBuild' -State 'Running' -Message $text
    $rebuildUtc = Get-DemoMemberValue -InputObject $Health -Name 'rebuildUtc'
    $evidence = [ordered]@{ oldMode = $(if ($oldMode) { $oldMode } else { 'PaygWizard' }); rebuildUtc = [string]$rebuildUtc; rebuildState = $state; arcResourceId = [string](Get-DemoMemberValue -InputObject $Health -Name 'rebuildArcId'); arcNew = $(if ($arcNew -is [bool]) { $arcNew } else { $null }); arcAction = 'Keep'; arcDeleted = @(); arcProblem = '' }
    $later = ' configure-arc.ps1 deletes a disconnected Arc machine, with its SQL Server instances, before it onboards the new guest.'
    $arcText = ''
    if ($arcNew -isnot [bool]) {
        $arcText = 'In Azure, nothing was deleted: archost01 couldn''t tell whether its new guest is onboarded to Azure Arc yet.' + $later
    }
    else {
        try {
            $target = Get-DemoArcTarget -Config $Config
            $machine = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
            $decision = Get-DemoT2RebuildArcDecision -Machine $machine -RebuildUtc $rebuildUtc
            $evidence['arcAction'] = $decision.Action
            switch ($decision.Action) {
                'None' {
                    $arcText = 'In Azure, the old guest had no Arc machine left.'
                }
                'Delete' {
                    $evidence['arcDeleted'] = @(Remove-DemoArcStaleResource -Target $target -Confirm:$false)
                    $arcText = 'In Azure, the old guest''s Arc resources were deleted, because {0}: {1}.' -f $decision.Reason, (@($evidence['arcDeleted']) -join ', ')
                }
                default {
                    $arcText = ('In Azure, the Arc machine arcsql01 was kept, because {0}.' -f $decision.Reason) + $later
                }
            }
        }
        catch {
            $evidence['arcProblem'] = Protect-DemoText -Text $_.Exception.Message
            $arcText = 'In Azure, the old guest''s Arc machine couldn''t be deleted now ({0});{1}' -f $evidence['arcProblem'], $later
        }
    }
    try {
        $results.AddRange([object[]]@(Clear-DemoGuidedStopLeftover -Config $Config))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'DEPLOY.T2.GUIDEDLEFTOVER' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('What an earlier guided stop left open couldn''t be checked: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly: it removes Bastion and rotates the host password, and leaves the VMs running.'))
    }
    Write-DemoLog -Message ('T2: {0}' -f $arcText)
    $results.Insert(0, (New-DemoResult -CheckId 'DEPLOY.T2.REBUILD' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} {1}' -f $text, $arcText) -Evidence $evidence -Remediation 'Nothing to do: deploy.ps1 waits for the new guest, onboards it to Azure Arc, and finishes T2, with no step for a person.' -DocUrl 'https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc'))
    return $results.ToArray()
}

function Get-DemoT2ModeResult {
    <#
    .SYNOPSIS
    DEPLOY.T2.MODE (2026-11-09), when the T2 host kept its existing guest in the mode it was built in, because SQL Server is
    set up in it (health modeAdopted): a Pass that says which mode, why, and that nothing needs a person. $null otherwise.
    Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Health
    )

    if (-not [bool](Get-DemoMemberValue -InputObject $Health -Name 'modeAdopted')) {
        return $null
    }
    $mode = [string](Get-DemoMemberValue -InputObject $Health -Name 'installMode')
    $message = 'T2 keeps its existing guest as it is, in the mode it was built in, {0}: SQL Server is set up in arcsql01, so it''s never rebuilt or deleted on its own, and nothing in T2 needs a person. A new T2 guest would come from Arc Jumpstart''s image (JumpstartImage).' -f $mode
    return (New-DemoResult -CheckId 'DEPLOY.T2.MODE' -Area 'infra' -Target 'T2' -Status 'Pass' -Message $message -Evidence ([ordered]@{ installMode = $mode; configuredMode = [string](Get-DemoMemberValue -InputObject $Health -Name 'configuredMode'); modeSource = [string](Get-DemoMemberValue -InputObject $Health -Name 'modeSource') }) -Remediation 'Nothing to do. To make T2 from Arc Jumpstart''s image instead, run ./scripts/destroy.ps1, then ./scripts/deploy.ps1.' -DocUrl 'https://learn.microsoft.com/fabric/database/hub/add-sql#prerequisites-for-sql-server-enabled-by-azure-arc')
}

function Update-DemoT2InstallModeRecord {
    <#
    .SYNOPSIS
    Records the T2 guest's own install mode in the resource group's DbHubT2InstallMode tag (2026-11-09), from the host's
    health, only for a guest that has nothing left to set up: one the host kept in its own mode (modeAdopted), one made from
    the Jumpstart image, or a build guest whose SQL Server a pass saw set up (guestSetUp). A golden capture tags its snapshot
    with it (Get-DemoT2GuestInstallMode). Nothing when the host doesn't say, or the record is already right. Never throws.
    Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Health,

        [AllowNull()]
        [object] $State
    )

    $guestMode = [string](Get-DemoMemberValue -InputObject $Health -Name 'guestMode')
    $mode = ''
    if ([bool](Get-DemoMemberValue -InputObject $Health -Name 'modeAdopted')) {
        $mode = [string](Get-DemoMemberValue -InputObject $Health -Name 'installMode')
    }
    elseif ($guestMode -eq 'JumpstartImage' -or ($guestMode -and [bool](Get-DemoMemberValue -InputObject $Health -Name 'guestSetUp'))) {
        $mode = $guestMode
    }
    if ($mode -notin $script:T2InstallModes -or [string](Get-DemoMemberValue -InputObject $State -Name 'T2InstallMode') -ceq $mode) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), ('Record T2''s install mode, {0}' -f $mode))) {
        return
    }
    try {
        Set-DemoDeploymentStateLocked -Config $Config -Value @{ T2InstallMode = $mode } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('T2''s install mode wasn''t recorded, so the next run asks its host again: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
}
