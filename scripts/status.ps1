#Requires -Version 7.4
<#
.SYNOPSIS
Shows the demo's status (plan section 9.6). Read-only.

.DESCRIPTION
Health per target (power state and bootstrap health), T1's SQL Server instances in unified inventory and
its monitoring, T3's state, the active activity profile on T1 and T3 (read from T1, so T3 isn't woken),
Arc's connection and days disconnected, on-demand Bastion and its public IP with their hourly list price
(a Warning while either exists, including a public IP left over after an interrupted delete),
month-to-date cost against the monthly ceiling, the next auto-shutdown, and the expiry tag. -Detail also
reads the full health (the guest's evaluation days left, the workload runner) and T2's activity profile,
which takes a Run Command per item.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Detail
Also read the full health and T2's activity profile.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/status.ps1 -Detail
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $Detail,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/status.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Get-DemoEnvironmentStatus -Config $config -Detail:$Detail)

Write-DemoResultReport -Result $results -Title 'status.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
