#Requires -Version 7.4
<#
.SYNOPSIS
Deploys and configures the whole demo with one command, and continues where it stopped with -Resume
(plan section 9.2, ADR 0011).

.DESCRIPTION
By default (ADR 0018), Preflight runs first, then four tracks, each in its own PowerShell process with its
own subscription guard, started before the template so their guards run while it deploys: T1 (T3 set up
from T1 first, so T3's telemetry starts early; then the bootstrap bundle and the workload runner together in
parallel Run Command chunks, the loader with T1's monitoring merged while the bootstrap runs, T1 Ready, the
activity profiles, and telemetry), T2 (a host restored from a golden snapshot starts as soon as the template
has deployed archost01 and is released first: passwords rotated and the copy's Arc identity reset, with its
artifacts sent meanwhile; then its loader, Arc onboarding and configuration with PAYG and monitoring, and
telemetry), T4 (the PostgreSQL flexible server's checks and its Azure Monitor metrics; T1's track sets it
up through the P6 group, and a stopped T4 is started before the template; Phase 24, ADR 0019), and Fabric
(the notebooks, the Real-Time Dashboard, the history report, and the Fabric app).
The bundle and the runner are built while Preflight runs. The validation then
checks Database Hub's estate, the runner, the Hub checklist with the T3 gate, and the dashboard's tiles, and
DEPLOY.TIMING records each track's steps and the total. Without a golden snapshot, the T2 host builds its
guest in the background: deploy.ps1 returns when T1, T3, and Fabric are done and reports DEPLOY.T2.BACKGROUND
as Manual action required with the command that continues it, or waits with -WaitForT2.

-Sequential runs the earlier single sequence of Invoke-DemoDeployment: Preflight, Infrastructure, Artifacts
(the bootstrap bundle and the workload runner, in Run Command chunks), Bootstraps (the loaders, then T1
Ready), T3 (the group membership, the setup from T1, the runner on T3), T4 (the PostgreSQL flexible
server's checks, its setup from T1 through the P6 group, and its Azure Monitor metrics), Activity (the
configured activityProfile on T1, T3, and T4), Monitoring (T1, waiting while the SQL IaaS extension updates after the
template), T2 (Arc onboarding and configuration, then T2's profile), Fabric (the Hub checklist and, on
request, the notebook import), and Validation (telemetry for each ready target, the runner's status, and a
summary).

- Every step is idempotent. The last step each track finished is recorded in the resource group's tags, so
  -Resume continues from there on any machine, and GitHub Actions (deploy.yml) runs the same tracks.
  -FromStage and -StopAfter keep their stage names; each track runs the steps that belong to those stages.
- A Fail stops its track. Manual action required (for example the T2 setup-wizard step in PaygWizard mode)
  never stops it and is never hidden: the summary at the end lists each item with its exact steps.
- -WhatIf runs the read-only preflight and the template's what-if, then stops.
- It never signs in or changes the Azure CLI context: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's default subscription.
  Every Azure call carries the configured subscription.
- Results go to the console, to -OutputPath as JSON lines, and in GitHub Actions to the job summary.
  Exit code: 0 Pass or Warning, 1 Fail, 2 Manual action required with -TreatManualAsError.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json).

.PARAMETER Resume
Continue after the last stage that finished.

.PARAMETER FromStage
Start at this stage: Preflight, Infrastructure, Artifacts, Bootstraps, T3, T4, Activity, Monitoring, T2,
Fabric, or Validation.

.PARAMETER StopAfter
Stop after this stage. Infrastructure provisions what the Deploy to Azure button does.

.PARAMETER SkipRunner
Deploy without the workload runner (no .NET SDK needed); the activity profiles don't run.

.PARAMETER SkipFabric
Skip the Fabric stage.

.PARAMETER ImportNotebooks
Import or update both notebooks in the Fabric workspace (also fabric.importNotebooks).

.PARAMETER SkipPolicyInventory
Passed to preflight; networkMode auto then resolves to private.

.PARAMETER PolicyCacheHours
Reuse preflight's last complete policy inventory when it's at most this many hours old and the policy
assignments that apply to the subscription are unchanged (default 168, one week; the assignments are listed
every time, and the reused results say so). 0 reads every policy definition again (7-13 minutes measured).

.PARAMETER T1WaitMinutes
How long to wait for T1's bootstrap to be Ready (default 45).

.PARAMETER T2WaitMinutes
How long to wait for the T2 host to reach Arc onboarding (default 120; the guest build takes about 60 to 90
minutes). 0 checks once.

.PARAMETER MonitoringWaitMinutes
How long to wait for T1's monitoring, including the SQL IaaS extension's update after a deployment.

.PARAMETER TelemetryWaitMinutes
How long the validation waits for fresh telemetry.

.PARAMETER Sequential
Run the stages one after another, as before the parallel tracks (ADR 0018).

.PARAMETER WaitForT2
When T2 builds its guest (no golden snapshot), wait for it up to -T2WaitMinutes instead of returning.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
Exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/deploy.ps1

.EXAMPLE
./scripts/deploy.ps1 -Resume
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $Resume,

    [ValidatePattern('^(Preflight|Infrastructure|Artifacts|Bootstraps|T3|T4|Activity|Monitoring|T2|Fabric|Validation)?$')]
    [string] $FromStage = '',

    [ValidatePattern('^(Preflight|Infrastructure|Artifacts|Bootstraps|T3|T4|Activity|Monitoring|T2|Fabric|Validation)?$')]
    [string] $StopAfter = '',

    [switch] $SkipRunner,

    [switch] $SkipFabric,

    [switch] $ImportNotebooks,

    [switch] $SkipPolicyInventory,

    [ValidateRange(0, 720)]
    [int] $PolicyCacheHours = 168,

    [ValidateRange(0, 240)]
    [int] $T1WaitMinutes = 45,

    [ValidateRange(0, 360)]
    [int] $T2WaitMinutes = 120,

    [ValidateRange(0, 60)]
    [int] $MonitoringWaitMinutes = 20,

    [ValidateRange(0, 120)]
    [int] $TelemetryWaitMinutes = 15,

    [switch] $Sequential,

    [switch] $WaitForT2,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/deploy.jsonl'),

    [switch] $TreatManualAsError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
$parameters = @{
    Config                = $config
    ConfigPath            = (Resolve-Path -LiteralPath $ConfigPath).Path
    Resume                = $Resume
    SkipRunner            = $SkipRunner
    SkipFabric            = $SkipFabric
    ImportNotebooks       = $ImportNotebooks
    SkipPolicyInventory   = $SkipPolicyInventory
    PolicyCacheHours      = $PolicyCacheHours
    T1WaitMinutes         = $T1WaitMinutes
    T2WaitMinutes         = $T2WaitMinutes
    MonitoringWaitMinutes = $MonitoringWaitMinutes
    TelemetryWaitMinutes  = $TelemetryWaitMinutes
    # Preference variables don't reach module functions, so -WhatIf is passed on explicitly.
    WhatIf                = [bool]$WhatIfPreference
}
if ($FromStage) {
    $parameters['FromStage'] = $FromStage
}
if ($StopAfter) {
    $parameters['StopAfter'] = $StopAfter
}
if (-not $Sequential) {
    $parameters['Parallel'] = $true
    $parameters['WaitForT2'] = $WaitForT2
}
$results = @(Invoke-DemoDeployment @parameters)

Write-DemoResultReport -Result $results -Title 'deploy.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
