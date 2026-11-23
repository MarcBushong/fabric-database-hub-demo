function Invoke-DemoDeployment {
    <#
    .SYNOPSIS
    Runs the demo's deployment stages in order, with -Resume (plan section 9.2, ADR 0011). deploy.ps1 and
    deploy.yml call it.

    .DESCRIPTION
    Every stage is idempotent, and a re-run converges. The last stage that finished is recorded in the
    resource group's tags (Set-DemoDeploymentState), so -Resume continues after it from any machine. On an existing
    environment, what's stopped (the nightly auto-shutdown, stop-demo.ps1, a stop) starts while preflight runs, and runs
    before the first stage that needs it (Request-DemoStoppedStart, Wait-DemoStoppedStart; Phase 28 live finding). Then,
    on a run that ends with the validation and has no Monitoring stage, T1's monitoring plugin is checked, and restarted
    when it isn't running (Invoke-DemoT1MonitoringCheck, DEPLOY.T1.MONITORING; Phase 28 live finding, 2026-10-30).
    Stages:

    1. Preflight: Invoke-DemoPreflight (subscription guard, P1-P6, region, sizes, quota, policy, cost). Any
       Fail stops here. It resolves the network mode, the T3 free offer, and the P6 group's name. A run that starts
       after it (a resume) checks the Fabric workspace as preflight does when it reaches the Fabric stage
       (Get-DemoFabricSharedResult -Resolve; 2026-11-19): one that another demo environment records, and this one
       doesn't, stops it before anything changes (DEPLOY.FABRIC.SHARED Fail).
    2. Infrastructure: the template without the bootstraps' new settings (Invoke-DemoTemplateDeployment); a
       free-offer rejection falls back to regular serverless with a Warning. With the Key Vault opt-in
       (keyVault.enabled), Initialize-DemoKeyVault then deploys the vault and the operator's access to it; a
       vault Fail is reported but doesn't stop the deployment, since only start-demo.ps1 -Interactive needs it.
    3. Artifacts: Publish-DemoWorkloadRunner and New-DemoBootstrapBundle, then Send-DemoWorkloadRunner and
       Send-DemoBootstrapBundle to each VM. A VM that already has exactly these chunks is skipped.
    4. Bootstraps: the template again with both hashes, which runs the loaders; Wait-DemoBootstrapLoader;
       then T1's health until it's Ready (the WorkloadRunner step included).
    5. T3: Add-DemoT1ToT3AdminGroup, Invoke-DemoT3SqlFromT1 -Name Setup, Enable-DemoT3Workload, Test-DemoT3 -
       the order that worked live, so T1 never asks for an Azure SQL token before it's in the P6 group.
    5a. T4 (Phase 24, ADR 0019): Test-DemoT4, Enable-DemoT4Workload (T1 sets the PostgreSQL flexible server
       up through the P6 group), and METRICS.T4. A stopped T4 is started before the template, which a stopped
       server would reject. A T4 failure is reported without stopping the run.
    6. Activity: the configured activityProfile on T1 and T3 until the next auto-shutdown (Set-DemoTargetProfile),
       business-day by default since 2026-11-03, set as baseline until the run's switch at its end (after DONE's checks,
       also when a stage stops it at a Fail; DEPLOY.INCIDENTS_*), so no incident slows the run's own Run Commands.
       The VMs set it again at boot only when activityProfileOnBoot is true (ADR 0016, R183).
    7. Monitoring: Enable-DemoSqlVmMonitoring for T1 after the template deployments, waiting while a
       redeployment keeps the SQL IaaS extension Updating for about 10 minutes (Phase 13 live finding), as
       configure-monitoring.ps1 -Target T1 -WaitMinutes does; Updating is a wait, not a failure.
    8. T2: Invoke-DemoArcConfiguration: onboarding when the host waits for it, then the extension, license
       type, and monitoring (T2.ARC.MONITORING), then T2's activity profile. In PaygWizard mode it reports
       Manual action required with the wizard steps; the stage stays open, and the later stages still run. What an
       earlier guided stop or session left open (Bastion, a handed-over host password) is cleaned up here too
       (Clear-DemoGuidedStopLeftover; Phase 28 review).
    9. Fabric: configure-fabric.ps1 (the Hub checklist, the Real-Time Dashboard, and the notebook import with
       -ImportNotebooks or fabric.importNotebooks), then configure-powerbi.ps1 (the history semantic model and
       report), as the parallel Fabric track imports them (Phase 28 review follow-up), then the Insights app
       (configure-fabric-app.ps1, part of every deployment since 2026-11-05; Invoke-DemoInsightsAppStep), whose step
       never stops the stage or keeps the run from DONE. Its sign-in starts with the run, alongside the stages
       (Start-DemoFabricAppSignIn), and this stage waits for it until its deadline. Not selected with -SkipFabric.
    10. Validation: Test-DemoHubTelemetry for each ready target, the runner's status on T1, and a summary that
        lists every Manual action required item with its exact steps. A target whose telemetry didn't come gets its
        monitoring checked, and its telemetry once more, before the run is judged (Invoke-DemoTelemetryCheck; Phase 28
        live finding, 2026-10-30). Since Phase 28 (review finding 4), with no
        stage open and nothing failed, DONE's read-only checks follow (Invoke-DemoDoneGate: Database Hub's estate,
        T4's metrics, T2's PAYG and monitoring, and the Fabric items), so deploy.ps1 -Sequential can end DONE.
    11. The history report's snapshot (2026-11-06, ADR 0014's amendment), after DONE's checks and the switch to the run's
        activity profile, on a run whose validation ran: NB_DatabaseHub_LiveActivity once, analyze-only (CONFIRM false),
        then the history model's refresh (Invoke-DemoHistorySnapshotStep, DEPLOY.FABRIC.HISTORY), as the parallel path
        does. It never stops the run or keeps it from DONE.
    12. T4's read replica at the run's end (2026-11-16; Invoke-DemoT4ReplicaDeployEnd, DEPLOY.T4.REPLICA.END), as the
        parallel path does: deleted unless a session uses it now, on a run that stops at a Fail too. Never a Fail.
    13. Not here: once deploy.ps1 judges the run DONE, its ending stops again what the run started when it found the demo
        stopped (2026-11-19; Complete-DemoDeploymentRun, Invoke-DemoUpdateEndStop, DEPLOY.ENDSTOP), from DEPLOY.VMSTART's
        evidence of what ran when the run began. Both paths record it the same way (Wait-DemoStoppedStart).

    A Fail stops the run, and nothing after it runs but the switch and the replica's end. Manual action required never
    stops it and is never hidden: it's in the results and in DEPLOY.SUMMARY. Deployment success alone is never Pass
    (ADR 0012).
    With -WhatIf, it runs the read-only preflight (without registering providers) and the template's
    what-if, then stops.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ConfigPath
    The configuration file, for the Fabric stage's configure-fabric.ps1. Without it, the stage writes the
    configuration to a private temporary file.

    .PARAMETER Resume
    Start after the last stage the resource group's tags record.

    .PARAMETER FromStage
    Start at this stage (and run the ones after it).

    .PARAMETER StopAfter
    Stop after this stage. Infrastructure gives what the Deploy to Azure button gives.

    .PARAMETER SkipRunner
    Deploy without the workload runner: no .NET SDK needed, and the WorkloadRunner steps are Not selected.

    .PARAMETER SkipFabric
    Skip the Fabric stage.

    .PARAMETER ImportNotebooks
    Import or update both notebooks in the Fabric workspace (also fabric.importNotebooks in the configuration).

    .PARAMETER SkipPolicyInventory
    Passed to preflight: networkMode auto then resolves to private.

    .PARAMETER PolicyCacheHours
    Passed to preflight (Get-DemoPolicyConstraint -CacheHours): reuse a complete policy inventory at most this
    many hours old while the assignments that apply to the subscription are unchanged. 0 (the default) reads
    everything; deploy.ps1 passes 168.

    .PARAMETER T1WaitMinutes
    How long to wait for T1's bootstrap to be Ready.

    .PARAMETER T2WaitMinutes
    How long the T2 stage waits for the host to reach the Arc onboarding step (0: don't wait). With -Parallel and
    -WaitForT2: how long the T2 track waits for the guest build and, in PaygWizard mode, the guided stop (Phase 28;
    deploy.ps1's default is 180).

    .PARAMETER MonitoringWaitMinutes
    How long to wait for T1's monitoring plugin, including a SQL IaaS extension that's Updating.

    .PARAMETER TelemetryWaitMinutes
    How long the validation waits for fresh telemetry rows.

    .PARAMETER ChunkSizeKiB
    Run Command chunk size for the bundle and the runner.

    .PARAMETER Parallel
    Run Invoke-DemoParallelDeployment instead (ADR 0018): Preflight here, the T1, T2, and Fabric tracks in
    their own processes, started before the template so their guards run while it deploys, then the
    validation, DEPLOY.TIMING, and the history report's snapshot. deploy.ps1 passes it unless -Sequential.

    .PARAMETER WaitForT2
    With -Parallel: when T2 builds its guest (no golden snapshot), wait up to -T2WaitMinutes instead of
    returning with DEPLOY.T2.BACKGROUND.

    .PARAMETER ChunkParallelism
    With -Parallel: how many chunk Run Commands run on a VM at once.

    .PARAMETER ArcWaitMinutes
    With -Parallel: how long configure-arc's sequence waits for the extension and the SQL Server instance.

    .PARAMETER AutoResume
    With -Parallel: continue an unfinished deployment (the state's last stage is set and isn't Validation), as -Resume
    does, when neither -Resume nor -FromStage is given (Phase 28; deploy.ps1 passes it, except in GitHub Actions).

    .PARAMETER ProgressPath
    With -Parallel: the progress model behind the live status page (Phase 28), which every stage and track updates.

    .PARAMETER PagePath
    With -Parallel: the status page, named in the guided stop's prompt.

    .EXAMPLE
    Invoke-DemoDeployment -Config $config -Resume
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $Resume,

        [ValidateSet('Preflight', 'Infrastructure', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'T2', 'Fabric', 'Validation')]
        [string] $FromStage = '',

        [ValidateSet('Preflight', 'Infrastructure', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'T2', 'Fabric', 'Validation')]
        [string] $StopAfter = '',

        [switch] $SkipRunner,

        [switch] $SkipFabric,

        [switch] $ImportNotebooks,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 720)]
        [int] $PolicyCacheHours = 0,

        [ValidateRange(0, 240)]
        [int] $T1WaitMinutes = 45,

        [ValidateRange(0, 360)]
        [int] $T2WaitMinutes = 180,

        [ValidateRange(0, 60)]
        [int] $MonitoringWaitMinutes = 20,

        [ValidateRange(0, 120)]
        [int] $TelemetryWaitMinutes = 15,

        [ValidateRange(1, 512)]
        [int] $ChunkSizeKiB = 512,

        [switch] $Parallel,

        [switch] $WaitForT2,

        [ValidateRange(1, 16)]
        [int] $ChunkParallelism = 8,

        [ValidateRange(5, 120)]
        [int] $ArcWaitMinutes = 45,

        [switch] $AutoResume,

        [string] $ProgressPath = '',

        [string] $PagePath = ''
    )

    if ($Parallel) {
        $parallelArguments = @{
            Config                = $Config
            ConfigPath            = $ConfigPath
            Resume                = $Resume
            FromStage             = $FromStage
            StopAfter             = $StopAfter
            SkipRunner            = $SkipRunner
            SkipFabric            = $SkipFabric
            ImportNotebooks       = $ImportNotebooks
            SkipPolicyInventory   = $SkipPolicyInventory
            PolicyCacheHours      = $PolicyCacheHours
            T1WaitMinutes         = $T1WaitMinutes
            T2WaitMinutes         = $T2WaitMinutes
            MonitoringWaitMinutes = $MonitoringWaitMinutes
            TelemetryWaitMinutes  = $TelemetryWaitMinutes
            ChunkSizeKiB          = $ChunkSizeKiB
            ChunkParallelism      = $ChunkParallelism
            WaitForT2             = $WaitForT2
            ArcWaitMinutes        = $ArcWaitMinutes
            AutoResume            = $AutoResume
            ProgressPath          = $ProgressPath
            PagePath              = $PagePath
        }
        return (Invoke-DemoParallelDeployment @parallelArguments)
    }

    $stages = @(Get-DemoDeploymentStageName)
    $results = [System.Collections.Generic.List[object]]::new()
    $whatIf = [bool]$WhatIfPreference
    $hostVm = Get-DemoHostVmName -Config $Config
    $vmNames = @('sqlvm01', $hostVm)
    # The runner goes to T1 and, in the nested mode, to the T2 host (the evaluation-only mode has none).
    $runnerVms = @('sqlvm01') + @(if ($hostVm -eq 'archost01') { 'archost01' })

    # The Insights app's sign-in (2026-11-06 live finding), as in the parallel path: whether the Rayfin CLI is already
    # signed in is read from now on, alongside the subscription guard, when the Fabric stage can run; the sign-in's start
    # below takes its answer (Start-DemoFabricAppSignInCheck).
    $signInCheck = $null
    $fabricIndex = [array]::IndexOf($stages, 'Fabric')
    $firstIndex = if ($FromStage) { [array]::IndexOf($stages, $FromStage) } else { 0 }
    $lastIndex = if ($StopAfter) { [array]::IndexOf($stages, $StopAfter) } else { $stages.Count - 1 }
    if (-not $whatIf -and -not $SkipFabric -and $firstIndex -le $fabricIndex -and $fabricIndex -le $lastIndex) {
        $signInCheck = Start-DemoFabricAppSignInCheck -Config $Config
    }

    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        Stop-DemoRayfinSignInStatus -Status $signInCheck
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Sign in yourself (az login --tenant <tenantId>) and select nothing else: the scripts pass --subscription on every call.'))
        return $results.ToArray()
    }

    $state = Get-DemoDeploymentState -Config $Config
    # Issue #65: this run's key for the T2 host's guest restart, as the parallel path has (Invoke-DemoParallelDeployment), so
    # T2's onboarding, its sign-in data check, and its profile restart the guest at most once for this run, and a rerun gets
    # its own (review of e617f34: -Sequential had none, so the host's hourly keys, which differ by caller, each allowed one).
    $recoveryModel = Read-DemoProgress -Path $ProgressPath
    Set-DemoRunRecoveryKey -Key (New-DemoRunRecoveryKey -RunId $(if ($null -ne $recoveryModel) { [string]$recoveryModel['runId'] } else { '' }))
    $startIndex = 0
    if ($FromStage) {
        $startIndex = [array]::IndexOf($stages, $FromStage)
    }
    elseif ($Resume -and $state.Stage -and $state.Stage -in $stages) {
        $startIndex = [array]::IndexOf($stages, $state.Stage) + 1
    }
    if ($whatIf) {
        $startIndex = 0
    }
    $stopIndex = if ($StopAfter) { [array]::IndexOf($stages, $StopAfter) } else { $stages.Count - 1 }
    if ($startIndex -ge $stages.Count) {
        $startIndex = [array]::IndexOf($stages, 'Validation')
        Write-DemoLog -Message 'Every stage finished earlier; running the validation again.'
    }
    # 2026-11-16 (the merge's upgrade test): a resume after the Fabric stage publishes the Fabric items again when this copy
    # of the scripts has other content than the stage last published in full (Get-DemoFabricContentReopen), so an upgraded
    # environment never keeps the older notebooks, history model, or Insights app.
    if ($Resume -and -not $FromStage -and -not $whatIf -and -not $SkipFabric -and $startIndex -gt $fabricIndex -and $fabricIndex -le $stopIndex) {
        $contentReason = Get-DemoFabricContentReopen -State $state -Current (Get-DemoFabricContentSha256)
        if ($contentReason) {
            $startIndex = $fabricIndex
            Write-DemoLog -Message ('An earlier run recorded the Fabric stage as finished, but {0} So this run continues from the Fabric stage, which publishes them again.' -f $contentReason)
        }
    }
    # The .NET SDK the workload runner's build needs, before anything is created (2026-11-09): the dotnet on PATH, the SDK
    # installed for the user earlier, or the pinned SDK, installed now (Initialize-DemoDotNetSdk), when the run builds it.
    $artifactsIndex = [array]::IndexOf($stages, 'Artifacts')
    if (-not $whatIf -and -not $SkipRunner -and $startIndex -le $artifactsIndex -and $artifactsIndex -le $stopIndex) {
        $sdkRecord = Initialize-DemoDotNetSdk -ProgressPath $ProgressPath -Confirm:$false
        if ($null -ne $sdkRecord) {
            $results.Add($sdkRecord)
            if ([string]$sdkRecord.status -eq 'Fail') {
                Stop-DemoRayfinSignInStatus -Status $signInCheck
                return $results.ToArray()
            }
        }
    }
    else {
        Set-DemoProgressStep -Path $ProgressPath -Id 'DotNetSdk' -State 'Skipped' -Message $(if ($whatIf) { 'What if: nothing is installed.' } elseif ($SkipRunner) { 'Not needed: -SkipRunner builds no workload runner.' } else { 'Not needed: this run builds no workload runner.' })
    }
    # The run's activity profile (2026-11-03, ADR 0010): the Activity and T2 stages set its interim, baseline in place of a
    # profile with incidents, and the run switches the VMs it noted once its own Run Commands are done, also when it stops
    # at a Fail; Complete-DemoDeploymentRun sends the switch when the run ends before that. A run without preflight says
    # the default here.
    $activity = Get-DemoActivityProfile -Config $Config
    $switchTo = if ($activity.HasIncidents) { $activity.Name } else { '' }
    Clear-DemoActivitySwitch
    if ($startIndex -gt 0 -and -not $whatIf) {
        $notice = New-DemoActivityProfileNotice -ActivityProfile $activity -CheckPrefix 'DEPLOY'
        if ($null -ne $notice) {
            $results.Add($notice)
        }
    }
    $switchActivity = {
        if (-not $whatIf -and $activity.HasIncidents) {
            & $addAll @(Send-DemoPendingActivitySwitch -Config $Config -ActivityProfile $activity -Result $results.ToArray() -CheckPrefix 'DEPLOY' -RequestedBy 'deploy')
        }
    }
    # A run that stops at a Fail switches the VMs it noted too, and deletes T4's read replica as a whole run does
    # (2026-11-16), then returns what it has.
    $finishEarly = {
        & $switchActivity
        if (-not $whatIf) {
            $results.Add((Invoke-DemoT4ReplicaDeployEnd -Config $Config -ProgressPath $ProgressPath -ChecksRan $false -Confirm:$false))
        }
        $results.ToArray()
    }
    # T4's size as an earlier run's fallback settled it, unless the configuration sets one (Phase 28 and its follow-up). T4 is
    # part of every deployment (2026-11-09): a "no T4" record has the fallback try every size again when this run deploys
    # the template.
    $infrastructureIndex = [array]::IndexOf($stages, 'Infrastructure')
    $Config = Resolve-DemoEffectiveConfig -Config $Config -State $state -TemplateRuns:(-not $whatIf -and $startIndex -le $infrastructureIndex -and $stopIndex -ge $infrastructureIndex)
    # A resume after an earlier run left T5 out because Azure didn't create its account (DbHubT5Refused; review, 2026-11-19):
    # this run leaves it out too, with DEPLOY.T5; a run that deploys the template tries T5 again.
    $t5Resume = if ($whatIf) { $null } else { Resolve-DemoT5LeftOut -Config $Config -State $state -TemplateRuns:($startIndex -le $infrastructureIndex -and $stopIndex -ge $infrastructureIndex) }
    if ($null -ne $t5Resume) {
        $Config = $t5Resume.Config
        $results.Add($t5Resume.Result)
        Write-DemoLog -Level Warning -Message ([string]$t5Resume.Result.message)
        Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Checks', 'T5.Telemetry' -State 'Skipped' -Status 'Warning' -Message ([string]$t5Resume.Result.message)
    }
    # T4's size and autonomous tuning (#24, 2026-11-17): a run that deploys the template without preflight checks them as
    # PREFLIGHT.T4.TUNING does, so a t4SkuName that can't run the tuning t4AutonomousTuning asks for is a Fail before
    # anything changes.
    if ($startIndex -gt 0 -and -not $whatIf -and $startIndex -le $infrastructureIndex -and $stopIndex -ge $infrastructureIndex -and (Test-DemoT4Enabled -Config $Config)) {
        $tuning = New-DemoT4TuningResult -Config $Config -CheckPrefix DEPLOY
        $results.Add($tuning)
        if ([string]$tuning.status -eq 'Fail') {
            Write-DemoLog -Level Warning -Message ([string]$tuning.message)
            Set-DemoProgressStep -Path $ProgressPath -Id 'Infrastructure' -State 'Failed' -Status 'Fail' -Message ('{0} {1}' -f $tuning.message, $tuning.remediation)
            return $results.ToArray()
        }
    }
    # The Fabric workspace that another demo environment records (2026-11-19), as preflight checks it, before a stage
    # writes to Fabric: a configuration edited by hand since the earlier run stops here (DEPLOY.FABRIC.SHARED).
    if ($startIndex -gt 0 -and -not $whatIf -and -not $SkipFabric -and $stopIndex -ge $fabricIndex) {
        $sharedCheck = Get-DemoFabricSharedResult -Config $Config -Resolve
        if ($null -ne $sharedCheck) {
            $results.Add($sharedCheck)
            if ([string]$sharedCheck.status -eq 'Fail') {
                Write-DemoLog -Level Warning -Message ([string]$sharedCheck.message)
                Set-DemoProgressStep -Path $ProgressPath -Id 'Fabric.Items' -State 'Failed' -Status 'Fail' -Message ('{0} {1}' -f $sharedCheck.message, $sharedCheck.remediation) -MaxLength 1200
                return $results.ToArray()
            }
        }
    }

    # Values later stages need; preflight resolves them, and a resumed run reads them from the state.
    $context = @{
        NetworkMode      = $state.NetworkMode
        T3UseFreeLimit   = $state.T3UseFreeLimit
        T3AdminGroupName = $state.T3AdminGroupName
        T2Complete       = (Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T2')
        OpenStage        = ''
        T4StartSku       = ''
        # PREFLIGHT.POLICY.COSMOSPUBLIC's evidence (2026-11-21): $null without preflight, so a new T5 keeps its endpoint.
        T5Policy         = $null
    }
    # The recorded stage only moves forward over stages that finished, so -Resume never skips an open one.
    $recordStage = {
        param([string] $Name, [hashtable] $Extra = @{})
        if ($whatIf) {
            return
        }
        $values = @{}
        if (-not $context.OpenStage) {
            $values['Stage'] = $Name
        }
        foreach ($key in $Extra.Keys) {
            $values[$key] = $Extra[$key]
        }
        if ($values.Count -eq 0) {
            return
        }
        try {
            Set-DemoDeploymentState -Config $Config -Value $values -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The stage {0} finished, but its state wasn''t recorded: {1}' -f $Name, $_.Exception.Message)
        }
    }
    $addAll = { param([object[]] $Items) foreach ($item in @($Items)) { if ($null -ne $item) { $results.Add($item) } } }
    $hasStatus = { param([object[]] $Items, [string[]] $Status) @($Items | Where-Object { $null -ne $_ -and [string]$_.status -in $Status }).Count -gt 0 }
    $stageResult = {
        param([string] $Name, [string] $Status, [string] $Message, [string] $Remediation = '')
        $results.Add((New-DemoResult -CheckId ('DEPLOY.STAGE.{0}' -f $Name.ToUpperInvariant()) -Area 'infra' -Target 'subscription' -Status $Status -Message $Message -Remediation $Remediation))
    }
    $ensureContext = {
        if (-not $context.NetworkMode) {
            $configured = if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }
            $context.NetworkMode = if ($configured -in 'public', 'private') { $configured } else { (Resolve-DemoNetworkMode -ConfiguredMode $configured -PolicyUnknown).EffectiveMode }
        }
        if ($null -eq $context.T3UseFreeLimit) {
            $context.T3UseFreeLimit = if ([string]$Config['t3FreeOffer'] -eq 'off') { $false } else { [bool](Get-DemoT3FreeOfferStatus -Config $Config).UseFreeLimit }
        }
    }

    $validated = $false
    # Phase 28 live finding (2026-10-30), as in the parallel path: what's stopped starts while preflight runs, and runs
    # before the first stage that needs it. Running VMs are only read; nothing on a first deployment or a what-if.
    $stoppedStart = $null
    $vmsReady = $false
    $vmStagesInRange = $startIndex -le $stopIndex -and @($stages[$startIndex..$stopIndex] | Where-Object { $_ -ne 'Preflight' }).Count -gt 0
    $existing = -not $whatIf -and [bool](Get-DemoMemberValue -InputObject $state -Name 'Exists')
    if ($existing -and $vmStagesInRange) {
        $stoppedStart = Request-DemoStoppedStart -Config $Config -SkipT4:(-not (Test-DemoT4Enabled -Config $Config)) -Confirm:$false
    }
    # T1's monitoring plugin can stop after a restart, hours after start-demo.ps1 found it running (Phase 28 live finding,
    # 2026-10-30), so a run that ends with the validation and has no Monitoring stage checks it once the VMs run.
    $inRange = { param([string] $Name) $position = [array]::IndexOf($stages, $Name); $position -ge $startIndex -and $position -le $stopIndex }
    $checkT1Monitoring = $existing -and (& $inRange 'Validation') -and -not (& $inRange 'Monitoring')
    # The Insights app's sign-in (2026-11-05), as in the parallel path: when the Fabric stage runs, it starts now, while the
    # person is still at the keyboard, and runs alongside the stages, none of which waits for it; the Fabric stage waits for
    # it until its deadline, right before the app's step (Complete-DemoFabricAppSignIn -Wait). Whether it's needed comes
    # from the read that started before the guard ($signInCheck; 2026-11-06), which a run without the Fabric stage ends.
    $appSignIn = $null
    if (-not $whatIf -and -not $SkipFabric -and (& $inRange 'Fabric')) {
        $appSignIn = Start-DemoFabricAppSignIn -Config $Config -Check $signInCheck -Confirm:$false
        & $addAll @(Complete-DemoFabricAppSignIn -SignIn $appSignIn)
    }
    else {
        Stop-DemoRayfinSignInStatus -Status $signInCheck
    }
    # -Sequential records only its stage, never a track, so once preflight passes, the records of the parallel tracks whose
    # steps this run does again are lowered (all of them from preflight): a later parallel -Resume then runs those steps
    # again instead of trusting an earlier run's record (Get-DemoTrackRecordReset; Phase 28 live finding, 2026-10-30).
    $trackReset = @{}
    if (-not $whatIf -and $startIndex -le $stopIndex) {
        $trackPlan = Resolve-DemoTrackPlan -FromStage $stages[$startIndex] -StopAfter $stages[$stopIndex] -SkipFabric:$SkipFabric -SkipT4:(-not (Test-DemoT4Enabled -Config $Config))
        $trackReset = Get-DemoTrackRecordReset -Plan $trackPlan -State $state -FreshStart:($startIndex -eq 0)
    }
    for ($index = $startIndex; $index -le $stopIndex; $index++) {
        $stage = $stages[$index]
        Write-DemoLog -Message ('Stage {0} of {1}: {2}.' -f ($index + 1), $stages.Count, $stage)
        if ($stage -ne 'Preflight' -and -not $vmsReady) {
            $vmsReady = $true
            if ($trackReset.Count -gt 0) {
                try {
                    Set-DemoDeploymentState -Config $Config -Value $trackReset -Confirm:$false
                    Write-DemoLog -Message ('The track records an earlier run left were reset ({0}), so a later resume can''t skip a step this run doesn''t finish.' -f ((@($trackReset.Keys | Sort-Object) | ForEach-Object { $_ -replace '^Track', '' }) -join ', '))
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('The track records an earlier run left couldn''t be reset, so a later resume could skip a step this run doesn''t finish: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
                }
            }
            if ($null -ne $stoppedStart) {
                $started = @(Wait-DemoStoppedStart -Config $Config -Request $stoppedStart -ActivityProfile $activity)
                & $addAll $started
                if (@($started | Where-Object { [string]$_.checkId -eq 'DEPLOY.VMSTART' -and [string]$_.status -eq 'Fail' }).Count -gt 0) {
                    return (& $finishEarly)
                }
                # A VM that was already running may still serve an earlier run's incidents: its targets get the interim
                # baseline before this run's Run Commands reach it, and the switch at the end brings the profile back.
                # One this run started got it as soon as it ran (Wait-DemoStoppedStart; review of PR 16, 2026-11-04).
                $alreadyRunning = Get-DemoMemberValue -InputObject $stoppedStart -Name 'Running'
                Invoke-DemoActivityQuiet -Config $Config -ActivityProfile $activity -VmName @($alreadyRunning) -RequestedBy 'deploy'
            }
            if ($checkT1Monitoring) {
                $occasion = if ($null -ne $stoppedStart -and $stoppedStart.Vms.Contains('sqlvm01')) { 'the start' } else { 'the deployment' }
                $results.Add((Invoke-DemoT1MonitoringCheck -Config $Config -Occasion $occasion))
            }
        }
        # A stage that can leave a VM on the interim baseline: the loaders can install the runner, which then sets it, and
        # T3, T4, Activity, and T2 set it. The run switches that VM at its end (2026-11-03).
        if ($switchTo -and -not $whatIf) {
            switch ($stage) {
                'Bootstraps' { foreach ($vm in $runnerVms) { Register-DemoActivitySwitch -VmName $vm } }
                { $_ -in 'T3', 'T4', 'Activity' } { Register-DemoActivitySwitch -VmName 'sqlvm01' }
                'T2' { if ($hostVm -eq 'archost01') { Register-DemoActivitySwitch -VmName 'archost01' } }
            }
        }
        switch ($stage) {
            'Preflight' {
                $preflight = @(Invoke-DemoPreflight -Config $Config -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours -SkipProviderRegistration:$whatIf -SkipRunner:$SkipRunner)
                & $addAll $preflight
                if (& $hasStatus $preflight 'Fail') {
                    & $stageResult 'Preflight' 'Fail' 'Preflight has at least one Fail, so nothing was deployed.' 'Fix each Fail above (its remediation says how), then run deploy.ps1 again.'
                    if ($null -ne $stoppedStart -and @($stoppedStart.Requested).Count -gt 0) {
                        # What this run asked to start keeps running, and billing (ADR 0016), until a stop.
                        $results.Add((New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('This run started {0} while preflight ran; it keeps running until ./scripts/stop-demo.ps1 or the nightly auto-shutdown.' -f (@($stoppedStart.Requested) -join ' and ')) -Evidence ([ordered]@{ vms = @($stoppedStart.Requested); started = @($stoppedStart.Requested); notRunning = @(); afterPreflightFail = $true }) -Remediation 'Fix the preflight Fail, then run ./scripts/deploy.ps1 again; or run ./scripts/stop-demo.ps1 to stop the VMs now.'))
                    }
                    return (& $finishEarly)
                }
                $pick = { param([string] $CheckId, [string] $Key) $item = $preflight | Where-Object { $_.checkId -eq $CheckId } | Select-Object -First 1; Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'evidence') -Name $Key }
                $mode = [string](& $pick 'PREFLIGHT.POLICY.SQLPUBLIC' 'effectiveNetworkMode')
                if ($mode -in 'public', 'private') {
                    $context.NetworkMode = $mode
                }
                $free = & $pick 'PREFLIGHT.T3.FREEOFFER' 'useFreeLimit'
                if ($null -ne $free) {
                    $context.T3UseFreeLimit = [bool]$free
                }
                $group = [string](& $pick 'PREFLIGHT.P6.GROUP' 'groupDisplayName')
                if ($group) {
                    $context.T3AdminGroupName = $group
                }
                # Whether a policy needs a new T5's private endpoint (2026-11-21, ADR 0027), for the template step.
                $context.T5Policy = ($preflight | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'PREFLIGHT.POLICY.COSMOSPUBLIC' } | Select-Object -First 1 | ForEach-Object { $_.evidence })
                # Where T4's fallback starts (Phase 28 and its follow-up), as in the parallel path.
                $context.T4StartSku = Select-DemoT4StartSku -Sku @(foreach ($checkId in 'PREFLIGHT.T4.SKU', 'PREFLIGHT.T4.CAPABILITY', 'PREFLIGHT.T4.FALLBACK') { [string](& $pick $checkId 'startSku') }) -Order ([string[]]@(@('') + @(Get-DemoT4FallbackOrder -Config $Config)))
                & $ensureContext
                & $stageResult 'Preflight' 'Pass' (Get-DemoPreflightPassText -NetworkMode ([string]$context.NetworkMode) -T3UseFreeLimit ([bool]$context.T3UseFreeLimit))
            }
            'Infrastructure' {
                & $ensureContext
                $deployArguments = @{
                    Config                  = $Config
                    Action                  = $(if ($whatIf) { 'WhatIf' } else { 'Create' })
                    NetworkMode             = $context.NetworkMode
                    T3UseFreeLimit          = [bool]$context.T3UseFreeLimit
                    T3AdminGroupDisplayName = [string]$context.T3AdminGroupName
                    # An existing T4 whose size the configuration doesn't set moves to the default (2026-11-04, ADR 0019).
                    ScaleT4                 = $true
                    # The wait for a T4 server Azure refused shows on the status page (2026-11-09).
                    ProgressPath            = $ProgressPath
                    # A new T5's private endpoint, only when a policy needs it (2026-11-21, ADR 0027).
                    T5Policy                = $context.T5Policy
                }
                if ($context.T4StartSku) {
                    $deployArguments['T4StartSku'] = $context.T4StartSku
                }
                if ($startIndex -gt 0) {
                    # Without preflight's cost checks, T4 that doesn't exist yet is priced before it's created (#26, 2026-11-17).
                    $deployArguments['PriceT4Creation'] = $true
                }
                if (-not $whatIf -and (Test-DemoT4Enabled -Config $Config) -and @($results | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.START' -and [string]$_.status -eq 'Pass' }).Count -eq 0) {
                    # A stopped T4 rejects the template's update, so it starts first (Phase 24, ADR 0019), unless this run
                    # already started it.
                    $t4Start = Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 20 -CheckPrefix DEPLOY
                    if ($t4Start.status -ne 'Not selected') {
                        $results.Add($t4Start)
                    }
                }
                # A redeployment keeps the loaders' current settings, so it doesn't start new bootstrap runs.
                if ($state.BundleSha256 -and @($vmNames | Where-Object { $_ -notin $state.BundleSentTo }).Count -eq 0) {
                    $deployArguments['BootstrapBundleSha256'] = $state.BundleSha256
                    $deployArguments['BootstrapChunkCount'] = $state.BundleChunkCount
                    if ($state.RunnerSha256 -and @($runnerVms | Where-Object { $_ -notin $state.RunnerSentTo }).Count -eq 0) {
                        $deployArguments['WorkloadRunnerSha256'] = $state.RunnerSha256
                        $deployArguments['WorkloadRunnerChunkCount'] = $state.RunnerChunkCount
                    }
                }
                $deployment = Invoke-DemoTemplateDeployment @deployArguments
                & $addAll $deployment.Results
                if ($whatIf) {
                    & $stageResult 'Infrastructure' 'Not selected' 'What if: the template''s what-if ran; nothing was deployed, and later stages were skipped.'
                    # Nor is the history report's snapshot taken, which a deployment takes at its end (2026-11-06).
                    $results.Add((Invoke-DemoHistorySnapshotStep -Config $Config -WhatIfRun -SkipFabric:$SkipFabric -ProgressPath $ProgressPath))
                    return (& $finishEarly)
                }
                if (-not $deployment.Succeeded) {
                    & $stageResult 'Infrastructure' 'Fail' 'The template deployment failed, so the later stages didn''t run.' 'Fix the cause in DEPLOY.TEMPLATE, then run deploy.ps1 -Resume.'
                    return (& $finishEarly)
                }
                $context.T3UseFreeLimit = [bool]$deployment.T3UseFreeLimit
                # What T4 got (the fallback can change its size or leave it out): the later stages, the Bootstraps stage's
                # template included, keep it (Phase 28 follow-up).
                $deployedT4 = Get-DemoMemberValue -InputObject $deployment -Name 'T4Enabled'
                if ($null -ne $deployedT4) {
                    $deployedSku = [string](Get-DemoMemberValue -InputObject $deployment -Name 'T4SkuName')
                    if ([bool]$deployedT4 -ne (Test-DemoT4Enabled -Config $Config) -or ([bool]$deployedT4 -and $deployedSku -and $deployedSku -ne (Get-DemoT4SkuName -Config $Config))) {
                        $Config = if ([bool]$deployedT4 -and $deployedSku) { Copy-DemoT4Config -Config $Config -Source deployed -SkuName $deployedSku } else { Copy-DemoT4Config -Config $Config -Source deployed -Off }
                    }
                }
                # T5 left out because Azure didn't create its account (review, 2026-11-19): the later stages go on without
                # it, the Bootstraps stage's template included, and its rows say why.
                $t5LeftOutText = ''
                $deployedT5 = Get-DemoMemberValue -InputObject $deployment -Name 'T5Enabled'
                if ($null -ne $deployedT5 -and -not [bool]$deployedT5 -and (Test-DemoT5Enabled -Config $Config)) {
                    $t5LeftOutText = [string](Get-DemoMemberValue -InputObject $deployment -Name 'T5LeftOut')
                    $Config = Copy-DemoT5OffConfig -Config $Config -Reason $t5LeftOutText
                    $t5Warning = @($results | Where-Object { [string]$_.checkId -eq 'DEPLOY.T5' }) | Select-Object -Last 1
                    Set-DemoProgressStep -Path $ProgressPath -Id 'T5.Checks', 'T5.Telemetry' -State 'Skipped' -Status 'Warning' -Message $(if ($null -ne $t5Warning) { [string]$t5Warning.message } else { 'T5 is left out of this run: Azure didn''t create its account.' })
                }
                & $recordStage 'Infrastructure' @{ NetworkMode = $context.NetworkMode; T3UseFreeLimit = [bool]$context.T3UseFreeLimit; T3AdminGroupName = [string]$context.T3AdminGroupName }
                $t4NoteValue = [string](Get-DemoMemberValue -InputObject $deployment -Name 'T4Note')
                # T4 created over a cost ceiling, or without a price, by a run without preflight (#26): the stage is a Warning.
                $deploymentResults = Get-DemoMemberValue -InputObject $deployment -Name 'Results'
                $overCeiling = @(@($deploymentResults) | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'DEPLOY.T4.SIZE' -and [string](Get-DemoMemberValue -InputObject $_.evidence -Name 'outcome') -eq 'Create' }).Count -gt 0
                & $stageResult 'Infrastructure' $(if ($overCeiling -or $t5LeftOutText) { 'Warning' } else { 'Pass' }) ((@($(if ($t4NoteValue) { 'The infrastructure is deployed. ' + $t4NoteValue } else { 'The infrastructure is deployed.' }), $(if ($t5LeftOutText) { 'T5 is left out of this run: Azure didn''t create its account (DEPLOY.T5 says why, with the fix).' })) | Where-Object { $_ }) -join ' ')
                if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
                    # Opt-in, and only start-demo.ps1 -Interactive needs it, so a vault Fail is reported (it
                    # counts in DEPLOY.SUMMARY and the exit code) without stopping the deployment.
                    & $addAll @(Initialize-DemoKeyVault -Config $Config -Confirm:$false)
                }
                # The nightly safety stop (ADR 0024), part of every deployment; its problems are Warnings, never a Fail.
                $safetyResults = @(Invoke-DemoSafetyStopSetup -Config $Config -ConfigPath $ConfigPath -Confirm:$false)
                & $addAll $safetyResults
                # Preflight counted this safety stop (2026-11-19, option 2): when its setup didn't put it in place, the worst case
                # without it, on the console and the Infrastructure row (DEPLOY.COST.T4RESTART).
                $planResult = New-DemoSafetyStopPlanResult -Result $results.ToArray() -SetupResult $safetyResults -Config $Config -ConfigPath $ConfigPath
                if ($null -ne $planResult) {
                    $results.Add($planResult)
                    Write-DemoLog -Level Warning -Message ('{0} {1}' -f $planResult.message, $planResult.remediation)
                    Add-DemoProgressStepNote -Path $ProgressPath -Id 'Infrastructure' -Status 'Warning' -Note ('{0} {1}' -f $planResult.message, $planResult.remediation)
                }
                # The session control's Azure part (ADR 0026), the same way; its notebook comes with the Fabric stage.
                & $addAll @(Invoke-DemoControlDeployStep -Config $Config -ConfigPath $ConfigPath -Part Azure -ProgressPath $ProgressPath -SkipFabric:$SkipFabric)
                # T5's container lifecycle (2026-11-19, ADR 0027), once the control's role and runbooks are up to date: Session
                # when Run all can create the container again, so the stops delete it; a Warning otherwise. Never a Fail.
                & $addAll @(Update-DemoT5ContainerLifecycle -Config $Config -ConfigPath $ConfigPath -ProgressPath $ProgressPath -PriorResult $results.ToArray() -Confirm:$false)
            }
            'Artifacts' {
                $current = Get-DemoDeploymentState -Config $Config
                $bundle = New-DemoBootstrapBundle -Confirm:$false
                $bundleSentTo = @(if ($current.BundleSha256 -eq $bundle.Sha256) { $current.BundleSentTo })
                $bundleChunks = $current.BundleChunkCount
                foreach ($vm in $vmNames) {
                    if ($vm -in $bundleSentTo) {
                        $results.Add((New-DemoResult -CheckId ('DEPLOY.ARTIFACTS.BUNDLE_{0}' -f $vm.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $vm) -Status 'Pass' -Message ('{0} already has bundle {1}.' -f $vm, $bundle.Sha256.Substring(0, 12))))
                        continue
                    }
                    $sent = Send-DemoBootstrapBundle -Config $Config -Bundle $bundle -VmName $vm -ChunkSizeKiB $ChunkSizeKiB -Confirm:$false
                    $bundleSentTo += $vm
                    $bundleChunks = [int]$sent.ChunkCount
                    & $recordStage 'Infrastructure' @{ BundleSha256 = $bundle.Sha256; BundleChunkCount = $bundleChunks; BundleSentTo = $bundleSentTo }
                    $results.Add((New-DemoResult -CheckId ('DEPLOY.ARTIFACTS.BUNDLE_{0}' -f $vm.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $vm) -Status 'Pass' -Message ('Bundle {0} sent to {1} in {2} chunk(s), {3:N0} seconds.' -f $bundle.Sha256.Substring(0, 12), $vm, $sent.ChunkCount, $sent.Seconds)))
                }
                $runnerExtra = @{}
                if ($SkipRunner) {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.ARTIFACTS.RUNNER' -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message 'The workload runner was skipped (-SkipRunner); the WorkloadRunner steps report Not selected.'))
                    $runnerExtra = @{ RunnerSha256 = ''; RunnerChunkCount = 0; RunnerSentTo = @() }
                }
                else {
                    $runner = Publish-DemoWorkloadRunner -Confirm:$false
                    $runnerSentTo = @(if ($current.RunnerSha256 -eq $runner.Sha256) { $current.RunnerSentTo })
                    $runnerChunks = $current.RunnerChunkCount
                    foreach ($vm in $runnerVms) {
                        if ($vm -in $runnerSentTo) {
                            $results.Add((New-DemoResult -CheckId ('DEPLOY.ARTIFACTS.RUNNER_{0}' -f $vm.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $vm) -Status 'Pass' -Message ('{0} already has runner {1}.' -f $vm, $runner.Sha256.Substring(0, 12))))
                            continue
                        }
                        $sent = Send-DemoWorkloadRunner -Config $Config -Runner $runner -VmName $vm -ChunkSizeKiB $ChunkSizeKiB -Confirm:$false
                        $runnerSentTo += $vm
                        $runnerChunks = [int]$sent.ChunkCount
                        & $recordStage 'Infrastructure' @{ RunnerSha256 = $runner.Sha256; RunnerChunkCount = $runnerChunks; RunnerSentTo = $runnerSentTo }
                        $results.Add((New-DemoResult -CheckId ('DEPLOY.ARTIFACTS.RUNNER_{0}' -f $vm.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $vm) -Status 'Pass' -Message ('Runner {0} sent to {1} in {2} chunk(s), {3:N0} seconds.' -f $runner.Sha256.Substring(0, 12), $vm, $sent.ChunkCount, $sent.Seconds)))
                    }
                    $runnerExtra = @{ RunnerSha256 = $runner.Sha256; RunnerChunkCount = $runnerChunks; RunnerSentTo = $runnerSentTo }
                }
                $extra = @{ BundleSha256 = $bundle.Sha256; BundleChunkCount = $bundleChunks; BundleSentTo = $bundleSentTo }
                foreach ($key in $runnerExtra.Keys) {
                    $extra[$key] = $runnerExtra[$key]
                }
                & $recordStage 'Artifacts' $extra
                & $stageResult 'Artifacts' 'Pass' ('Bundle {0} is on {1}.' -f $bundle.Sha256.Substring(0, 12), ($vmNames -join ' and '))
            }
            'Bootstraps' {
                & $ensureContext
                $current = Get-DemoDeploymentState -Config $Config
                if (-not $current.BundleSha256 -or @($vmNames | Where-Object { $_ -notin $current.BundleSentTo }).Count -gt 0) {
                    & $stageResult 'Bootstraps' 'Fail' 'The bootstrap bundle hasn''t reached every VM, so the loaders can''t run.' 'Run deploy.ps1 -FromStage Artifacts.'
                    return (& $finishEarly)
                }
                $deployArguments = @{
                    Config                  = $Config
                    NetworkMode             = $context.NetworkMode
                    T3UseFreeLimit          = [bool]$context.T3UseFreeLimit
                    T3AdminGroupDisplayName = [string]$context.T3AdminGroupName
                    BootstrapBundleSha256   = $current.BundleSha256
                    BootstrapChunkCount     = $current.BundleChunkCount
                    ScaleT4                 = $true
                    ProgressPath            = $ProgressPath
                    T5Policy                = $context.T5Policy
                }
                if ($current.RunnerSha256 -and @($runnerVms | Where-Object { $_ -notin $current.RunnerSentTo }).Count -eq 0) {
                    $deployArguments['WorkloadRunnerSha256'] = $current.RunnerSha256
                    $deployArguments['WorkloadRunnerChunkCount'] = $current.RunnerChunkCount
                }
                $deployment = Invoke-DemoTemplateDeployment @deployArguments
                & $addAll $deployment.Results
                if (-not $deployment.Succeeded) {
                    & $stageResult 'Bootstraps' 'Fail' 'The deployment that adds the loaders failed.' 'Fix the cause in DEPLOY.TEMPLATE, then run deploy.ps1 -Resume.'
                    return (& $finishEarly)
                }
                if (-not $whatIf -and $hostVm -eq 'archost01') {
                    # The host's loader starts a bootstrap generation that builds its guest; until T2 is done, deploy.ps1's
                    # watchdog never restarts the host (Get-DemoHostRestartBlocker, Phase 28 review follow-up).
                    try {
                        Set-DemoDeploymentState -Config $Config -Value @{ T2BuildUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } -Confirm:$false
                    }
                    catch {
                        Write-DemoLog -Level Warning -Message ('The T2 host''s bootstrap generation wasn''t recorded: {0}' -f $_.Exception.Message)
                    }
                }
                $loaders = @(foreach ($vm in $vmNames) { Wait-DemoBootstrapLoader -Config $Config -VmName $vm })
                & $addAll $loaders
                if (& $hasStatus $loaders 'Fail') {
                    & $stageResult 'Bootstraps' 'Fail' 'A bootstrap loader failed.' 'Read its INFRA.BOOTSTRAP.LOADER_* message, fix the cause, then run deploy.ps1 -FromStage Artifacts.'
                    return (& $finishEarly)
                }
                $wait = Wait-DemoVmHealthState -Config $Config -VmName 'sqlvm01' -State @('Ready', 'Failed', 'ManualActionRequired') -MaxPolls ([int][System.Math]::Ceiling($T1WaitMinutes / 5)) -PollSeconds 300
                $t1State = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'state')
                $t1Message = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'message')
                if ($t1State -eq 'Ready') {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T1.READY' -Area 't1' -Target 'T1' -Status 'Pass' -Message ('T1''s bootstrap is Ready: {0}' -f $t1Message)))
                }
                elseif ($t1State -eq 'Failed') {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T1.READY' -Area 't1' -Target 'T1' -Status 'Fail' -Message ('T1''s bootstrap failed: {0}' -f $t1Message) -Remediation 'Read C:\ProgramData\DbHubDemo\logs on sqlvm01 (Get-DemoVmHealth -View Full), fix the cause, then run deploy.ps1 -FromStage Artifacts to start a new bootstrap generation.'))
                    & $stageResult 'Bootstraps' 'Fail' 'T1''s bootstrap failed.'
                    return (& $finishEarly)
                }
                else {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T1.READY' -Area 't1' -Target 'T1' -Status 'Warning' -Message ('T1 isn''t Ready after {0} minutes (state {1}: {2}).' -f $T1WaitMinutes, $t1State, $t1Message) -Remediation 'Run deploy.ps1 -Resume later; the bootstrap keeps converging on its own.'))
                    & $stageResult 'Bootstraps' 'Warning' 'The loaders ran, but T1 isn''t Ready yet, so the run stopped here.' 'Run deploy.ps1 -Resume later.'
                    return (& $finishEarly)
                }
                & $recordStage 'Bootstraps'
                & $stageResult 'Bootstraps' 'Pass' ('The loaders ran on {0}, and T1 is Ready.' -f ($vmNames -join ' and '))
            }
            'T3' {
                & $ensureContext
                $t3Results = [System.Collections.Generic.List[object]]::new()
                $principalId = Get-DemoT1PrincipalId -Config $Config
                $group = Add-DemoT1ToT3AdminGroup -Config $Config -PrincipalId $principalId
                $t3Results.Add($group)
                $results.Add($group)
                if ($group.status -in 'Fail', 'Manual action required') {
                    & $stageResult 'T3' $group.status 'T1 couldn''t join the T3 administrators group (P6), so T3 wasn''t configured.' $group.remediation
                    if ($group.status -eq 'Fail') {
                        return (& $finishEarly)
                    }
                    $context.OpenStage = 'T3'
                    continue
                }
                $setup = Invoke-DemoT3SqlFromT1 -Config $Config -Name Setup
                $t3Results.Add($setup.Result)
                $results.Add($setup.Result)
                if ($setup.Status -eq 'Fail') {
                    & $stageResult 'T3' 'Fail' 'The T3 setup from T1 failed.' 'Read the T3 setup result, fix the cause, then run deploy.ps1 -FromStage T3.'
                    return (& $finishEarly)
                }
                $current = Get-DemoDeploymentState -Config $Config
                if ($current.RunnerSha256) {
                    $enable = Enable-DemoT3Workload -Config $Config -Confirm:$false
                    $t3Results.Add($enable)
                    $results.Add($enable)
                }
                $checks = @(Test-DemoT3 -Config $Config -NetworkMode $context.NetworkMode -T3UseFreeLimit ([bool]$context.T3UseFreeLimit))
                & $addAll $checks
                if (& $hasStatus ($t3Results.ToArray() + $checks) 'Fail') {
                    & $stageResult 'T3' 'Fail' 'A T3 step or check failed.' 'Read the T3 and WORKLOAD.T3 results, fix the cause, then run deploy.ps1 -FromStage T3.'
                    return (& $finishEarly)
                }
                & $recordStage 'T3'
                & $stageResult 'T3' 'Pass' 'T3 is configured from T1 and checked.'
            }
            'T4' {
                # T5 (2026-11-18, ADR 0027), which this stage covers too, as T1's T5 step does in the parallel path: the Cosmos
                # DB account's checks, then T1's access through the runner's warmup. First, so a configuration with t4Enabled
                # false still checks it (review, 2026-11-19). A T5 failure doesn't stop the stage; DONE needs HUB.ESTATE.T5 and
                # METRICS.T5.
                if (Test-DemoT5Enabled -Config $Config) {
                    # The container exists only during a session (2026-11-19): a resumed run skips the template, which creates it.
                    $results.Add((New-DemoT5Container -Config $Config -CheckId 'DEPLOY.T5.CONTAINER' -Confirm:$false))
                    $t5Checks = @(Test-DemoT5 -Config $Config)
                    & $addAll $t5Checks
                    $t5Current = Get-DemoDeploymentState -Config $Config
                    if (-not (& $hasStatus $t5Checks 'Fail') -and $t5Current.RunnerSha256 -and 'sqlvm01' -in $t5Current.RunnerSentTo) {
                        # Through T1's subnet's service endpoint (2026-11-21), the warmup waits for its virtual network rule too.
                        $viaRule = [string](Get-DemoMemberValue -InputObject (@($t5Checks | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'T5.NETWORK' }) | Select-Object -First 1 | ForEach-Object { $_.evidence }) -Name 'path') -eq 'ServiceEndpoint'
                        $results.Add((Invoke-DemoT5WarmUp -Config $Config -ServiceEndpoint:$viaRule))
                    }
                }
                # T4 (Phase 24, ADR 0019): the server's checks, then T1 sets it up through the P6 group (already
                # joined in the T3 stage), then its Azure Monitor metrics. A T4 failure doesn't stop the run.
                if (-not (Test-DemoT4Enabled -Config $Config)) {
                    & $stageResult 'T4' 'Not selected' 'T4 is off in this configuration (t4Enabled is false).'
                    & $recordStage 'T4'
                    continue
                }
                $t4Checks = @(Test-DemoT4 -Config $Config)
                & $addAll $t4Checks
                $current = Get-DemoDeploymentState -Config $Config
                $t4Enable = $null
                if (-not (& $hasStatus $t4Checks 'Fail') -and $current.RunnerSha256) {
                    # A max_connections value the template set waits for a restart (a static parameter); T4 restarts right
                    # before T1 connects (ADR 0019, 2026-11-03).
                    $t4Restart = Invoke-DemoT4PendingRestart -Config $Config
                    if ($null -ne $t4Restart) {
                        $results.Add($t4Restart)
                    }
                    $t4Enable = Enable-DemoT4Workload -Config $Config -Confirm:$false
                    $results.Add($t4Enable)
                }
                $t4State = Get-DemoT4State -Config $Config
                $results.Add((Test-DemoT4MetricFlow -Config $Config -ServerId $t4State.Names.ServerId -State $t4State.State -WaitMinutes ([System.Math]::Min($TelemetryWaitMinutes, 10))))
                # T4's read replica (2026-11-13, ADR 0025), after T4's restart above, as the T4 track creates it; once it's created
                # or isn't supported, the environment has the replica's lifecycle (DbHubT4Replica Session), not after a failure.
                $replicaResults = @(Invoke-DemoT4ReplicaCreate -Config $Config -CheckPrefix DEPLOY)
                & $addAll $replicaResults
                $replicaCreated = @($replicaResults | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.REPLICA' -and [string]$_.status -eq 'Pass' }).Count -gt 0
                if ($replicaCreated -or @($replicaResults | Where-Object { [string]$_.status -eq 'Not supported' }).Count -gt 0) {
                    try {
                        Set-DemoDeploymentState -Config $Config -Value @{ T4Replica = [string](Get-DemoT4ReplicaSetting)['recordValue'] } -Confirm:$false
                    }
                    catch {
                        $results.Add((New-DemoResult -CheckId 'DEPLOY.T4.REPLICA.RECORD' -Area 'infra' -Target 'T4' -Status 'Warning' -Message ('The replica''s record (DbHubT4Replica) wasn''t set on the resource group: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/deploy.ps1 again.'))
                    }
                }
                if ($replicaCreated) {
                    $results.Add((Test-DemoT4ReplicaServer -Config $Config))
                    $results.Add((Test-DemoT4ReplicaEstate -Config $Config -WaitMinutes 5))
                    $results.Add((Test-DemoT4ReplicaMetricFlow -Config $Config -WaitMinutes ([System.Math]::Min($TelemetryWaitMinutes, 10))))
                }
                & $recordStage 'T4'
                if ((& $hasStatus $t4Checks 'Fail') -or ($null -ne $t4Enable -and $t4Enable.status -eq 'Fail')) {
                    & $stageResult 'T4' 'Fail' 'A T4 check or its setup failed; the rest of the deployment continues.' 'Read the T4 and WORKLOAD.T4.ENABLE results, fix the cause, then run deploy.ps1 -FromStage T4.'
                }
                else {
                    & $stageResult 'T4' 'Pass' 'T4 is checked and set up from T1.'
                }
            }
            'Activity' {
                # The VMs don't set the profile at boot unless activityProfileOnBoot is true (R183), so the
                # deployment sets it explicitly; it ends before the next auto-shutdown. A profile with incidents starts as
                # its interim, baseline, until the run's switch (2026-11-03).
                $current = Get-DemoDeploymentState -Config $Config
                $profileName = $activity.Interim
                $skip = if ($current.RunnerSha256) { '' } else { 'No workload runner was deployed (-SkipRunner).' }
                $activityResults = @(foreach ($target in @('T1', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' }) + @(if (Test-DemoT5Enabled -Config $Config) { 'T5' })) {
                        Set-DemoTargetProfile -Config $Config -Target $target -ProfileName $profileName -CheckPrefix 'DEPLOY' -SkipReason $skip -RequestedBy 'deploy' -SwitchTo $switchTo
                    })
                & $addAll $activityResults
                & $recordStage 'Activity'
                if (& $hasStatus $activityResults 'Warning') {
                    & $stageResult 'Activity' 'Warning' ('The activity profile {0} couldn''t be set everywhere; the deployment continues.' -f $profileName) 'Set it with demo-control.yml or ./scripts/start-demo.ps1 -ActivityProfile <name>.'
                }
                else {
                    & $stageResult 'Activity' 'Pass' ('T1 and T3 run the {0} activity profile until the next auto-shutdown{1}; a VM that starts later sets it again only when activityProfileOnBoot is true.' -f $profileName, $(if ($switchTo) { ', and this run switches them to {0} at its end' -f $switchTo } else { '' }))
                }
            }
            'Monitoring' {
                # A NotRunning plugin gets the short grace, then the agent's restart, and T1.SQLVM.MONITORING is read
                # again once the restart has run, so a Fail there stops the stage with its own cause
                # (Invoke-DemoSqlVmMonitoringWait; live, 2026-10-27 and 2026-10-30).
                $monitoringResults = @(Invoke-DemoSqlVmMonitoringWait -Config $Config -WaitMinutes $MonitoringWaitMinutes)
                foreach ($item in $monitoringResults) {
                    $results.Add($item)
                }
                # A repair of the SqlIaasExtension, when there was one, comes first (2026-11-16); its Fail has its own fix.
                $monitoringFail = @($monitoringResults | Where-Object { [string]$_.status -eq 'Fail' } | Select-Object -First 1)
                if ($monitoringFail.Count -gt 0) {
                    & $stageResult 'Monitoring' 'Fail' 'T1 performance monitoring couldn''t be turned on.' $monitoringFail[0].remediation
                    return (& $finishEarly)
                }
                & $recordStage 'Monitoring'
                & $stageResult 'Monitoring' 'Pass' ('T1 performance monitoring: {0}.' -f $monitoringResults[-1].status)
            }
            'T2' {
                $arcArguments = @{ Config = $Config; WaitForHostMinutes = $T2WaitMinutes; WaitMinutes = 15; Confirm = $false }
                $plainKey = [string]$env:DBHUB_SQL_PRODUCT_KEY
                $secureKey = $null
                if ($plainKey) {
                    Remove-Item -LiteralPath 'Env:DBHUB_SQL_PRODUCT_KEY' -ErrorAction SilentlyContinue
                    Register-DemoSecret -Value $plainKey.Trim()
                    $secureKey = [System.Security.SecureString]::new()
                    foreach ($character in $plainKey.Trim().ToCharArray()) {
                        $secureKey.AppendChar($character)
                    }
                    $secureKey.MakeReadOnly()
                    $plainKey = $null
                    $arcArguments['ProductKey'] = $secureKey
                }
                try {
                    $arc = @(Invoke-DemoArcConfiguration @arcArguments)
                }
                finally {
                    if ($null -ne $secureKey) {
                        $secureKey.Dispose()
                    }
                }
                & $addAll $arc
                # What an earlier guided stop or session left open (setup can finish after a Ctrl+C at a parallel run's guided
                # stop, which skipped its cleanup) goes, whatever the Arc configuration found, so DONE never comes with it
                # (Phase 28 review).
                & $addAll @(Clear-DemoGuidedStopLeftover -Config $Config)
                if (& $hasStatus $arc 'Fail') {
                    & $stageResult 'T2' 'Fail' 'T2''s Arc onboarding or configuration failed.' 'Read the T2.* results, fix the cause, then run deploy.ps1 -FromStage T2.'
                    return (& $finishEarly)
                }
                if (& $hasStatus $arc 'Manual action required') {
                    & $stageResult 'T2' 'Manual action required' 'T2 waits for a manual step (see the T2 results for the exact steps); the later stages still run.' 'Do the step, then run deploy.ps1 -Resume: it continues with T2.'
                    $context.OpenStage = 'T2'
                    continue
                }
                if (@($arc | Where-Object { [string]$_.checkId -eq 'T2.ARC.CONNECTED' -and $_.status -eq 'Pass' }).Count -eq 0) {
                    & $stageResult 'T2' 'Warning' ('T2''s guest isn''t connected to Azure Arc yet: the host didn''t reach the onboarding step within {0} minutes.' -f $T2WaitMinutes) 'Run deploy.ps1 -Resume later: it continues with T2.'
                    $context.OpenStage = 'T2'
                    continue
                }
                # Set-DemoArcSqlConfiguration already converged the extension, license type, and monitoring
                # (T2.ARC.MONITORING), as configure-monitoring.ps1 -Target T2 would.
                $context.T2Complete = $true
                $current = Get-DemoDeploymentState -Config $Config
                $t2Skip = if (-not $current.RunnerSha256 -or 'archost01' -notin $current.RunnerSentTo) { 'T2 has no workload runner (-SkipRunner, or it wasn''t sent to archost01).' } else { '' }
                $results.Add((Set-DemoTargetProfile -Config $Config -Target 'T2' -ProfileName $activity.Interim -CheckPrefix 'DEPLOY' -SkipReason $t2Skip -RequestedBy 'deploy' -SwitchTo $switchTo))
                # The guest build is done, so the bootstrap generation's record goes (Get-DemoHostRestartBlocker).
                & $recordStage 'T2' @{ T2BuildUtc = '' }
                & $stageResult 'T2' 'Pass' 'T2 is onboarded to Azure Arc, configured, and monitored.'
            }
            'Fabric' {
                $importNotebooks = $ImportNotebooks -or [bool](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'importNotebooks')
                if ($SkipFabric) {
                    & $stageResult 'Fabric' 'Not selected' 'The Fabric stage was skipped (-SkipFabric).'
                    continue
                }
                # The notebooks, the Hub checklist, and the Real-Time Dashboard, then the history semantic model and report, as the
                # parallel Fabric track imports them (review follow-up): DONE's FABRIC.ITEMS.REQUIRED looks for all of them, and a
                # new workspace has none. Then the Insights app, part of every deployment (2026-11-05), whose step never stops
                # the stage or keeps the run from DONE (Invoke-DemoInsightsAppStep).
                $fabricContent = Get-DemoFabricContentSha256
                $fabric = @(Invoke-DemoFabricStage -Config $Config -ConfigPath $ConfigPath -ImportNotebooks:$importNotebooks -KeepEditedNotebooks -ImportDashboard)
                & $addAll $fabric
                if (& $hasStatus $fabric 'Fail') {
                    & $stageResult 'Fabric' 'Fail' 'A Fabric or Database Hub check failed.' 'Read the HUB.* and FABRIC.* results, fix the cause, then run deploy.ps1 -FromStage Fabric.'
                    return (& $finishEarly)
                }
                $powerBI = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $ConfigPath)
                & $addAll $powerBI
                if (& $hasStatus $powerBI 'Fail') {
                    & $stageResult 'Fabric' 'Fail' 'The history semantic model or report failed.' 'Read the FABRIC.* results, fix the cause, then run deploy.ps1 -FromStage Fabric.'
                    return (& $finishEarly)
                }
                # The session control's notebook (ADR 0026), now that the workspace exists, and before the Insights app, whose
                # Manage runs it (ADR 0029): the app's step reads its IDs, so a first deployment's Manage has them
                # (2026-11-19, the final tests' net-new run). Never a Fail.
                & $addAll @(Invoke-DemoControlDeployStep -Config $Config -ConfigPath $ConfigPath -Part Fabric -ProgressPath $ProgressPath -PriorResult $results.ToArray())
                & $addAll @(Complete-DemoFabricAppSignIn -SignIn $appSignIn -Wait)
                $app = @(Invoke-DemoInsightsAppStep -Config $Config -ConfigPath $ConfigPath -FabricResult $fabric)
                & $addAll $app
                # The app's step proves whether the CLI was signed in, so its records settle a sign-in Warning they contradict
                # (2026-11-06 live finding).
                $null = Update-DemoFabricAppSignInFromApp -SignIn $appSignIn -AppResult $app -Results $results
                $appSummary = Get-DemoInsightsAppSummary -Result $app
                $appText = if ($null -ne $appSummary -and [bool]$appSummary.Failed) { '; the Insights app wasn''t created or doesn''t work, which doesn''t block DONE (the summary says why)' } elseif ($null -ne $appSummary -and [bool]$appSummary.Deployed) { ', with the Insights app' } else { '' }
                # What the stage published, once the app is this version's too (2026-11-16, Get-DemoFabricContentReopen), and
                # what the app's Manage has (2026-11-19).
                $published = Get-DemoInsightsAppManageRecord -Result $app
                if ($null -ne $appSummary -and [string]$appSummary.State -eq 'Done') {
                    $published['FabricSha256'] = $fabricContent
                }
                & $recordStage 'Fabric' $published
                & $stageResult 'Fabric' 'Pass' ('The Database Hub checklist ran, the Real-Time Dashboard and the history model and report are in the workspace{0}{1}.' -f $(if ($importNotebooks) { ', and the notebooks were imported or updated' } else { '' }), $appText)
            }
            'Validation' {
                $targets = @('T1', 'T3')
                if ($context.T2Complete) {
                    $targets = @('T1', 'T2', 'T3')
                }
                # A target whose telemetry didn't come gets its monitoring checked, and its telemetry once more, unless a
                # stage is open, so the run isn't DONE anyway (Invoke-DemoTelemetryCheck; Phase 28 live finding).
                & $addAll @(Invoke-DemoTelemetryCheck -Config $Config -Target $targets -WaitMinutes $TelemetryWaitMinutes -ProgressPath $ProgressPath -ProgressStepId 'Validation' -NoRecovery:([bool]$context.OpenStage))
                # T1's AssociatedServices step must have converged: unified inventory lists only the engine (a Fail).
                $results.Add((Test-DemoSqlVmAssociatedService -Config $Config -WaitMinutes 10 -ListedStatus 'Fail'))
                $current = Get-DemoDeploymentState -Config $Config
                if ($current.RunnerSha256) {
                    $status = Invoke-DemoWorkloadCommand -Config $Config -Target 'T1' -ArgumentList 'status', '--json' -TimeoutSeconds 300 -Confirm:$false
                    $results.Add($status.Result)
                }
                # The Database Agent loop's one manual step, once per deployment (2026-11-18): under "Please confirm"
                # (HUB.AGENT.T3), as in the parallel path.
                $agentItem = Get-DemoT3AgentSetupItem -Config $Config -ServerName ('azuresql01-{0}' -f [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $current -Name 'Tags') -Name 'deploymentId'))
                if ($null -ne $agentItem) {
                    $results.Add($agentItem)
                }
                & $recordStage 'Validation'
                & $stageResult 'Validation' 'Pass' ('The validation ran for {0}.' -f ($targets -join ', '))
                $validated = $true
            }
        }
    }

    # DONE's read-only checks, as the parallel path runs them once every track finished (Phase 28, review finding 4):
    # after this run's validation, with no stage open and nothing failed, each DONE requirement the results don't show
    # passing yet (Database Hub's estate, T4's metrics, T2's PAYG and monitoring, the Fabric items) is checked, so a
    # sequential run is judged by the same requirements and can end DONE.
    $requirement = @()
    $doneChecked = $false
    if ($validated -and -not $context.OpenStage -and -not (& $hasStatus $results.ToArray() 'Fail')) {
        $current = Get-DemoDeploymentState -Config $Config
        $installMode = if ([string]$Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'JumpstartImage' }
        $requirement = Get-DemoDoneRequirement -InstallMode $installMode -SkipFabric:$SkipFabric -SkipT5:(-not (Test-DemoT5Enabled -Config $Config))
        & $addAll @(Invoke-DemoDoneGate -Config $Config -Result $results.ToArray() -Requirement $requirement -TelemetryWaitMinutes $TelemetryWaitMinutes -ProgressPath $ProgressPath)
        $doneChecked = $true
    }

    # The switch (2026-11-03): DONE's checks have read what they need, so this run's own Run Commands are done.
    & $switchActivity

    # The history report's snapshot (2026-11-06), as in the parallel path: after DONE's telemetry checks and the switch,
    # NB_DatabaseHub_LiveActivity runs once, analyze-only, and the history model is refreshed. Never a Fail.
    if ($validated) {
        $results.Add((Invoke-DemoHistorySnapshotStep -Config $Config -Result $results.ToArray() -Requirement $requirement -DoneChecked:$doneChecked -SkipFabric:$SkipFabric -ActivityProfile $activity -ProgressPath $ProgressPath))
    }
    # T5's container lifecycle once more, now that the session control is done (2026-11-19, F14), as in the parallel path:
    # only when this run granted the control's role and the first check, right after the grant, didn't see it.
    if (-not $whatIf) {
        $null = Invoke-DemoT5LifecycleRecheck -Config $Config -ConfigPath $ConfigPath -ProgressPath $ProgressPath -Results $results
    }
    # T4's read replica (2026-11-16), as in the parallel path: DONE's checks and the history snapshot have read it, so it's
    # deleted unless a session uses it now. Never a Fail.
    if (-not $whatIf) {
        $results.Add((Invoke-DemoT4ReplicaDeployEnd -Config $Config -ProgressPath $ProgressPath -ChecksRan $doneChecked -Confirm:$false))
    }

    $all = $results.ToArray()
    # Phase 28 live finding (2026-10-30): what only a person can confirm is listed once each, apart from what needs you.
    $summary = Get-DemoDeploySummary -Result $all -FinishedText 'Every stage that ran finished.'
    $results.Add((New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status $summary.Status -Message $summary.Message -Evidence $summary.Evidence))
    return $results.ToArray()
}
