#Requires -Version 7.4
<#
.SYNOPSIS
Deletes the demo: the Arc resources first, then the resource group and everything in it, then the
subscription deployment record, and checks that nothing is left (plan section 9.6, ADR 0002).

.DESCRIPTION
Arc onboarding creates the T2 guest's Arc resources outside the template, so they're deleted explicitly,
SQL Server instances first, then machines. Then the resource group goes, with T3, the budget, and Bastion,
then the subscription-scope deployment record dbhub-<environment>-main. Last, the residual check
(Test-DemoTeardownResidue, TEARDOWN.RESIDUAL.*) confirms that nothing carrying the environment's deploymentId, no
Arc resource, role assignment, managed identity, P6 membership, deployment record, or budget is left
(DESTROY.RESIDUAL; docs/cleanup.md). Only this environment counts: its resource group by its exact name and its
deploymentId, never another prefix's environment with the same environment name.
The GitHub identity's resource group (rg-<prefix>-control) stays. It asks for confirmation unless -Force.
With -IfExpired (the scheduled expiry workflow) it deletes only when the resource group's expiresOn tag
(expiresOn in the configuration) has passed, and otherwise does nothing. Running it again after an
interruption finishes the cleanup.

In a shared subscription, agree on it with the environment's owner first: a PaygWizard environment holds the
setup-wizard step, which no script can redo (docs/cleanup.md). So destroy.ps1 refuses to delete one unless a
boot-verified golden snapshot in rg-<prefix>-golden keeps it (capture-t2-golden.ps1, test-t2-golden.ps1), or
-WithoutGolden accepts the loss. The golden group stays unless -IncludeGolden.

With -ResidueOnly it deletes nothing: it runs only the residual check again, read-only, with the manifest an
earlier destroy wrote (-ManifestPath, out/destroy-manifest-<environment>.json by default), and writes the results to
out/destroy-residue-<environment>.jsonl. Use it once Azure Resource Graph has caught up, or after a Warning.

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
so the check can run again later. With -ResidueOnly, the manifest to read. Default:
out/destroy-manifest-<environment>.json, which every prefix and subscription with that environment name shares:
a manifest there of another resource group or subscription is never used (with -ResidueOnly, DESTROY.MANIFEST is a
Fail), so give each environment its own path to keep both.

.PARAMETER IncludeGolden
Also delete rg-<prefix>-golden and its T2 golden snapshots (ADR 0018). Without it, the golden group stays, so
the next deploy.ps1 restores T2 from it (DESTROY.GOLDEN says so).

.PARAMETER WithoutGolden
Destroy a PaygWizard environment even though no boot-verified golden snapshot keeps its setup-wizard step.
Without it, destroy.ps1 deletes nothing in that case (DESTROY.GOLDEN.GUARD Fail).

.PARAMETER ResidueOnly
Delete nothing and ask nothing: run only the residual check again with the saved manifest (DESTROY.MANIFEST, the
TEARDOWN.RESIDUAL.* checks, and DESTROY.RESIDUAL).

.PARAMETER OutputPath
Where to write the results as JSON lines (default: out/destroy.jsonl, or out/destroy-residue-<environment>.jsonl
with -ResidueOnly).

.EXAMPLE
./scripts/destroy.ps1

.EXAMPLE
./scripts/destroy.ps1 -Force -IfExpired

.EXAMPLE
./scripts/destroy.ps1 -ConfigPath ./out/demo.config.test.json -ResidueOnly -ManifestPath ./out/destroy-manifest-test.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Destroy')]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [Parameter(ParameterSetName = 'Destroy')]
    [switch] $Force,

    [Parameter(ParameterSetName = 'Destroy')]
    [switch] $IfExpired,

    [Parameter(ParameterSetName = 'Destroy')]
    [ValidateRange(1, 180)]
    [int] $WaitMinutes = 60,

    [Parameter(ParameterSetName = 'Destroy')]
    [switch] $SkipResidueCheck,

    [ValidateRange(0, 120)]
    [int] $ResidueWaitMinutes = 10,

    [string] $ManifestPath = '',

    [Parameter(ParameterSetName = 'Destroy')]
    [switch] $IncludeGolden,

    [Parameter(ParameterSetName = 'Destroy')]
    [switch] $WithoutGolden,

    [Parameter(Mandatory, ParameterSetName = 'Residue')]
    [switch] $ResidueOnly,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/destroy.jsonl')
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
$ManifestPath = Resolve-DemoUserPath -Path $ManifestPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$config = Get-DemoConfig -Path $ConfigPath
if (-not $ManifestPath) {
    # One path per environment name, shared by every prefix and subscription with that name: the residual check uses a
    # manifest there only when it's of this resource group and subscription (Read-DemoTeardownManifest).
    $ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath ('../out/destroy-manifest-{0}.json' -f $config['environment'])
}
if ($ResidueOnly) {
    # Read-only: the destroy's own results stay as they were.
    if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
        $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath ('../out/destroy-residue-{0}.jsonl' -f $config['environment'])
    }
    $results = @(Remove-DemoEnvironment -Config $config -ResidueOnly -ManifestPath $ManifestPath -ResidueWaitMinutes $ResidueWaitMinutes -Confirm:$false)
    Write-DemoResultReport -Result $results -Title 'destroy.ps1 -ResidueOnly'
    Export-DemoResult -Result $results -Path $OutputPath
    exit (Get-DemoExitCode -Result $results)
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
