#Requires -Version 7.4
<#
.SYNOPSIS
Makes a redacted zip of what deploy.ps1 and the other scripts left in out/, to attach to a Deployment problem issue
(Phase 28). Local and read-only: it calls nothing in Azure.

.DESCRIPTION
It collects the newest results (out/*.jsonl), the status page's model (out/deploy-progress.json), deploy.ps1's console
transcripts (out/logs/*.log), and the VM instance views the Run Command watchdog saved (out/diagnostics/*.json). It
redacts each file again (secrets, every GUID, the T3 and T4 servers' random suffix, email addresses, your home folder,
and your configuration's owner and account names), scans the redacted copy for anything that still looks secret, and
writes the zip only when the scan finds nothing (Export-DemoDiagnosticBundle). Look through the zip before you attach
it; never attach your configuration file.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json). Optional: its owner, ownerEmail, and azureAccount values are
masked too when it's there.

.PARAMETER Path
The zip to write (default: out/diagnostics-<UTC time>.zip).

.PARAMETER OutputPath
Where to write the result as JSON lines.

.EXAMPLE
./scripts/collect-diagnostics.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [string] $Path = '',

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/collect-diagnostics.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$mask = @()
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $config = Get-DemoConfig -Path $ConfigPath
        $mask = @(foreach ($key in 'owner', 'ownerEmail', 'azureAccount') {
                if ($config.Contains($key) -and $config[$key]) {
                    [string]$config[$key]
                }
            })
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The configuration couldn''t be read, so only the standard redaction applies: {0}' -f $_.Exception.Message)
    }
}
$directory = Split-Path -Path ([System.IO.Path]::GetFullPath($OutputPath)) -Parent
$arguments = @{ Directory = $directory; Mask = $mask; WhatIf = [bool]$WhatIfPreference; Confirm = $false }
if ($Path) {
    $arguments['Path'] = $Path
}
$results = @(Export-DemoDiagnosticBundle @arguments)

Write-DemoResultReport -Result $results -Title 'collect-diagnostics.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
