<#
.SYNOPSIS
Phase 7 hook: stores the SQL Server product key for ProductKey mode on the T2 host (ADR 0006, ADR 0009).

.DESCRIPTION
The orchestrator runs this script in a managed Run Command on archost01, with the key in protectedParameters
only (prerequisite P10). It stores the key with DPAPI (LocalMachine scope) in
C:\ProgramData\DbHubDemo\protected\sql-product-key.bin, readable only by SYSTEM and Administrators, and
starts the bootstrap task so the waiting install step continues. It never echoes the key. The install step
passes the key to SQL Server setup once and deletes the file after setup succeeds.
Run Command passes the key to this script as an argument, so the Windows PowerShell log's opening events hold
it: the script stops its session's further engine and provider events (Disable-DemoSessionEventLog), and after
use clears that log if it holds the key (Clear-DemoProtectedValueLog, ADR 0009, Phase 26f), writing only
'DBHUBDEMO-LOG found=<n> cleared=<True|False> error=<type>'. The orchestrator inserts both functions from
vm/bootstrap/ProtectedValueLog.ps1 right after the param block (Add-DemoProtectedValueLogHelper).
Windows PowerShell 5.1.

.PARAMETER ProductKey
The SQL Server product key (five groups of five characters). Protected parameter.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.
#>
[CmdletBinding()]
param(
    [string] $ProductKey = '',

    [string] $Root = 'C:\ProgramData\DbHubDemo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Disable-DemoSessionEventLog
$exitCode = 1

try {
    $key = $ProductKey.Trim().ToUpperInvariant()
    if ($key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
        throw 'ProductKey must be five groups of five letters or digits.'
    }
    $folder = Join-Path -Path $Root -ChildPath 'protected'
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $path = Join-Path -Path $folder -ChildPath 'sql-product-key.bin'
    Add-Type -AssemblyName 'System.Security'
    $protected = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($key), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes($path, $protected)
    # icacls can write to stderr even when it succeeds; with 'Stop', Windows PowerShell 5.1 would end the script on
    # that line, so the exit code decides.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /C /Q 2>&1 | ForEach-Object { [string]$_ })
        $icaclsExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($icaclsExitCode -ne 0) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw ('icacls failed with exit code {0}: {1}' -f $icaclsExitCode, ($output -join ' '))
    }
    Start-ScheduledTask -TaskName 'DbHubDemo-Bootstrap' -ErrorAction SilentlyContinue
    Write-Output 'The product key is stored for the T2 install step.'
    $exitCode = 0
}
catch {
    [Console]::Error.WriteLine(('Storing the product key failed: {0}' -f ($_.Exception.Message -replace '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b', '[REDACTED:product-key]')))
}
finally {
    $log = Clear-DemoProtectedValueLog -Value $ProductKey
    Write-Output ('DBHUBDEMO-LOG found={0} cleared={1} error={2}' -f $log.found, $log.cleared, $log.error)
}
exit $exitCode
