#Requires -Version 7.4
<#
.SYNOPSIS
Writes your demo configuration (config/demo.config.json) from your Azure CLI sign-in, so the first run needs no IDs
looked up by hand (Phase 26b, ADR 0023).

.DESCRIPTION
deploy.ps1 runs it for you when there's no configuration yet (Phase 28), so 'az login' then ./scripts/deploy.ps1 is
enough. Run it yourself to choose the options below, or to write a second configuration. Run it once after 'az login',
before preflight.ps1:

  az login                                   # you sign in; add --use-device-code in a codespace
  ./scripts/init.ps1 -CreateAdminGroup       # asks only when there's a real choice
  ./scripts/preflight.ps1
  ./scripts/deploy.ps1

What it does, in order:
1. Reads the subscriptions in your Azure CLI profile ('az account list', local and read-only: the one Azure CLI call
   before the subscription guard). It asks which one when there's more than one, and never changes your default
   subscription or signs you in.
2. Runs the subscription guard for that subscription, then reads, through it: you (Microsoft Graph), your permissions
   on the subscription (P1), the Fabric capacities you can assign (it asks when there's more than one), and whether
   the Fabric workspace "Database Hub Demo" exists. A new workspace gets fabric.importNotebooks true, and deploy.ps1
   creates it with its lakehouse.
3. Finds the Microsoft Entra security group for T3's and T4's administrators (P6) by name, by default
   <prefix>-<environment>-sql-admins. With -CreateAdminGroup it creates it with you as the owner when it's missing; a
   tenant that doesn't allow that gets Manual action required with the steps for an administrator.
4. Sets how T2 gets SQL Server without asking (2026-11-09, so a first deployment never needs anyone to sign in to a VM):
   -T2SqlInstallMode when you give it, otherwise JumpstartImage (the default: Arc Jumpstart's prebuilt SQL Server 2022
   Standard guest; no stop, and Hub Performance on T2), and one line says which and how to choose another on purpose:
   Developer (no stop; T2 in Hub's Estate only). PaygWizard, which needs a person at SQL Server's setup wizard, is retired
   from the one-click deployment: deploy.ps1 runs a configuration's PaygWizard as JumpstartImage.
5. Writes the configuration, validated against config/environment.schema.json. Git ignores the file, and it holds no
   secrets. An existing file is replaced only with -Force, after a copy to out/config-backup. -WhatIf writes nothing
   and creates no group.
6. Prints the exact next steps.

fabric.manageCapacity stays false unless -ManageCapacity: then start-demo.ps1 resumes a paused capacity and
stop-demo.ps1 pauses only what it resumed. Use it only for a capacity that's yours alone.

.PARAMETER ConfigPath
Where to write the configuration (default: config/demo.config.json). A path Git would commit is refused.

.PARAMETER SubscriptionId
Use this subscription from your Azure CLI profile instead of asking.

.PARAMETER TenantId
Only consider subscriptions in this tenant.

.PARAMETER Location
The Azure region (default westus3). Preflight checks that Database Hub supports it.

.PARAMETER Prefix
The resource name prefix (default dbhub).

.PARAMETER T2SqlInstallMode
JumpstartImage or Developer, to choose T2's mode on purpose; without it, JumpstartImage, the default, with no question
(2026-11-09). ProductKey is set in the configuration file (prerequisite P10).

.PARAMETER WorkspaceName
The Fabric workspace's name (default "Database Hub Demo"). deploy.ps1 creates it when it's missing.

.PARAMETER LakehouseName
The lakehouse's name (default LH_DatabaseHub).

.PARAMETER CapacityName
The Fabric capacity for a new workspace; without it, the one you can assign, or init.ps1 asks.

.PARAMETER AdminGroupName
The P6 group's display name (default <prefix>-<environment>-sql-admins).

.PARAMETER AdminGroupObjectId
Use this P6 group.

.PARAMETER CreateAdminGroup
Create the P6 group, owned by you, when none has its name.

.PARAMETER OwnerEmail
The budget alerts' address, when Microsoft Graph returns none for you.

.PARAMETER TimeZone
The Windows time zone ID for the VMs' daily auto-shutdown, for example 'Eastern Standard Time' (default: this
machine's).

.PARAMETER ManageCapacity
Write fabric.manageCapacity true (a capacity that's yours alone).

.PARAMETER Force
Replace an existing configuration, after a copy to out/config-backup.

.PARAMETER NonInteractive
Never ask; an ambiguous choice is Manual action required.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/init.ps1 -CreateAdminGroup

.EXAMPLE
./scripts/init.ps1 -WhatIf

.EXAMPLE
./scripts/init.ps1 -ConfigPath ./config/test.local.json -WorkspaceName 'Database Hub Demo test' -NonInteractive -SubscriptionId <id>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [string] $SubscriptionId = '',

    [string] $TenantId = '',

    [string] $Location = '',

    [string] $Prefix = '',

    [ValidateSet('', 'JumpstartImage', 'Developer')]
    [string] $T2SqlInstallMode = '',

    [string] $WorkspaceName = '',

    [string] $LakehouseName = '',

    [string] $CapacityName = '',

    [string] $AdminGroupName = '',

    [string] $AdminGroupObjectId = '',

    [switch] $CreateAdminGroup,

    [string] $OwnerEmail = '',

    [string] $TimeZone = '',

    [switch] $ManageCapacity,

    [switch] $Force,

    [switch] $NonInteractive,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/init.jsonl')
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

$parameters = @{
    Path               = $ConfigPath
    SubscriptionId     = $SubscriptionId
    TenantId           = $TenantId
    Location           = $Location
    Prefix             = $Prefix
    T2SqlInstallMode   = $T2SqlInstallMode
    WorkspaceName      = $WorkspaceName
    LakehouseName      = $LakehouseName
    CapacityName       = $CapacityName
    AdminGroupName     = $AdminGroupName
    AdminGroupObjectId = $AdminGroupObjectId
    CreateAdminGroup   = $CreateAdminGroup
    OwnerEmail         = $OwnerEmail
    TimeZone           = $TimeZone
    ManageCapacity     = $ManageCapacity
    Force              = $Force
    NonInteractive     = $NonInteractive
    WhatIf             = [bool]$WhatIfPreference
    Confirm            = $false
}
$init = Initialize-DemoConfig @parameters
$results = @($init.Results)

Write-DemoResultReport -Result $results -Title 'init.ps1'
Export-DemoResult -Result $results -Path $OutputPath
if (@($init.NextSteps).Count -gt 0) {
    Write-Information -MessageData ("`nNext steps:") -InformationAction Continue
    $step = 0
    foreach ($line in $init.NextSteps) {
        $step++
        Write-Information -MessageData ('  {0}. {1}' -f $step, $line) -InformationAction Continue
    }
}
exit (Get-DemoExitCode -Result $results)
