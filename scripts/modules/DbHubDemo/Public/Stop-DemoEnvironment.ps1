function Stop-DemoEnvironment {
    <#
    .SYNOPSIS
    Stops the demo's compute after a session: Bastion goes, the host password is rotated, the T2 guest shuts
    down cleanly, and the VMs are deallocated; T3 stays unless -RemoveT3 (plan section 9.4, ADR 0016).
    stop-demo.ps1 and the scheduled stop and bastion-cleanup workflows call it.

    .DESCRIPTION
    - Default: removes on-demand Bastion and then its public IP, including a public IP left over after an
      interrupted delete (C8); rotates the T2 host's administrator password if a one-time password was set,
      and with the Key Vault opt-in disables the vault's copy (Disable-DemoHostPasswordSecret, STOP.KEYVAULT);
      once Bastion is gone, clears the record of a guided stop whose cleanup didn't finish (GuidedStopUtc, as after a
      Ctrl+C at the guided stop), so deploy.ps1's DONE no longer waits for it (Phase 28 review);
      sets every target's activity profile to off, so nothing restarts on the next boot (R183): one managed Run Command
      per VM, both VMs at once, waited for at most -ProfileOffWaitSeconds (about 3 minutes), because an incident in
      progress can keep a VM's Run Commands waiting for minutes; one that doesn't finish in time is a Warning, reported
      after the deallocation, that says the VM was deallocated anyway, which stops the incident with it (2026-11-03);
      stops the guest arcsql01 cleanly over PowerShell Direct, as before, within the same bound (a guest stop that
      doesn't finish in time is a Warning: the host's deallocation shuts the guest down through its automatic stop
      action, ShutDown); then deallocates the T2 VM and sqlvm01. T3 isn't
      touched: with its profile off (the T3 profile is a file on T1, so this doesn't wake it), serverless
      auto-pause stops its compute t3AutoPauseMinutes after the last session. T4, the PostgreSQL flexible
      server (Phase 24, ADR 0019), gets its profile off and is stopped (STOP.T4.STOP; Servers - Stop). A
      stopped flexible server starts on its own after seven days, so the result says when (the stop time plus seven days),
      what it then bills, and whether the nightly safety stop (ADR 0024) stops it again (Phase 28 follow-up); its
      storage and the Defender plans a tenant policy enables are billed while it's stopped.
      With the on-demand activity control (control.enabled, ADR 0020), it first removes a pending auto-stop, so
      it can't deallocate a later session's VMs (STOP.CONTROL.AUTOSTOP).
    - -ParkT2 (C4): only the T2 side, and only T2's profile goes off; T1, T3, and T4 keep running, for
      agent-focused demos on T1 and T3.
    - -RemoveBastionOnly: only Bastion, the password rotation, and the guided stop's record; with -IfExpired, a Bastion
      host goes only after its expiry tag (the bastion-cleanup workflow), and a leftover public IP goes at once.
    - -RemoveT3: also deletes T3 and its private endpoint (Remove-DemoT3; the user-directed lifecycle). The
      next start-demo.ps1 recreates it under the same names.
    - Phase 26b (ADR 0023), both opt-in and skipped with -ParkT2: -SaveHistory (or fabric.saveHistoryOnStop) runs
      NB_DatabaseHub_LiveActivity on demand to save the session's history (Save-DemoFabricHistory), and then, with
      fabric.manageCapacity true, the Fabric capacity that start-demo.ps1 resumed is paused (STOP.FABRIC.CAPACITY,
      Suspend-DemoFabricCapacity), never while that run is still going. With the defaults the capacity isn't called.
      T4's read replica (ADR 0025) is deleted after each session, and its Azure Monitor metrics with it, so -SaveHistory
      first reads T4's and the replica's metrics (STOP.T4.HISTORY) and sends them with that run; when the run doesn't save
      them (a paused capacity, for example), they're kept in out/history-pending, with the command that adds them once
      the capacity runs (STOP.T4.HISTORY.PENDING, Save-DemoPostgresHistoryPending).
    Run Command needs a running VM: a password rotation on a deallocated host reports Manual action required
    with the steps, and a profile on a VM that isn't running is already inactive (Not selected).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ParkT2
    Stop only the T2 side.

    .PARAMETER RemoveBastionOnly
    Remove Bastion (and rotate the host password) and nothing else.

    .PARAMETER IfExpired
    With -RemoveBastionOnly: only after the Bastion's expiry tag.

    .PARAMETER RemoveT3
    Also delete T3.

    .PARAMETER SaveHistory
    Save the session's history first: run NB_DatabaseHub_LiveActivity on demand, at most 15 minutes, before the Fabric
    capacity is paused (STOP.FABRIC.SAVEHISTORY; also with fabric.saveHistoryOnStop). Not with -ParkT2.

    .PARAMETER SaveHistoryWindowMinutes
    How far back the saved history goes (default 720 minutes; the notebook uses 5-minute bins up to 12 hours).

    .PARAMETER ProfileOffWaitSeconds
    How long the profiles' off waits for both VMs together before the stop goes on anyway, and how long the guest's clean
    shutdown may take (default 180).

    .EXAMPLE
    Stop-DemoEnvironment -Config $config -RemoveT3
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $ParkT2,

        [switch] $RemoveBastionOnly,

        [switch] $IfExpired,

        [switch] $RemoveT3,

        [switch] $SaveHistory,

        [ValidateRange(15, 10080)]
        [int] $SaveHistoryWindowMinutes = 720,

        [ValidateRange(30, 900)]
        [int] $ProfileOffWaitSeconds = 180
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was stopped. Sign in yourself and run stop-demo.ps1 again; the VMs still auto-shut down on schedule.'))
        return $results.ToArray()
    }
    $action = if ($RemoveBastionOnly) { 'Remove on-demand Bastion and rotate the host password' } elseif ($ParkT2) { 'Park T2: stop the guest and deallocate the T2 VM' } else { 'Remove Bastion, stop the guest, and deallocate both VMs' }
    if ($RemoveT3) {
        $action += '; delete T3'
    }
    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), $action)) {
        $results.Add((New-DemoResult -CheckId 'STOP.DEMO' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0}.' -f $action)))
        return $results.ToArray()
    }
    $hostVm = Get-DemoHostVmName -Config $Config
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config

    $bastion = Remove-DemoBastion -Config $Config -IfExpired:$IfExpired -Confirm:$false
    $results.Add($bastion)
    $state = Get-DemoDeploymentState -Config $Config
    $sessionOver = ($bastion.status -eq 'Pass' -or -not $IfExpired)
    if ($state.HostPasswordUtc -and $sessionOver) {
        # Set-DemoVmLocalPassword reports Manual action required, with the steps, when the host isn't running. A rotation
        # that fails on a running host is a Warning with the portal's way (Phase 28): the state still records the handover,
        # so the next start-demo.ps1 or stop-demo.ps1 rotates it again. That covers a password a person set in the portal
        # at the guided stop too.
        $rotation = Set-DemoVmLocalPassword -Config $Config -VmName $hostVm -Rotate -Confirm:$false
        if ([string]$rotation.status -eq 'Fail') {
            $rotation = New-DemoResult -CheckId 'STOP.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Warning' -Message ('{0} The password set for the last session is still valid until it''s rotated.' -f $rotation.message) -Evidence $rotation.evidence -Remediation ('Run ./scripts/stop-demo.ps1 -RemoveBastionOnly again, which rotates it, or in the Azure portal open {0}, then Help, then Reset password, and set a random value you don''t keep.' -f $hostVm) -DocUrl 'https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp'
        }
        $results.Add($rotation)
    }
    if ($sessionOver -and (Get-DemoKeyVaultSetting -Config $Config).Enabled) {
        # The opt-in vault's copy goes too, even when the host couldn't be rotated: nobody needs it after the session.
        $results.Add((Disable-DemoHostPasswordSecret -Config $Config -VmName $hostVm -CheckId 'STOP.KEYVAULT' -Confirm:$false))
    }
    if ($sessionOver -and [string]$bastion.status -in 'Pass', 'Not selected' -and [string](Get-DemoMemberValue -InputObject $state -Name 'GuidedStopUtc')) {
        # The guided stop's Bastion is gone, so deploy.ps1's DONE no longer waits for it (Get-DemoGuidedStopLeftover;
        # Phase 28 review); the host's request expires on its own.
        try {
            Set-DemoDeploymentState -Config $Config -Value @{ GuidedStopUtc = '' } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The guided stop''s end wasn''t recorded on the resource group: {0}' -f $_.Exception.Message)
        }
    }
    if ($RemoveBastionOnly) {
        return $results.ToArray()
    }
    if (-not $ParkT2 -and (Get-DemoActivityControlSetting -Config $Config).Enabled) {
        # The on-demand activity control's pending auto-stop (ADR 0020) would deallocate a later session's VMs.
        $results.Add((Clear-DemoActivityControlAutoStop -Config $Config -Confirm:$false))
    }

    $power = @{}
    foreach ($vm in 'sqlvm01', $hostVm) {
        $power[$vm] = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm
    }
    # Activity off before the VMs stop, so a later boot doesn't keep T3 awake (R183); the T3 profile is a
    # file on T1, so turning it off doesn't wake T3. T4's is too, but a T4 that was never created has no
    # activity, and T1's runner may not know T4 yet (live, 2026-10-26), so it's left alone.
    $t4On = Test-DemoT4Enabled -Config $Config
    $t4Missing = $false
    if ($t4On -and -not $ParkT2) {
        # Only a server Azure says doesn't exist, or is deleting (Dropping: a server it refused, or one deleted by hand;
        # 2026-11-09), is skipped; one that couldn't be read is still stopped below.
        $t4Read = Get-DemoT4State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
        $t4Missing = [string]$t4Read.State -eq 'NotFound' -or [bool](Get-DemoMemberValue -InputObject $t4Read -Name 'Removing')
    }
    $profileTargets = if ($ParkT2) { @('T2') } else { @('T1', 'T3') + @(if ($t4On) { 'T4' }) + @('T2') }
    $offTargets = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $profileTargets) {
        $vm = if ($item -eq 'T2') { $hostVm } else { 'sqlvm01' }
        $skip = ''
        if (-not $state.RunnerSha256) {
            $skip = 'No workload runner was deployed, so no activity runs.'
        }
        elseif ($item -eq 'T4' -and $t4Missing) {
            $skip = 'T4 isn''t deployed, so it has no activity to turn off.'
        }
        elseif ($item -eq 'T2' -and ($hostVm -ne 'archost01' -or 'archost01' -notin $state.RunnerSentTo)) {
            $skip = 'T2 has no workload runner (the evaluation-only mode, or the runner wasn''t sent to archost01).'
        }
        elseif ($power[$vm] -ne 'PowerState/running') {
            $skip = '{0} isn''t running, so no activity runs there. A profile ends at the auto-shutdown it was set for, and nothing sets it again at boot unless activityProfileOnBoot is true.' -f $vm
        }
        if ($skip) {
            $results.Add((Set-DemoTargetProfile -Config $Config -Target $item -ProfileName 'off' -CheckPrefix 'STOP' -SkipReason $skip -RequestedBy 'stop-demo'))
        }
        else {
            $offTargets.Add($item)
        }
    }
    # The profiles go off in one managed Run Command per VM, both VMs at once, and the wait is bounded (about 3 minutes):
    # an incident in progress can keep a VM's Run Commands waiting for minutes (2026-10-23), and deallocating the VM stops
    # it anyway, so the stop never waits for it (2026-11-03). A profile that isn't off yet is reported after the
    # deallocation, which is what stops its activity then.
    $notOff = [System.Collections.Generic.List[object]]::new()
    if ($offTargets.Count -gt 0) {
        foreach ($record in @(Send-DemoProfileRunCommand -Config $Config -Target $offTargets.ToArray() -ProfileName 'off' -RequestedBy 'stop-demo' -WaitSeconds $ProfileOffWaitSeconds -ExpiresMinutes 10)) {
            if ([string]$record.Outcome -in 'Set', 'NotSetUp', 'GuestOff') {
                $results.Add((ConvertTo-DemoStopProfileResult -Record $record -WaitSeconds $ProfileOffWaitSeconds))
            }
            else {
                $notOff.Add($record)
            }
        }
    }

    # T4's read replica (2026-11-13, ADR 0025) exists only during a session: it's deleted now, while the VMs deallocate, so
    # nothing bills for it between sessions and no 7-day restart applies to it. Its Azure Monitor metrics go with it
    # (ResourceNotFound, live 2026-11-13), so the session's history captures them first (-SaveHistory). Deleting it leaves
    # T4 Ready (about 100 seconds, live), and T4's stop below waits for it.
    $replicaDeleting = $false
    $postgresHistory = $null
    if (-not $ParkT2 -and $t4On -and -not $t4Missing) {
        if (-not (Test-DemoT4ReplicaSetUp -State $state)) {
            $results.Add((New-DemoT4ReplicaNotSetUpResult -CheckId 'STOP.T4.REPLICA'))
        }
        else {
            $capacitySettingEarly = Get-DemoFabricCapacitySetting -Config $Config
            if ($SaveHistory -or $capacitySettingEarly.SaveHistoryOnStop) {
                $postgresHistory = Get-DemoPostgresHistoryCapture -Config $Config -WindowMinutes $SaveHistoryWindowMinutes
                if ($null -ne $postgresHistory -and $null -ne $postgresHistory.Result) {
                    $results.Add($postgresHistory.Result)
                }
            }
            $replicaDelete = Remove-DemoT4Replica -Config $Config -CheckPrefix STOP -NoWait -DeploymentId ([string]$state.Tags['deploymentId'])
            if ($null -ne $replicaDelete) {
                $replicaDeleting = [string]$replicaDelete.status -eq 'Pass' -and [string](Get-DemoMemberValue -InputObject $replicaDelete.evidence -Name 'stateBefore') -ne 'NotFound'
                if (-not $replicaDeleting) {
                    $results.Add($replicaDelete)
                }
            }
        }
    }

    if ($hostVm -eq 'archost01' -and $power[$hostVm] -eq 'PowerState/running') {
        # A clean guest shutdown before the host deallocates, as before, within the same bound; the guest's automatic stop
        # action (ShutDown) shuts it down when the host deallocates otherwise.
        $results.Add((Stop-DemoGuestVm -Config $Config -TimeoutSeconds $ProfileOffWaitSeconds -Confirm:$false))
    }
    $vms = if ($ParkT2) { @($hostVm) } else { @($hostVm, 'sqlvm01') }
    $deallocated = @{}
    foreach ($vm in $vms) {
        $stopped = Invoke-DemoVmPowerAction -Config $Config -VmName $vm -Action Deallocate
        $results.Add($stopped)
        $deallocated[$vm] = [string]$stopped.status -eq 'Pass'
    }
    foreach ($record in $notOff) {
        $results.Add((ConvertTo-DemoStopProfileResult -Record $record -WaitSeconds $ProfileOffWaitSeconds -DeallocationFailed:(-not [bool]$deallocated[[string]$record.VmName])))
    }
    if (-not $ParkT2 -and $t4On -and -not $t4Missing) {
        if ($replicaDeleting) {
            # The replica's deletion went out before the VMs' deallocation; T4 stops once it's gone.
            $replicaGone = Wait-DemoT4ReplicaState -Config $Config -State @('NotFound') -TimeoutMinutes ([int](Get-DemoT4ReplicaSetting)['deleteTimeoutMinutes']) -PollSeconds 10 -DeploymentId ([string]$state.Tags['deploymentId'])
            if ($replicaGone.Present) {
                $results.Add((Remove-DemoT4Replica -Config $Config -CheckPrefix STOP -DeploymentId ([string]$state.Tags['deploymentId'])))
                Write-DemoLog -Level Warning -Message ('T4''s read replica ({0}) is still {1}; T4 stops anyway, and the nightly safety stop stops a replica that''s still there after T4.' -f $replicaGone.Names.ServerName, $replicaGone.State)
            }
            else {
                # This run deleted it (live, 2026-11-13: a second Remove-DemoT4Replica then said "isn't there, so there's nothing
                # to delete").
                $replicaName = [string](Get-DemoMemberValue -InputObject $replicaDelete.evidence -Name 'replica')
                $results.Add((New-DemoResult -CheckId 'STOP.T4.REPLICA' -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4''s read replica ({0}) was deleted, so nothing bills for it until the next session creates it again.' -f $replicaName) -Evidence ([ordered]@{ replica = $replicaName; stateBefore = [string](Get-DemoMemberValue -InputObject $replicaDelete.evidence -Name 'stateBefore'); stateAfter = 'NotFound' }) -DocUrl ([string](Get-DemoT4ReplicaSetting)['docUrls']['concepts'])))
            }
        }
        # After the VMs, so T1's runner has ended T4's sessions; the stop finishes in the background.
        $results.Add((Invoke-DemoT4PowerAction -Config $Config -Action Stop -WaitMinutes 0 -CheckPrefix STOP))
    }
    elseif (-not $ParkT2 -and $t4On) {
        $results.Add((New-DemoResult -CheckId 'STOP.T4.STOP' -Area 'infra' -Target 'T4' -Status 'Not selected' -Message 'T4 isn''t deployed, so there''s nothing to stop.'))
    }

    if (-not $ParkT2) {
        # Phase 26b (ADR 0023): the session's history first, then the capacity the demo resumed, because a pause would
        # cancel a notebook run. Both are opt-in; with the defaults the capacity isn't called.
        $capacitySetting = Get-DemoFabricCapacitySetting -Config $Config
        $historyRunning = $false
        if ($SaveHistory -or $capacitySetting.SaveHistoryOnStop) {
            $historySaved = $false
            try {
                $saved = Save-DemoFabricHistory -Config $Config -WindowMinutes $SaveHistoryWindowMinutes -PostgresMetrics $(if ($null -ne $postgresHistory) { [string]$postgresHistory.Json } else { '' })
                $results.Add($saved.Result)
                $historyRunning = [bool]$saved.StillRunning
                $historySaved = [string]$saved.Result.status -eq 'Pass' -or $historyRunning
            }
            catch {
                $results.Add((New-DemoResult -CheckId 'STOP.FABRIC.SAVEHISTORY' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The session''s history wasn''t saved: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'In Fabric, run NB_DatabaseHub_LiveActivity in the demo''s workspace (Run all).'))
            }
            # T4's read replica is deleted by now, and its metrics with it (ADR 0025): when the run that would have added them
            # to the history didn't (a paused capacity, for example), they're kept in out/history-pending, with the command
            # that adds them once the capacity runs, so they're never lost without a word.
            if (-not $historySaved -and $null -ne $postgresHistory -and [string]$postgresHistory.Json) {
                $kept = Save-DemoPostgresHistoryPending -Config $Config -Json ([string]$postgresHistory.Json) -Confirm:$false
                if ($null -ne $kept) {
                    $results.Add($kept)
                }
            }
        }
        if ($historyRunning -and $capacitySetting.ManageCapacity) {
            $results.Add((New-DemoResult -CheckId 'STOP.FABRIC.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The history run is still going, so the Fabric capacity the demo resumed wasn''t paused under it.' -Remediation 'Once the run finishes (Monitor hub in Fabric), run stop-demo.ps1 again: it pauses the capacity.'))
        }
        else {
            $results.Add((Suspend-DemoFabricCapacity -Config $Config -State $state -CheckPrefix STOP -Confirm:$false))
        }
    }

    if ($RemoveT3) {
        $results.Add((Remove-DemoT3 -Config $Config -Confirm:$false))
    }
    return $results.ToArray()
}
