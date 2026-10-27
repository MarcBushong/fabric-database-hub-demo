function Set-DemoArcSqlProductKey {
    <#
    .SYNOPSIS
    Sends the SQL Server product key for ProductKey mode (prerequisite P10) to the T2 host, only as a
    protected Run Command parameter (ADR 0006, ADR 0009). Returns the T2.SQL.PRODUCTKEY result.

    .DESCRIPTION
    Runs vm/bootstrap/Set-DemoSqlProductKey.ps1 on the host with Invoke-DemoVmRunCommand. The key goes only
    into protectedParameters (written to a private temporary file, never on a command line), is registered
    with Register-DemoSecret so it's redacted everywhere, and is never echoed. On the host the script stores it
    with DPAPI (LocalMachine) for the install step, which waits in WaitingForProductKey until it arrives and
    deletes the file after setup succeeds. The Run Command is deleted afterward. In the evaluation-only mode
    the key goes to the Azure VM arcsql01 instead, labeled EVALUATION ONLY.

    configure-arc.ps1 calls this only while the host reports WaitingForProductKey, so a key isn't left on
    a host that no longer needs it.

    .PARAMETER Config
    Configuration from Get-DemoConfig. t2SqlInstallMode must be ProductKey.

    .PARAMETER ProductKey
    The SQL Server product key, as a SecureString: five groups of five letters or digits.

    .PARAMETER TimeoutSeconds
    The Run Command's script timeout.

    .EXAMPLE
    Set-DemoArcSqlProductKey -Config $config -ProductKey (Read-Host -AsSecureString -Prompt 'SQL Server product key')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [securestring] $ProductKey,

        [ValidateRange(60, 1800)]
        [int] $TimeoutSeconds = 300
    )

    $target = Get-DemoArcTarget -Config $Config
    $docUrl = 'https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt'
    $evidence = [ordered]@{ hostVm = $target.HostVmName; installMode = $target.InstallMode }
    $newResult = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'T2.SQL.PRODUCTKEY' -Area 't2' -Target 'T2' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl -EvaluationOnly:$target.EvaluationOnly
    }

    if ($target.InstallMode -ne 'ProductKey') {
        return (& $newResult 'Not selected' ('t2SqlInstallMode is {0}; only ProductKey mode takes a product key.' -f $target.InstallMode))
    }
    $key = [System.Net.NetworkCredential]::new('', $ProductKey).Password.Trim().ToUpperInvariant()
    Register-DemoSecret -Value $key
    if ($key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
        $key = $null
        return (& $newResult 'Fail' 'The product key must be five groups of five letters or digits, separated by hyphens. It was not sent.' 'Run configure-arc.ps1 -ProductKey again and type the key from your licensing agreement.')
    }

    $script = Add-DemoProtectedValueLogHelper -ScriptText (Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Set-DemoSqlProductKey.ps1') -Raw)
    if (-not $PSCmdlet.ShouldProcess($target.HostVmName, 'Send the SQL Server product key in a protected Run Command')) {
        $key = $null
        return (& $newResult 'Not selected' 'What if: the product key was not sent.')
    }
    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName $target.HostVmName -RunCommandName 'DbHubDemo-SqlProductKey' -Script $script -ProtectedParameter @{ ProductKey = $key } -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    }
    catch {
        return (& $newResult 'Fail' ('The product key Run Command could not run: {0}' -f $_.Exception.Message) 'Run configure-arc.ps1 -ProductKey again.')
    }
    finally {
        $key = $null
    }
    if ($null -eq $run) {
        return (& $newResult 'Not selected' 'What if: the product key was not sent.')
    }
    $evidence['executionState'] = $run.ExecutionState
    $evidence['exitCode'] = $run.ExitCode
    # Run Command hands protected parameters to the script as arguments, so the host's Windows PowerShell log
    # records the key; the script clears that log when it holds the key, even when storing it failed (ADR 0009,
    # Phase 26f).
    $log = Get-DemoProtectedValueLogResult -Output ([string]$run.Output)
    $evidence['powerShellLog'] = [ordered]@{ found = $log.Found; cleared = $log.Cleared }
    $logCommand = 'On {0}, in an elevated prompt: wevtutil clear-log "Windows PowerShell", or ./scripts/check-sign-in-data.ps1 -VmName {0} -Clean.' -f $target.HostVmName
    if (-not $run.Succeeded) {
        $detail = if ($run.Error) { $run.Error } else { $run.Output }
        $logNote = ''
        $remediation = 'Run configure-arc.ps1 -ProductKey again; the key is never stored on the operator side.'
        if ($log.Cleared) {
            $logNote = ' The Windows PowerShell log there recorded the key and was cleared, which endpoint protection may report.'
        }
        elseif ($log.Found -gt 0) {
            $logNote = ' The Windows PowerShell log there recorded the key, and it couldn''t be cleared.'
            $remediation = '{0} {1}' -f $remediation, $logCommand
        }
        return (& $newResult 'Fail' ('Storing the product key on {0} failed: {1}{2}' -f $target.HostVmName, $detail, $logNote) $remediation)
    }
    $stored = 'The product key reached {0} only as a protected Run Command parameter and is stored there with DPAPI for the unattended install, which continues on its own.' -f $target.HostVmName
    if ($log.Found -gt 0 -and -not $log.Cleared) {
        return (& $newResult 'Manual action required' ('{0} The Windows PowerShell log on {1} recorded the key, and it couldn''t be cleared ({2}).' -f $stored, $target.HostVmName, $log.Error) $logCommand)
    }
    if ($log.Cleared) {
        return (& $newResult 'Warning' ('{0} Run Command handed the key to the host''s PowerShell as an argument, so the Windows PowerShell log recorded it; that log was cleared, which endpoint protection may report.' -f $stored))
    }
    return (& $newResult 'Pass' $stored)
}
