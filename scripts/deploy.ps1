#Requires -Version 7.4
<#
.SYNOPSIS
Deploys and configures the whole demo with one command after 'az login', and continues where it stopped when you run it
again (plan section 9.2, ADR 0011, Phase 28).

.DESCRIPTION
One command, one guided stop (Phase 28):
- No configuration yet: it writes one first, as init.ps1 does (Initialize-DemoFirstRun: the same prompts, and the P6
  admin group created when it's missing and you may create it), then deploys. init.ps1 still works on its own. Since
  2026-11-09 neither asks how T2 gets SQL Server: a first deployment gets JumpstartImage, which needs nobody.
- An existing environment is upgraded in place (2026-11-09): a T2 guest built in PaygWizard mode whose SQL Server setup
  was never finished is rebuilt from Arc Jumpstart's image (about 27 minutes; DEPLOY.T2.REBUILD), a finished guest keeps
  its mode when the configuration doesn't name t2SqlInstallMode (DEPLOY.T2.MODE), and a missing T4 is created
  (DEPLOY.T4.MISSING), or the run says why not (DEPLOY.T4.OFF).
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
  -Resume does. It starts VMs that were stopped, for example by the nightly auto-shutdown or stop-demo.ps1, and a
  stopped T4, while preflight runs; running VMs are only read.
- The Insights app (APP_DatabaseHub_Insights) is part of every deployment. It deploys with your Azure CLI sign-in
  (az login, since 2026-11-09): each Rayfin CLI command gets a token for its own audience, so no browser opens. Only
  after Fabric refused that token in an earlier run does the Rayfin CLI's own browser sign-in (P14) start at the
  beginning, while you're still at the keyboard: on Windows in a window of its own, elsewhere in this terminal. Nothing
  waits for it but the app's own step, and that only until its deadline (15 minutes after the start). In CI, or a
  session that can't take keyboard input, it isn't started.
  When the app isn't created, or doesn't work, the run still goes on and can still end DONE; the status page shows the
  app's step Failed with the actual error and how to fix it, and the banner says so.
- It ends with one banner: DONE (Database Hub shows every target, and where to look) or NOT DONE (why, the single next
  action, and the exact command). The exit code is 0 only when it's DONE (and for a -WhatIf with no Fail).
- Ctrl+C stops it within seconds, track processes included: their slow Azure cleanups are left to the next run or
  stop-demo.ps1, the PC may sleep again, and the status page says Stopped, not done, with the command to continue.

By default (ADR 0018), Preflight runs first, then four tracks, each in its own PowerShell process with its
own subscription guard, started before the template so their guards run while it deploys: T1 (T3 set up
from T1 first, so T3's telemetry starts early; then the bootstrap bundle and the workload runner together in
parallel Run Command chunks, the loader with T1's monitoring merged while the bootstrap runs, T1 Ready, the
activity profiles, and telemetry), T2 (a host restored from a golden snapshot starts as soon as the template
has deployed archost01 and is released first: passwords rotated and the copy's Arc identity reset, with its
artifacts sent meanwhile; then its loader, Arc onboarding and configuration with PAYG and monitoring, and
telemetry), T4 (the PostgreSQL flexible server's checks and its Azure Monitor metrics; T1's track sets it
up through the P6 group, and a stopped T4 is started before the template; Phase 24, ADR 0019), and Fabric
(the notebooks, the Real-Time Dashboard, the history report, and the Insights app).
The bundle and the runner are built while Preflight runs. With networkMode private, the policy inventory runs
alongside the deployment instead of before it (with public or auto it stays in preflight). The validation then checks
Database Hub's estate for every target, the runner, the Hub checklist with the T3 gate, and the dashboard's tiles, and
DEPLOY.TIMING records each track's steps and the total.

-Sequential runs the earlier single sequence of Invoke-DemoDeployment: Preflight, Infrastructure, Artifacts
(the bootstrap bundle and the workload runner, in Run Command chunks), Bootstraps (the loaders, then T1
Ready), T3 (the group membership, the setup from T1, the runner on T3), T4 (the PostgreSQL flexible
server's checks, its setup from T1 through the P6 group, and its Azure Monitor metrics), Activity (the
configured activityProfile on T1, T3, and T4, business-day by default: as baseline until the run's switch), Monitoring
(T1, waiting while the SQL IaaS extension updates after the
template), T2 (Arc onboarding and configuration, then T2's profile), Fabric (the Hub checklist and, on
request, the notebook import), and Validation (telemetry for each ready target, the runner's status, and a
summary), then DONE's checks and the history report's snapshot. It has no guided stop.

- The activity profile (2026-11-03, ADR 0010): business-day by default, the steady mix plus bounded incidents at fixed
  minutes past each UTC hour, which fill Database Hub's Performance page; set activityProfile to baseline for the
  quieter demo. The run sets baseline first and switches to a profile with incidents once its own Run Commands on each
  VM are done, after DONE's checks (DEPLOY.INCIDENTS_*), so no incident slows them; when it ends before that (Ctrl+C,
  an error), the switch is sent without waiting. A VM the run starts gets baseline as soon as its SQL Server, or T2's
  guest, answers, and the run's own Run Commands there wait for it, at most about 12.5 minutes (DEPLOY.INTERIM_*). A
  configuration that doesn't set activityProfile gets one notice.

- The history report's snapshot (2026-11-06, ADR 0014): last, once DONE's telemetry checks have passed and the switch is
  sent, NB_DatabaseHub_LiveActivity runs once in Fabric, analyze-only (CONFIRM false, so it sends no activity request
  of its own), saves the last 24 hours to the lakehouse, and the history model is refreshed, so the history report has
  data; about 2 to 5 minutes, at most about 15 (DEPLOY.FABRIC.HISTORY, the status page's last row). It runs as you,
  with the Azure CLI's Fabric token; it never resumes, pauses, or scales the capacity, and it never keeps the run from
  DONE: a paused capacity or a job that outlives the wait is a Warning, and -WhatIf, -SkipFabric, GitHub Actions, or a
  run whose telemetry checks didn't pass take none (Not selected). The data is partial: incidents start only at the end
  of the run, so incident measures stay blank until incidents have run and the notebook runs again
  (./scripts/stop-demo.ps1 -SaveHistory, or ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport
  -RunLiveActivity).

- Every step is idempotent. The last step each track finished is recorded in the resource group's tags, so
  a later run continues from there on any machine, and GitHub Actions (deploy.yml) runs the same tracks.
  -FromStage and -StopAfter keep their stage names; each track runs the steps that belong to those stages.
- A Fail stops its track. Manual action required never stops it and is never hidden.
- -WhatIf runs the read-only preflight and the template's what-if, then stops.
- It never signs in or changes the Azure CLI context: sign in first with 'az login --tenant <tenantId>'. You don't need
  to change the Azure CLI's default subscription. Every Azure call carries the configured subscription.
- Results go to the console, to -OutputPath as JSON lines, and in GitHub Actions to the job summary; the console's
  transcript goes to out/logs (not in GitHub Actions). ./scripts/collect-diagnostics.ps1 zips them, redacted.
  Exit code: 0 when DONE, 1 when NOT DONE with a Fail, 2 when NOT DONE otherwise. After Ctrl+C, PowerShell usually ends
  the script itself, with its own exit code; the console and the status page still say NOT DONE with the command that
  continues. GitHub Actions keeps the earlier codes: 0 Pass or Warning, 1 Fail, 2 Manual action required with
  -TreatManualAsError.

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
Skip the Fabric stage, and the history report's snapshot at the end (Not selected).

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

.PARAMETER NoSelfUpdate
Don't check whether this copy is behind GitHub's main, and don't update it (also DBHUB_NO_SELF_UPDATE=1). By default,
before anything else, a clean checkout of main that's behind origin's main fast-forwards (git merge --ff-only) and
deploy.ps1 starts again with the new code and the same parameters; anything else (local changes, another branch,
diverged, offline, no Git, a downloaded zip) is a Warning with the exact command, and the run goes on with the code in
this folder (DEPLOY.SELFUPDATE, 2026-11-09). CI skips the check.

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

    [switch] $TreatManualAsError,

    [switch] $NoSelfUpdate
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
# 2026-11-09, the owner's choice: before anything else (no transcript, no configuration, no Azure call), a clean main
# that's behind GitHub's main fast-forwards and this script runs again with the new code and the same parameters; the
# old code goes no further. Anything else is a Warning with the exact command, and the run goes on (DEPLOY.SELFUPDATE).
$selfUpdate = Invoke-DemoSelfUpdate -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RepositoryRoot (Join-Path -Path $PSScriptRoot -ChildPath '..') -ConfigPath (Resolve-DemoUserPath -Path $ConfigPath) -NoSelfUpdate:$NoSelfUpdate -Nested:$entryNested -WhatIf:([bool]$WhatIfPreference)
if ($selfUpdate.Restarted) {
    exit ([int]$selfUpdate.ExitCode)
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
$awake = ''
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
    # A Ctrl+C while the run's experience starts still lets the PC sleep again (the outer finally block below).
    $awake = 'starting'
    $run = Start-DemoDeploymentRun -Config $config -ConfigPath $resolvedConfigPath -WaitForT2:$waitForT2Now -T2WaitMinutes $T2WaitMinutes -SkipFabric:$SkipFabric -NoStatusPage:$NoStatusPage -NoBrowser:$NoBrowser -OutputDirectory $outDirectory -Note @($selfUpdate.Note) -WhatIf:$whatIf -Confirm:$false
    $results = @($selfUpdate.Result | Where-Object { $null -ne $_ })
    $outcome = $null
    $finished = $false
    $stopped = $false
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
            $results = @($results) + @(Invoke-DemoDeployment @parameters)
        }
        catch [System.OperationCanceledException] {
            # Ctrl+C that the wait for the tracks noticed itself (Phase 28 live finding): the ending below says so.
            $stopped = $true
        }
        catch {
            $results = @($results) + @(New-DemoResult -CheckId 'DEPLOY.RUN' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('deploy.ps1 stopped: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again; it continues where it stopped. If it stops the same way, ./scripts/collect-diagnostics.ps1 makes a redacted zip for a Deployment problem issue.')
        }
        $finished = $true
    }
    finally {
        # Always one ending, even after Ctrl+C, and fast then: the model and the page say DONE or NOT DONE (Stopped, not
        # done, with the command to continue), and the PC may sleep again whatever happens (Phase 28 live finding).
        try {
            $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @($results) -WhatIfRun:$whatIf -StopAfter $StopAfter -SkipFabric:$SkipFabric -Sequential:$Sequential -Stopped:($stopped -or -not $finished)
        }
        finally {
            $null = Exit-DemoKeepAwake
            $awake = 'released'
        }
        if (-not $finished) {
            Write-DemoDeploymentOutcome -Outcome $outcome -WorkspaceName $workspaceName
        }
    }

    # A remediation that says to run deploy.ps1 names this run's own command, with its -ConfigPath (2026-11-06).
    Write-DemoResultReport -Result $results -Title 'deploy.ps1' -OutcomeDone:($null -ne $outcome -and [string]$outcome.Kind -eq 'Done') -DeployCommand ([string]$run.Command)
    Export-DemoResult -Result $results -Path $OutputPath
    Write-DemoDeploymentOutcome -Outcome $outcome -WorkspaceName $workspaceName
    if ($environment.GitHubActions) {
        exit (Get-DemoExitCode -Result $results -TreatManualAsError:$TreatManualAsError)
    }
    exit ([int]$outcome.ExitCode)
}
finally {
    # Stopped while its experience was starting (Ctrl+C), before the block above could let the PC sleep again.
    if ($awake -eq 'starting') {
        $null = Exit-DemoKeepAwake
    }
    if ($transcript) {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
    }
}