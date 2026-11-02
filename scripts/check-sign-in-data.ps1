#Requires -Version 7.4
<#
.SYNOPSIS
Checks the demo's VMs and the T2 guest for sign-in data left behind, and with -Clean removes it and checks
again (ADR 0009). It prints counts and locations only, never a value.

.DESCRIPTION
Runs Find-DemoSignInData: the subscription guard, then for each running VM (sqlvm01, and archost01 with its
guest arcsql01) a managed Run Command that takes no secret and is deleted afterward. Without -Clean, nothing
on the VMs changes. With -Clean, token-shaped values in files are replaced with [REDACTED], the browser
sign-in caches in the guest are deleted, and a PowerShell or Application event log is cleared only when it holds
a token-shaped value (a Warning, because endpoint protection may report a cleared log); the Security log only
with -ClearSecurityLog, and otherwise the result is Manual action required with the command. Then the VMs are
checked again.

The deployment runs the same cleanup on its own after each interactive sign-in and Arc onboarding, and the
golden snapshot is captured only after it passes; this script is for an audit, or to clean up by hand.
It never signs in or changes the Azure CLI context. Exit code: 0 Pass, Warning, or Manual action required; 1 Fail.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER VmName
The VMs to check; by default sqlvm01 and the T2 VM.

.PARAMETER Clean
Remove what's found, then check again.

.PARAMETER ClearSecurityLog
With -Clean, also clear the Security log when it holds a token-shaped value.

.PARAMETER Force
Don't ask for confirmation before -Clean.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/check-sign-in-data.ps1

.EXAMPLE
./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [ValidateSet('sqlvm01', 'archost01', 'arcsql01')]
    [string[]] $VmName = @(),

    [switch] $Clean,

    [switch] $ClearSecurityLog,

    [switch] $Force,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/check-sign-in-data.jsonl')
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
# A check changes nothing on the VMs, so it never asks; a cleanup asks unless -Force.
$confirm = $Clean -and -not $Force -and $ConfirmPreference -ne 'None'
$results = @(Find-DemoSignInData -Config $config -VmName $VmName -Clean:$Clean -ClearSecurityLog:$ClearSecurityLog -WhatIf:([bool]$WhatIfPreference) -Confirm:$confirm)

Write-DemoResultReport -Result $results -Title 'check-sign-in-data.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
