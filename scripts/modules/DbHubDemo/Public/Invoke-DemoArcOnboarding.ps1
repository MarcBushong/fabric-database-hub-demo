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
    2. Probes the guest through vm/bootstrap/Invoke-DemoArcOnboard.ps1 -Action Probe (read-only): PowerShell
       Direct reachability, isolation from IMDS and the wire server (ADR 0004), DNS, and 'azcmagent show -j'.
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
       Fail (ADR 0009).
    5. Waits up to -ConnectWaitMinutes for the Azure machine to report Connected.

    In the opt-in evaluation-only mode (t2Mode EvaluationOnlyAzureVm, ADR 0006) the same steps run on the Azure
    VM arcsql01 itself, and the result is labeled EVALUATION ONLY. Under -WhatIf nothing runs.

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
    The onboarding Run Command's script timeout: download, copy, install, and connect.

    .PARAMETER ConnectWaitMinutes
    How long to wait for the Azure machine to report Connected afterward.

    .PARAMETER PollIntervalSeconds
    Seconds between reads while waiting.

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
        [int] $PollIntervalSeconds = 15
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
    $hostState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
    $evidence['hostState'] = $hostState
    if (-not $Force -and $hostState -ne 'WaitingForArcOnboarding') {
        $hostMessage = [string](Get-DemoMemberValue -InputObject $health -Name 'message')
        switch ($hostState) {
            'Ready' { return (& $newResult 'Pass' ('{0} is Ready, so it isn''t waiting for onboarding; T2.ARC.CONNECTED checks the machine.' -f $target.HostVmName)) }
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
                    return (& $newResult 'Pass' ('{0} is already Connected; {1} reports {2}, so onboarding isn''t needed.' -f $target.MachineName, $target.HostVmName, $(if ($hostState) { $hostState } else { 'no state' })))
                }
                $decision = Get-DemoArcOnboardingDecision -HostState $hostState -MachineName $target.MachineName -ResourceGroupName $target.ResourceGroupName -SubscriptionId $target.SubscriptionId -Probe $null -Machine $null
                return (& $newResult $decision.Status $decision.Reason 'Wait for the host to reach WaitingForArcOnboarding (the guest build takes 60 to 90 minutes), then run configure-arc.ps1 again.')
            }
        }
    }

    # 2. Probe the guest (read-only), and 3. read the Azure machine.
    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoArcOnboard.ps1') -Raw
    try {
        $probeRun = Invoke-DemoVmRunCommand -Config $Config -VmName $target.HostVmName -RunCommandName 'DbHubDemo-ArcProbe' -Script $script -Parameter @{ Action = 'Probe'; MachineName = $target.MachineName; Mode = $target.T2Mode } -TimeoutSeconds 600 -PollIntervalSeconds ([System.Math]::Min(30, $PollIntervalSeconds)) -Confirm:$false
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
        foreach ($name in 'guestReachable', 'imdsReachable', 'wireServerReachable', 'dnsResolves', 'agentInstalled', 'agentStatus', 'agentVersion', 'guestVmId', 'markerStatus') {
            $evidence[$name] = Get-DemoMemberValue -InputObject $probe -Name $name
        }
        $evidence['agentKeys'] = @(Get-DemoMemberValue -InputObject $probe -Name 'agentKeys')
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

    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName $target.HostVmName -RunCommandName 'DbHubDemo-ArcOnboard' -Script $script -Parameter $parameters -ProtectedParameter $protected -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds ([System.Math]::Min(30, $PollIntervalSeconds)) -Confirm:$false
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
        elseif ($parameters['TokenSource'] -eq 'HostIdentity') {
            $remediation = 'The host identity''s token was used. Check that id-<prefix>-<env>-arc-onboard still has Azure Connected Machine Onboarding on the resource group, then run configure-arc.ps1 again; or onboard with your own token: configure-arc.ps1 -UseCallerToken.'
        }
        return (& $newResult 'Fail' ('Onboarding {0} failed (execution state {1}, exit code {2}): {3}' -f $target.MachineName, $run.ExecutionState, $run.ExitCode, $detail) $remediation)
    }
    foreach ($name in 'outcome', 'resourceId', 'agentVersion', 'agentStatus', 'guestVmId', 'taskStarted', 'tokenPassedBy', 'connectAttempts', 'authorizationWaitSeconds') {
        $evidence[$name] = Get-DemoMemberValue -InputObject $outcome -Name $name
    }

    # 5b. The token's carriers (ADR 0009): the Run Command is already deleted. Run Command passes protected
    # parameters to the script as arguments, so the host's PowerShell can log them, and the guest's agent ran
    # with the token; remove what's left of it on the host and in the guest, and verify none is left (fail closed).
    if ($parameters['Action'] -eq 'Onboard') {
        $sweep = Invoke-DemoSignInDataAction -Config $Config -VmName $target.HostVmName -Action 'Clean' -Scope $(if ($target.EvaluationOnly) { 'Local' } else { 'Both' }) -IncludeBrowserCache:$target.EvaluationOnly
        $sweepResult = Get-DemoSignInDataResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -VmName $target.HostVmName -GuestName $(if ($target.EvaluationOnly) { '' } else { $target.MachineName }) -Outcome $sweep
        $evidence['signInData'] = [ordered]@{ status = $sweepResult.status; message = $sweepResult.message; seconds = $sweep.Seconds }
        if ($sweepResult.status -eq 'Fail') {
            return (& $newResult 'Fail' ('{0} is onboarded, but the onboarding token''s traces couldn''t be removed and verified: {1}' -f $target.MachineName, $sweepResult.message) 'Run ./scripts/check-sign-in-data.ps1 -Clean until it passes, then ./scripts/configure-arc.ps1 again.')
        }
        if ($sweepResult.status -eq 'Manual action required') {
            return (& $newResult 'Manual action required' ('{0} is onboarded. {1}' -f $target.MachineName, $sweepResult.message) $sweepResult.remediation)
        }
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
    if ($warnings.Count -gt 0) {
        return (& $newResult 'Warning' ('{0} {1}; the host continues its bootstrap. {2}' -f $target.MachineName, $verb, ($warnings -join ' ')))
    }
    return (& $newResult 'Pass' ('{0} {1}; the host continues its bootstrap.' -f $target.MachineName, $verb))
}
