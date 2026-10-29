#Requires -Version 7.4
<#
.SYNOPSIS
Starts the demo for a session: the cost guardrail, the VMs, T3 (resumed, or recreated when it was removed),
the activity profile, an optional warm-up, and on-demand Bastion with a one-time host password (plan
sections 9.4, 9.6).

.DESCRIPTION
- The cost guardrail runs first: the live estimate against sessionCeilingUsd and monthlyCeilingUsd, and this
  month's actual cost plus one session against monthlyCeilingUsd. A Fail stops the start before anything
  runs; -SkipCostCheck starts anyway.
- Starts sqlvm01 and the T2 VM at once and waits until they run. The bootstraps continue on their own. A
  golden snapshot's source host gets its air-gapped guest back (T2.GOLDEN.SOURCE).
- T3 persists between demos by default and is resumed (Invoke-DemoT3WarmUp). After stop-demo.ps1 -RemoveT3
  it's recreated under the same names and configured from T1, then the readiness gate checks Resource
  Graph, the extended property, and fresh telemetry, and reports a Warning with the measured lag otherwise;
  T1's monitoring is checked again after that template deployment, waiting while the SQL IaaS extension
  updates.
- Sets the activity profile (-ActivityProfile, or the configured activityProfile) on T1, T3, and T2 until
  the next auto-shutdown. The VMs don't set it at boot unless activityProfileOnBoot is true, so a VM that
  starts some other way doesn't keep T3 awake (ADR 0016).
- -WarmUpMinutes: the activity keeps running in the background and the script returns once the profiles are
  set (ADR 0018); START.WARMUP says when to check the telemetry. -WaitForWarmUp waits that long and checks
  that telemetry arrives (the scheduled warm-up workflows use 30).
- -Interactive deploys Azure Bastion Basic for the T2 setup-wizard step (about 8 minutes); stop-demo.ps1
  removes it, and the bastion-cleanup workflow does after bastionMaxHours.
- -ResetAdminPassword (with -Interactive) sets a one-time password for the T2 host's administrator through a
  Run Command and copies it to your clipboard. It's never displayed, logged, or stored, and stop-demo.ps1
  rotates it to a value nobody keeps. Without a working clipboard (for example in Cloud Shell or GitHub
  Actions) nothing is set, and the result says how to reset it in the portal instead.
- With the Key Vault opt-in (keyVault.enabled, which requires assignRoles), the password goes to the vault
  instead of the clipboard, before it's set on the VM: Initialize-DemoKeyVault -EnsureOnly makes sure of the
  vault and your access, Set-DemoHostPasswordSecret stores it, and START.KEYVAULT says where to copy it in
  the portal for the Bastion form. stop-demo.ps1 rotates the password and disables the secret. No clipboard
  is needed, so this also works in Cloud Shell.

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER ActivityProfile
off, baseline, business-day, or incident:<scenario>; empty uses the configured activityProfile.

.PARAMETER WarmUpMinutes
Minutes of activity before the telemetry check (0: none). Without -WaitForWarmUp, nothing waits for it.

.PARAMETER WaitForWarmUp
Wait -WarmUpMinutes, then check that telemetry arrives (the scheduled start and warm-up workflows).

.PARAMETER SkipT3
Leave T3 alone.

.PARAMETER SkipT4
Leave T4, the PostgreSQL flexible server, stopped.

.PARAMETER SkipCostCheck
Start without the cost guardrail.

.PARAMETER Interactive
Deploy on-demand Bastion.

.PARAMETER ResetAdminPassword
With -Interactive: a one-time password for the T2 host's administrator, on your clipboard or, with the Key
Vault opt-in, in the vault.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/start-demo.ps1 -WarmUpMinutes 30

.EXAMPLE
./scripts/start-demo.ps1 -Interactive -ResetAdminPassword
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidatePattern('^((off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47}))?$')]
    [string] $ActivityProfile = '',

    [ValidateRange(0, 240)]
    [int] $WarmUpMinutes = 0,

    [switch] $WaitForWarmUp,

    [switch] $SkipT3,

    [switch] $SkipT4,

    [switch] $SkipCostCheck,

    [switch] $Interactive,

    [switch] $ResetAdminPassword,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/start-demo.jsonl'),

    [switch] $TreatManualAsError
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
# Preference variables don't reach module functions, so -WhatIf is passed on explicitly.
$whatIf = [bool]$WhatIfPreference
$results = [System.Collections.Generic.List[object]]::new()
$results.AddRange([object[]]@(Start-DemoEnvironment -Config $config -ActivityProfile $ActivityProfile -WarmUpMinutes $WarmUpMinutes -WaitForWarmUp:$WaitForWarmUp -SkipT3:$SkipT3 -SkipT4:$SkipT4 -SkipCostCheck:$SkipCostCheck -Interactive:$Interactive -WhatIf:$whatIf -Confirm:$false))

