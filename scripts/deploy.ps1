#Requires -Version 7.4
<#
.SYNOPSIS
Deploys and configures the whole demo with one command after 'az login', and continues where it stopped when you run it
again (plan section 9.2, ADR 0011, Phase 28).

.DESCRIPTION
One command, one guided stop (Phase 28):
- No configuration yet: it writes one first, as init.ps1 does (Initialize-DemoFirstRun: the same prompts, and the P6
  admin group created when it's missing and you may create it), then deploys. init.ps1 still works on its own.
- It keeps this PC awake while it runs (Windows), writes the progress model out/deploy-progress.json and the live status
  page out/deploy-status.html, opens the page (in GitHub Codespaces it says how to preview it), and prints what to
  expect: the timeline, and in PaygWizard mode when a person is needed and for how long. ./scripts/status.ps1 -Watch
  shows the same view in a second terminal.
- Without a golden snapshot it waits for T2's guest build in every install mode (up to -T2WaitMinutes, 180 by
  default), and in PaygWizard mode it stops once for a person: Bastion opens, the browser opens archost01's page, and
  the guest signs itself in and opens a pre-filled SQL Server setup, where you choose pay-as-you-go and Standard and
  sign in to Azure (about 10 minutes, about 60 to 90 minutes after the start). It then finishes T2 by itself:
  onboarding, PAYG, monitoring, and telemetry. -NoWaitForT2 opts out; GitHub Actions and other CI systems don't wait
  unless -WaitForT2.
- Run it again with no parameters and it continues an unfinished deployment (the resource group's state tags), as
  -Resume does.
- It ends with one banner: DONE (Database Hub shows every target, and where to look) or NOT DONE (why, the single next
  action, and the exact command). The exit code is 0 only when it's DONE (and for a -WhatIf with no Fail).

By default (ADR 0018), Preflight runs first, then four tracks, each in its own PowerShell process with its
own subscription guard, started before the template so their guards run while it deploys: T1 (T3 set up
from T1 first, so T3's telemetry starts early; then the bootstrap bundle and the workload runner together in
parallel Run Command chunks, the loader with T1's monitoring merged while the bootstrap runs, T1 Ready, the
activity profiles, and telemetry), T2 (a host restored from a golden snapshot starts as soon as the template
has deployed archost01 and is released first: passwords rotated and the copy's Arc identity reset, with its
artifacts sent meanwhile; then its loader, Arc onboarding and configuration with PAYG and monitoring, and
telemetry), T4 (the PostgreSQL flexible server's checks and its Azure Monitor metrics; T1's track sets it
up through the P6 group, and a stopped T4 is started before the template; Phase 24, ADR 0019), and Fabric
(the notebooks, the Real-Time Dashboard, the history report, and the optional Insights app).
The bundle and the runner are built while Preflight runs. With networkMode private, the policy inventory runs
alongside the deployment instead of before it (with public or auto it stays in preflight). The validation then checks
Database Hub's estate for every target, the runner, the Hub checklist with the T3 gate, and the dashboard's tiles, and
DEPLOY.TIMING records each track's steps and the total.

-Sequential runs the earlier single sequence of Invoke-DemoDeployment: Preflight, Infrastructure, Artifacts
(the bootstrap bundle and the workload runner, in Run Command chunks), Bootstraps (the loaders, then T1
Ready), T3 (the group membership, the setup from T1, the runner on T3), T4 (the PostgreSQL flexible
server's checks, its setup from T1 through the P6 group, and its Azure Monitor metrics), Activity (the
configured activityProfile on T1, T3, and T4), Monitoring (T1, waiting while the SQL IaaS extension updates after the
template), T2 (Arc onboarding and configuration, then T2's profile), Fabric (the Hub checklist and, on
request, the notebook import), and Validation (telemetry for each ready target, the runner's status, and a
summary). It has no guided stop.

- Every step is idempotent. The last step each track finished is recorded in the resource group's tags, so
  a later run continues from there on any machine, and GitHub Actions (deploy.yml) runs the same tracks.
  -FromStage and -StopAfter keep their stage names; each track runs the steps that belong to those stages.
- A Fail stops its track. Manual action required never stops it and is never hidden.
- -WhatIf runs the read-only preflight and the template's what-if, then stops.
- It never signs in or changes the Azure CLI context: sign in first with 'az login --tenant <tenantId>'. You don't need
  to change the Azure CLI's default subscription. Every Azure call carries the configured subscription.
- Results go to the console, to -OutputPath as JSON lines, and in GitHub Actions to the job summary; the console's
  transcript goes to out/logs (not in GitHub Actions). ./scripts/collect-diagnostics.ps1 zips them, redacted.
  Exit code: 0 when DONE, 1 when NOT DONE with a Fail, 2 when NOT DONE otherwise. GitHub Actions keeps the earlier
  codes: 0 Pass or Warning, 1 Fail, 2 Manual action required with -TreatManualAsError.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json). When it doesn't exist yet, deploy.ps1 writes it first.

.PARAMETER Resume
Continue after the last stage that finished. A run without -Resume or -FromStage does this by itself when the last
deployment didn't finish (not in GitHub Actions).

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
How long to wait for T2's guest build and, in PaygWizard mode, its guided stop (default 180: the build takes about
60 to 90 minutes, and the guided stop waits at least 45 minutes for a person once it asks). 0 checks once.

.PARAMETER MonitoringWaitMinutes
How long to wait for T1's monitoring, including the SQL IaaS extension's update after a deployment.

.PARAMETER TelemetryWaitMinutes
How long the validation waits for fresh telemetry.

.PARAMETER Sequential
Run the stages one after another, as before the parallel tracks (ADR 0018). It has no guided stop.

.PARAMETER WaitForT2
Wait for T2 in GitHub Actions or another CI system too. Elsewhere it's the default.

