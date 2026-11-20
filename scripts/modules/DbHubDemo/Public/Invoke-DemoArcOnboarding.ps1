function Invoke-DemoArcOnboarding {
    <#
    .SYNOPSIS
    Onboards the T2 guest arcsql01 to Azure Arc, with the host's onboarding identity when it's attached and
    otherwise the caller's short-lived token, without ever creating a duplicate Arc machine (ADR 0005, ADR 0009).
    Returns the T2.ARC.ONBOARDING result.

    .DESCRIPTION
    1. Reads the host's health.json through a read-only Run Command (Get-DemoVmHealth). Onboarding runs only
       while the host reports WaitingForArcOnboarding, or with -Force; otherwise the host's state is reported
       and nothing changes. In PaygWizard mode the host waits there right after the SQL Server media step,
       before the setup wizard; in ProductKey and Developer modes, after the unattended install (ADR 0003).
       With -Force it first waits, up to -PassWaitMinutes, while the host's bootstrap pass runs (#65 follow-up).
    2. Probes the guest through vm/bootstrap/Invoke-DemoArcOnboard.ps1 -Action Probe (read-only): PowerShell
       Direct reachability, isolation from IMDS and the wire server (ADR 0004), DNS, and 'azcmagent show -j'.
       Since 2026-11-19 (dbhubfx: the probe ran inside the host's own bootstrap pass and gave up), the probe and the
       onboarding first wait for that pass and hold its lock (bootstrap.lock, at most 30 minutes; fail closed), and a
       probe that finds the guest unreachable tries again after pauses of 10, 30, and 60 seconds. A guest that still
       doesn't answer is a Fail whose fix is to run ./scripts/deploy.ps1 again, with PowerShell Direct's own error, and
       configuration waits for it; with an Azure machine that's already Connected it's a Warning, and configuration goes
       on.
    3. Reads Microsoft.HybridCompute/machines/arcsql01 and applies the decision table
       (Get-DemoArcOnboardingDecision):
       - already Connected to the expected machine: skip, and write the marker again;
       - the machine exists but the guest isn't connected to it (a rebuilt guest): delete its
         sqlServerInstances, then the machine (no documented cascade), then onboard, which prevents AZCM0044
         and duplicates;
       - the agent is configured for the machine but the Azure resource is gone: reset the agent locally
         (azcmagent disconnect --force-local-only), then onboard;
       - no agent connection and no machine: onboard.
    4. Onboards with Invoke-DemoArcOnboard.ps1 -Action Onboard on the host, which hands the token to the agent
       inside the guest over PowerShell Direct in a protected config file (azcmagent connect --config, never on
       a command line), writes the marker arc-onboarded.json, and starts the DbHubDemo-Bootstrap task. The Run
       Command is deleted afterward. The token:
       - the host identity, whenever the least-privilege identity id-<prefix>-<env>-arc-onboard is attached to
         archost01 (deploy.ps1 creates it, with Azure Connected Machine Onboarding on the resource group, when
         assignRoles is true): the host requests its token from its own IMDS, so no token leaves the operator's
         machine, none is passed to the Run Command, and a connect that Azure refuses while the new role
         assignment propagates is retried for up to 7.5 minutes;
       - otherwise the caller's: 'az account get-access-token --resource https://management.azure.com/' through
         Invoke-DemoAz, registered with Register-DemoSecret at once and passed only as a protected Run Command
         parameter. It's valid for about an hour, and Run Command hands it to the host's PowerShell as an
         argument, where process auditing and endpoint protection can record it.
       -UseHostIdentity requires the identity (Fail when it isn't attached); -UseCallerToken skips it.
       Right after the onboarding, a second Run Command (DbHubDemo-SignInData, no secret) removes what's left of
       the token on the host and in the guest (Run Command passes protected parameters to the script as
       arguments, which the host's PowerShell can log) and verifies that none is left; if any is, the result is
       Fail (ADR 0009). Since 2026-11-19 (dbhubfn, a first deployment whose sweep failed to connect to the guest while the
       host's own sign-in cleanup checked it), it first waits for the host's bootstrap pass and holds its lock
       (bootstrap.lock, at most 30 minutes), so the two never sweep the guest at the same time, and a guest part that
       fails runs again up to three more times, 10, 30, and 60 seconds apart, with issue #65's bounded recovery first
       (DEPLOY.T2.GUESTRETRY or DEPLOY.T2.GUESTRESTART). In the nested mode, the onboarding records on the resource group
       that its sweep is owed (DbHubArcSweepUtc) until it passes, so every later run sweeps and verifies again, whatever
       the host's state; a Fail's fix is to run ./scripts/deploy.ps1 again.
    5. Waits up to -ConnectWaitMinutes for the Azure machine to report Connected.

    PowerShell Direct into the guest that breaks while the guest runs with a healthy heartbeat (issue #65, 2026-11-18: an
    update's WriteMarker failed with "The Hyper-V socket target process has ended") is cleared on the host: it restarts
    the guest once for this run (deploy.ps1's recovery key, Get-DemoRunRecoveryKey, or outside a deploy.ps1 run that set
    one, this call's own, which its probe, its onboarding, and its sign-in data sweep share) and runs the action again once
    (Invoke-DemoArcOnboardWithRecovery). The evidence then has guestRecovery, which deploy.ps1 reports as
    DEPLOY.T2.GUESTRESTART.

    In the opt-in evaluation-only mode (t2Mode EvaluationOnlyAzureVm, ADR 0006) the same steps run on the Azure
    VM arcsql01 itself, and the result is labeled EVALUATION ONLY. That VM turns its Azure guest agent off at least 15
    minutes after its Arc marker, which ends Run Command there, so no sweep is recorded as owed or run again later: its own
    SignInCleanup step checks first. Under -WhatIf nothing runs.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Health
    The host's health summary when the caller has just read it (Get-DemoVmHealth -View Summary), which saves
    a Run Command. Read here when omitted.

    .PARAMETER Force
    Onboard even when the host doesn't report WaitingForArcOnboarding, for example to repair a connection
    after the host finished.

    .PARAMETER UseHostIdentity
    Require the least-privilege host identity (ADR 0005, assignRoles = true): Fail when it isn't attached to
    archost01, instead of falling back to the caller's token. It's used whenever it's attached anyway.

    .PARAMETER UseCallerToken
    Use the caller's token even when the host identity is attached, for example while its role assignment is
    being repaired.

    .PARAMETER TimeoutSeconds
    The onboarding Run Command's script timeout: download, copy, install, and connect. The Run Command gets 35 minutes
    more, for the wait for the host's bootstrap pass and the tries while the guest doesn't answer (at most 7200 seconds).

    .PARAMETER ConnectWaitMinutes
    How long to wait for the Azure machine to report Connected afterward.

    .PARAMETER PollIntervalSeconds
    Seconds between reads while waiting.

    .PARAMETER PassWaitMinutes
    With -Force, how long onboarding waits while the host's bootstrap pass runs, before its PowerShell Direct sessions go
    into the guest (#65 follow-up): a new generation that hasn't reported yet (the health read's generationPending), a step
    it converges (InProgress), a restart (RebootPending), or no report yet (NotStarted). Any other state ends the wait. 0
    doesn't wait.

    .EXAMPLE
    Invoke-DemoArcOnboarding -Config (Get-DemoConfig -Path ./config/demo.config.json)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Health,

        [switch] $Force,

        [switch] $UseHostIdentity,

        [switch] $UseCallerToken,

        [ValidateRange(300, 7200)]
        [int] $TimeoutSeconds = 1800,

        [ValidateRange(0, 60)]
        [int] $ConnectWaitMinutes = 5,

        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 15,

        [ValidateRange(0, 60)]
        [int] $PassWaitMinutes = 20
    )

    $target = Get-DemoArcTarget -Config $Config
    $setting = $target.Setting
    $docUrl = $setting.DocUrls['connect']
    $evidence = [ordered]@{
        hostVm      = $target.HostVmName
        machineName = $target.MachineName
        t2Mode      = $target.T2Mode
        installMode = $target.InstallMode
        force       = [bool]$Force
        tokenSource = 'None'
    }
    $newResult = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl -EvaluationOnly:$target.EvaluationOnly
    }

    if ($UseHostIdentity -and $UseCallerToken) {
        return (& $newResult 'Fail' '-UseHostIdentity and -UseCallerToken exclude each other.' 'Use one of them, or neither: the host identity is used whenever it''s attached.')
    }
    if ($UseHostIdentity -and $target.EvaluationOnly) {
        return (& $newResult 'Fail' 'The host-identity token needs the nested T2 mode, where deploy.ps1 attaches id-<prefix>-<env>-arc-onboard to archost01 (ADR 0005).' 'Run without -UseHostIdentity to use your own token.')
    }
    if (-not $PSCmdlet.ShouldProcess($target.MachineName, ('Onboard to Azure Arc through {0}: read its health, probe the guest, delete a stale Arc machine if one exists, and connect' -f $target.HostVmName))) {
        return (& $newResult 'Not selected' 'What if: nothing ran. Onboarding reads the host''s health, probes the guest, and onboards it while the host waits for it.')
    }

    # Issue #65: the host restarts the guest at most once for this run to clear a broken PowerShell Direct channel. Outside a
    # deploy.ps1 run that set its key (configure-arc.ps1), this call makes its own, so its probe, its onboarding, and its
    # sign-in data check share that one restart (review of e617f34): the host's own hourly keys differ by caller (arc- and
    # signin-), so each of them allowed one.
    $recoveryKey = Get-DemoRunRecoveryKey
    if (-not $recoveryKey) {
        $recoveryKey = New-DemoRunRecoveryKey -Prefix 'arc'
    }
    # The sign-in data sweep after an onboarding (ADR 0009). 2026-11-19 (dbhubfn): a first onboarding's sweep failed while
    # the host's own sign-in cleanup swept the guest beside it, and a rerun never swept again, because the host was past
    # onboarding. Now the sweep waits for the host's bootstrap pass and holds its lock (at most SweepLockMinutes), so the two
    # never sweep the guest at the same time; a guest that doesn't answer gets issue #65's bounded recovery; and the
    # onboarding leaves a record on the resource group (DbHubArcSweepUtc) until its sweep passes, so a plain rerun of
    # deploy.ps1 sweeps and verifies again by itself, whatever the host's state.
    # Not in the evaluation-only mode (review of e617f34): that VM turns its Azure guest agent off at least 15 minutes after
    # its Arc marker (DisableAzureGuestAgent), so Run Command never reaches it again, and a check owed there could never run
    # nor clear; its own SignInCleanup step cleans it and checks it first, and stops its build when anything is left. There,
    # the record is neither read nor written, and only the sweep right after the onboarding runs, as before.
    $sweepLockMinutes = 30
    $sweepOwed = if ($target.EvaluationOnly) { '' } else { Get-DemoArcSweepOwed -Target $target }
    $sweepFix = if ($target.EvaluationOnly) {
        'Run ./scripts/check-sign-in-data.ps1 -VmName {0} -Clean -Force while Run Command still works on {0}, before its bootstrap turns the Azure guest agent off (at least 15 minutes after the onboarding), then run ./scripts/deploy.ps1.' -f $target.HostVmName
    }
    else {
        'Run ./scripts/deploy.ps1 again: it runs the sign-in data cleanup after the Arc onboarding and its check again by itself, and T2 goes on once it passes.'
    }
    $runSweep = {
        $withGuest = -not $target.EvaluationOnly
        if ($withGuest) {
            Write-DemoLog -Message ('Sign-in data cleanup after the Arc onboarding of {0}: it waits for {1}''s own bootstrap pass first (at most {2} minutes), so the two never sweep {0} at the same time.' -f $target.MachineName, $target.HostVmName, $sweepLockMinutes)
        }
        $sweep = Invoke-DemoSignInDataAction -Config $Config -VmName $target.HostVmName -Action 'Clean' -Scope $(if ($withGuest) { 'Both' } else { 'Local' }) -IncludeBrowserCache:$target.EvaluationOnly -LockMinutes $sweepLockMinutes -RecoveryKey $recoveryKey
        $sweepResult = Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName $target.HostVmName -GuestName $(if ($withGuest) { $target.MachineName } else { '' }) -Outcome $sweep -Remediation $sweepFix
        $sweepEvidence = Get-DemoMemberValue -InputObject $sweepResult -Name 'evidence'
        $record = [ordered]@{ status = $sweepResult.status; message = $sweepResult.message; seconds = $sweep.Seconds; note = [string](Get-DemoMemberValue -InputObject $sweepEvidence -Name 'note') }
        foreach ($name in 'lockSeconds', 'lockTimedOut', 'guestRecovery') {
            $value = Get-DemoMemberValue -InputObject $sweepEvidence -Name $name
            if ($null -ne $value) {
                $record[$name] = $value
            }
        }
        $guestEvidence = Get-DemoMemberValue -InputObject $sweepEvidence -Name ('{0} (guest)' -f $target.MachineName)
        $guestError = [string](Get-DemoMemberValue -InputObject $guestEvidence -Name 'error')
        if ($guestError) {
            $record['error'] = $guestError
        }
        $evidence['signInData'] = $record
        if ($sweepResult.status -in 'Pass', 'Warning') {
            if ($sweepOwed) {
                $null = Set-DemoArcSweepOwed -Config $Config -Value '' -Confirm:$false
            }
        }
        elseif ($sweepResult.status -eq 'Fail' -and -not $target.EvaluationOnly) {
            # Recorded again, in case the record before the onboarding wasn't written: the next run must sweep again.
            $null = Set-DemoArcSweepOwed -Config $Config -Value $(if ($sweepOwed -and $sweepOwed -ne 'unknown') { $sweepOwed } else { [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }) -Confirm:$false
        }
        return $sweepResult
    }
    # The result that ends onboarding when its sweep didn't pass; $null when it did.
    $sweepStop = {
        param([object] $SweepResult)
        if ($SweepResult.status -eq 'Fail') {
            return (& $newResult 'Fail' ('{0} is onboarded, but the onboarding token''s traces couldn''t be removed and verified: {1}' -f $target.MachineName, $SweepResult.message) $sweepFix)
        }
        if ($SweepResult.status -eq 'Manual action required') {
            return (& $newResult 'Manual action required' ('{0} is onboarded. {1}' -f $target.MachineName, $SweepResult.message) $SweepResult.remediation)
        }
        return $null
    }
    # A sweep an earlier run's onboarding left unfinished, on a path that doesn't onboard: it runs now, and its outcome goes
    # with the result's message.
    $owedSweep = {
        param([string] $Status, [string] $Message)
        $sweepResult = & $runSweep
        $stop = & $sweepStop $sweepResult
        if ($null -ne $stop) {
            return $stop
        }
        $then = if ($sweepResult.status -eq 'Warning') { 'Warning' } else { $Status }
        return (& $newResult $then ('{0} The sign-in data check after an earlier run''s Arc onboarding, which didn''t pass then, passed now: {1}' -f $Message, $sweepResult.message))
    }

    # 1. The host's state (read-only).
    $health = $Health
    if ($null -eq $health) {
        try {
            $health = Get-DemoVmHealth -Config $Config -VmName $target.HostVmName -View Summary
        }
        catch {
            return (& $newResult 'Fail' ('The health of {0} could not be read: {1}' -f $target.HostVmName, $_.Exception.Message) 'Check that the VM is running and that the bootstrap loader succeeded (Wait-DemoBootstrapLoader).')
        }
    }
    if ($null -eq $health) {
        return (& $newResult 'Not selected' 'What if: nothing ran. Onboarding reads the host''s health, probes the guest, and onboards it while the host waits for it.')
    }
    # #65 follow-up: after a new bundle, the host's pass checks every step again, and PowerShell Direct sessions that
    # deploy.ps1 started while it ran broke (the user's update, 2026-11-18). Without -Force the host's state already holds
    # onboarding back, so -Force (a golden copy, a repair) waits here, up to PassWaitMinutes, before its probe and marker go
    # into the guest, for as long as a pass runs: a generation that hasn't reported yet (the health read's generationPending),
    # and then the step that pass converges, which it reports as InProgress (the follow-up's review: an existing golden copy
    # keeps its Arc marker, so its pass goes on to WorkloadRunner, whose install stops the workload in the guest), a restart
    # (RebootPending), and no report yet (NotStarted). Any other state is where a pass ends: WaitingForArcOnboarding, Ready,
    # ManualActionRequired, Failed, WaitingForProductKey, or another wait.
    $passRunning = {
        param([object] $Read)
        [bool](Get-DemoMemberValue -InputObject $Read -Name 'generationPending') -or [string](Get-DemoMemberValue -InputObject $Read -Name 'state') -in 'InProgress', 'RebootPending', 'NotStarted'
    }
    $passText = {
        param([object] $Read)
        $passStep = [string](Get-DemoMemberValue -InputObject $Read -Name 'currentStep')
        $passState = [string](Get-DemoMemberValue -InputObject $Read -Name 'state')
        if ([bool](Get-DemoMemberValue -InputObject $Read -Name 'generationPending')) {
            return ('checks every step again for its new bootstrap generation ({0})' -f $(if ($passStep) { 'step {0}' -f $passStep } else { 'starting' }))
        }
        if ($passState -eq 'NotStarted') {
            return 'hasn''t reported a bootstrap pass yet (NotStarted)'
        }
        return ('runs its bootstrap pass ({0}{1})' -f $passState, $(if ($passStep) { ', step {0}' -f $passStep } else { '' }))
    }
    if ($Force -and (& $passRunning $health)) {
        $passClock = [System.Diagnostics.Stopwatch]::StartNew()
        while ((& $passRunning $health) -and $passClock.Elapsed.TotalMinutes -lt $PassWaitMinutes) {
            Write-DemoLog -Message ('{0} {1}; onboarding waits until the pass ends, so its PowerShell Direct sessions into {2} don''t overlap it ({3} of at most {4} minutes).' -f $target.HostVmName, (& $passText $health), $target.MachineName, [int]$passClock.Elapsed.TotalMinutes, $PassWaitMinutes)
            Start-Sleep -Seconds $PollIntervalSeconds
            try {
                $again = Get-DemoVmHealth -Config $Config -VmName $target.HostVmName -View Summary
                if ($null -ne $again) {
                    $health = $again
                }
            }
            catch {
                Write-DemoLog -Level Warning -Message ('Reading the health of {0} again failed; reading it once more: {1}' -f $target.HostVmName, $_.Exception.Message)
            }
        }
        $evidence['passWaitSeconds'] = [int]$passClock.Elapsed.TotalSeconds
        if (& $passRunning $health) {
            $evidence['passPending'] = $true
            Write-DemoLog -Level Warning -Message ('{0} still {1} after {2} minutes; onboarding goes ahead, and a PowerShell Direct channel that breaks is recovered (issue #65).' -f $target.HostVmName, (& $passText $health), $PassWaitMinutes)
        }
    }
    $hostState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
    $evidence['hostState'] = $hostState
    if (-not $Force -and $hostState -ne 'WaitingForArcOnboarding') {
        $hostMessage = [string](Get-DemoMemberValue -InputObject $health -Name 'message')
        switch ($hostState) {
            'Ready' {
                $readyText = '{0} is Ready, so it isn''t waiting for onboarding; T2.ARC.CONNECTED checks the machine.' -f $target.HostVmName
                if ($sweepOwed) {
                    return (& $owedSweep 'Pass' $readyText)
                }
                return (& $newResult 'Pass' $readyText)
            }
            'ManualActionRequired' { return (& $newResult 'Manual action required' ('{0} is past onboarding and waits for a manual step: {1}' -f $target.HostVmName, $hostMessage) 'Follow the instructions in health.json (Get-DemoVmHealth -View Full), then run configure-arc.ps1 again.') }
            'WaitingForProductKey' { return (& $newResult 'Manual action required' ('{0} waits for the SQL Server product key (ProductKey mode, prerequisite P10) before onboarding.' -f $target.HostVmName) 'Run ./scripts/configure-arc.ps1 -ProductKey, or set DBHUB_SQL_PRODUCT_KEY in GitHub Actions.') }
            'Failed' { return (& $newResult 'Fail' ('{0} reports a failed bootstrap step: {1}' -f $target.HostVmName, $hostMessage) 'Read health.json and the bootstrap log on the host, fix the cause, and run deploy.ps1 -Resume.') }
            default {
                # Past the wizard, the host reports InProgress while it configures and seeds the database. A
                # machine that's already Connected needs no onboarding, and configuration can go ahead (live
                # finding, 2026-10-21).
                $connected = $null
                try {
                    $connected = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
                }
                catch {
                    Write-Debug -Message ('The Arc machine could not be read: {0}' -f $_.Exception.Message)
                }
                if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $connected -Name 'properties') -Name 'status') -eq 'Connected') {
                    $evidence['azureStatus'] = 'Connected'
                    $evidence['decision'] = 'AlreadyConnected'
                    $connectedText = '{0} is already Connected; {1} reports {2}, so onboarding isn''t needed.' -f $target.MachineName, $target.HostVmName, $(if ($hostState) { $hostState } else { 'no state' })
                    if ($sweepOwed) {
                        return (& $owedSweep 'Pass' $connectedText)
                    }
                    return (& $newResult 'Pass' $connectedText)
                }
                $decision = Get-DemoArcOnboardingDecision -HostState $hostState -MachineName $target.MachineName -ResourceGroupName $target.ResourceGroupName -SubscriptionId $target.SubscriptionId -Probe $null -Machine $null
                return (& $newResult $decision.Status $decision.Reason 'Wait for the host to reach WaitingForArcOnboarding (the guest build takes 60 to 90 minutes), then run configure-arc.ps1 again.')
            }
        }
    }

    # 2. Probe the guest (read-only), and 3. read the Azure machine.
    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoArcOnboard.ps1') -Raw
    # dbhubfx (2026-11-19): the probe's PowerShell Direct sessions ran inside the host's own bootstrap pass and found the guest
    # unreachable, and onboarding never started. Each action on the host now waits for that pass first and holds its lock
    # (bootstrap.lock, at most ArcLockMinutes), and one that finds the guest unreachable runs again after pauses of 10, 30,
    # and 60 seconds; the Run Commands' timeouts leave room for both.
    $arcLockMinutes = 30
    $probeParameters = @{ Action = 'Probe'; MachineName = $target.MachineName; Mode = $target.T2Mode; LockMinutes = [string]$arcLockMinutes }
    if ($recoveryKey) {
        $probeParameters['RecoveryKey'] = $recoveryKey
    }
    try {
        # 60 minutes: a probe takes about a minute, but it first waits for the host's bootstrap pass (at most 30 minutes),
        # runs again while the guest doesn't answer (about 2 minutes more), and one that finds the channel broken restarts
        # the guest and waits for it (issue #65); Run Command ends a script at its timeout.
        $probeRun = Invoke-DemoVmRunCommand -Config $Config -VmName $target.HostVmName -RunCommandName 'DbHubDemo-ArcProbe' -Script $script -Parameter $probeParameters -TimeoutSeconds (1500 + $arcLockMinutes * 60 + 300) -PollIntervalSeconds ([System.Math]::Min(30, $PollIntervalSeconds)) -Confirm:$false
    }
    catch {
        return (& $newResult 'Fail' ('The guest could not be probed: {0}' -f $_.Exception.Message) 'Run configure-arc.ps1 again; a conflict with an extension that a policy installs clears within minutes.')
    }
    if ($null -eq $probeRun) {
        return (& $newResult 'Not selected' 'What if: nothing ran. The guest would be probed and onboarded.')
    }
    $probe = $null
    if ($probeRun.Succeeded) {
        $probe = ConvertFrom-DemoRunCommandOutput -Text $probeRun.Output
    }
    else {
        $evidence['probeError'] = if ($probeRun.Error) { $probeRun.Error } else { $probeRun.Output }
    }
    if ($null -ne $probe) {
        foreach ($name in 'guestReachable', 'imdsReachable', 'wireServerReachable', 'dnsResolves', 'agentInstalled', 'agentStatus', 'agentVersion', 'guestVmId', 'markerStatus', 'guestRecovery', 'guestError', 'probeTries') {
            $evidence[$name] = Get-DemoMemberValue -InputObject $probe -Name $name
        }
        # The probe's own wait for the host's bootstrap pass, kept apart from the onboarding's (lockSeconds), which comes
        # later and replaced it (live, 2026-11-19, dbhubfy: the row said 0, the onboarding's).
        $evidence['probeLockSeconds'] = Get-DemoMemberValue -InputObject $probe -Name 'lockSeconds'
        # Get-DemoMemberValue returns an array whole, so @() around the call would nest it: [[...]] in the evidence.
        $agentKeys = Get-DemoMemberValue -InputObject $probe -Name 'agentKeys'
        $evidence['agentKeys'] = @($agentKeys)
    }
    try {
        $machine = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
    }
    catch {
        return (& $newResult 'Fail' $_.Exception.Message 'Check that Microsoft.HybridCompute is registered (preflight), then run configure-arc.ps1 again.')
    }
    $evidence['azureMachineExists'] = $null -ne $machine

    # 4. Decide.
    $decision = Get-DemoArcOnboardingDecision -HostState $hostState -Force:$Force -Probe $probe -Machine $machine -MachineName $target.MachineName -ResourceGroupName $target.ResourceGroupName -SubscriptionId $target.SubscriptionId -EvaluationOnly:$target.EvaluationOnly
    $evidence['decision'] = $decision.Action
    Write-DemoLog -Message ('Arc onboarding decision for {0}: {1}. {2}' -f $target.MachineName, $decision.Action, $decision.Reason)
    if ($decision.Action -eq 'GuestUnreachable') {
        # dbhubfx (2026-11-19): a Warning here let configuration go on against an Arc machine that didn't exist, so NOT DONE
        # led with its consequence (T2.ARC.SQLEXTENSION) and named configure-arc.ps1. The guest didn't answer even after the
        # host's own pass, the pauses, and issue #65's recovery: a Fail whose fix is a plain rerun, and configuration waits
        # for it (Invoke-DemoArcConfiguration). With an Azure machine that's already Connected (an update), it stays a
        # Warning, and configuration, which goes through Azure, goes on.
        $azureNow = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $machine -Name 'properties') -Name 'status')
        $detail = [string](Get-DemoMemberValue -InputObject $probe -Name 'guestError')
        if (-not $detail -and $evidence.Contains('probeError')) {
            $detail = [string]$evidence['probeError']
        }
        $detail = (Protect-DemoText -Text $detail).Trim().TrimEnd('.')
        if ($detail.Length -gt 300) {
            $detail = $detail.Substring(0, 297) + '...'
        }
        $tries = [int](Get-DemoMemberValue -InputObject $probe -Name 'probeTries')
        $what = if ($target.EvaluationOnly) { 'The probe on {0} failed' -f $target.HostVmName } elseif ($null -eq $probe) { 'The probe of {0} on {1} failed' -f $target.MachineName, $target.HostVmName } else { '{0} didn''t answer over PowerShell Direct on {1}' -f $target.MachineName, $target.HostVmName }
        $what = '{0}{1}{2}.' -f $what, $(if ($tries -gt 1) { ' after {0} tries' -f $tries } else { '' }), $(if ($detail) { ': {0}' -f $detail } else { '' })
        $unreachableFix = 'Run ./scripts/deploy.ps1 again: it probes {0} again, after {1}''s own bootstrap pass, and onboards it once it answers.' -f $target.MachineName, $target.HostVmName
        if ($azureNow -eq 'Connected') {
            return (& $newResult 'Warning' ('{0} Its Azure Arc machine is Connected, so its configuration goes on.' -f $what) $unreachableFix)
        }
        return (& $newResult 'Fail' ('{0} It isn''t onboarded to Azure Arc, so its configuration waits for it.' -f $what) $unreachableFix)
    }
    if ($decision.Action -notin 'AlreadyConnected', 'CleanupStaleThenOnboard', 'DisconnectLocalThenOnboard', 'Onboard') {
        return (& $newResult $decision.Status $decision.Reason)
    }

    if ($decision.Action -eq 'CleanupStaleThenOnboard') {
        try {
            $deleted = Remove-DemoArcStaleResource -Target $target -PollIntervalSeconds $PollIntervalSeconds -Confirm:$false
        }
        catch {
            return (& $newResult 'Fail' ('Deleting the stale Arc resources failed: {0}' -f $_.Exception.Message) 'Run configure-arc.ps1 again; deletion continues where it stopped.')
        }
        $evidence['deletedStaleResources'] = @($deleted)
    }

    # 5. Onboard (or write the marker again).
    $parameters = [ordered]@{
        Action      = if ($decision.Action -eq 'AlreadyConnected') { 'WriteMarker' } else { 'Onboard' }
        MachineName = $target.MachineName
        Mode        = $target.T2Mode
    }
    $parameters['SubscriptionId'] = $target.SubscriptionId
    $parameters['TenantId'] = $target.TenantId
    $parameters['ResourceGroup'] = $target.ResourceGroupName
    $parameters['Location'] = $target.Location
    $parameters['Cloud'] = $setting.Cloud
    $parameters['CorrelationId'] = [guid]::NewGuid().ToString()
    $parameters['TokenSource'] = 'Parameter'
    $parameters['LockMinutes'] = [string]$arcLockMinutes
    if ($recoveryKey) {
        $parameters['RecoveryKey'] = $recoveryKey
    }
    $evidence['correlationId'] = $parameters['CorrelationId']
    $protected = @{}
    if ($parameters['Action'] -eq 'Onboard') {
        $parameters['Tags'] = ConvertTo-DemoArcTagString -Tag (Get-DemoResourceGroupTag -SubscriptionId $target.SubscriptionId -ResourceGroupName $target.ResourceGroupName)
        $parameters['AgentUrl'] = [string]$setting.Agent['url']
        $parameters['AgentSha256'] = [string]$setting.Agent['sha256']
        $parameters['AgentSignerPatternBase64'] = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$setting.Agent['signerSubjectPattern']))
        $parameters['AgentMaxCacheDays'] = [string]$setting.Agent['maxCacheDays']
        $parameters['DisconnectLocalFirst'] = if ($decision.Action -eq 'DisconnectLocalThenOnboard') { 'true' } else { 'false' }
        # The host identity whenever it's attached (ADR 0009): no operator token on the host or in the guest.
        $identity = $null
        if ($target.EvaluationOnly) {
            $evidence['hostIdentity'] = 'not used in the evaluation-only mode'
        }
        elseif ($UseCallerToken) {
            $evidence['hostIdentity'] = 'skipped (-UseCallerToken)'
        }
        else {
            $identity = Get-DemoArcHostIdentity -Config $Config -Target $target
            $evidence['hostIdentity'] = if ($identity.Found) { 'attached' } else { $identity.Reason }
        }
        if ($UseHostIdentity -and -not ($null -ne $identity -and $identity.Found)) {
            return (& $newResult 'Fail' ('The onboarding identity can''t be used: {0}.' -f $evidence['hostIdentity']) 'Deploy with assignRoles = true, which creates and attaches it, or run without -UseHostIdentity to use your own token.')
        }
        if ($null -ne $identity -and $identity.Found) {
            $parameters['TokenSource'] = 'HostIdentity'
            $parameters['IdentityClientId'] = $identity.ClientId
            $evidence['tokenSource'] = 'HostIdentity'
            Write-DemoLog -Message ('Arc onboarding of {0} uses the host identity {1}; your token isn''t used.' -f $target.MachineName, $identity.Name)
        }
        else {
            $evidence['tokenSource'] = 'Caller'
            Write-DemoLog -Message ('Arc onboarding of {0} uses your token: {1}.' -f $target.MachineName, $evidence['hostIdentity'])
            try {
                $protected['AccessToken'] = Get-DemoArmAccessToken -SubscriptionId $target.SubscriptionId
            }
            catch {
                return (& $newResult 'Fail' $_.Exception.Message "Sign in yourself with 'az login', then run configure-arc.ps1 again.")
            }
        }
    }

    if ($parameters['Action'] -eq 'Onboard' -and -not $target.EvaluationOnly) {
        # Owed until it passes (2026-11-19): written before the token goes to the host, so a run that stops during the
        # onboarding or its sweep leaves the next run to sweep again. Not in the evaluation-only mode (see above).
        $sweepOwed = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $null = Set-DemoArcSweepOwed -Config $Config -Value $sweepOwed -Confirm:$false
    }
    try {
        # The onboarding's own work, plus the wait for the host's bootstrap pass and the tries while the guest doesn't answer.
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName $target.HostVmName -RunCommandName 'DbHubDemo-ArcOnboard' -Script $script -Parameter $parameters -ProtectedParameter $protected -TimeoutSeconds ([System.Math]::Min(7200, $TimeoutSeconds + $arcLockMinutes * 60 + 300)) -PollIntervalSeconds ([System.Math]::Min(30, $PollIntervalSeconds)) -Confirm:$false
    }
    catch {
        return (& $newResult 'Fail' ('The onboarding Run Command could not run: {0}' -f $_.Exception.Message) 'Run configure-arc.ps1 again; a conflict with an extension that a policy installs clears within minutes.')
    }
    finally {
        $protected.Clear()
    }
    if ($null -eq $run) {
        return (& $newResult 'Not selected' 'What if: the onboarding Run Command did not run.')
    }
    $outcome = ConvertFrom-DemoRunCommandOutput -Text $run.Output
    if (-not $run.Succeeded -or $null -eq $outcome) {
        $detail = if ($run.Error) { $run.Error } else { $run.Output }
        $evidence['error'] = $detail
        $remediation = 'Read the bootstrap log on the host (C:\ProgramData\DbHubDemo\logs), fix the cause, and run configure-arc.ps1 again.'
        if ($detail -match 'AZCM0044') {
            $remediation = 'An Arc machine with this name already exists (AZCM0044). Run configure-arc.ps1 again: it deletes a stale machine before onboarding.'
        }
        elseif ($detail -match 'bootstrap\.lock|did not answer over PowerShell Direct') {
            # Nothing was changed (dbhubfx, 2026-11-19): the host's own pass held its lock, or the guest didn't answer.
            $remediation = 'Run ./scripts/deploy.ps1 again: it onboards {0} after {1}''s own bootstrap pass, once {0} answers.' -f $target.MachineName, $target.HostVmName
        }
        elseif ($parameters['TokenSource'] -eq 'HostIdentity') {
            $remediation = 'The host identity''s token was used. Check that id-<prefix>-<env>-arc-onboard still has Azure Connected Machine Onboarding on the resource group, then run configure-arc.ps1 again; or onboard with your own token: configure-arc.ps1 -UseCallerToken.'
        }
        return (& $newResult 'Fail' ('Onboarding {0} failed (execution state {1}, exit code {2}): {3}' -f $target.MachineName, $run.ExecutionState, $run.ExitCode, $detail) $remediation)
    }
    # lockSeconds is the onboarding's own wait for the host's bootstrap pass; the probe's is probeLockSeconds.
    foreach ($name in 'outcome', 'resourceId', 'agentVersion', 'agentStatus', 'guestVmId', 'taskStarted', 'tokenPassedBy', 'connectAttempts', 'authorizationWaitSeconds', 'lockSeconds') {
        $evidence[$name] = Get-DemoMemberValue -InputObject $outcome -Name $name
    }
    # A restart the action made; one the probe made stays when the action made none.
    $actionRecovery = Get-DemoMemberValue -InputObject $outcome -Name 'guestRecovery'
    if ($null -ne $actionRecovery) {
        $evidence['guestRecovery'] = $actionRecovery
    }

    # 5b. The token's carriers (ADR 0009): the Run Command is already deleted. Run Command passes protected
    # parameters to the script as arguments, so the host's PowerShell can log them, and the guest's agent ran
    # with the token; remove what's left of it on the host and in the guest, and verify none is left (fail closed).
    # Also when only the marker was written, if an earlier run's onboarding left its sweep unfinished (2026-11-19).
    $sweptNow = $false
    if ($parameters['Action'] -eq 'Onboard' -or $sweepOwed) {
        $stop = & $sweepStop (& $runSweep)
        if ($null -ne $stop) {
            return $stop
        }
        $sweptNow = $parameters['Action'] -ne 'Onboard'
    }

    $machine = Wait-DemoArcMachineConnected -Target $target -WaitMinutes $ConnectWaitMinutes -PollIntervalSeconds $PollIntervalSeconds
    $azureStatus = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $machine -Name 'properties') -Name 'status')
    $evidence['azureStatus'] = $azureStatus
    if ($azureStatus -ne 'Connected') {
        return (& $newResult 'Warning' ('The agent in {0} reports Connected and the marker is written, but Azure shows the machine as ''{1}'' after {2} minutes.' -f $target.MachineName, $azureStatus, $ConnectWaitMinutes) 'Run configure-arc.ps1 again in a few minutes; T2.ARC.CONNECTED checks the machine.')
    }
    $verb = if ($decision.Action -eq 'AlreadyConnected') { 'was already Connected; the marker was written again' } else { 'is onboarded and Connected' }
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ([string]$evidence['tokenPassedBy'] -eq 'CommandLine') {
        $warnings.Add('The agent didn''t take the token from its config file, so it got it on its command line once; the sweep after onboarding removed what that left.')
    }
    if ($evidence.Contains('signInData') -and $evidence['signInData']['status'] -eq 'Warning') {
        $warnings.Add([string]$evidence['signInData']['message'])
    }
    # A Pass from the sweep can carry a note: the LSA secret Azure's provisioning leaves, deleted with automatic sign-in off.
    $signInNote = ''
    if ($evidence.Contains('signInData') -and $evidence['signInData']['status'] -ne 'Warning' -and $evidence['signInData']['note']) {
        $signInNote = ' ' + [string]$evidence['signInData']['note']
    }
    if ($sweptNow -and $evidence['signInData']['status'] -ne 'Warning') {
        $signInNote = ' The sign-in data check after an earlier run''s Arc onboarding, which didn''t pass then, passed now: {0}' -f [string]$evidence['signInData']['message']
    }
    if ($warnings.Count -gt 0) {
        return (& $newResult 'Warning' ('{0} {1}; the host continues its bootstrap. {2}{3}' -f $target.MachineName, $verb, ($warnings -join ' '), $signInNote))
    }
    return (& $newResult 'Pass' ('{0} {1}; the host continues its bootstrap.{2}' -f $target.MachineName, $verb, $signInNote))
}
