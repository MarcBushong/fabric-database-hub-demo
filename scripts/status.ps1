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

-Watch (Phase 28) shows deploy.ps1's live status instead, from its progress model out/deploy-progress.json: the
banner (Deploying, no action needed; Waiting for you, with the steps, the portal link, and the time left; Done; or
Stopped, not done, with the command to run) and every track's steps, drawn again every few seconds until the run ends.
It reads only that local file, so it works in a second terminal anywhere, GitHub Codespaces included. Without a model
on this machine (deploy.ps1 runs elsewhere, or hasn't started), it reads Azure as above, once.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Detail
Also read the full health and T2's activity profile.

.PARAMETER Watch
Show deploy.ps1's live status from out/deploy-progress.json, refreshed every -IntervalSeconds, until the run ends.

.PARAMETER IntervalSeconds
How often -Watch refreshes (default 5).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/status.ps1 -Detail

.EXAMPLE
./scripts/status.ps1 -Watch
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $Detail,

    [switch] $Watch,

    [ValidateRange(2, 60)]
    [int] $IntervalSeconds = 5,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/status.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

if ($Watch) {
    $kind = Show-DemoDeploymentProgress -Path (Join-Path -Path (Split-Path -Path ([System.IO.Path]::GetFullPath($OutputPath)) -Parent) -ChildPath 'deploy-progress.json') -Watch -IntervalSeconds $IntervalSeconds
    if ($kind -ne 'None') {
        exit $(if ($kind -eq 'Stopped') { 2 } else { 0 })
    }
    Write-DemoLog -Message 'There''s no deploy.ps1 progress on this machine (out/deploy-progress.json): deploy.ps1 runs elsewhere or hasn''t started. Here''s what Azure says instead.'
}
$config = Get-DemoConfig -Path $ConfigPath
$results = @(Get-DemoEnvironmentStatus -Config $config -Detail:$Detail)

Write-DemoResultReport -Result $results -Title 'status.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
