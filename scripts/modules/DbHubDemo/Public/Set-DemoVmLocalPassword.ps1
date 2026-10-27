function Set-DemoVmLocalPassword {
    <#
    .SYNOPSIS
    Sets the password of a demo VM's administrator account through a managed Run Command, with the password
    only as a protected parameter (ADR 0009).

    .DESCRIPTION
    For the T2 setup-wizard step over Bastion: start-demo.ps1 -Interactive -ResetAdminPassword sets a
    one-time password and copies it to the operator's clipboard without displaying it, or, with the Key
    Vault opt-in (keyVault.enabled), stores it in the vault first (Set-DemoHostPasswordSecret); stop-demo.ps1
    rotates it to a value nobody keeps (-Rotate). The account is the VM's osProfile.adminUsername; a VM attached
    from a golden OS disk has no osProfile (ADR 0018), so the VM then picks its built-in administrator, the
    local account whose SID ends in -500, which is the account Azure names at creation. The VM runs
    Set-LocalUser, so no VMAccess extension is involved. The password travels Base64-encoded in one protected
    parameter, because Run Command passes parameters as '-Name value' arguments that allow only some symbols
    (Base64 uses only allowed ones and, for a printable password, starts with a letter); it's never logged or
    returned. A value shorter than 12 characters or that reads like a type name (what a SecureString becomes
    when it's bound to a string) is refused before the Run Command. Run Command needs the VM running: a
    rotation on a deallocated VM reports Manual action required with the steps (a Fail would hide that the
    one-time password is still valid until the next start), and a new password reports Fail.

    Source: Set-LocalUser, https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/set-localuser
    (checked 2026-10-20).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The VM; archost01 by default.

    .PARAMETER Password
    The new password. Without it, -Rotate is required.

    .PARAMETER Rotate
    Set a new random password that's discarded at once.

    .EXAMPLE
    Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Password')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName = 'archost01',

        [Parameter(Mandatory, ParameterSetName = 'Password')]
        [securestring] $Password,

        [Parameter(Mandatory, ParameterSetName = 'Rotate')]
        [switch] $Rotate
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $checkId = if ($Rotate) { 'STOP.HOSTPASSWORD' } else { 'START.HOSTPASSWORD' }
    $target = if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' }
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $power = Get-DemoVmPowerState -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName
    if ($power -ne 'PowerState/running') {
        $powerText = if ($power) { $power.Split('/')[1] } else { 'not found' }
        if ($Rotate) {
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Manual action required' -Message ('The one-time password on {0} wasn''t rotated: the VM is {1}, and Run Command needs it running.' -f $VmName, $powerText) -Remediation ('Start it and rotate the password: ./scripts/start-demo.ps1 (it rotates a leftover one-time password), then ./scripts/stop-demo.ps1. Or, in the Azure portal, open {0}, then Help, then Reset password, and set a random value you don''t keep.' -f $VmName) -Evidence ([ordered]@{ vmName = $VmName; powerState = $power }) -DocUrl $docUrl)
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('No one-time password was set: {0} is {1}, and Run Command needs it running.' -f $VmName, $powerText) -Remediation 'Start the VM (./scripts/start-demo.ps1), then run start-demo.ps1 -Interactive -ResetAdminPassword again.' -Evidence ([ordered]@{ vmName = $VmName; powerState = $power }) -DocUrl $docUrl)
    }
    $user = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', $VmName, '--query', 'osProfile.adminUsername', '--output', 'tsv') -AllowFailure
    $userName = ([string]$user.StdOut).Trim()
    # Empty: the VM has no osProfile (attached from a golden disk), so the VM picks its built-in administrator.
    if ($user.ExitCode -ne 0 -or ($userName -and $userName -notmatch '^[A-Za-z0-9._-]{1,20}$')) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The administrator account of {0} couldn''t be read.' -f $VmName) -DocUrl $docUrl)
    }
    $accountText = if ($userName) { $userName } else { 'the built-in administrator' }
    if (-not $PSCmdlet.ShouldProcess($VmName, ('{0} the password of {1}' -f $(if ($Rotate) { 'Rotate' } else { 'Set' }), $accountText))) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Not selected' -Message ('What if: the password of {0} on {1} wasn''t changed.' -f $accountText, $VmName))
    }
    $secret = if ($Rotate) { New-DemoAdminPassword } else { $Password }
    $script = @'
