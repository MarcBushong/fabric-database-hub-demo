#Requires -Version 7.4
<#
.SYNOPSIS
Changes the activity on the demo's targets: a profile or one bounded incident (demo-control.yml and the
live-activity notebook call it; ADR 0010, ADR 0011).

.DESCRIPTION
Takes the inputs demo-control.yml declares, with the names the live-activity notebook dispatches:
target (all, T1, T2, T3, or T4), scenario (baseline, business-day, off, or incident:<scenario>), duration
(1-240 minutes), concurrency (0 or 1-64), intensity (0 or 1-10), reset-before, and auto-cleanup. Each target
gets 'profile set' through Run Command; everything ends before the next auto-shutdown, and the runner clamps
it to the scenario's limits. An incident on 'all' runs on the scenario's default target.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Target
all, T1, T2, T3, or T4 (the PostgreSQL flexible server, when t4Enabled; Phase 24, ADR 0019).

.PARAMETER Scenario
baseline, business-day, off, or incident:<scenario>.

.PARAMETER Duration
Minutes, 1-240.

.PARAMETER Concurrency
0 for the scenario's default, or 1-64.

.PARAMETER Intensity
0 for the scenario's default, or 1-10.

.PARAMETER ResetBefore
'true' or 'false' (workflow inputs are strings).

.PARAMETER AutoCleanup
'true' or 'false'.

.PARAMETER RequestedBy
Who asked (a name, never a secret).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/demo-control.ps1 -Target T1 -Scenario incident:locking-blocking -Duration 15
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('all', 'T1', 'T2', 'T3', 'T4')]
    [string] $Target = 'all',

    [Parameter(Mandatory)]
    [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
    [string] $Scenario,

    [ValidateRange(1, 240)]
    [int] $Duration = 30,

    [ValidateRange(0, 64)]
    [int] $Concurrency = 0,

    [ValidateRange(0, 10)]
    [int] $Intensity = 0,

    [ValidateSet('true', 'false')]
    [string] $ResetBefore = 'false',

    [ValidateSet('true', 'false')]
    [string] $AutoCleanup = 'true',

    [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
    [string] $RequestedBy = 'demo-control',

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/demo-control.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Invoke-DemoControl -Config $config -Target $Target -Scenario $Scenario -DurationMinutes $Duration -Concurrency $Concurrency -Intensity $Intensity -ResetBefore ($ResetBefore -eq 'true') -AutoCleanup ($AutoCleanup -eq 'true') -RequestedBy $RequestedBy -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)

Write-DemoResultReport -Result $results -Title 'demo-control.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
