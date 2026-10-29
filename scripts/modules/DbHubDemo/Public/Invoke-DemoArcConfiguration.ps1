function Invoke-DemoArcConfiguration {
    <#
    .SYNOPSIS
    The configure-arc.ps1 sequence for T2: the subscription guard, the product key (ProductKey mode), Arc
    onboarding, SQL Server enabled by Azure Arc configuration, and the Arc checks (ADR 0005, ADR 0006).

    .DESCRIPTION
    1. Runs the subscription guard (Assert-DemoAzContext) and stops with a Fail result if it doesn't pass:
       nothing else runs.
    2. Reads the T2 host's health (a read-only Run Command). With -WaitForHostMinutes it reads it again every
       -HostPollMinutes until the host waits for the orchestrator (WaitingForProductKey or
       WaitingForArcOnboarding), needs a manual step, is Ready, or Failed.
    3. ProductKey mode: when the host reports WaitingForProductKey, sends -ProductKey with
       Set-DemoArcSqlProductKey (only as a protected Run Command parameter), then, within the same wait budget,
       waits for the unattended install to reach WaitingForArcOnboarding. Without a key it reports Manual
       action required. A key is never sent to a host that isn't waiting for one.
    4. Onboards with Invoke-DemoArcOnboarding (the host identity whenever it's attached to archost01, otherwise
       the caller's token); a stale Arc machine from an earlier guest build is deleted first, so there are never
       duplicates.
    5. Once the host is past onboarding (or with -Force), converges the Azure extension for SQL Server, its
       license type, the sqlServerInstances resource, and monitoring (Set-DemoArcSqlConfiguration). In
       PaygWizard mode, while the host's step is ArcOnboardingBeforeWizard, GuidedSetup, or SqlSetupWizard, that
       waits (T2.ARC.CONFIGURATION Manual action required) until the host's setup check passes, so a wrong install
       never gets pay-as-you-go (Phase 28); deploy.ps1's guided stop then runs this sequence again.
    6. Reports T2.ARC.CONNECTED, T2.ARC.NODUPLICATES, and T2.ARC.DISCONNECTEDDAYS (Get-DemoArcCheck).
    Every step is re-runnable. Under -WhatIf only the guard runs. In the evaluation-only mode, once the VM's
    Azure guest agent is disabled (the procedure's last step), Run Command can't read its health; a Connected
    Arc machine then counts as Ready, and the Azure checks still run.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ProductKey
    The SQL Server product key for ProductKey mode (prerequisite P10), as a SecureString.

    .PARAMETER Force
    Onboard and configure even when the host doesn't wait for onboarding (Invoke-DemoArcOnboarding -Force).

    .PARAMETER UseHostIdentity
    Require the least-privilege host identity (assignRoles = true): onboarding fails when it isn't attached.

    .PARAMETER UseCallerToken
    Onboard with the caller's token even when the host identity is attached.

    .PARAMETER WaitForHostMinutes
    How long to wait for the host to reach a state this sequence acts on. 0 reads it once.

    .PARAMETER HostPollMinutes
    Minutes between health reads while waiting for the host.

    .PARAMETER WaitMinutes
    How long Set-DemoArcSqlConfiguration waits for the extension and the instance resource.

    .PARAMETER SkipConfiguration
    Onboard only; leave the extension, license type, and monitoring alone.

    .EXAMPLE
    Invoke-DemoArcConfiguration -Config $config -WaitForHostMinutes 120
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [securestring] $ProductKey,

        [switch] $Force,

        [switch] $UseHostIdentity,

        [switch] $UseCallerToken,

        [ValidateRange(0, 360)]
        [int] $WaitForHostMinutes = 0,

        [ValidateRange(1, 60)]
        [int] $HostPollMinutes = 5,

        [ValidateRange(0, 120)]
        [int] $WaitMinutes = 15,

        [switch] $SkipConfiguration
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $Config['subscriptionId'] -TenantId $Config['tenantId'] -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Fix the Azure CLI context yourself, then run configure-arc.ps1 again.'))
        return $results.ToArray()
    }

    $target = Get-DemoArcTarget -Config $Config
    $docUrl = $target.Setting.DocUrls['connect']
    if (-not $PSCmdlet.ShouldProcess($target.MachineName, 'Send the product key if the host waits for it, onboard to Azure Arc, and configure SQL Server enabled by Azure Arc')) {
        $results.Add((New-DemoArcResult -CheckId 'T2.ARC.ONBOARDING' -Target $target -Status 'Not selected' -Message ('What if: nothing ran. configure-arc.ps1 reads the health of {0}, sends the product key when it waits for one (ProductKey mode), onboards {1} when it waits for onboarding, deletes a stale Arc machine first, and configures the Azure extension for SQL Server, its license type, and monitoring.' -f $target.HostVmName, $target.MachineName) -DocUrl $docUrl))
        return $results.ToArray()
    }

    $stopStates = @('WaitingForProductKey', 'WaitingForArcOnboarding', 'ManualActionRequired', 'Ready', 'Failed')
    $maxPolls = [int][System.Math]::Floor($WaitForHostMinutes / $HostPollMinutes)
    $pollSeconds = $HostPollMinutes * 60
    try {
        $wait = Wait-DemoVmHealthState -Config $Config -VmName $target.HostVmName -State $stopStates -MaxPolls $maxPolls -PollSeconds $pollSeconds
    }
    catch {
        $readError = $_.Exception.Message
        $wait = $null
        if ($target.EvaluationOnly) {
            # The evaluation procedure disables the Azure guest agent last, which ends Run Command on the VM; a
            # Connected Arc machine then stands in for the health read.
            $machine = $null
            try {
                $machine = Get-DemoArcArmResource -SubscriptionId $target.SubscriptionId -Url $target.MachineUrl
            }
            catch {
                Write-Debug -Message 'The Arc machine could not be read either.'
            }
            if ([string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $machine -Name 'properties') -Name 'status') -eq 'Connected') {
                Write-DemoLog -Level Warning -Message ('EVALUATION ONLY: the health of {0} could not be read ({1}), but its Arc machine is Connected: the Azure guest agent is disabled, as the evaluation procedure requires. Continuing with the Azure checks.' -f $target.HostVmName, $readError)
                $wait = [pscustomobject]@{ Health = [pscustomobject]@{ state = 'Ready'; message = 'Read from Azure Arc; the Azure guest agent is disabled.' }; Polls = 0 }
            }
        }
        if ($null -eq $wait) {
            $results.Add((New-DemoArcResult -CheckId 'T2.ARC.ONBOARDING' -Target $target -Status 'Fail' -Message ('The health of {0} could not be read: {1}' -f $target.HostVmName, $readError) -Remediation 'Check that the VM is running and that the bootstrap loader succeeded, then run configure-arc.ps1 again.' -DocUrl $docUrl))
            return $results.ToArray()
        }
    }
    $health = $wait.Health
    $hostState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')

    $keyDocUrl = 'https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt'
    if ($target.InstallMode -eq 'ProductKey' -and $hostState -eq 'WaitingForProductKey') {
        if ($null -eq $ProductKey) {
            $results.Add((New-DemoArcResult -CheckId 'T2.SQL.PRODUCTKEY' -Target $target -Status 'Manual action required' -Message ('{0} waits for the SQL Server product key (ProductKey mode, prerequisite P10); onboarding follows the unattended install.' -f $target.HostVmName) -Remediation 'Run ./scripts/configure-arc.ps1 -ProductKey and type the key, or set the DBHUB_SQL_PRODUCT_KEY secret for GitHub Actions.' -DocUrl $keyDocUrl))
            return $results.ToArray()
        }
        $keyResult = Set-DemoArcSqlProductKey -Config $Config -ProductKey $ProductKey -Confirm:$false
        $results.Add($keyResult)
        # A Warning: the key is stored, and the Windows PowerShell log that recorded it was cleared (Phase 26f).
        if ($keyResult.status -notin 'Pass', 'Warning') {
            return $results.ToArray()
        }
        try {
            $wait = Wait-DemoVmHealthState -Config $Config -VmName $target.HostVmName -State @('WaitingForArcOnboarding', 'ManualActionRequired', 'Ready', 'Failed') -MaxPolls ([System.Math]::Max(0, $maxPolls - $wait.Polls)) -PollSeconds $pollSeconds
        }
        catch {
            $results.Add((New-DemoArcResult -CheckId 'T2.ARC.ONBOARDING' -Target $target -Status 'Fail' -Message ('The health of {0} could not be read after the product key was sent: {1}' -f $target.HostVmName, $_.Exception.Message) -Remediation 'Run configure-arc.ps1 again; the key is already stored on the host.' -DocUrl $docUrl))
            return $results.ToArray()
        }
        $health = $wait.Health
        $hostState = [string](Get-DemoMemberValue -InputObject $health -Name 'state')
    }
    elseif ($null -ne $ProductKey) {
        $reason = if ($target.InstallMode -ne 'ProductKey') { 't2SqlInstallMode is {0}; only ProductKey mode takes a product key' -f $target.InstallMode } else { '{0} reports {1}, not WaitingForProductKey' -f $target.HostVmName, $hostState }
        $results.Add((New-DemoArcResult -CheckId 'T2.SQL.PRODUCTKEY' -Target $target -Status 'Not selected' -Message ('{0}, so the product key was not sent.' -f $reason) -Remediation 'In ProductKey mode, run configure-arc.ps1 -ProductKey -WaitForHostMinutes 120 so the key is sent when the host waits for it.' -DocUrl $keyDocUrl))
    }

    $onboarding = Invoke-DemoArcOnboarding -Config $Config -Health $health -Force:$Force -UseHostIdentity:$UseHostIdentity -UseCallerToken:$UseCallerToken -Confirm:$false
    $results.Add($onboarding)

    # The host is past onboarding when it waits for it, needs a manual step, or is Ready, or when the Arc machine
    # is already Connected while the host configures and seeds the database after the wizard (InProgress).
    $alreadyConnected = $onboarding.status -eq 'Pass' -and [string](Get-DemoMemberValue -InputObject $onboarding.evidence -Name 'azureStatus') -eq 'Connected'
    $pastOnboarding = ($hostState -in 'WaitingForArcOnboarding', 'ManualActionRequired', 'Ready') -or $alreadyConnected
    if ($onboarding.status -eq 'Fail' -or -not ($Force -or $pastOnboarding)) {
        $why = if ($onboarding.status -eq 'Fail') { 'onboarding failed' } else { '{0} reports {1} and isn''t at onboarding yet' -f $target.HostVmName, $(if ($hostState) { $hostState } else { 'no state' }) }
        $results.Add((New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Not selected' -Message ('Configuring SQL Server enabled by Azure Arc was skipped because {0}.' -f $why) -Remediation 'Run configure-arc.ps1 again when the host waits for onboarding, or add -WaitForHostMinutes.' -DocUrl $target.Setting.DocUrls['configuration']))
        return $results.ToArray()
    }
    if ($SkipConfiguration) {
        $results.Add((New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Not selected' -Message '-SkipConfiguration: the Azure extension for SQL Server, its license type, and monitoring were left alone.' -DocUrl $target.Setting.DocUrls['configuration']))
    }
    elseif ($target.InstallMode -eq 'PaygWizard' -and -not $target.EvaluationOnly -and $hostState -ne 'Ready' -and [string](Get-DemoMemberValue -InputObject $health -Name 'currentStep') -in 'ArcOnboardingBeforeWizard', 'GuidedSetup', 'SqlSetupWizard') {
        # Phase 28: no license type or monitoring before the host's setup check passed, so a wrong install (Evaluation,
        # Developer, a named instance) never gets pay-as-you-go.
        $results.Add((New-DemoArcResult -CheckId 'T2.ARC.CONFIGURATION' -Target $target -Status 'Manual action required' -Message ('{0} waits for the SQL Server setup step in {1} (host step {2}), so the Azure extension for SQL Server, its license type, and monitoring wait until the host''s setup check passes.' -f $target.HostVmName, $target.MachineName, [string](Get-DemoMemberValue -InputObject $health -Name 'currentStep')) -Remediation 'Run ./scripts/deploy.ps1: it opens Bastion, guides you through the pre-filled setup (pay-as-you-go, Standard), and continues on its own.' -DocUrl $target.Setting.DocUrls['configuration']))
    }
    else {
        foreach ($item in @(Set-DemoArcSqlConfiguration -Config $Config -WaitMinutes $WaitMinutes -Confirm:$false)) {
            $results.Add($item)
        }
    }
    foreach ($item in @(Get-DemoArcCheck -Config $Config -Check 'Connected', 'NoDuplicates', 'DisconnectedDays')) {
        $results.Add($item)
    }
    return $results.ToArray()
}
