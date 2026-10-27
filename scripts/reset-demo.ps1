#Requires -Version 7.4
<#
.SYNOPSIS
Returns the demo databases to a known, quiet state without redeploying (ADR 0010).

.DESCRIPTION
For each target, the workload runner's reset (through Run Command; T1 and T3 from sqlvm01, T2 through
archost01 into the guest): it stops every scenario and profile, waits, kills leftover ContosoCare.Demo/
sessions, verifies that no demo transaction is open, empties the scratch tables, and sets the activity
profile to off unless -KeepProfile. -Reseed restores the seed data; -UndoRemediation drops the
missing-index remediation, so that scenario starts again from 'before'. It acts only inside ContosoCare.

Resetting T3 connects to it, which resumes a paused serverless database; with its profile off it pauses
again t3AutoPauseMinutes later. -RebuildGuest reports Not supported for now (destroy.ps1 then deploy.ps1
rebuilds everything).

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Target
all (default), T1, T2, T3, or T4.

.PARAMETER Reseed
Reseed the business data with the recorded seed and scale.

.PARAMETER UndoRemediation
Drop the missing-index remediation indexes.

.PARAMETER KeepProfile
Keep the activity profile; by default it's set to off.

.PARAMETER RebuildGuest
Rebuild the T2 guest (not supported yet).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/reset-demo.ps1

.EXAMPLE
./scripts/reset-demo.ps1 -Target T1 -UndoRemediation
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('all', 'T1', 'T2', 'T3', 'T4')]
    [string] $Target = 'all',

    [switch] $Reseed,

    [switch] $UndoRemediation,

    [switch] $KeepProfile,

    [switch] $RebuildGuest,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/reset-demo.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
$results = @(Reset-DemoWorkload -Config $config -Target $Target -Reseed:$Reseed -UndoRemediation:$UndoRemediation -KeepProfile:$KeepProfile -RebuildGuest:$RebuildGuest -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)

Write-DemoResultReport -Result $results -Title 'reset-demo.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
