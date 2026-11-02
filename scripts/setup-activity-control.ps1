#Requires -Version 7.4
<#
.SYNOPSIS
Sets up the optional on-demand activity control (ADR 0020), grants its roles as an Owner, rotates its webhook, or
removes it.

.DESCRIPTION
The control lets a Fabric notebook start the demo's targets and run bounded scenarios on demand, through an Azure
Automation webhook whose URL lives only in a Key Vault secret, with a one-time auto-stop for every run, Stop now,
and the nightly auto-shutdown behind it. It's off by default (control.enabled); Contributor-only deployers use
./scripts/demo-control.ps1 or the demo-control workflow instead.

Without a switch (Contributor): resolves the vault's network mode from control.vaultNetworkMode and the tenant's
policy, then creates or updates rg-<prefix>-control with the identity, the Automation account, the vault, the
runbooks, the daily T4 safety stop, the webhook and its secret, and the control notebook (in a folder of the existing
workspace when vaults can be public, or in the "DBHub Control" workspace with a managed private endpoint when a
policy makes them private). It never resumes, pauses, or scales the Fabric capacity.

-GrantRole (an Owner, signed in with multifactor authentication, once): the custom role "DbHub Demo Activity
Operator" and its assignments A1-A3, with a confirmation that shows each role, scope, and object ID.

-RotateWebhook: a new webhook and secret version, then the old webhook goes. -Remove: deletes everything the control
created, after a confirmation for each part unless -Force.

-WhatIf changes nothing and lists what each step would do. destroy.ps1 never touches rg-<prefix>-control.

.PARAMETER ConfigPath
Path to the demo configuration (config/demo.config.json).

.PARAMETER GrantRole
Create the custom role and assign A1, A2, and A3 (an Owner).

.PARAMETER RotateWebhook
Replace the webhook and its secret.

.PARAMETER Remove
Remove the control: role assignments, the role, the Fabric items, and the Azure resources.

.PARAMETER Force
With -Remove, don't ask before each part.

.PARAMETER SkipFabric
Leave Fabric alone (for example while the capacity is paused).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/setup-activity-control.ps1 -WhatIf

.EXAMPLE
./scripts/setup-activity-control.ps1 -GrantRole
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Setup')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [Parameter(ParameterSetName = 'Grant', Mandatory)]
    [switch] $GrantRole,

    [Parameter(ParameterSetName = 'Setup')]
    [switch] $RotateWebhook,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch] $Remove,

    [Parameter(ParameterSetName = 'Remove')]
    [switch] $Force,

    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'Remove')]
    [switch] $SkipFabric,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/setup-activity-control.jsonl')
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
$arguments = @{ Config = $config; ConfigPath = $ConfigPath; WhatIf = [bool]$WhatIfPreference }
if ($GrantRole) {
    $arguments['GrantRole'] = $true
}
elseif ($Remove) {
    $arguments['Remove'] = $true
    $arguments['Force'] = [bool]$Force
    $arguments['SkipFabric'] = [bool]$SkipFabric
}
else {
    $arguments['RotateWebhook'] = [bool]$RotateWebhook
    $arguments['SkipFabric'] = [bool]$SkipFabric
}
$results = @(Invoke-DemoActivityControlSetup @arguments)

Write-DemoResultReport -Result $results -Title 'setup-activity-control.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
