function Start-DemoDeploymentTrackJob {
    <#
    .SYNOPSIS
    Starts one of deploy.ps1's parallel tracks in its own PowerShell process (a background job), which imports
    DbHubDemo, runs the subscription guard itself, and runs Invoke-DemoDeploymentTrack (ADR 0018). Internal.

    .DESCRIPTION
    deploy.ps1 starts the tracks right after Preflight, so each guard runs while the template deploys; the
    track then waits for the parent's word through the context's HandoffPath (Invoke-DemoDeploymentTrack).
    -DelaySeconds staggers the processes inside the jobs, so their first Azure CLI calls don't share the
    token cache at the same moment and the parent doesn't wait. The configuration and the context cross the
    process boundary as PSSerializer XML (depth 20), so nested values and their types survive; the job writes
    each result, then its summary, the same way, one line each, prefixed DBHUB-RESULT or DBHUB-SUMMARY. Its
    log lines carry the track's name (DBHUB_LOG_TRACK).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T4', 'Fabric')]
        [string] $Track,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Context,

        [string[]] $Step = @(),

        [ValidateRange(0, 120)]
        [int] $DelaySeconds = 0
    )

    if (-not $PSCmdlet.ShouldProcess($Track, 'Start the deployment track in its own process')) {
        return
    }
    $modulePath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    $configXml = [System.Management.Automation.PSSerializer]::Serialize($Config, 20)
    $contextXml = [System.Management.Automation.PSSerializer]::Serialize($Context, 20)
    $job = {
        param([string] $ModulePath, [string] $ConfigXml, [string] $TrackName, [string] $ContextXml, [string[]] $Steps, [int] $Delay)
        $ErrorActionPreference = 'Stop'
        $env:DBHUB_LOG_TRACK = $TrackName
        if ($Delay -gt 0) {
            Start-Sleep -Seconds $Delay
        }
        Import-Module -Name $ModulePath -Force
        $emit = {
            param([string] $Kind, [object] $Item)
            'DBHUB-{0} {1}' -f $Kind, ([System.Management.Automation.PSSerializer]::Serialize($Item, 20) -replace '\r?\n', '')
        }
        $configValue = [System.Management.Automation.PSSerializer]::Deserialize($ConfigXml)
        $contextValue = [System.Management.Automation.PSSerializer]::Deserialize($ContextXml)
        try {
            $guard = Assert-DemoAzContext -SubscriptionId ([string]$configValue['subscriptionId']) -TenantId ([string]$configValue['tenantId']) -Account ([string]$configValue['azureAccount'])
            Write-DemoLog -Message ('Subscription guard in this process: {0}.' -f $guard.status)
        }
        catch {
            & $emit 'RESULT' (New-DemoResult -CheckId ('DEPLOY.TRACK.{0}' -f $TrackName.ToUpperInvariant()) -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('Track {0}: the subscription guard failed in its process, so nothing ran: {1}' -f $TrackName, $_.Exception.Message) -Remediation 'Fix the Azure CLI sign-in yourself, then run deploy.ps1 -Resume.')
            & $emit 'SUMMARY' ([pscustomobject]@{ Track = $TrackName; Status = 'Fail'; Steps = @(); Timing = @{}; ReadyUtc = @{} })
            return
        }
        $module = Get-Module -Name 'DbHubDemo'
        $outcome = & $module { param($TrackConfig, $Name, $TrackContext, $Names) Invoke-DemoDeploymentTrack -Config $TrackConfig -Track $Name -Context $TrackContext -Step $Names } $configValue $TrackName $contextValue $Steps
        foreach ($item in @($outcome.Results)) {
            & $emit 'RESULT' $item
        }
        & $emit 'SUMMARY' ($outcome | Select-Object -Property * -ExcludeProperty Results)
    }
    return (Start-Job -Name ('dbhub-track-{0}' -f $Track) -ScriptBlock $job -ArgumentList $modulePath, $configXml, $Track, $contextXml, @($Step), $DelaySeconds)
}

