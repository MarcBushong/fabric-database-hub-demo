#Requires -Version 7.4
<#
.SYNOPSIS
Proves a T2 golden snapshot before anything relies on it: a copy boots in quarantine, its Arc identity is
reset, SQL Server Standard runs, and with -Onboard a fresh onboarding gives pay-as-you-go and monitoring
(ADR 0018, section 6).

.DESCRIPTION
Runs Test-DemoT2GoldenSnapshot in a disposable resource group, rg-<prefix>-gtest by default, never in the
demo's group:
- a disk created from the snapshot must succeed;
- the copy's host subnet denies all outbound traffic before its first boot, and the copy's guest must find no
  Arc endpoint reachable before its agent is reset locally ('azcmagent disconnect --force-local-only');
- SQL Server must run Standard edition, and the host's and the guest's passwords are rotated;
- with -Onboard, the deny rule goes and the copy is onboarded fresh in the test group: Standard, license type
  PAYG, and monitoring must pass;
- the source's Arc machine must be untouched during the test: the same properties, the same last status change
  when it was already Disconnected, and no Administrative operation in its Activity Log (Resource Health and
  other events are listed, but they aren't operations);
- the test group is deleted through the destroy path, with the residual check.
The snapshot is tagged boot-verified, then onboard-verified, and older golden snapshots are deleted once the
newest one passes, unless -KeepOlderSnapshots. This PC and its display stay awake until it finishes. It never signs in or changes the Azure CLI context. Exit code: 0 Pass or Warning, 1 Fail.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER SnapshotName
The golden snapshot to prove; the newest one by default.

.PARAMETER Onboard
After the boot test, onboard the copy fresh in the test group and check PAYG and monitoring.

.PARAMETER TestEnvironment
The test environment's name; the group is rg-<prefix>-<name>.

.PARAMETER KeepOlderSnapshots
Keep older golden snapshots even when this one passes.

.PARAMETER KeepTestGroup
Leave the test group for inspection; delete it later with -CleanupOnly.

.PARAMETER CleanupOnly
Only delete a test group that an interrupted run left behind.

.PARAMETER ArcWaitMinutes
How long the onboarding waits for the Azure extension for SQL Server and the instance resource.

.PARAMETER Force
Don't ask for confirmation.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/test-t2-golden.ps1 -Onboard

.EXAMPLE
./scripts/test-t2-golden.ps1 -CleanupOnly
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [string] $SnapshotName = '',

    [switch] $Onboard,

    [ValidatePattern('^[a-z0-9]{2,8}$')]
    [string] $TestEnvironment = 'gtest',

    [switch] $KeepTestGroup,

    [switch] $KeepOlderSnapshots,

    [switch] $CleanupOnly,

    [ValidateRange(5, 120)]
    [int] $ArcWaitMinutes = 45,

    [switch] $Force,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/test-t2-golden.jsonl')
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
$confirm = -not $Force -and $ConfirmPreference -ne 'None'
$arguments = @{
    Config             = $config
    SnapshotName       = $SnapshotName
    Onboard            = $Onboard
    TestEnvironment    = $TestEnvironment
    KeepTestGroup      = $KeepTestGroup
    KeepOlderSnapshots = $KeepOlderSnapshots
    CleanupOnly        = $CleanupOnly
    ArcWaitMinutes     = $ArcWaitMinutes
    WhatIf             = [bool]$WhatIfPreference
    Confirm            = $confirm
}
$null = Enter-DemoKeepAwake
try {
    $results = @(Test-DemoT2GoldenSnapshot @arguments)
}
finally {
    $null = Exit-DemoKeepAwake
}

Write-DemoResultReport -Result $results -Title 'test-t2-golden.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
