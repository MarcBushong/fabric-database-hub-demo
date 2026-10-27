#Requires -Version 7.4
<#
.SYNOPSIS
Writes your demo configuration (config/demo.config.json) from your Azure CLI sign-in, so the first run needs no IDs
looked up by hand (Phase 26b, ADR 0023).

.DESCRIPTION
Run it once after 'az login', before preflight.ps1:

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
4. Asks how T2 installs SQL Server: PaygWizard (the default: Hub Performance on T2, after a one-time setup wizard of
   about an hour) or Developer (no wizard; T2 in Hub's Estate only).
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
PaygWizard or Developer; without it, init.ps1 asks (PaygWizard with -NonInteractive).

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

    [ValidateSet('', 'PaygWizard', 'Developer')]
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
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

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