param([string] $UserName = '', [string] $PasswordBase64)
$ErrorActionPreference = 'Stop'
Disable-DemoSessionEventLog
try {
    if (-not $UserName) {
        $UserName = (Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1).Name
    }
    $plain = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PasswordBase64))
    Set-LocalUser -Name $UserName -Password (ConvertTo-SecureString -String $plain -AsPlainText -Force)
    $plain = $null
    'DBHUBDEMO-PASSWORD set for ' + $UserName
}
finally {
    # Run Command passed the value as an argument, so the Windows PowerShell log may hold it (ADR 0009, Phase 26f).
    $log = Clear-DemoProtectedValueLog -Value $PasswordBase64
    'DBHUBDEMO-LOG found={0} cleared={1} error={2}' -f $log.found, $log.cleared, $log.error
}
'@
    $script = Add-DemoProtectedValueLogHelper -ScriptText $script
    $run = $null
    try {
        $plainText = [System.Net.NetworkCredential]::new('', $secret).Password
        # A SecureString bound to a [string] parameter becomes its type name; never set that.
        if ($plainText.Length -lt 12 -or $plainText -match '^System\.[A-Za-z.]+$') {
            throw 'the password was refused before the Run Command: it''s shorter than 12 characters or a type name, which means a conversion went wrong.'
        }
        Register-DemoSecret -Value $plainText
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plainText))
        $plainText = $null
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName $VmName -RunCommandName 'DbHubDemo-HostPassword' -Script $script -Parameter @{ UserName = $userName } -ProtectedParameter @{ PasswordBase64 = $encoded } -TimeoutSeconds 300 -Confirm:$false
        $encoded = $null
    }
    catch {
        $run = [pscustomobject]@{ Succeeded = $false; Output = ''; Error = $_.Exception.Message }
    }
    finally {
        if ($Rotate) {
            $secret.Dispose()
        }
    }
    # Run Command hands protected parameters to the script as arguments, so the VM's Windows PowerShell log
    # records the encoded password; the script clears that log when it holds it, even when the change failed
    # (ADR 0009, Phase 26f).
    $log = Get-DemoProtectedValueLogResult -Output $(if ($null -ne $run) { [string]$run.Output } else { '' })
    $evidence = [ordered]@{ vmName = $VmName; userName = $accountText; powerShellLog = [ordered]@{ found = $log.Found; cleared = $log.Cleared } }
    $logCommand = 'On {0}, in an elevated prompt: wevtutil clear-log "Windows PowerShell"' -f $VmName
    if ($null -eq $run -or -not $run.Succeeded -or [string]$run.Output -notmatch 'DBHUBDEMO-PASSWORD set') {
        $detail = if ($null -ne $run) { (Protect-DemoText -Text ([string]$run.Error)).Trim() } else { '' }
        $logNote = ''
        $remediation = 'Reset it in the portal (the VM, then Help, then Reset password), or run the script again.'
        if ($log.Cleared) {
            $logNote = ' The Windows PowerShell log there recorded the password and was cleared, which endpoint protection may report.'
        }
        elseif ($log.Found -gt 0) {
            $logNote = ' The Windows PowerShell log there recorded the password, and it couldn''t be cleared.'
            $remediation = '{0} {1}' -f $remediation, $logCommand
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The password of {0} on {1} wasn''t changed: {2}{3}' -f $accountText, $VmName, $detail, $logNote) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    try {
        Set-DemoDeploymentState -Config $Config -Value @{ HostPasswordSet = $(if ($Rotate) { '' } else { [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }) } -Confirm:$false
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The password change wasn''t recorded on the resource group: {0}' -f $_.Exception.Message)
    }
    $message = if ($Rotate) { 'The password of {0} on {1} was rotated to a value nobody keeps.' } else { 'The one-time password of {0} on {1} is set.' }
    $message = $message -f $accountText, $VmName
    if ($log.Found -gt 0 -and -not $log.Cleared) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Manual action required' -Message ('{0} The Windows PowerShell log on {1} recorded the password, and it couldn''t be cleared ({2}).' -f $message, $VmName, $log.Error) -Evidence $evidence -Remediation $logCommand -DocUrl $docUrl)
    }
    if ($log.Cleared) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Warning' -Message ('{0} Run Command handed the password to the VM''s PowerShell as an argument, so the Windows PowerShell log recorded it; that log was cleared, which endpoint protection may report.' -f $message) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl)
}
