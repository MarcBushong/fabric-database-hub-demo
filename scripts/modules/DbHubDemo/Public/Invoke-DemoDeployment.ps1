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
       Fail stops here. It resolves the network mode, the T3 free offer, and the P6 group's name.
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
    6. Activity: the configured activityProfile on T1 and T3 until the next auto-shutdown (Set-DemoTargetProfile).
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
       report), as the parallel Fabric track imports them (Phase 28 review follow-up); the optional Insights app stays
       configure-fabric-app.ps1's. Not selected with -SkipFabric.
    10. Validation: Test-DemoHubTelemetry for each ready target, the runner's status on T1, and a summary that
        lists every Manual action required item with its exact steps. A target whose telemetry didn't come gets its
        monitoring checked, and its telemetry once more, before the run is judged (Invoke-DemoTelemetryCheck; Phase 28
        live finding, 2026-10-30). Since Phase 28 (review finding 4), with no
        stage open and nothing failed, DONE's read-only checks follow (Invoke-DemoDoneGate: Database Hub's estate,
        T4's metrics, T2's PAYG and monitoring, and the Fabric items), so deploy.ps1 -Sequential can end DONE.

    A Fail stops the run, and nothing after it runs. Manual action required never stops it and is never
    hidden: it's in the results and in DEPLOY.SUMMARY. Deployment success alone is never Pass (ADR 0012).
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
    validation and DEPLOY.TIMING. deploy.ps1 passes it unless -Sequential.

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

    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Sign in yourself (az login --tenant <tenantId>) and select nothing else: the scripts pass --subscription on every call.'))
        return $results.ToArray()
    }

    $state = Get-DemoDeploymentState -Config $Config
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

    # Values later stages need; preflight resolves them, and a resumed run reads them from the state.
    $context = @{
        NetworkMode      = $state.NetworkMode
        T3UseFreeLimit   = $state.T3UseFreeLimit
        T3AdminGroupName = $state.T3AdminGroupName
        T2Complete       = (Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T2')
        OpenStage        = ''
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
    for ($index = $startIndex; $index -le $stopIndex; $index++) {
        $stage = $stages[$index]
        Write-DemoLog -Message ('Stage {0} of {1}: {2}.' -f ($index + 1), $stages.Count, $stage)
        if ($stage -ne 'Preflight' -and -not $vmsReady) {
            $vmsReady = $true
            if ($null -ne $stoppedStart) {
                $started = @(Wait-DemoStoppedStart -Config $Config -Request $stoppedStart)
                & $addAll $started
                if (@($started | Where-Object { [string]$_.checkId -eq 'DEPLOY.VMSTART' -and [string]$_.status -eq 'Fail' }).Count -gt 0) {
                    return $results.ToArray()
                }
            }
            if ($checkT1Monitoring) {
                $occasion = if ($null -ne $stoppedStart -and $stoppedStart.Vms.Contains('sqlvm01')) { 'the start' } else { 'the deployment' }
                $results.Add((Invoke-DemoT1MonitoringCheck -Config $Config -Occasion $occasion))
            }
        }
        switch ($stage) {
            'Preflight' {
                $preflight = @(Invoke-DemoPreflight -Config $Config -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours -SkipProviderRegistration:$whatIf)
                & $addAll $preflight
                if (& $hasStatus $preflight 'Fail') {
                    & $stageResult 'Preflight' 'Fail' 'Preflight has at least one Fail, so nothing was deployed.' 'Fix each Fail above (its remediation says how), then run deploy.ps1 again.'
                    if ($null -ne $stoppedStart -and @($stoppedStart.Requested).Count -gt 0) {
                        # What this run asked to start keeps running, and billing (ADR 0016), until a stop.
                        $results.Add((New-DemoResult -CheckId 'DEPLOY.VMSTART' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('This run started {0} while preflight ran; it keeps running until ./scripts/stop-demo.ps1 or the nightly auto-shutdown.' -f (@($stoppedStart.Requested) -join ' and ')) -Evidence ([ordered]@{ vms = @($stoppedStart.Requested); notRunning = @(); afterPreflightFail = $true }) -Remediation 'Fix the preflight Fail, then run ./scripts/deploy.ps1 again; or run ./scripts/stop-demo.ps1 to stop the VMs now.'))
                    }
                    return $results.ToArray()
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
                    return $results.ToArray()
                }
                if (-not $deployment.Succeeded) {
                    & $stageResult 'Infrastructure' 'Fail' 'The template deployment failed, so the later stages didn''t run.' 'Fix the cause in DEPLOY.TEMPLATE, then run deploy.ps1 -Resume.'
                    return $results.ToArray()
                }
                $context.T3UseFreeLimit = [bool]$deployment.T3UseFreeLimit
                & $recordStage 'Infrastructure' @{ NetworkMode = $context.NetworkMode; T3UseFreeLimit = [bool]$context.T3UseFreeLimit; T3AdminGroupName = [string]$context.T3AdminGroupName }
                & $stageResult 'Infrastructure' 'Pass' 'The infrastructure is deployed.'
                if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
                    # Opt-in, and only start-demo.ps1 -Interactive needs it, so a vault Fail is reported (it
                    # counts in DEPLOY.SUMMARY and the exit code) without stopping the deployment.
                    & $addAll @(Initialize-DemoKeyVault -Config $Config -Confirm:$false)
                }
                # The on-demand activity control's A1 (ADR 0020): a redeploy deleted it with the group. Granted again only
                # with assignRoles; otherwise, or when it fails, Manual action required with the -GrantRole command.
                & $addAll @(Invoke-DemoActivityControlRegrant -Config $Config -ConfigPath $ConfigPath -Confirm:$false)
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
                    return $results.ToArray()
                }
                $deployArguments = @{
                    Config                  = $Config
                    NetworkMode             = $context.NetworkMode
                    T3UseFreeLimit          = [bool]$context.T3UseFreeLimit
                    T3AdminGroupDisplayName = [string]$context.T3AdminGroupName
                    BootstrapBundleSha256   = $current.BundleSha256
                    BootstrapChunkCount     = $current.BundleChunkCount
                }
                if ($current.RunnerSha256 -and @($runnerVms | Where-Object { $_ -notin $current.RunnerSentTo }).Count -eq 0) {
                    $deployArguments['WorkloadRunnerSha256'] = $current.RunnerSha256
                    $deployArguments['WorkloadRunnerChunkCount'] = $current.RunnerChunkCount
                }
                $deployment = Invoke-DemoTemplateDeployment @deployArguments
                & $addAll $deployment.Results
                if (-not $deployment.Succeeded) {
                    & $stageResult 'Bootstraps' 'Fail' 'The deployment that adds the loaders failed.' 'Fix the cause in DEPLOY.TEMPLATE, then run deploy.ps1 -Resume.'
                    return $results.ToArray()
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
                    return $results.ToArray()
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
                    return $results.ToArray()
                }
                else {
                    $results.Add((New-DemoResult -CheckId 'DEPLOY.T1.READY' -Area 't1' -Target 'T1' -Status 'Warning' -Message ('T1 isn''t Ready after {0} minutes (state {1}: {2}).' -f $T1WaitMinutes, $t1State, $t1Message) -Remediation 'Run deploy.ps1 -Resume later; the bootstrap keeps converging on its own.'))
                    & $stageResult 'Bootstraps' 'Warning' 'The loaders ran, but T1 isn''t Ready yet, so the run stopped here.' 'Run deploy.ps1 -Resume later.'
                    return $results.ToArray()
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
                        return $results.ToArray()
                    }
                    $context.OpenStage = 'T3'
                    continue
                }
                $setup = Invoke-DemoT3SqlFromT1 -Config $Config -Name Setup
                $t3Results.Add($setup.Result)
                $results.Add($setup.Result)
                if ($setup.Status -eq 'Fail') {
                    & $stageResult 'T3' 'Fail' 'The T3 setup from T1 failed.' 'Read the T3 setup result, fix the cause, then run deploy.ps1 -FromStage T3.'
                    return $results.ToArray()
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
                    return $results.ToArray()
                }
                & $recordStage 'T3'
                & $stageResult 'T3' 'Pass' 'T3 is configured from T1 and checked.'
            }
            'T4' {
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
                    $t4Enable = Enable-DemoT4Workload -Config $Config -Confirm:$false
                    $results.Add($t4Enable)
                }
                $t4State = Get-DemoT4State -Config $Config
                $results.Add((Test-DemoT4MetricFlow -Config $Config -ServerId $t4State.Names.ServerId -State $t4State.State -WaitMinutes ([System.Math]::Min($TelemetryWaitMinutes, 10))))
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
                # deployment sets it explicitly; it ends before the next auto-shutdown.
                $current = Get-DemoDeploymentState -Config $Config
                $profileName = if ($Config['activityProfile']) { [string]$Config['activityProfile'] } else { 'baseline' }
                $skip = if ($current.RunnerSha256) { '' } else { 'No workload runner was deployed (-SkipRunner).' }
                $activity = @(foreach ($target in @('T1', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' })) {
                        Set-DemoTargetProfile -Config $Config -Target $target -ProfileName $profileName -CheckPrefix 'DEPLOY' -SkipReason $skip -RequestedBy 'deploy'
                    })
                & $addAll $activity
                & $recordStage 'Activity'
                if (& $hasStatus $activity 'Warning') {
                    & $stageResult 'Activity' 'Warning' ('The activity profile {0} couldn''t be set everywhere; the deployment continues.' -f $profileName) 'Set it with demo-control.yml or ./scripts/start-demo.ps1 -ActivityProfile <name>.'
                }
                else {
                    & $stageResult 'Activity' 'Pass' ('T1 and T3 run the {0} activity profile until the next auto-shutdown; a VM that starts later sets it again only when activityProfileOnBoot is true.' -f $profileName)
                }
            }
            'Monitoring' {
                $monitoring = Enable-DemoSqlVmMonitoring -Config $Config -WaitMinutes $MonitoringWaitMinutes -Confirm:$false
                $results.Add($monitoring)
                if ($monitoring.status -eq 'Fail') {
                    & $stageResult 'Monitoring' 'Fail' 'T1 performance monitoring couldn''t be turned on.' $monitoring.remediation
                    return $results.ToArray()
                }
                if (Test-DemoSqlVmMonitoringStuck -Result $monitoring) {
                    # The template run can leave the plugin NotRunning, and waiting doesn't bring it back (live, 2026-10-27).
                    $monitoring = Restore-DemoSqlVmMonitoringPlugin -Config $Config -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment'
                    $results.Add($monitoring)
                }
                & $recordStage 'Monitoring'
                & $stageResult 'Monitoring' 'Pass' ('T1 performance monitoring: {0}.' -f $monitoring.status)
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
                    return $results.ToArray()
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
                $profileName = if ($Config['activityProfile']) { [string]$Config['activityProfile'] } else { 'baseline' }
                $t2Skip = if (-not $current.RunnerSha256 -or 'archost01' -notin $current.RunnerSentTo) { 'T2 has no workload runner (-SkipRunner, or it wasn''t sent to archost01).' } else { '' }
                $results.Add((Set-DemoTargetProfile -Config $Config -Target 'T2' -ProfileName $profileName -CheckPrefix 'DEPLOY' -SkipReason $t2Skip -RequestedBy 'deploy'))
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
                # new workspace has none. The optional Insights app stays configure-fabric-app.ps1's.
                $fabric = @(Invoke-DemoFabricStage -Config $Config -ConfigPath $ConfigPath -ImportNotebooks:$importNotebooks -NewNotebooksOnly -ImportDashboard)
                & $addAll $fabric
                if (& $hasStatus $fabric 'Fail') {
                    & $stageResult 'Fabric' 'Fail' 'A Fabric or Database Hub check failed.' 'Read the HUB.* and FABRIC.* results, fix the cause, then run deploy.ps1 -FromStage Fabric.'
                    return $results.ToArray()
                }
                $powerBI = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $ConfigPath)
                & $addAll $powerBI
                if (& $hasStatus $powerBI 'Fail') {
                    & $stageResult 'Fabric' 'Fail' 'The history semantic model or report failed.' 'Read the FABRIC.* results, fix the cause, then run deploy.ps1 -FromStage Fabric.'
                    return $results.ToArray()
                }
                & $recordStage 'Fabric'
                & $stageResult 'Fabric' 'Pass' ('The Database Hub checklist ran, the Real-Time Dashboard and the history model and report are in the workspace{0}.' -f $(if ($importNotebooks) { ', and the notebooks were imported or updated' } else { '' }))
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
    if ($validated -and -not $context.OpenStage -and -not (& $hasStatus $results.ToArray() 'Fail')) {
        $current = Get-DemoDeploymentState -Config $Config
        $installMode = if ([string]$Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
        $requirement = Get-DemoDoneRequirement -InstallMode $installMode -T4Off:([bool](Get-DemoT4OffReason -Config $Config -State $current)) -SkipFabric:$SkipFabric
        & $addAll @(Invoke-DemoDoneGate -Config $Config -Result $results.ToArray() -Requirement $requirement -TelemetryWaitMinutes $TelemetryWaitMinutes -ProgressPath $ProgressPath)
    }

    $all = $results.ToArray()
    # Phase 28 live finding (2026-10-30): what only a person can confirm is listed once each, apart from what needs you.
    $summary = Get-DemoDeploySummary -Result $all -FinishedText 'Every stage that ran finished.'
    $results.Add((New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status $summary.Status -Message $summary.Message -Evidence $summary.Evidence))
    return $results.ToArray()
}