.PARAMETER NoWaitForT2
Don't wait for T2's guest build: T1, T3, T4, and Fabric finish now, T2 builds in the background, and a later
./scripts/deploy.ps1 finishes it (with the guided stop in PaygWizard mode).

.PARAMETER NoStatusPage
Write no progress model and no status page.

.PARAMETER NoBrowser
Don't open the status page or the portal in a browser; their paths and links are printed.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.PARAMETER TreatManualAsError
In GitHub Actions: exit with code 2 when a result is Manual action required.

.EXAMPLE
./scripts/deploy.ps1

.EXAMPLE
./scripts/deploy.ps1 -NoWaitForT2
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
    [int] $T2WaitMinutes = 180,

    [ValidateRange(0, 60)]
    [int] $MonitoringWaitMinutes = 20,

    [ValidateRange(0, 120)]
    [int] $TelemetryWaitMinutes = 15,

    [switch] $Sequential,

    [switch] $WaitForT2,

    [switch] $NoWaitForT2,

    [switch] $NoStatusPage,

    [switch] $NoBrowser,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/deploy.jsonl'),

    [switch] $TreatManualAsError
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
$whatIf = [bool]$WhatIfPreference
$environment = Get-DemoRunEnvironment
$outDirectory = Split-Path -Path ([System.IO.Path]::GetFullPath($OutputPath)) -Parent

# The console's transcript, for ./scripts/collect-diagnostics.ps1 (every line on the console is already redacted).
# https://learn.microsoft.com/powershell/module/microsoft.powershell.host/start-transcript
$transcript = $false
if (-not $environment.GitHubActions -and -not $whatIf) {
    try {
        $logPath = Join-Path -Path $outDirectory -ChildPath ('logs/deploy-{0}.log' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture))
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $logPath -Parent) -Force
        $null = Start-Transcript -LiteralPath $logPath -UseMinimalHeader -WhatIf:$false
        $transcript = $true
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The console''s transcript couldn''t be started: {0}' -f $_.Exception.Message)
    }
}

try {
    # 1. The first run writes the configuration, as init.ps1 does (brief goal 1).
    $firstRun = Initialize-DemoFirstRun -ConfigPath $ConfigPath -Environment $environment -WhatIf:$whatIf
    if ($firstRun.Ran) {
        Write-DemoResultReport -Result @($firstRun.Results) -Title 'deploy.ps1: first-run setup (as init.ps1)'
        Export-DemoResult -Result @($firstRun.Results) -Path (Join-Path -Path $outDirectory -ChildPath 'init.jsonl')
    }
    if (-not $firstRun.Ready) {
        Write-DemoDeploymentOutcome -Outcome $firstRun.Outcome
        exit ([int]$firstRun.Outcome.ExitCode)
    }

    $config = Get-DemoConfig -Path $ConfigPath
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $workspaceName = if ($config['fabric'] -is [System.Collections.IDictionary]) { [string]$config['fabric']['workspaceName'] } else { '' }
    # Wait for T2 by default (brief goal 2); CI keeps returning early unless -WaitForT2.
    $waitForT2Now = -not $NoWaitForT2 -and (-not $environment.Ci -or $WaitForT2) -and -not $Sequential
    $run = Start-DemoDeploymentRun -Config $config -ConfigPath $resolvedConfigPath -WaitForT2:$waitForT2Now -T2WaitMinutes $T2WaitMinutes -SkipFabric:$SkipFabric -NoStatusPage:$NoStatusPage -NoBrowser:$NoBrowser -OutputDirectory $outDirectory -WhatIf:$whatIf -Confirm:$false
    $results = @()
    $outcome = $null
    $finished = $false
    try {
        $parameters = @{
            Config                = $config
            ConfigPath            = $resolvedConfigPath
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
            WhatIf                = $whatIf
        }
        if ($FromStage) {
            $parameters['FromStage'] = $FromStage
        }
        if ($StopAfter) {
            $parameters['StopAfter'] = $StopAfter
        }
        if (-not $Sequential) {
            $parameters['Parallel'] = $true
            $parameters['WaitForT2'] = $waitForT2Now
            # A plain run continues an unfinished deployment (brief item 2); GitHub Actions keeps its inputs' meaning.
            $parameters['AutoResume'] = -not $Resume -and -not $FromStage -and -not $environment.GitHubActions
            $parameters['ProgressPath'] = [string]$run.ProgressPath
            $parameters['PagePath'] = [string]$run.PagePath
        }
        try {
            $results = @(Invoke-DemoDeployment @parameters)
        }
        catch {
            $results = @($results) + @(New-DemoResult -CheckId 'DEPLOY.RUN' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('deploy.ps1 stopped: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again; it continues where it stopped. If it stops the same way, ./scripts/collect-diagnostics.ps1 makes a redacted zip for a Deployment problem issue.')
        }
        $finished = $true
    }
    finally {
        # Always one ending, even after Ctrl+C: the model and the page say DONE or NOT DONE, and the PC may sleep again.
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @($results) -WhatIfRun:$whatIf -StopAfter $StopAfter -SkipFabric:$SkipFabric -Sequential:$Sequential
        $null = Exit-DemoKeepAwake
        if (-not $finished) {
            Write-DemoDeploymentOutcome -Outcome $outcome -WorkspaceName $workspaceName
        }
    }

    Write-DemoResultReport -Result $results -Title 'deploy.ps1'
    Export-DemoResult -Result $results -Path $OutputPath
    Write-DemoDeploymentOutcome -Outcome $outcome -WorkspaceName $workspaceName
    if ($environment.GitHubActions) {
        exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
    }
    exit ([int]$outcome.ExitCode)
}
finally {
    if ($transcript) {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
    }
}