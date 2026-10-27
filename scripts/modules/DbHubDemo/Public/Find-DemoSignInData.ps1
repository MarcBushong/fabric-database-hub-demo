function Find-DemoSignInData {
    <#
    .SYNOPSIS
    Finds, and with -Clean removes, sign-in data left on the demo's VMs and in the T2 guest, and verifies that
    none remains (ADR 0009). check-sign-in-data.ps1 calls it. Results hold counts and locations only.

    .DESCRIPTION
    1. The subscription guard.
    2. For each VM (sqlvm01, and archost01 with its guest arcsql01; or arcsql01 in the evaluation-only mode),
       reads its power state. Run Command needs a running VM, so a VM that isn't running is a Warning and
       isn't checked.
    3. Runs vm/bootstrap/Invoke-DemoSignInResidue.ps1 in a managed Run Command (DbHubDemo-SignInData) that
       takes no secret and is deleted afterward: a scan that changes nothing on the VM, or with -Clean, the
       cleanup and then a scan. The cleanup replaces token-shaped values in files with [REDACTED], deletes the
       browser sign-in caches in the guest, and clears a PowerShell or Application event log only when it holds
       a token-shaped value; the Security log only with -ClearSecurityLog. Clearing an event log removes all its
       events, and endpoint protection may report it.
    One result per VM, SECURITY.SIGNIN.<VM> (Get-DemoSignInDataResult): Fail when sign-in data from a person
    is left, or the VM or its guest couldn't be checked (fail closed); Manual action required when the Security
    log holds a token-shaped value, with the command that clears it; Warning when the cleanup cleared an event
    log, or only an application's or a managed identity's token was found; Pass when nothing is left. -WhatIf
    runs step 1 only.

    Sources (checked 2026-10-27):
    - Managed Run Command: https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
    - PowerShell Direct: https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
    - Clearing an event log (wevtutil clear-log):
      https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/debug-customscriptextension-runcommand-scripts

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The VMs to check; by default sqlvm01 and the T2 VM.

    .PARAMETER Clean
    Remove what's found, then check again.

    .PARAMETER ClearSecurityLog
    With -Clean, also clear the Security log when it holds a token-shaped value. Clearing it erases the audit
    trail, so it's never done otherwise.

    .PARAMETER TimeoutSeconds
    The Run Command's script timeout.

    .EXAMPLE
    Find-DemoSignInData -Config $config

    .EXAMPLE
    Find-DemoSignInData -Config $config -VmName archost01 -Clean -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('sqlvm01', 'archost01', 'arcsql01')]
        [string[]] $VmName = @(),

        [switch] $Clean,

        [switch] $ClearSecurityLog,

        [ValidateRange(300, 7200)]
        [int] $TimeoutSeconds = 2400
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was checked. Sign in yourself and run check-sign-in-data.ps1 again.'))
        return $results.ToArray()
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $hostVm = Get-DemoHostVmName -Config $Config
    $targets = if ($VmName.Count -gt 0) { @($VmName | Select-Object -Unique) } else { @('sqlvm01', $hostVm) }
    $action = if ($Clean) { 'Clean' } else { 'Scan' }
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'

    foreach ($vm in $targets) {
        $checkId = 'SECURITY.SIGNIN.{0}' -f $vm.ToUpperInvariant()
        $target = Get-DemoVmTarget -VmName $vm
        $isNestedHost = $vm -eq 'archost01'
        $description = if ($Clean) { 'Remove sign-in data from {0}{1} and check that none is left' } else { 'Check {0}{1} for sign-in data (counts and locations only)' }
        if (-not $PSCmdlet.ShouldProcess($vm, ($description -f $vm, $(if ($isNestedHost) { ' and its guest' } else { '' })))) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'security' -Target $target -Status 'Not selected' -Message ('What if: {0} wasn''t checked.' -f $vm) -DocUrl $docUrl))
            continue
        }
        $power = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $vm
        if ($power -ne 'PowerState/running') {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'security' -Target $target -Status 'Warning' -Message ('{0} isn''t running ({1}), so it wasn''t checked: Run Command needs a running VM.' -f $vm, $(if ($power) { $power } else { 'power state unknown' })) -Evidence ([ordered]@{ vm = $vm; powerState = $power }) -Remediation 'Start it (./scripts/start-demo.ps1), then run ./scripts/check-sign-in-data.ps1 again.' -DocUrl $docUrl))
            continue
        }
        $outcome = Invoke-DemoSignInDataAction -Config $Config -VmName $vm -Action $action -Scope $(if ($isNestedHost) { 'Both' } else { 'Local' }) -IncludeBrowserCache:($vm -eq 'arcsql01') -ClearSecurityLog:$ClearSecurityLog -TimeoutSeconds $TimeoutSeconds
        $guestName = if ($isNestedHost) { 'arcsql01' } else { '' }
        $results.Add((Get-DemoSignInDataResult -CheckId $checkId -Area 'security' -Target $target -VmName $vm -Outcome $outcome -GuestName $guestName))
    }
    return $results.ToArray()
}
