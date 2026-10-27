function Wait-DemoBootstrapLoader {
    <#
    .SYNOPSIS
    Waits for the bootstrap loader Run Command on one VM and reports its exit code as a validation result
    (ADR 0003, ADR 0012).

    .DESCRIPTION
    infra/modules/bootstrap.bicep deploys the managed Run Command DbHubDemo-Bootstrap with asyncExecution
    true and treatFailureAsDeploymentFailure false, so the deployment succeeds as soon as the loader starts,
    whatever the loader does next. This reads the Run Command's instance view (az rest GET
    ...?$expand=instanceView, through Invoke-DemoAz) until the script finishes, so a failed loader is never
    hidden behind a successful deployment:
    - Pass: execution state Succeeded and exit code 0. The loader verified and installed the bundle and
      started the scheduled task; the state machine's own progress is in health.json.
    - Fail: any other terminal state or exit code, with the last 4 KB of the script's error output, or no
      loader Run Command on the VM.
    - Warning: still running when the wait ends.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    sqlvm01 (target T1) or archost01 (target T2).

    .PARAMETER ResourceGroupName
    Defaults to rg-<prefix>-<environment>.

    .PARAMETER TimeoutSeconds
    How long to wait for the loader to finish.

    .EXAMPLE
    'sqlvm01', 'archost01' | ForEach-Object { Wait-DemoBootstrapLoader -Config $config -VmName $_ }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $ResourceGroupName = '',

        [ValidateRange(30, 7200)]
        [int] $TimeoutSeconds = 900
    )

    $subscriptionId = $Config['subscriptionId']
    if (-not $ResourceGroupName) {
        $ResourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    }
    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $checkId = 'INFRA.BOOTSTRAP.LOADER_{0}' -f ($VmName -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $remediation = 'Read C:\ProgramData\DbHubDemo\logs\loader.log on the VM (Bastion), then run deploy.ps1 -Resume, which sends the bundle again and re-runs the loader (ADR 0003).'

    $url = '{0}/DbHubDemo-Bootstrap?api-version={1}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName), (Get-DemoRunCommandApiVersion)
    $state = Wait-DemoRunCommand -SubscriptionId $subscriptionId -Url $url -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds 10
    $evidence = @{
        vmName            = $VmName
        executionState    = $state.ExecutionState
        provisioningState = $state.ProvisioningState
        exitCode          = $state.ExitCode
    }

    if (-not $state.Found) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' `
                -Message ('{0} has no bootstrap loader Run Command (DbHubDemo-Bootstrap): {1}' -f $VmName, $state.Error) `
                -Evidence $evidence -Remediation 'Deploy the template with bootstrapBundleSha256 and bootstrapChunkCount after Send-DemoBootstrapBundle (deploy.ps1 -Resume).' -DocUrl $docUrl)
    }
    if ($state.WaitTimedOut) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Warning' `
                -Message ('The bootstrap loader on {0} was still {1} after {2} seconds.' -f $VmName, $state.ExecutionState, $TimeoutSeconds) `
                -Evidence $evidence -Remediation 'Run Wait-DemoBootstrapLoader again, or read health.json on the VM.' -DocUrl $docUrl)
    }
    if ($state.ExecutionState -eq 'Succeeded' -and $state.ExitCode -eq 0) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' `
                -Message ('The bootstrap loader on {0} finished with exit code 0: the bundle is verified and installed, and the scheduled task is running.' -f $VmName) `
                -Evidence $evidence -DocUrl $docUrl)
    }
    $detail = if ($state.Error) { $state.Error } else { $state.Output }
    if ($detail.Length -gt 1000) {
        $detail = $detail.Substring($detail.Length - 1000)
    }
    $evidence['error'] = $detail
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' `
            -Message ('The bootstrap loader on {0} failed (execution state {1}, exit code {2}): {3}' -f $VmName, $state.ExecutionState, $state.ExitCode, $detail) `
            -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}
