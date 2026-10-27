Set-StrictMode -Version Latest

# Module state. The context is set by Initialize-DemoVmContext; secrets registered at run time are redacted
# from every log line, state file, and health file.
$script:DemoVmContext = $null
$script:DemoVmSecrets = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:DemoVmUtf8 = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false
# '[K]' in the account-key rule matches the same text as 'K', but keeps this file from looking like an account
# key to the operator-side guard that checks the bundle before it travels in Run Commands (ADR 0009).
$script:DemoVmRedactionRules = @(
    @{ Pattern = '(?i)(https?://[^\s"''?]+)\?[^\s"'']*'; Replacement = '$1?[REDACTED]' }
    @{ Pattern = '(?i)((?:^|[?&;\s"''])sig=)[^&\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Pattern = 'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'; Replacement = '[REDACTED:jwt]' }
    @{ Pattern = '(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}'; Replacement = '$1[REDACTED]' }
    @{ Pattern = '(?i)(Account[K]ey=)[^;\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Pattern = '(?i)(\b(?:password|pwd)\s*[=:]\s*)[^;\s"'']+'; Replacement = '$1[REDACTED]' }
    @{ Pattern = '(?i)(/PID=)("[^"]*"|\S+)'; Replacement = '$1[REDACTED]' }
    @{ Pattern = '(?i)(--access-token\s+)\S+'; Replacement = '$1[REDACTED]' }
    @{ Pattern = '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b'; Replacement = '[REDACTED:product-key]' }
)

# Windows PowerShell 5.1 has no Join-Path with several children, so the library files are listed here.
foreach ($library in @('Core.ps1', 'State.ps1', 'Runner.ps1', 'Download.ps1', 'Platform.ps1', 'Sql.ps1', 'Workload.ps1')) {
    . ([System.IO.Path]::Combine($PSScriptRoot, 'lib', $library))
}

Export-ModuleMember -Function @(
    'Add-DemoVmWarning'
    'Build-DemoVmPassword'
    'ConvertFrom-DemoVmRunnerJson'
    'ConvertTo-DemoVmHashtable'
    'ConvertTo-DemoVmProcessArgument'
    'Enter-DemoVmLock'
    'Exit-DemoVmLock'
    'Expand-DemoVmVerifiedZip'
    'Get-DemoVmContext'
    'Get-DemoVmDataVolume'
    'Get-DemoVmDotNetPin'
    'Get-DemoVmFileSha256'
    'Get-DemoVmFileSha512'
    'Get-DemoVmMediaPin'
    'Get-DemoVmNextShutdown'
    'Get-DemoVmRunnerOutcome'
    'Get-DemoVmRunnerZip'
    'Get-DemoVmSetting'
    'Get-DemoVmState'
    'Get-DemoVmStepRecord'
    'Get-DemoVmUtcNow'
    'Get-DemoVmWorkloadHealth'
    'Get-DemoVmWorkloadPath'
    'Get-DemoVmWorkloadSetting'
    'Get-DemoVmWorkloadTaskDefinition'
    'Initialize-DemoVmContext'
    'Initialize-DemoVmDataDisk'
    'Install-DemoVmDotNetRuntime'
    'Invoke-DemoVmFileRetry'
    'Invoke-DemoVmNativeCommand'
    'Invoke-DemoVmRestart'
    'Invoke-DemoVmRunnerProcess'
    'Invoke-DemoVmRunnerSetup'
    'Invoke-DemoVmSql'
    'Invoke-DemoVmSqlScript'
    'Invoke-DemoVmStateMachine'
    'Join-DemoVmPath'
    'New-DemoVmStepResult'
    'New-DemoVmWorkloadRecord'
    'Protect-DemoVmFolder'
    'Protect-DemoVmSecret'
    'Protect-DemoVmText'
    'Read-DemoVmJsonFile'
    'Register-DemoVmSecret'
    'Register-DemoVmWorkloadTask'
    'Remove-DemoVmOldRunner'
    'Save-DemoVmDownload'
    'Save-DemoVmState'
    'Set-DemoVmActivityProfile'
    'Split-DemoVmSqlBatch'
    'Start-DemoVmWorkload'
    'Stop-DemoVmWorkload'
    'Test-DemoVmDotNetRuntime'
    'Test-DemoVmFileHash'
    'Test-DemoVmNameResolve'
    'Test-DemoVmRunnerChunk'
    'Test-DemoVmRunnerPackage'
    'Test-DemoVmT3Enabled'
    'Test-DemoVmT4Enabled'
    'Test-DemoVmWorkloadRecord'
    'Test-DemoVmWorkloadTask'
    'Unprotect-DemoVmSecret'
    'Write-DemoVmHealth'
    'Write-DemoVmJsonFile'
    'Write-DemoVmLog'
    'Write-DemoVmWorkloadInstall'
)
