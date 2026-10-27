function Start-DemoEnvironment {
    <#
    .SYNOPSIS
    Starts the demo for a session: the cost guardrail, the VMs, T3 (resumed, or recreated with stable names
    when it was removed), the activity profile, an optional warm-up, and on-demand Bastion (plan sections 9.4
    and 9.6). start-demo.ps1 and the scheduled start and warm-up workflows call it.

    .DESCRIPTION
    1. The subscription guard; nothing runs if it fails.
    2. The cost guardrail (Test-DemoStartCost): the live estimate against sessionCeilingUsd and
       monthlyCeilingUsd, and the month-to-date actual cost plus one session against monthlyCeilingUsd. A Fail
       stops here, before anything starts; -SkipCostCheck skips it.
    3. Requests both VM starts at once, then waits until sqlvm01 and the T2 VM run (START.VM_*; ADR 0018). The
       bootstraps resume on their own. A golden snapshot's source host gets its air-gapped guest back
       (T2.GOLDEN.SOURCE, Invoke-DemoGoldenSourceRelease). T1's monitoring plugin, which can stay NotRunning
       after a deallocation (live, 2026-10-22), gets the SQL IaaS Agent service restarted
       (START.T1.MONITORING, Restore-DemoSqlVmMonitoringPlugin): first it waits up to 5 minutes for the agent to
       report the plugin's status, because a restart right after boot, before that, left it NotRunning (live,
       2026-10-26), then restarts the service only when the plugin isn't Running, and checks for Running and OK.
       A one-time host password left from an earlier session that couldn't be rotated is rotated now, unless
       -Interactive; with the Key Vault opt-in, the vault's copy is disabled too (START.KEYVAULT.CLEANUP).
       Before the VMs start, with the on-demand activity control (control.enabled, ADR 0020), a pending auto-stop
       of a notebook run is cancelled, because this session takes over: a Warning says the VMs now run until
       stop-demo.ps1 or the nightly auto-shutdown (START.CONTROL.AUTOSTOP). When it can't be cancelled, the
       Warning gives the pending stop's time and how to cancel it, and the start carries on. A DbHub-Stop job
       that's queued or running is waited for, up to 10 minutes, and never stopped (START.CONTROL.STOPJOB): a Pass
       when it finishes; a Warning when it's still running after the wait or its state can't be read.
       With fabric.manageCapacity true (Phase 26b, ADR 0023), the Fabric capacity in fabric.capacityName is resumed
       when it's Paused and recorded in the group's DbHubFabricCapacityResumed tag, so stop-demo.ps1 pauses only what
       the demo resumed (START.FABRIC.CAPACITY; Resume-DemoFabricCapacity). With false, the default, it's Not selected
       and the capacity isn't called.
    4. T3 (the user-directed lifecycle, ADR 0016): when it exists, Invoke-DemoT3WarmUp resumes it. When
       stop-demo.ps1 -RemoveT3 removed it, the template recreates it under the same names (keeping the
       loaders' settings), then Add-DemoT1ToT3AdminGroup, Invoke-DemoT3SqlFromT1 -Name Setup,
       Enable-DemoT3Workload, the readiness gate (Test-DemoT3Readiness: Resource Graph, the extended property,
       and fresh telemetry, otherwise a Warning with the measured lag), and T1's monitoring: a template
       deployment keeps the SQL IaaS extension Updating for about 10 minutes, which is a wait, not a failure
       (Enable-DemoSqlVmMonitoring -WaitMinutes, as configure-monitoring.ps1 -Target T1 does).
    4a. T4, the PostgreSQL flexible server (Phase 24, ADR 0019): its start is requested with the VMs
       (Servers - Start) and confirmed before its profile is set (START.T4.START). -SkipT4 leaves it stopped.
    5. Sets the activity profile (-ActivityProfile, or the configured activityProfile, baseline by default)
       on T1, T3, T4, and T2 until the next auto-shutdown (START.PROFILE_*). The VMs don't set it at boot unless
       activityProfileOnBoot is true, so this is what starts the demo's activity. T2's guest needs a few
       minutes after the host starts, so its profile is retried.
    6. -WarmUpMinutes: the activity keeps running in the background, and START.WARMUP says when to check the
       telemetry (ADR 0018). With -WaitForWarmUp it waits that long, then checks that telemetry arrives for
       each started target (Test-DemoHubTelemetry), so Hub charts have history when the presenter joins.
    7. -Interactive deploys Bastion (New-DemoBastion), capped at bastionMaxHours. The one-time host password
       is start-demo.ps1's job, because it goes to the operator's clipboard or, with the Key Vault opt-in, to
       the vault.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ActivityProfile
    off, baseline, business-day, or incident:<scenario>; empty uses the configured activityProfile.

    .PARAMETER WarmUpMinutes
    Minutes of activity before the telemetry check (the scheduled start uses 30 with -WaitForWarmUp).

    .PARAMETER WaitForWarmUp
    Wait -WarmUpMinutes, then check the telemetry. Without it, the activity runs in the background and the
    function returns once the profiles are set.

    .PARAMETER SkipT3
    Leave T3 alone.

    .PARAMETER Interactive
    Deploy on-demand Bastion for the T2 setup-wizard step.

    .PARAMETER SkipCostCheck
    Start without the cost guardrail (for example right after a preflight that ran it).

    .PARAMETER T3ReadinessMinutes
    How long the readiness gate waits after T3 is recreated.

    .PARAMETER MonitoringWaitMinutes
    How long T1's monitoring may stay Updating after T3 is recreated.

    .PARAMETER T2ProfileRetrySeconds
    Seconds between profile attempts while T2's guest boots, and while T1's SQL Server starts (both VMs boot
    at once).

    .PARAMETER SkipT4
    Leave T4, the PostgreSQL flexible server, stopped.

    .PARAMETER T4StartMinutes
    How long to wait for T4 to be Ready before its activity profile is set.

    .EXAMPLE
    Start-DemoEnvironment -Config $config -WarmUpMinutes 30
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^((off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47}))?$')]
        [string] $ActivityProfile = '',

        [ValidateRange(0, 240)]
        [int] $WarmUpMinutes = 0,

        [switch] $WaitForWarmUp,

        [switch] $SkipT3,

        [switch] $Interactive,

        [switch] $SkipCostCheck,

        [ValidateRange(0, 120)]
        [int] $T3ReadinessMinutes = 30,

        [ValidateRange(0, 60)]
        [int] $MonitoringWaitMinutes = 20,

        [ValidateRange(0, 600)]
        [int] $T2ProfileRetrySeconds = 120,

        [switch] $SkipT4,

        [ValidateRange(1, 30)]
        [int] $T4StartMinutes = 15
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was started. Sign in yourself and run start-demo.ps1 again.'))
        return $results.ToArray()
    }
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $state = Get-DemoDeploymentState -Config $Config
    if (-not $state.Exists) {
        $results.Add((New-DemoResult -CheckId 'START.DEMO' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('{0} doesn''t exist: there''s nothing to start.' -f $resourceGroupName) -Remediation 'Run deploy.ps1 first.'))
        return $results.ToArray()
    }
    $networkMode = if ($state.NetworkMode -in 'public', 'private') { $state.NetworkMode } else { (Resolve-DemoNetworkMode -ConfiguredMode ([string]$Config['networkMode']) -PolicyUnknown).EffectiveMode }

    if ($SkipCostCheck) {
        $results.Add((New-DemoResult -CheckId 'START.COST' -Area 'preflight' -Target 'subscription' -Status 'Not selected' -Message 'The cost guardrail was skipped (-SkipCostCheck).'))
    }
    else {
        $cost = @(Test-DemoStartCost -Config $Config -NetworkMode $networkMode -T3UseFreeLimit $state.T3UseFreeLimit)
        foreach ($item in $cost) {
            $results.Add($item)
        }
        if (@($cost | Where-Object { $_.status -eq 'Fail' }).Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'START.DEMO' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'The cost guardrail failed, so nothing was started.' -Remediation 'Read the cost results above: pick a cheaper profile or options, or raise the ceiling in the configuration (ADR 0016). -SkipCostCheck starts anyway.'))
            return $results.ToArray()
        }
    }

    if (-not $PSCmdlet.ShouldProcess($resourceGroupName, 'Start the demo VMs, resume or recreate T3, and set the activity profile')) {
        $results.Add((New-DemoResult -CheckId 'START.DEMO' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message 'What if: nothing was started.'))
        return $results.ToArray()
    }
    # A local session takes over from an on-demand run (ADR 0020): the run's pending auto-stop would deallocate this
    # session's VMs, so it's cancelled first, with a Warning, and a stop job already in flight is waited for. Nothing
    # here stops the start.
    if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        try {
            foreach ($item in @(Clear-DemoActivityControlAutoStop -Config $Config -Purpose Start -Confirm:$false)) {
                $results.Add($item)
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId 'START.CONTROL.AUTOSTOP' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('A pending on-demand auto-stop couldn''t be checked: {0}. If one is pending, it deallocates the VMs at its time; the start carried on.' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'status.ps1 shows whether one is pending (STATUS.CONTROL). To cancel it, delete the schedule dbhub-autostop in the control Automation account aa-<prefix>-control (Shared resources > Schedules) in the Azure portal, or run start-demo.ps1 again.' -DocUrl 'https://learn.microsoft.com/rest/api/automation/schedule/delete'))
        }
    }
    $hostVm = Get-DemoHostVmName -Config $Config
    # fabric.manageCapacity (Phase 26b, ADR 0023): only a Paused capacity that's yours alone is resumed, and recorded in
    # the group's tags for stop-demo.ps1; with the default (false) the capacity isn't called.
    $results.Add((Resume-DemoFabricCapacity -Config $Config -State $state -Confirm:$false))
    # Both VMs boot at once (ADR 0018): both starts are requested, then each is waited for. T4's start is
    # requested with them and confirmed before its profile is set (Phase 24, ADR 0019). The results say which
    # starts this run requested, so a VM it started isn't reported as already running (Phase 25d).
    $startRequested = @{}
    foreach ($vm in 'sqlvm01', $hostVm) {
        $startRequested[$vm] = [bool](Request-DemoVmStart -Config $Config -VmName $vm)
    }
    $t4On = -not $SkipT4 -and (Test-DemoT4Enabled -Config $Config)
    $t4Request = if ($t4On) { Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 0 -CheckPrefix START } else { $null }
    foreach ($vm in 'sqlvm01', $hostVm) {
        $results.Add((Invoke-DemoVmPowerAction -Config $Config -VmName $vm -Action Start -StartRequested:$startRequested[$vm]))
    }
    $running = @{}
    foreach ($vm in 'sqlvm01', $hostVm) {
        $running[$vm] = @($results | Where-Object { $_.checkId -eq ('START.VM_{0}' -f $vm.ToUpperInvariant()) -and $_.status -eq 'Pass' }).Count -gt 0
    }

    # A golden snapshot's source host has an air-gapped guest until the first start after the capture.
    if ($running[$hostVm]) {
        $sourceRelease = Invoke-DemoGoldenSourceRelease -Config $Config
        if ($null -ne $sourceRelease) {
            $results.Add($sourceRelease)
        }
    }

    # After a deallocation, T1's monitoring plugin can stay NotRunning, so T1 sends no performance telemetry
    # (live, 2026-10-22); the SQL IaaS Agent service is restarted when it does, once the agent has reported the
    # plugin's status (live, 2026-10-26: a restart before that left it NotRunning).
    if ($running['sqlvm01']) {
        $results.Add((Restore-DemoSqlVmMonitoringPlugin -Config $Config))
    }

    if ($state.HostPasswordUtc -and -not $Interactive -and $running[$hostVm]) {
        Write-DemoLog -Message ('A one-time password set on {0} at {1} was never rotated; rotating it now.' -f $hostVm, $state.HostPasswordUtc)
        $results.Add((Set-DemoVmLocalPassword -Config $Config -VmName $hostVm -Rotate -Confirm:$false))
        if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
            $results.Add((Disable-DemoHostPasswordSecret -Config $Config -VmName $hostVm -CheckId 'START.KEYVAULT.CLEANUP' -Confirm:$false))
        }
    }

    $t3Ready = $false
    if (-not $SkipT3) {
        $t3 = Get-DemoT3State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
        if ($t3.Exists) {
            foreach ($item in @(Invoke-DemoT3WarmUp -Config $Config)) {
                $results.Add($item)
            }
            $t3Ready = $true
        }
        elseif (-not $running['sqlvm01']) {
            $results.Add((New-DemoResult -CheckId 'START.T3' -Area 'infra' -Target 'T3' -Status 'Fail' -Message 'T3 doesn''t exist, and it can''t be recreated without T1 running.' -Remediation 'Fix the T1 start first, then run start-demo.ps1 again.'))
        }
        else {
            Write-DemoLog -Message ('T3 ({0}) doesn''t exist; recreating it under the same names.' -f $t3.ServerName)
            $useFreeLimit = if ([string]$Config['t3FreeOffer'] -eq 'off') { $false } elseif ($null -ne $state.T3UseFreeLimit) { [bool]$state.T3UseFreeLimit } else { [bool](Get-DemoT3FreeOfferStatus -Config $Config).UseFreeLimit }
            $deployArguments = @{
                Config                  = $Config
                NetworkMode             = $networkMode
                T3UseFreeLimit          = $useFreeLimit
                T3AdminGroupDisplayName = $state.T3AdminGroupName
            }
            if ($state.BundleSha256 -and $state.BundleChunkCount -gt 0) {
                $deployArguments['BootstrapBundleSha256'] = $state.BundleSha256
                $deployArguments['BootstrapChunkCount'] = $state.BundleChunkCount
                if ($state.RunnerSha256 -and $state.RunnerChunkCount -gt 0) {
                    $deployArguments['WorkloadRunnerSha256'] = $state.RunnerSha256
                    $deployArguments['WorkloadRunnerChunkCount'] = $state.RunnerChunkCount
                }
            }
            $deployment = Invoke-DemoTemplateDeployment @deployArguments
            foreach ($item in $deployment.Results) {
                $results.Add($item)
            }
            if ($deployment.Succeeded) {
                $group = Add-DemoT1ToT3AdminGroup -Config $Config -PrincipalId (Get-DemoT1PrincipalId -Config $Config)
                $results.Add($group)
                if ($group.status -in 'Pass', 'Warning') {
                    $setup = Invoke-DemoT3SqlFromT1 -Config $Config -Name Setup
                    $results.Add($setup.Result)
                    if ($setup.Status -in 'Pass', 'Warning' -and $state.RunnerSha256) {
                        $results.Add((Enable-DemoT3Workload -Config $Config -Confirm:$false))
                    }
                    $t3Ready = $setup.Status -in 'Pass', 'Warning'
                }
                $gate = Test-DemoT3Readiness -Config $Config -WaitMinutes $T3ReadinessMinutes
                foreach ($item in @($gate.Results)) {
                    $results.Add($item)
                }
                # The redeployment keeps the SQL IaaS extension Updating for about 10 minutes: a wait.
                $results.Add((Enable-DemoSqlVmMonitoring -Config $Config -WaitMinutes $MonitoringWaitMinutes -Confirm:$false))
            }
        }
    }

    $t4Ready = $false
    if ($t4On) {
        $t4Requested = $null -ne $t4Request -and [string](Get-DemoMemberValue -InputObject $t4Request.evidence -Name 'stateBefore') -notin @('', 'Ready')
        $t4Start = if ($t4Request.status -in 'Pass', 'Warning') { Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes $T4StartMinutes -CheckPrefix START -Requested:$t4Requested } else { $t4Request }
        $results.Add($t4Start)
        $t4Ready = $t4Start.status -eq 'Pass' -and [string](Get-DemoMemberValue -InputObject $t4Start.evidence -Name 'stateAfter') -eq 'Ready'
    }

    $profileName = if ($ActivityProfile) { $ActivityProfile } elseif ($Config['activityProfile']) { [string]$Config['activityProfile'] } else { 'baseline' }
    $t3Enabled = $t3Ready -and ((Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T3') -or @($results | Where-Object { $_.checkId -like 'WORKLOAD.T3*' -and $_.status -in 'Pass', 'Warning' }).Count -gt 0)
    $profileTargets = @('T1', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' }) + @('T2')
    foreach ($target in $profileTargets) {
        $skip = ''
        if (-not $state.RunnerSha256) {
            $skip = 'No workload runner was deployed (deploy.ps1 -SkipRunner).'
        }
        elseif ($target -in 'T1', 'T3', 'T4' -and -not $running['sqlvm01']) {
            $skip = 'sqlvm01 isn''t running.'
        }
        elseif ($target -eq 'T4' -and $SkipT4) {
            $skip = 'T4 was left alone (-SkipT4).'
        }
        elseif ($target -eq 'T4' -and -not $t4Ready) {
            $skip = 'T4 isn''t running (START.T4.START says why), so its activity wasn''t started.'
        }
        elseif ($target -eq 'T4' -and -not (Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T4')) {
            $skip = 'T4 isn''t set up for the runner yet (deploy.ps1 runs Enable-DemoT4Workload in T1''s T4 step).'
        }
        elseif ($target -eq 'T3' -and $SkipT3) {
            $skip = 'T3 was left alone (-SkipT3).'
        }
        elseif ($target -eq 'T3' -and -not $t3Enabled) {
            $skip = 'T3 isn''t ready for the runner yet (deploy.ps1 runs Enable-DemoT3Workload in its T3 stage).'
        }
        elseif ($target -eq 'T2' -and ($hostVm -ne 'archost01' -or 'archost01' -notin $state.RunnerSentTo)) {
            $skip = 'T2 has no workload runner (the evaluation-only mode, or the runner wasn''t sent to archost01).'
        }
        elseif ($target -eq 'T2' -and -not $running[$hostVm]) {
            $skip = ('{0} isn''t running.' -f $hostVm)
        }
        # T2's guest boots after its host, and T1's SQL Server can still be starting because both VMs boot at once
        # (live, 2026-10-22: T1's first attempt found no server), so both retry.
        $attempts = if ($target -in 'T1', 'T2') { 3 } else { 1 }
        $results.Add((Set-DemoTargetProfile -Config $Config -Target $target -ProfileName $profileName -CheckPrefix 'START' -SkipReason $skip -RequestedBy 'start-demo' -Attempts $attempts -RetrySeconds $T2ProfileRetrySeconds))
    }

    if ($WarmUpMinutes -gt 0 -and -not $WaitForWarmUp) {
        # The warm-up runs in the background (ADR 0018): the profiles keep the activity going until the next
        # auto-shutdown, so nothing here waits for it.
        $results.Add((New-DemoResult -CheckId 'START.WARMUP' -Area 'workload' -Target 'subscription' -Status 'Not selected' -Message ('The activity runs on the VMs until the next auto-shutdown, so Hub charts fill in from now; start-demo.ps1 didn''t wait {0} minutes for it. After that, check the telemetry: ./scripts/validate.ps1 -Area Telemetry.' -f $WarmUpMinutes) -Remediation '-WaitForWarmUp waits here and checks the telemetry instead (the scheduled warm-up workflows use it).'))
    }
    elseif ($WarmUpMinutes -gt 0) {
        Write-DemoLog -Message ('Warming up for {0} minutes so Hub charts have history.' -f $WarmUpMinutes)
        Start-Sleep -Seconds ($WarmUpMinutes * 60)
        $telemetryTargets = @('T1')
        if (-not $SkipT3 -and $t3Ready) {
            $telemetryTargets += 'T3'
        }
        if (Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T2') {
            $telemetryTargets += 'T2'
        }
        foreach ($item in @(Test-DemoHubTelemetry -Config $Config -Target $telemetryTargets -WaitMinutes 15)) {
            $results.Add($item)
        }
    }

    if ($Interactive) {
        $results.Add((New-DemoBastion -Config $Config -Confirm:$false))
    }
    return $results.ToArray()
}
