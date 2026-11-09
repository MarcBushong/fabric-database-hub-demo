#Requires -Version 7.4
<#
.SYNOPSIS
Assigns the nightly safety stop's one role (ADR 0024), for an Owner, once per deployment when deploy.ps1 couldn't.

.DESCRIPTION
Every deployment has a nightly safety stop: at the VMs' auto-shutdown time it deallocates the demo's VMs, stops T4 (a
stopped PostgreSQL flexible server starts itself again after 7 days), and later checks that T3 paused, without waking
it, and stops T4 again if it runs. Its runbook acts with the identity id-<prefix>-<environment>-safetystop, which needs
the custom role "DbHub Demo Safety Stop" (read and stop only) at the demo resource group. deploy.ps1 assigns it when the
person who runs it may; when not, it ends DONE with a Warning that names this command.

This script, run by an Owner (or a User Access Administrator; a Role Based Access Control Administrator once the role
exists):
1. creates or updates the custom role with exactly its seven approved actions, assignable in the configured subscription
   only, when it's missing or differs;
2. assigns it to the safety stop's identity at rg-<prefix>-<environment> only; the result names the identity's object ID.

It needs the identity, which deploy.ps1 creates. A redeploy after destroy.ps1 makes a new identity, so the role is
assigned again then: by deploy.ps1 when you may, otherwise with this script. -WhatIf changes nothing and lists what it
would do. It never signs in or changes the Azure CLI context: sign in first with 'az login --tenant <tenantId>'.

.PARAMETER ConfigPath
Path to the demo configuration (config/demo.config.json).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/grant-safety-stop.ps1 -WhatIf

.EXAMPLE
./scripts/grant-safety-stop.ps1 -ConfigPath ./config/demo.config.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/grant-safety-stop.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This checkout's DbHubDemo, loaded again on every run, so a session that ran an earlier checkout's script doesn't keep
# that code (live finding, 2026-11-06). Not when the repository's own code runs this script (a DbHubDemo function,
# another script, or a test): it loaded the module already, and the module's state stays, such as the subscription
# guard's validated context, the redaction's registered values, or a test's mocks.
$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested)
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Invoke-DemoSafetyStopSetup -Config $config -ConfigPath $ConfigPath -GrantRole -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)

Write-DemoResultReport -Result $results -Title 'grant-safety-stop.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