function Start-DemoArtifactBuildJob {
    <#
    .SYNOPSIS
    Builds the bootstrap bundle and the workload runner in their own PowerShell process while Preflight runs,
    and hands them to the track processes as 'artifacts' in the run's handoff directory (ADR 0018). Internal.

    .DESCRIPTION
    The handoff holds Bundle and Runner (New-DemoBootstrapBundle and Publish-DemoWorkloadRunner: paths, sizes,
    and SHA-256 values, nothing secret) and Error, which is set instead when the build failed. It's written
    whatever happens, so no track waits for a build that died.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [string] $HandoffPath,

        [switch] $SkipRunner
    )

    if (-not $PSCmdlet.ShouldProcess($HandoffPath, 'Build the bootstrap bundle and the workload runner in their own process')) {
        return
    }
    $modulePath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    $build = {
        param([string] $BuildModulePath, [bool] $NoRunner, [string] $Directory)
        $ErrorActionPreference = 'Stop'
        $env:DBHUB_LOG_TRACK = 'Build'
        $value = [pscustomobject]@{ Bundle = $null; Runner = $null; Error = '' }
        try {
            Import-Module -Name $BuildModulePath -Force
            $value.Bundle = New-DemoBootstrapBundle -Confirm:$false
            if (-not $NoRunner) {
                $value.Runner = Publish-DemoWorkloadRunner -Confirm:$false
            }
        }
        catch {
            $value.Error = [string]$_.Exception.Message
        }
        finally {
            $module = Get-Module -Name 'DbHubDemo'
            if ($null -ne $module) {
                if ($value.Error) {
                    $value.Error = & $module { param($Text) Protect-DemoText -Text $Text } $value.Error
                }
                & $module { param($Path, $Item) Write-DemoTrackHandoff -Path $Path -Name 'artifacts' -Value $Item -Confirm:$false } $Directory $value
            }
            else {
                $temporary = Join-Path -Path $Directory -ChildPath 'artifacts.tmp'
                [System.IO.File]::WriteAllText($temporary, [System.Management.Automation.PSSerializer]::Serialize($value, 5))
                Move-Item -LiteralPath $temporary -Destination (Join-Path -Path $Directory -ChildPath 'artifacts.xml') -Force
            }
        }
    }
    return (Start-Job -Name 'dbhub-build-artifacts' -ScriptBlock $build -ArgumentList $modulePath, ([bool]$SkipRunner), $HandoffPath)
}

function Receive-DemoDeploymentTrackOutput {
    <#
    .SYNOPSIS
    Reads what a track job wrote since the last read: its results and its summary (deserialized), and its log
    lines, which go to the console as they arrive. Returns Results and Summary. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job] $Job
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $summary = $null
    foreach ($line in @(Receive-Job -Job $Job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)) {
        if ($line -isnot [string]) {
            continue
        }
        if ($line.StartsWith('DBHUB-RESULT ', [System.StringComparison]::Ordinal)) {
            $items.Add([System.Management.Automation.PSSerializer]::Deserialize($line.Substring(13)))
        }
        elseif ($line.StartsWith('DBHUB-SUMMARY ', [System.StringComparison]::Ordinal)) {
            $summary = [System.Management.Automation.PSSerializer]::Deserialize($line.Substring(14))
        }
    }
    foreach ($problem in @($jobErrors)) {
        Write-DemoLog -Level Warning -Message ('{0}: {1}' -f $Job.Name, (Protect-DemoText -Text ([string]$problem)))
    }
    return [pscustomobject]@{ Results = $items.ToArray(); Summary = $summary }
}