$keyVaultSection = $config['keyVault']
$useVault = ($keyVaultSection -is [System.Collections.IDictionary]) -and [bool]$keyVaultSection['enabled']
$noFail = @($results | Where-Object { $_.status -eq 'Fail' }).Count -eq 0
if ($ResetAdminPassword -and -not $Interactive) {
    $results.Add((New-DemoResult -CheckId 'START.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Not selected' -Message '-ResetAdminPassword works with -Interactive only, so no password was set.'))
}
elseif ($Interactive -and $ResetAdminPassword -and -not $whatIf -and $noFail -and $useVault) {
    # The opt-in vault replaces the clipboard (ADR 0009). The password is stored before it's set on the VM, so
    # a password nobody can read is never set.
    $hostVm = if ([string]$config['t2Mode'] -eq 'EvaluationOnlyAzureVm') { 'arcsql01' } else { 'archost01' }
    $vaultResults = @(Initialize-DemoKeyVault -Config $config -EnsureOnly -Confirm:$false)
    $results.AddRange([object[]]$vaultResults)
    if (@($vaultResults | Where-Object { $_.status -eq 'Fail' }).Count -eq 0) {
        $expires = ''
        $bastion = @($results | Where-Object { $_.checkId -eq 'START.BASTION' -and $_.status -eq 'Pass' }) | Select-Object -First 1
        if ($bastion -and $bastion.evidence -is [System.Collections.IDictionary]) {
            # Result evidence goes through JSON, which turns an ISO 8601 string into a DateTime.
            $value = $bastion.evidence['expiresUtc']
            $expires = if ($value -is [datetime]) { $value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$value }
            if ($expires -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
                $expires = ''
            }
        }
        $oneTime = New-DemoAdminPassword
        try {
            $stored = Set-DemoHostPasswordSecret -Config $config -VmName $hostVm -Password $oneTime -ExpiresUtc $expires -Confirm:$false
            $results.Add($stored)
            if ($stored.status -eq 'Pass') {
                $applied = Set-DemoVmLocalPassword -Config $config -VmName $hostVm -Password $oneTime -Confirm:$false
                $results.Add($applied)
                if ($applied.status -notin 'Pass', 'Warning') {
                    # The stored password never reached the VM, so nobody should read it.
                    $results.Add((Disable-DemoHostPasswordSecret -Config $config -VmName $hostVm -CheckId 'START.KEYVAULT.CLEANUP' -Confirm:$false))
                }
            }
        }
        finally {
            $oneTime.Dispose()
        }
    }
}
elseif ($Interactive -and $ResetAdminPassword -and -not $whatIf -and $noFail) {
    $hostVm = if ([string]$config['t2Mode'] -eq 'EvaluationOnlyAzureVm') { 'arcsql01' } else { 'archost01' }
    $portalSteps = 'In the Azure portal, open {0}, then Help, then Reset password, and set a password you''ll use once; stop-demo.ps1 rotates it afterward.' -f $hostVm
    # The clipboard is checked before anything changes: the password is never displayed, so without a
    # clipboard there'd be no way to hand it over.
    $clipboard = $false
    if (Get-Command -Name 'Set-Clipboard' -ErrorAction SilentlyContinue) {
        try {
            Set-Clipboard -Value ' '
            $clipboard = $true
        }
        catch {
            $clipboard = $false
        }
    }
    if (-not $clipboard) {
        $results.Add((New-DemoResult -CheckId 'START.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'This session has no working clipboard, so no one-time password was set: it''s never displayed.' -Remediation $portalSteps -DocUrl 'https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp'))
        # The person may now set a password in the portal: the state records the handover, so stop-demo.ps1 rotates it
        # (Phase 28, ADR 0009).
        try {
            Set-DemoDeploymentState -Config $config -Value @{ HostPasswordSet = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The handover wasn''t recorded, so after you reset the password in the portal, reset it again to a random value you don''t keep: {0}' -f $_.Exception.Message)
        }
    }
    else {
        $password = New-DemoAdminPassword
        try {
            $set = Set-DemoVmLocalPassword -Config $config -VmName $hostVm -Password $password -Confirm:$false
            $results.Add($set)
            if ($set.status -in 'Pass', 'Warning') {
                try {
                    Set-Clipboard -Value ([System.Net.NetworkCredential]::new('', $password).Password)
                    Write-DemoLog -Message ('The one-time password for {0} on {1} is on your clipboard. It isn''t shown or stored; stop-demo.ps1 rotates it.' -f $set.evidence['userName'], $hostVm)
                }
                catch {
                    $results.Add((New-DemoResult -CheckId 'START.CLIPBOARD' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'The one-time password was set but couldn''t be copied to the clipboard, and it''s never displayed.' -Remediation $portalSteps))
                }
            }
        }
        finally {
            $password.Dispose()
        }
    }
}

Write-DemoResultReport -Result $results.ToArray() -Title 'start-demo.ps1'
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray() -TreatManualAsError:$TreatManualAsError)
