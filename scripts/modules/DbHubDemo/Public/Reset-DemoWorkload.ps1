function Reset-DemoWorkload {
    <#
    .SYNOPSIS
    Returns the demo databases to a known, quiet state without redeploying (reset-demo.ps1; ADR 0010).

    .DESCRIPTION
    For each target, the runner's 'reset' through Invoke-DemoWorkloadCommand (on sqlvm01 for T1 and T3,
    through archost01 into the guest for T2): it stops everything, waits, kills leftover ContosoCare.Demo/
    sessions, verifies that no demo transaction is open, empties the scratch tables, and sets the activity
    profile to off unless -KeepProfile. -Reseed reseeds the business data with the recorded seed and scale,
    and -UndoRemediation drops the missing-index remediation indexes, so that scenario starts again from
    'before'. It acts only inside ContosoCare and only on sessions tagged ContosoCare.Demo/ (ADR 0010).

    A reset of T3 connects to it, which resumes a paused serverless database; it pauses again
    t3AutoPauseMinutes after the reset when its profile is off. A target whose VM isn't running is Not
    selected. -RebuildGuest (rebuilding the T2 guest from its image) is Not supported yet: the host's state
    machine needs a reset of its guest steps first (a documented follow-up); use destroy.ps1 and deploy.ps1.

    Returns RESET.<target> results, and RESET.GUEST with -RebuildGuest.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Target
    all (default), T1, T2, T3, or T4 (when t4Enabled).

    .PARAMETER Reseed
    Reseed the business data (minutes, depending on the profile's seed scale).

    .PARAMETER UndoRemediation
    Drop the missing-index remediation indexes.

    .PARAMETER KeepProfile
    Keep the activity profile; by default the reset sets it to off.

    .PARAMETER RebuildGuest
    Rebuild the T2 guest (not supported yet).

    .EXAMPLE
    Reset-DemoWorkload -Config $config -Target T1 -UndoRemediation
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('all', 'T1', 'T2', 'T3', 'T4')]
        [string] $Target = 'all',

        [switch] $Reseed,

        [switch] $UndoRemediation,

        [switch] $KeepProfile,

        [switch] $RebuildGuest
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was reset. Sign in yourself and run reset-demo.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $state = Get-DemoDeploymentState -Config $Config
    $hostVm = Get-DemoHostVmName -Config $Config

    if ($RebuildGuest) {
        $results.Add((New-DemoResult -CheckId 'RESET.GUEST' -Area 'workload' -Target 'T2' -Status 'Not supported' -Message 'Rebuilding the T2 guest isn''t supported yet: the host''s bootstrap state machine skips guest steps that succeeded, and resetting them safely is a follow-up.' -Remediation 'To start T2 over, run ./scripts/destroy.ps1, then ./scripts/deploy.ps1. To return its data to a known state, run reset-demo.ps1 -Target T2 -Reseed.'))
    }

    $targets = if ($Target -eq 'all') { @('T1', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' }) + @('T2') } else { @($Target) }
    $power = @{}
    foreach ($vm in 'sqlvm01', $hostVm) {
        $power[$vm] = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm
    }
    $t3 = $null
    $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('reset', '--json', '--requested-by', 'reset-demo'))
    if ($Reseed) {
        $arguments.Add('--reseed')
    }
    if ($UndoRemediation) {
        $arguments.Add('--undo-remediation')
    }
    if ($KeepProfile) {
        $arguments.Add('--keep-profile')
    }
    foreach ($item in $targets) {
        $checkId = 'RESET.{0}' -f $item
        $vm = if ($item -eq 'T2') { $hostVm } else { 'sqlvm01' }
        $skip = ''
        if (-not $state.RunnerSha256) {
            $skip = 'No workload runner was deployed (deploy.ps1 -SkipRunner).'
        }
        elseif ($item -eq 'T2' -and ($hostVm -ne 'archost01' -or 'archost01' -notin $state.RunnerSentTo)) {
            $skip = 'T2 has no workload runner (the evaluation-only mode, or the runner wasn''t sent to archost01).'
        }
        elseif ($power[$vm] -ne 'PowerState/running') {
            $skip = '{0} isn''t running; start it with start-demo.ps1.' -f $vm
        }
        elseif ($item -eq 'T3') {
            if ($null -eq $t3) {
                $t3 = Get-DemoT3State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
            }
            if (-not $t3.Exists) {
                $skip = 'T3 doesn''t exist (stop-demo.ps1 -RemoveT3); start-demo.ps1 recreates it.'
            }
        }
        elseif ($item -eq 'T4') {
            # T4 (Phase 24): a stopped flexible server has nothing to reset, and connecting wouldn't start it.
            $t4 = Get-DemoT4State -Config $Config -DeploymentId ([string]$state.Tags['deploymentId'])
            if (-not (Test-DemoT4Enabled -Config $Config)) {
                $skip = 'T4 is off in this configuration (t4Enabled is false).'
            }
            elseif ($t4.State -ne 'Ready') {
                $skip = 'T4 is {0}; start it with start-demo.ps1.' -f $t4.State
            }
        }
        if ($skip) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Not selected' -Message ('{0} wasn''t reset: {1}' -f $item, $skip)))
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item, ('Reset the ContosoCare demo state ({0})' -f ($arguments -join ' ')))) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Not selected' -Message ('What if: {0} wasn''t reset (runner arguments: {1}).' -f $item, ($arguments -join ' '))))
            continue
        }
        $timeout = if ($Reseed) { 3600 } else { 900 }
        $run = Invoke-DemoWorkloadCommand -Config $Config -Target $item -ArgumentList $arguments.ToArray() -TimeoutSeconds $timeout -Confirm:$false
        $evidence = [ordered]@{ reseed = [bool]$Reseed; undoRemediation = [bool]$UndoRemediation; keepProfile = [bool]$KeepProfile; exitCode = $run.ExitCode; checks = @($run.Records) }
        $message = [string]$run.Result.message
        if ($run.Status -in 'Pass', 'Warning') {
            $message = '{0} is reset{1}.{2}' -f $item, $(if ($KeepProfile) { '' } else { ', and its activity profile is off' }), $(if ($message) { ' Runner: ' + $message } else { '' })
        }
        elseif (-not $message) {
            $message = '{0} wasn''t reset: the runner exited with code {1}.' -f $item, $run.ExitCode
        }
        $remediation = if ($run.Status -in 'Fail', 'Manual action required') { 'Read the runner''s checks in the evidence; run reset-demo.ps1 again, or with -Reseed.' } else { '' }
        $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status $run.Status -Message $message -Evidence $evidence -Remediation $remediation))
    }
    return $results.ToArray()
}