function Invoke-DemoParallelDeployment {
    <#
    .SYNOPSIS
    deploy.ps1's default: Preflight and Infrastructure in this process, the T1, T2, T4, and Fabric tracks each
    in its own process, started right after Preflight, then the validation and the timing (ADR 0018). T4, the
    PostgreSQL flexible server (Phase 24, ADR 0019), is started first when it's stopped, because a stopped
    server rejects the template's update; its track checks the server and its metrics, and T1's track sets
    it up.
    Invoke-DemoDeployment -Parallel calls it. Internal.

    .DESCRIPTION
    1. The subscription guard; then the bootstrap bundle and the workload runner start building in their own
       process (Start-DemoArtifactBuildJob), which hands them over through a private handoff directory.
       Preflight (Invoke-DemoPreflight) and the T2 source (Resolve-DemoT2Source, PREFLIGHT.T2.SOURCE). Any
       Fail stops here. -WhatIf adds the template's what-if, then stops.
    2. The tracks (Invoke-DemoDeploymentTrack) start, each in a background job a few seconds apart, so their
       subscription guards run while the template deploys; each waits for this process's word that the
       template succeeded. Meanwhile T1 joins the T3 group (Microsoft Graph only), and a T2 restored from the
       golden snapshot starts its Restore as soon as the template has deployed archost01.
    3. Infrastructure: the template, with a new archost01's OS disk copied from the golden snapshot when the
       T2 source is golden, and no loaders (the tracks run them); then the handoff: the loader settings and
       T3's free-offer choice. A failed template is handed over too, and the tracks stop; what they did
       before is reported. A track's Fail stops only that track. -InProcess runs the tracks one after another
       in this process after the template, with no handoff (for tests).
    4. Validation: Database Hub's estate for the targets that finished, the runner's status on T1, and, after
       the Fabric track, the Hub checklist with the T3 gate and the Real-Time Dashboard's tile check.
    5. DEPLOY.TIMING (per track and per step, each target's ready time, and the total) and DEPLOY.SUMMARY.
       The clock stops when T1, T2, and T3 telemetry passed, Database Hub lists the estate, T2 runs Standard
       with PAYG and monitoring, and Fabric is imported (ADR 0018, section 1).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $Resume,

        [string] $FromStage = '',

        [string] $StopAfter = '',

        [switch] $SkipRunner,

        [switch] $SkipFabric,

        [switch] $ImportNotebooks,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 720)]
        [int] $PolicyCacheHours = 0,

        [int] $T1WaitMinutes = 45,

        [int] $T2WaitMinutes = 120,

        [int] $MonitoringWaitMinutes = 20,

        [int] $TelemetryWaitMinutes = 15,

        [int] $ChunkSizeKiB = 512,

        [ValidateRange(1, 16)]
        [int] $ChunkParallelism = 8,

        [switch] $WaitForT2,

        [ValidateRange(5, 120)]
        [int] $ArcWaitMinutes = 45,

        [ValidateRange(10, 600)]
        [int] $TrackTimeoutMinutes = 240,

        [switch] $InProcess
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $startUtc = [DateTime]::UtcNow
    $results = [System.Collections.Generic.List[object]]::new()
    $whatIf = [bool]$WhatIfPreference
    $addAll = { param([object[]] $Items) foreach ($item in @($Items)) { if ($null -ne $item) { $results.Add($item) } } }
    $hasStatus = { param([object[]] $Items, [string[]] $Wanted) @($Items | Where-Object { $null -ne $_ -and [string]$_.status -in $Wanted }).Count -gt 0 }
    $stageResult = {
        param([string] $Name, [string] $Status, [string] $Message, [string] $Remediation = '')
        $results.Add((New-DemoResult -CheckId ('DEPLOY.STAGE.{0}' -f $Name.ToUpperInvariant()) -Area 'infra' -Target 'subscription' -Status $Status -Message $Message -Remediation $Remediation))
    }
    $phase = [ordered]@{}
    $mark = { param([string] $Name, [System.Diagnostics.Stopwatch] $Watch) $phase[$Name] = [int]$Watch.Elapsed.TotalSeconds }

    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Sign in yourself and select nothing else: the scripts pass --subscription on every call.'))
        return $results.ToArray()
    }
    $mark.Invoke('Guard', $clock)

    $state = Get-DemoDeploymentState -Config $Config
    $skipT4 = -not (Test-DemoT4Enabled -Config $Config)
    $plan = Resolve-DemoTrackPlan -FromStage $FromStage -StopAfter $StopAfter -Resume:$Resume -State $state -SkipFabric:$SkipFabric -SkipT4:$skipT4
    if ($whatIf) {
        $plan = Resolve-DemoTrackPlan -StopAfter 'Infrastructure'
    }
    $context = @{
        NetworkMode           = $state.NetworkMode
        T3UseFreeLimit        = $state.T3UseFreeLimit
        T3AdminGroupName      = $state.T3AdminGroupName
        T2Source              = ''
        T2SnapshotId          = ''
        ConfigPath            = $ConfigPath
        ChunkSizeKiB          = $ChunkSizeKiB
        ChunkParallelism      = $ChunkParallelism
        T1WaitMinutes         = $T1WaitMinutes
        T2WaitMinutes         = $T2WaitMinutes
        MonitoringWaitMinutes = $MonitoringWaitMinutes
        TelemetryWaitMinutes  = $TelemetryWaitMinutes
        ArcWaitMinutes        = $ArcWaitMinutes
        WaitForT2             = [bool]$WaitForT2
        ImportNotebooks       = [bool]$ImportNotebooks
        ImportDashboard       = $true
    }
    $ensureContext = {
        if (-not $context.NetworkMode) {
            $configured = if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }
            $context.NetworkMode = if ($configured -in 'public', 'private') { $configured } else { (Resolve-DemoNetworkMode -ConfiguredMode $configured -PolicyUnknown).EffectiveMode }
        }
        if ($null -eq $context.T3UseFreeLimit) {
            $context.T3UseFreeLimit = if ([string]$Config['t3FreeOffer'] -eq 'off') { $false } else { [bool](Get-DemoT3FreeOfferStatus -Config $Config).UseFreeLimit }
        }
        if (-not $context.T2Source) {
            $source = Resolve-DemoT2Source -Config $Config
            $context.T2Source = $source.Source
            $context.T2SnapshotId = $source.SnapshotId
            # A host the template created from a snapshot in an earlier run is still a golden restore.
            if ($source.Source -eq 'existing-golden' -and [string](Get-DemoMemberValue -InputObject $state -Name 'T2Source') -eq 'golden' -and -not (Test-DemoDeploymentStageReached -Recorded $state.Stage -Stage 'T2')) {
                $context.T2Source = 'golden'
            }
            $results.Add($source.Result)
        }
    }

    $order = @('T1', 'T2', 'T4', 'Fabric') | Where-Object { @($plan.Tracks[$_]).Count -gt 0 }
    $needsArtifacts = @(@($plan.Tracks['T1']) + @($plan.Tracks['T2']) | Where-Object { $_ -in 'Artifacts', 'Bootstraps' }).Count -gt 0
    # Track processes start before the template and take what it returns from a private handoff directory.
    $useJobs = -not $InProcess -and -not $whatIf -and @($order).Count -gt 0
    $handoff = ''
    $buildJob = $null
    $jobs = [ordered]@{}
    $summaries = [ordered]@{}
    $trackResults = [ordered]@{}
    # Reads what each track process wrote since the last read.
    $collect = {
        foreach ($track in $jobs.Keys) {
            $read = Receive-DemoDeploymentTrackOutput -Job $jobs[$track]
            foreach ($item in $read.Results) {
                $trackResults[$track].Add($item)
            }
            if ($null -ne $read.Summary) {
                $summaries[$track] = $read.Summary
            }
        }
    }
    # Waits until every track process ended (or the deadline passed), then reads and removes them.
    $finishJobs = {
        param([datetime] $Deadline)
        while ($true) {
            & $collect
            if ($null -ne $buildJob -and $buildJob.State -notin 'NotStarted', 'Running' -and -not (Test-Path -LiteralPath (Join-Path -Path $handoff -ChildPath 'artifacts.xml'))) {
                # A build process that died without a word: the tracks get its error instead of waiting.
                Write-DemoTrackHandoff -Path $handoff -Name 'artifacts' -Value ([pscustomobject]@{ Bundle = $null; Runner = $null; Error = ('the build process ended ({0}) without a result' -f $buildJob.State) }) -Confirm:$false
            }
            $running = @($jobs.Values | Where-Object { $_.State -in 'NotStarted', 'Running' })
            if ($running.Count -eq 0) {
                break
            }
            if ([DateTime]::UtcNow -ge $Deadline) {
                foreach ($job in $running) {
                    Stop-Job -Job $job -ErrorAction SilentlyContinue
                }
                $runningNames = @($running | ForEach-Object { $_.Name }) -join ', '
                $results.Add((New-DemoResult -CheckId 'DEPLOY.TRACKS' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('{0} track(s) were still running after {1} minutes and were stopped: {2}.' -f $running.Count, $TrackTimeoutMinutes, $runningNames) -Remediation 'Run deploy.ps1 -Resume: each track continues after its last finished step.'))
                break
            }
            Start-Sleep -Seconds 10
        }
        & $collect
        foreach ($track in @($jobs.Keys)) {
            if (-not $summaries.Contains($track)) {
                $trackResults[$track].Add((New-DemoResult -CheckId ('DEPLOY.TRACK.{0}' -f $track.ToUpperInvariant()) -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('Track {0}''s process ended without a summary (job state {1}).' -f $track, $jobs[$track].State) -Remediation 'Run deploy.ps1 -Resume: the track continues after its last finished step.'))
                $summaries[$track] = [pscustomobject]@{ Track = $track; Status = 'Fail'; Steps = @(); Timing = @{}; ReadyUtc = @{} }
            }
            Remove-Job -Job $jobs[$track] -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        if ($useJobs) {
            $handoff = Initialize-DemoPrivateDirectory -Prefix 'dbhub-tracks'
            if ($needsArtifacts) {
                $buildJob = Start-DemoArtifactBuildJob -HandoffPath $handoff -SkipRunner:$SkipRunner -Confirm:$false
            }
        }

        # 1. Preflight and the T2 source.
        if ($plan.Preflight) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $preflight = @(Invoke-DemoPreflight -Config $Config -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours -SkipProviderRegistration:$whatIf)
            & $addAll $preflight
            $source = Resolve-DemoT2Source -Config $Config
            $results.Add($source.Result)
            $context.T2Source = $source.Source
            $context.T2SnapshotId = $source.SnapshotId
            if ((& $hasStatus $preflight 'Fail') -or $source.Result.status -eq 'Fail') {
                & $stageResult 'Preflight' 'Fail' 'Preflight has at least one Fail, so nothing was deployed.' 'Fix each Fail above (its remediation says how), then run deploy.ps1 again.'
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
            $mark.Invoke('Preflight', $watch)
            & $stageResult 'Preflight' 'Pass' ('Preflight passed (network mode {0}, T3 free offer {1}, T2 source {2}).' -f $context.NetworkMode, $context.T3UseFreeLimit, $context.T2Source)
        }

        # 2. The track processes, a few seconds apart, so their guards run while the template deploys.
        if ($useJobs) {
            & $ensureContext
            $context['HandoffPath'] = $handoff
            $context['HandoffTimeoutMinutes'] = $TrackTimeoutMinutes
            # A golden T2 starts its Restore once the template has deployed archost01 in this run; a deployment
            # record older than two minutes before now belongs to an earlier run.
            $context['EarlyT2'] = [bool]$plan.Infrastructure -and [string]$context.T2Source -eq 'golden'
            $context['EarlyStartUtc'] = [DateTime]::UtcNow.AddMinutes(-2).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            $delay = 0
            foreach ($track in $order) {
                Write-DemoLog -Message ('Starting track {0}: {1}.' -f $track, (@($plan.Tracks[$track]) -join ', '))
                $jobs[$track] = Start-DemoDeploymentTrackJob -Config $Config -Track $track -Context $context -Step @($plan.Tracks[$track]) -DelaySeconds $delay -Confirm:$false
                $trackResults[$track] = [System.Collections.Generic.List[object]]::new()
                $delay += 5
            }
        }

        # 3. Infrastructure.
        $loaderSettings = $null
        if ($plan.Infrastructure) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            & $ensureContext
            $deployArguments = @{
                Config                  = $Config
                Action                  = $(if ($whatIf) { 'WhatIf' } else { 'Create' })
                NetworkMode             = $context.NetworkMode
                T3UseFreeLimit          = [bool]$context.T3UseFreeLimit
                T3AdminGroupDisplayName = [string]$context.T3AdminGroupName
            }
            if ($context.T2Source -eq 'golden' -and $context.T2SnapshotId) {
                $deployArguments['T2OsDiskSourceId'] = $context.T2SnapshotId
            }
            if (-not $whatIf -and -not $skipT4) {
                # A stopped flexible server rejects every other management operation, including the template's
                # update, so a stopped T4 starts first (Phase 24, ADR 0019). Not selected when T4 doesn't exist yet.
                $t4Start = Invoke-DemoT4PowerAction -Config $Config -Action Start -WaitMinutes 20 -CheckPrefix DEPLOY
                if ($t4Start.status -ne 'Not selected') {
                    $results.Add($t4Start)
                }
            }
            $deployment = Invoke-DemoTemplateDeployment @deployArguments
            & $addAll $deployment.Results
            if ($whatIf) {
                & $stageResult 'Infrastructure' 'Not selected' 'What if: the template''s what-if ran; nothing was deployed, and the tracks were skipped.'
                return $results.ToArray()
            }
            if (-not $deployment.Succeeded) {
                & $stageResult 'Infrastructure' 'Fail' 'The template deployment failed, so the tracks stopped; what they finished before it is reported.' 'Fix the cause in DEPLOY.TEMPLATE, then run deploy.ps1 -Resume.'
                if ($useJobs) {
                    # The tracks stop; what they did before (T2's restore, T1's group membership) is reported.
                    Write-DemoTrackHandoff -Path $handoff -Name 'infrastructure' -Value ([pscustomobject]@{ Succeeded = $false; Message = 'the template deployment failed (DEPLOY.TEMPLATE).' }) -Confirm:$false
                    & $finishJobs ([DateTime]::UtcNow.AddMinutes($TrackTimeoutMinutes))
                    foreach ($track in $trackResults.Keys) {
                        & $addAll @($trackResults[$track])
                    }
                }
                return $results.ToArray()
            }
            $context.T3UseFreeLimit = [bool]$deployment.T3UseFreeLimit
            $loaderSettings = $deployment.Outputs['loaderSettings']
            try {
                Set-DemoDeploymentState -Config $Config -Value @{ Stage = 'Infrastructure'; NetworkMode = $context.NetworkMode; T3UseFreeLimit = [bool]$context.T3UseFreeLimit; T3AdminGroupName = [string]$context.T3AdminGroupName; T2Source = $(if ($context.T2Source -eq 'golden') { 'golden' } elseif ($context.T2Source -like 'existing-*') { $context.T2Source -replace '^existing-', '' } else { 'build' }) } -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The infrastructure is deployed, but its state wasn''t recorded: {0}' -f $_.Exception.Message)
            }
            $mark.Invoke('Infrastructure', $watch)
            & $stageResult 'Infrastructure' 'Pass' ('The infrastructure is deployed (archost01''s disk: {0}).' -f $(if ($deployArguments.Contains('T2OsDiskSourceId')) { 'restored from ' + ($context.T2SnapshotId -replace '^.*/', '') } else { 'as before' }))
            if ((Get-DemoKeyVaultSetting -Config $Config).Enabled) {
                & $addAll @(Initialize-DemoKeyVault -Config $Config -Confirm:$false)
            }
            # The on-demand activity control's A1 (ADR 0020), as in the sequential path.
            & $addAll @(Invoke-DemoActivityControlRegrant -Config $Config -ConfigPath $ConfigPath -Confirm:$false)
        }
        if ($StopAfter -in 'Preflight', 'Infrastructure') {
            $results.Add((New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status $(if (& $hasStatus $results.ToArray() 'Fail') { 'Fail' } else { 'Pass' }) -Message ('Stopped after {0} (-StopAfter).' -f $StopAfter)))
            return $results.ToArray()
        }
        & $ensureContext

        # The loader settings come from the template; a run that skipped it reads the last deployment's outputs.
        if ($null -eq $loaderSettings -and $needsArtifacts) {
            $outputs = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'sub', 'show', '--name', ('dbhub-{0}-main' -f $Config['environment']), '--query', 'properties.outputs.loaderSettings.value', '--output', 'json') -AsJson -AllowFailure
            $loaderSettings = $outputs
        }
        $context['LoaderSettings'] = $loaderSettings
        if ($useJobs) {
            Write-DemoTrackHandoff -Path $handoff -Name 'infrastructure' -Value ([pscustomobject]@{ Succeeded = $true; LoaderSettings = $loaderSettings; T3UseFreeLimit = [bool]$context.T3UseFreeLimit; Message = '' }) -Confirm:$false
        }
        elseif ($needsArtifacts) {
            try {
                $context['Bundle'] = New-DemoBootstrapBundle -Confirm:$false
                $context['Runner'] = if ($SkipRunner) { $null } else { Publish-DemoWorkloadRunner -Confirm:$false }
            }
            catch {
                $results.Add((New-DemoResult -CheckId 'DEPLOY.ARTIFACTS.BUILD' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The bootstrap bundle or the workload runner couldn''t be built: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run New-DemoBootstrapBundle and Publish-DemoWorkloadRunner yourself to see the error (the runner needs the .NET SDK, or use -SkipRunner).'))
                return $results.ToArray()
            }
        }

        # 4. The tracks.
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($InProcess) {
            foreach ($track in $order) {
                $outcome = Invoke-DemoDeploymentTrack -Config $Config -Track $track -Context $context -Step @($plan.Tracks[$track])
                $trackResults[$track] = @($outcome.Results)
                $summaries[$track] = $outcome
            }
        }
        else {
            & $finishJobs ([DateTime]::UtcNow.AddMinutes($TrackTimeoutMinutes))
            $built = if ($needsArtifacts -and $handoff) { Read-DemoTrackHandoff -Path $handoff -Name 'artifacts' } else { $null }
            $buildError = [string](Get-DemoMemberValue -InputObject $built -Name 'Error')
            if ($buildError) {
                $results.Add((New-DemoResult -CheckId 'DEPLOY.ARTIFACTS.BUILD' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The bootstrap bundle or the workload runner couldn''t be built: {0}' -f $buildError) -Remediation 'Run New-DemoBootstrapBundle and Publish-DemoWorkloadRunner yourself to see the error (the runner needs the .NET SDK, or use -SkipRunner).'))
            }
        }
    }
    finally {
        # Cancelled or finished: no track process outlives deploy.ps1, and the handoff directory goes.
        foreach ($job in @(@($jobs.Values) + @($buildJob) | Where-Object { $null -ne $_ })) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        if ($handoff) {
            Remove-DemoPrivateDirectory -Path $handoff -Confirm:$false | Out-Null
        }
    }
    foreach ($track in $trackResults.Keys) {
        & $addAll @($trackResults[$track])
    }
    $mark.Invoke('Tracks', $watch)
    foreach ($track in $summaries.Keys) {
        $summary = $summaries[$track]
        $status = [string]$summary.Status
        $message = 'Track {0}: {1}; finished steps: {2}.' -f $track, $status, $(if (@($summary.Steps).Count) { @($summary.Steps) -join ', ' } else { 'none' })
        $resultStatus = switch ($status) { 'Pass' { 'Pass' } 'Background' { 'Manual action required' } 'Open' { 'Warning' } default { 'Fail' } }
        $results.Add((New-DemoResult -CheckId ('DEPLOY.TRACK.{0}' -f $track.ToUpperInvariant()) -Area 'infra' -Target $(if ($track -eq 'Fabric') { 'fabric' } else { $track }) -Status $resultStatus -Message $message -Evidence ([ordered]@{ steps = @($summary.Steps); timing = $summary.Timing; readyUtc = $summary.ReadyUtc; early = @(Get-DemoMemberValue -InputObject $summary -Name 'Early') })))
    }

    # 5. Validation.
    $validationWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $t1Done = $summaries.Contains('T1') -and [string]$summaries['T1'].Status -eq 'Pass'
    $t2Done = $summaries.Contains('T2') -and [string]$summaries['T2'].Status -eq 'Pass'
    $fabricDone = $summaries.Contains('Fabric') -and [string]$summaries['Fabric'].Status -eq 'Pass'
    $t4Done = $summaries.Contains('T4') -and [string]$summaries['T4'].Status -eq 'Pass'
    if ($plan.Validation) {
        $estateTargets = @(@(if ($t1Done) { 'T1', 'T3' }) + @(if ($t2Done) { 'T2' }) + @(if ($t4Done) { 'T4' }))
        if ($estateTargets.Count -gt 0) {
            & $addAll @(Test-DemoHubEstate -Config $Config -Target $estateTargets)
        }
        if ($t1Done) {
            # T1's AssociatedServices step must have converged: unified inventory lists only the engine. A Fail, not a
            # Warning (live, 2026-10-22), after up to 10 minutes for inventory to catch up with the step.
            $results.Add((Test-DemoSqlVmAssociatedService -Config $Config -WaitMinutes 10 -ListedStatus 'Fail'))
        }
        $current = Get-DemoDeploymentState -Config $Config
        if ($t1Done -and $current.RunnerSha256) {
            $status = Invoke-DemoWorkloadCommand -Config $Config -Target 'T1' -ArgumentList 'status', '--json' -TimeoutSeconds 300 -Confirm:$false
            $results.Add($status.Result)
        }
        if ($fabricDone) {
            # The T3 gate's extended property: T1's track read it (T3.PROPERTY); a resumed run reads it from T1 now.
            $property = @($results) | Where-Object { [string]$_.checkId -eq 'T3.PROPERTY' -and [string]$_.status -in 'Pass', 'Fail' } | Select-Object -Last 1
            if ($null -eq $property) {
                $run = Invoke-DemoT3SqlFromT1 -Config $Config -Name Status -CheckId 'T3.PROPERTY' -MaxLoginWaitSeconds 120 -Confirm:$false
                if ($run.Status -eq 'Pass') {
                    $value = [string](Get-DemoMemberValue -InputObject (@($run.Rows) | Select-Object -First 1) -Name 'performance_monitoring')
                    $property = [pscustomobject]@{ status = $(if ($value -eq 'true') { 'Pass' } else { 'Fail' }); message = [string]$run.Message }
                }
            }
            $propertyCheck = $null
            if ($null -ne $property) {
                $answer = $property
                $propertyCheck = { param($Settings) $null = $Settings; $answer }.GetNewClosure()
            }
            & $addAll @(Invoke-DemoFabricStage -Config $Config -ConfigPath $ConfigPath -CheckDashboardData -T3PerformanceMonitoringCheck $propertyCheck)
        }
        try {
            Set-DemoDeploymentState -Config $Config -Value @{ Stage = $(if ($t1Done -and $t2Done -and ($fabricDone -or $SkipFabric)) { 'Validation' } elseif ($t1Done) { 'Monitoring' } else { 'Infrastructure' }) } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The validation ran, but the stage wasn''t recorded: {0}' -f $_.Exception.Message)
        }
    }
    $mark.Invoke('Validation', $validationWatch)

    # 6. Timing and the summary.
    $all = $results.ToArray()
    $passed = { param([string] $CheckId) @($all | Where-Object { [string]$_.checkId -eq $CheckId -and [string]$_.status -eq 'Pass' }).Count -gt 0 }
    $ready = [ordered]@{}
    foreach ($summary in $summaries.Values) {
        $readyValue = Get-DemoMemberValue -InputObject $summary -Name 'ReadyUtc'
        if ($readyValue -is [System.Collections.IDictionary]) {
            foreach ($key in $readyValue.Keys) {
                $ready[[string]$key] = [string]$readyValue[$key]
            }
        }
    }
    $clockStopped = (& $passed 'TELEMETRY.T1') -and (& $passed 'TELEMETRY.T2') -and (& $passed 'TELEMETRY.T3') -and (& $passed 'HUB.ESTATE.T1') -and (& $passed 'HUB.ESTATE.T2') -and (& $passed 'HUB.ESTATE.T3') -and (& $passed 'T2.ARC.SQLINSTANCE') -and (& $passed 'T2.ARC.MONITORING') -and (& $passed 'T1.SQLVM.ASSOCIATEDSERVICES') -and ($fabricDone -or $SkipFabric)
    $trackTiming = [ordered]@{}
    foreach ($track in $summaries.Keys) {
        $trackTiming[$track] = [ordered]@{ status = [string]$summaries[$track].Status; steps = $summaries[$track].Timing; startedUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'StartedUtc'); firstStepUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'FirstStepUtc'); endedUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'EndedUtc'); early = @(Get-DemoMemberValue -InputObject $summaries[$track] -Name 'Early') }
    }
    $minutes = [math]::Round($clock.Elapsed.TotalMinutes, 1)
    $timing = [ordered]@{ startUtc = $startUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); endUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); minutes = $minutes; phases = $phase; tracks = $trackTiming; targetReadyUtc = $ready; t2Source = $context.T2Source; clockStopped = $clockStopped; withinThirtyMinutes = ($clockStopped -and $minutes -le 30) }
    $timingMessage = if ($clockStopped) { 'Everything is deployed and populated in {0} minutes (T1, T2, and T3 telemetry, the estate, T2 PAYG with monitoring, T1''s inventory with only the engine, and Fabric).' -f $minutes } else { 'The run took {0} minutes; not every end-to-end condition passed yet, so the clock didn''t stop (see DEPLOY.SUMMARY).' -f $minutes }
    $results.Add((New-DemoResult -CheckId 'DEPLOY.TIMING' -Area 'infra' -Target 'subscription' -Status $(if ($clockStopped) { 'Pass' } else { 'Warning' }) -Message $timingMessage -Evidence $timing))

    $all = $results.ToArray()
    $manual = @($all | Where-Object { $_.status -eq 'Manual action required' })
    $failed = @($all | Where-Object { $_.status -eq 'Fail' })
    $steps = @($manual | ForEach-Object { '{0}: {1}' -f $_.checkId, $(if ($_.remediation) { $_.remediation } else { $_.message }) })
    $summaryStatus = if ($failed.Count -gt 0) { 'Fail' } elseif ($manual.Count -gt 0) { 'Manual action required' } else { 'Pass' }
    $summaryMessage = if ($manual.Count -gt 0) { ('{0} item(s) need you: {1}' -f $manual.Count, ($steps -join ' | ')) } elseif ($failed.Count -gt 0) { ('{0} check(s) failed.' -f $failed.Count) } else { 'Every track and the validation finished.' }
    $results.Add((New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status $summaryStatus -Message $summaryMessage -Evidence ([ordered]@{ manual = $steps; failed = @($failed | ForEach-Object { $_.checkId }); minutes = $minutes })))
    return $results.ToArray()
}
