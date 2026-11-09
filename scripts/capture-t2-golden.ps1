#Requires -Version 7.4
<#
.SYNOPSIS
Captures the finished T2 host as a golden snapshot, so a redeploy restores T2 with its setup-wizard state
instead of building it again (ADR 0018).

.DESCRIPTION
Runs New-DemoT2GoldenSnapshot: the subscription guard; the host and the policy checks; then it starts
archost01 if needed, checks the host is Ready with SQL Server Standard and the guest connected to Arc,
turns T2's activity off, rotates the host administrator's password, removes the sign-in data left on the
host and in the guest and verifies that none remains (ADR 0009), with -WipeFreeSpace overwrites the guest's
free space with zeros, air-gaps the guest (no automatic start, network adapter disconnected), shuts it down,
with -WipeFreeSpace compacts its disk and overwrites the host's free space with zeros, deallocates the host,
and creates an incremental snapshot of archost01-osdisk with network access DenyAll in rg-<prefix>-golden.
A disk created from the snapshot proves it's usable.

- The guest's Windows evaluation keeps counting inside the snapshot: the snapshot is tagged with its end,
  and preflight and status.ps1 warn 30 and 7 days before it.
- The source host doesn't stay air-gapped: once its guest is prepared, whatever happens next, the capture starts
  the host if needed, releases the guest (network back, automatic start Start, started), waits until arcsql01
  reads Connected again, and returns the host to the power state it found (GOLDEN.CAPTURE.SOURCE).
- It captures nothing while an on-demand run from the Fabric control is active (GOLDEN.CAPTURE.CONTROL), and
  a start of T2 from the Fabric control leaves the guest alone while the capture runs.
- Prove the snapshot boots before you rely on it: ./scripts/test-t2-golden.ps1 -Onboard.
- This PC and its display stay awake until it finishes (Enter-DemoKeepAwake).
- It never signs in or changes the Azure CLI context. Exit code: 0 Pass or Warning, 1 Fail.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER SkipPolicyInventory
Skip the read-only policy inventory; the snapshot's creation still fails on a deny.

.PARAMETER HostReadyMinutes
How long to wait for the started host to report Ready.

.PARAMETER WipeFreeSpace
Overwrite the guest's and the host's free space with zeros and compact the guest's disk before the snapshot,
so nothing deleted survives in free space (about an hour more on the lowest-cost host).

.PARAMETER MinHostFreeGB
With -WipeFreeSpace, the free space the host's C: needs first (default 45 GB).

.PARAMETER Force
Don't ask for confirmation.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/capture-t2-golden.ps1

.EXAMPLE
./scripts/capture-t2-golden.ps1 -WhatIf

.EXAMPLE
./scripts/capture-t2-golden.ps1 -WipeFreeSpace
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $SkipPolicyInventory,

    [ValidateRange(0, 60)]
    [int] $HostReadyMinutes = 20,

    [switch] $WipeFreeSpace,

    [ValidateRange(10, 1000)]
    [int] $MinHostFreeGB = 45,

    [switch] $Force,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/capture-t2-golden.jsonl')
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
$confirm = -not $Force -and $ConfirmPreference -ne 'None'
$null = Enter-DemoKeepAwake
try {
    $results = @(New-DemoT2GoldenSnapshot -Config $config -SkipPolicyInventory:$SkipPolicyInventory -HostReadyMinutes $HostReadyMinutes -WipeFreeSpace:$WipeFreeSpace -MinHostFreeGB $MinHostFreeGB -WhatIf:([bool]$WhatIfPreference) -Confirm:$confirm)
}
finally {
    $null = Exit-DemoKeepAwake
}

Write-DemoResultReport -Result $results -Title 'capture-t2-golden.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
