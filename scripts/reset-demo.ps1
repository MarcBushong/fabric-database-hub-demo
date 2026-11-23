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
again t3AutoPauseMinutes later.

-RebuildGuest (2026-11-21) makes the T2 guest arcsql01 again from Arc Jumpstart's image, and does nothing else: it asks
archost01 for the rebuild (RESET.GUEST: only while archost01 runs, in JumpstartImage mode, the default, and while no
golden capture holds the guest), then runs ./scripts/deploy.ps1 -FromStage Artifacts, which deletes the guest with its disk
and records, makes a new one (about 27 minutes), onboards it to Azure Arc (about 33), sets its database and activity up,
and ends DONE or NOT DONE. Its exit code is deploy.ps1's. To start everything over instead: ./scripts/destroy.ps1
-KeepFabric, then ./scripts/deploy.ps1, which keeps the Fabric workspaces with their history.

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Target
all (default), T1, T2, T3, T4, or T5 (T5, the Cosmos DB account: its runs stop and its profile goes off; there's no
data to reseed or remediation to undo there).

.PARAMETER Reseed
Reseed the business data with the recorded seed and scale.

.PARAMETER UndoRemediation
Drop the missing-index remediation indexes.

.PARAMETER KeepProfile
Keep the activity profile; by default it's set to off.

.PARAMETER RebuildGuest
Make the T2 guest again from Arc Jumpstart's image, then run deploy.ps1 -FromStage Artifacts (above); the other switches
don't apply.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/reset-demo.ps1

.EXAMPLE
./scripts/reset-demo.ps1 -Target T1 -UndoRemediation

.EXAMPLE
./scripts/reset-demo.ps1 -RebuildGuest
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('all', 'T1', 'T2', 'T3', 'T4', 'T5')]
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
$results = @(Reset-DemoWorkload -Config $config -Target $Target -Reseed:$Reseed -UndoRemediation:$UndoRemediation -KeepProfile:$KeepProfile -RebuildGuest:$RebuildGuest -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)

Write-DemoResultReport -Result $results -Title 'reset-demo.ps1'
Export-DemoResult -Result $results -Path $OutputPath
# -RebuildGuest (2026-11-21): once archost01 has the request, deploy.ps1 does the rebuild and finishes T2, in this command.
$rebuild = @($results | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'RESET.GUEST' }) | Select-Object -First 1
if ($RebuildGuest -and -not $WhatIfPreference -and $null -ne $rebuild -and [string]$rebuild.status -eq 'Pass') {
    Write-DemoLog -Message 'reset-demo.ps1: archost01 has the request; ./scripts/deploy.ps1 -FromStage Artifacts now makes T2''s guest again and finishes T2.'
    exit (Invoke-DemoDeployScript -ConfigPath $ConfigPath -FromStage Artifacts)
}
exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
