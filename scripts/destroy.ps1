#Requires -Version 7.4
<#
.SYNOPSIS
Deletes the demo: the Arc resources first, then the resource group and everything in it, then the
subscription deployment record, and checks that nothing is left (plan section 9.6, ADR 0002).

.DESCRIPTION
Arc onboarding creates the T2 guest's Arc resources outside the template, so they're deleted explicitly,
SQL Server instances first, then machines. Then the resource group goes, with T3, the budget, and Bastion,
then the subscription-scope deployment record dbhub-<environment>-main. Last, the residual check
(Test-DemoTeardownResidue, TEARDOWN.RESIDUAL.*) confirms that nothing carrying the environment's tags, no
Arc resource, role assignment, managed identity, P6 membership, deployment record, or budget is left
(DESTROY.RESIDUAL; docs/cleanup.md).
The GitHub identity's resource group (rg-<prefix>-control) stays. It asks for confirmation unless -Force.
With -IfExpired (the scheduled expiry workflow) it deletes only when the resource group's expiresOn tag
(expiresOn in the configuration) has passed, and otherwise does nothing. Running it again after an
interruption finishes the cleanup.

In a shared subscription, agree on it with the environment's owner first: a PaygWizard environment holds the
setup-wizard step, which no script can redo (docs/cleanup.md). So destroy.ps1 refuses to delete one unless a
boot-verified golden snapshot in rg-<prefix>-golden keeps it (capture-t2-golden.ps1, test-t2-golden.ps1), or
-WithoutGolden accepts the loss. The golden group stays unless -IncludeGolden.

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Force
Don't ask for confirmation (destroy.yml and the expiry workflow).

.PARAMETER IfExpired
Delete only after the expiresOn date (the day after it, in UTC).

.PARAMETER WaitMinutes
How long to wait for the resource group to be deleted.

.PARAMETER SkipResidueCheck
Skip the residual check after the deletion (DESTROY.RESIDUAL is Not selected).

.PARAMETER ResidueWaitMinutes
How long the residual check waits for Azure Resource Graph and Microsoft Entra to catch up.

.PARAMETER ManifestPath
Where to write what the residual check needs (names and IDs, no secrets), read before anything is deleted,
so the teardown tests can check again later. Default: out/destroy-manifest-<environment>.json.

.PARAMETER IncludeGolden
Also delete rg-<prefix>-golden and its T2 golden snapshots (ADR 0018). Without it, the golden group stays, so
the next deploy.ps1 restores T2 from it (DESTROY.GOLDEN says so).

.PARAMETER WithoutGolden
Destroy a PaygWizard environment even though no boot-verified golden snapshot keeps its setup-wizard step.
Without it, destroy.ps1 deletes nothing in that case (DESTROY.GOLDEN.GUARD Fail).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/destroy.ps1

.EXAMPLE
./scripts/destroy.ps1 -Force -IfExpired
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $Force,

    [switch] $IfExpired,

    [ValidateRange(1, 180)]
    [int] $WaitMinutes = 60,

    [switch] $SkipResidueCheck,

    [ValidateRange(0, 120)]
    [int] $ResidueWaitMinutes = 10,

    [string] $ManifestPath = '',

    [switch] $IncludeGolden,

    [switch] $WithoutGolden,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/destroy.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$ManifestPath = Resolve-DemoUserPath -Path $ManifestPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
if (-not $ManifestPath) {
    # One manifest per environment, so destroying another environment never overwrites it.
    $ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath ('../out/destroy-manifest-{0}.json' -f $config['environment'])
}
$confirm = -not $Force -and $ConfirmPreference -ne 'None'
$parameters = @{
    Config             = $config
    IfExpired          = $IfExpired
    WaitMinutes        = $WaitMinutes
    SkipResidueCheck   = $SkipResidueCheck
    ResidueWaitMinutes = $ResidueWaitMinutes
    ManifestPath       = $ManifestPath
    IncludeGolden      = $IncludeGolden
    WithoutGolden      = $WithoutGolden
    WhatIf             = [bool]$WhatIfPreference
    Confirm            = $confirm
}
$results = @(Remove-DemoEnvironment @parameters)

Write-DemoResultReport -Result $results -Title 'destroy.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
