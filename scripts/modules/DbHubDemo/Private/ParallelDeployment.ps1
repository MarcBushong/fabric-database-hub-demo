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
        # This process's ID first, so deploy.ps1 can end it at once when it's stopped (Stop-DemoRunJob).
        'DBHUB-PID {0}' -f $PID
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
        # The run's cancel marker, which tells this process's finally blocks to skip slow Azure cleanups when deploy.ps1
        # stops it (Test-DemoRunCancelled), and its private files under the handoff directory, which deploy.ps1 deletes
        # even when it has to end this process (Initialize-DemoPrivateDirectory). Phase 28 live finding.
        $handoffPath = [string]$contextValue['HandoffPath']
        if ($handoffPath) {
            $env:DBHUB_CANCEL_FILE = Join-Path -Path $handoffPath -ChildPath 'cancel.xml'
            $env:DBHUB_PRIVATE_ROOT = Join-Path -Path $handoffPath -ChildPath 'private'
        }
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
        # This process's ID first, so deploy.ps1 can end it at once when it's stopped (Stop-DemoRunJob).
        'DBHUB-PID {0}' -f $PID
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

function Start-DemoPolicyInventoryJob {
    <#
    .SYNOPSIS
    Runs preflight's policy inventory (Get-DemoPolicyConstraint) in its own PowerShell process, with its own subscription
    guard, while the template and the tracks run (Phase 28, brief goal 5). Internal.

    .DESCRIPTION
    Only with networkMode private, where the inventory resolves nothing the template needs; the what-if check in
    preflight still catches a policy that denies part of the deployment. Not with public (review finding 7): a Modify
    policy that turns SQL public access off isn't a denial, so preflight's own check must stop that run first. The job
    writes each PREFLIGHT.POLICY.* result as one DBHUB-RESULT line, as a track does (Receive-DemoDeploymentTrackOutput
    reads them), and a failed read as the PREFLIGHT.POLICY.INVENTORY Warning, as preflight does.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 720)]
        [int] $CacheHours = 0
    )

    if (-not $PSCmdlet.ShouldProcess('policy inventory', 'Read the policy inventory in its own process')) {
        return
    }
    $modulePath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    $configXml = [System.Management.Automation.PSSerializer]::Serialize($Config, 20)
    $inventory = {
        param([string] $InventoryModulePath, [string] $InventoryConfigXml, [int] $Hours)
        # This process's ID first, so deploy.ps1 can end it at once when it's stopped (Stop-DemoRunJob).
        'DBHUB-PID {0}' -f $PID
        $ErrorActionPreference = 'Stop'
        $env:DBHUB_LOG_TRACK = 'Policy'
        Import-Module -Name $InventoryModulePath -Force
        $configValue = [System.Management.Automation.PSSerializer]::Deserialize($InventoryConfigXml)
        $module = Get-Module -Name 'DbHubDemo'
        $items = & $module {
            param($PolicyConfig, $PolicyHours)
            try {
                $null = Assert-DemoAzContext -SubscriptionId ([string]$PolicyConfig['subscriptionId']) -TenantId ([string]$PolicyConfig['tenantId']) -Account ([string]$PolicyConfig['azureAccount'])
                @((Get-DemoPolicyConstraint -Config $PolicyConfig -CacheHours $PolicyHours).Results)
            }
            catch {
                New-DemoResult -CheckId 'PREFLIGHT.POLICY.INVENTORY' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message ('The policy inventory, which ran alongside the deployment, failed ({0}). The what-if check found no policy denials before anything was created.' -f (Protect-DemoText -Text $_.Exception.Message).TrimEnd('.'))
            }
        } $configValue $Hours
        foreach ($item in @($items)) {
            'DBHUB-RESULT {0}' -f ([System.Management.Automation.PSSerializer]::Serialize($item, 20) -replace '\r?\n', '')
        }
    }
    return (Start-Job -Name 'dbhub-policy-inventory' -ScriptBlock $inventory -ArgumentList $modulePath, $configXml, $CacheHours)
}

function Receive-DemoDeploymentTrackOutput {
    <#
    .SYNOPSIS
    Reads what a track job wrote since the last read: its results and its summary (deserialized), its process ID
    (DBHUB-PID, kept for Stop-DemoRunJob), and its log lines, which go to the console as they arrive. Returns Results
    and Summary. Internal.
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
        elseif ($line -match '^DBHUB-PID (\d{1,10})$') {
            # The job's process, for Stop-DemoRunJob (Phase 28 live finding).
            $script:DemoJobProcessId[$Job.InstanceId.ToString()] = [int]$Matches[1]
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
       The clock stops when every track finished and DONE's requirements passed (Get-DemoDoneRequirement; ADR 0018,
       section 1, as amended by Phase 28): Database Hub's estate for T1 to T4, T1, T2, and T3 telemetry, T4's
       metrics, T2 at Standard with PAYG and monitoring, T1's inventory, and the required Fabric items. T4's are left
       out when T4 is off; Developer mode leaves out T2's telemetry, PAYG, and monitoring.

    Phase 28: -AutoResume continues an unfinished deployment (the state's Stage is set and isn't Validation) as -Resume
    does; -ProgressPath is the status page's model, which each stage and track updates; with networkMode private the
    policy inventory runs in its own process alongside the deployment (Start-DemoPolicyInventoryJob), and
    its results replace preflight's placeholders at the end; preflight's T4 startSku starts the Burstable fallback;
    and this process prompts the person at the guided stop when the T2 track process reports it Ready in the progress
    model; without one (-NoStatusPage), the T2 track process prompts the person itself.
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

        [int] $T2WaitMinutes = 180,

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

        [switch] $InProcess,

        [switch] $AutoResume,

        [string] $ProgressPath = '',

        [string] $PagePath = ''
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
        # The status page's Preflight and Infrastructure steps (Phase 28).
        if ($Name -in 'Preflight', 'Infrastructure') {
            Set-DemoProgressStep -Path $ProgressPath -Id $Name -Status $Status -Message $Message
        }
    }
    $phase = [ordered]@{}
    $mark = { param([string] $Name, [System.Diagnostics.Stopwatch] $Watch) $phase[$Name] = [int]$Watch.Elapsed.TotalSeconds }

    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing ran. Sign in yourself and select nothing else: the scripts pass --subscription on every call.'))
        Set-DemoProgressStep -Path $ProgressPath -Id 'Preflight' -State 'Failed' -Status 'Fail' -Message $_.Exception.Message
        return $results.ToArray()
    }
    $mark.Invoke('Guard', $clock)

    $state = Get-DemoDeploymentState -Config $Config
    # Phase 28 (brief item 2): a plain deploy.ps1 continues an unfinished deployment from the resource group's tags.
    if ($AutoResume -and -not $Resume -and -not $FromStage -and -not $whatIf -and [string]$state.Stage -and [string]$state.Stage -ne 'Validation') {
        $Resume = [switch]::new($true)
        Write-DemoLog -Message ('An unfinished deployment is on record (its last finished stage is {0}), so this run continues it, as deploy.ps1 -Resume does. To start over from preflight instead: ./scripts/deploy.ps1 -FromStage Preflight.' -f $state.Stage)
    }
    # T4's size as an earlier run's Burstable fallback settled it, unless the configuration sets one (Phase 28).
    $Config = Resolve-DemoEffectiveConfig -Config $Config -State $state
    $skipT4 = -not (Test-DemoT4Enabled -Config $Config)
    $plan = Resolve-DemoTrackPlan -FromStage $FromStage -StopAfter $StopAfter -Resume:$Resume -State $state -SkipFabric:$SkipFabric -SkipT4:$skipT4
    if ($whatIf) {
        $plan = Resolve-DemoTrackPlan -StopAfter 'Infrastructure'
    }
    Set-DemoProgressPlan -Path $ProgressPath -Plan $plan -Resume:$Resume
    # The tracks run for as long as the T2 wait, the guided stop (at least 45 minutes for the person, plus about 20 to
    # prepare), and what follows it can take (Phase 28).
    if ($WaitForT2) {
        $TrackTimeoutMinutes = [System.Math]::Min(600, [System.Math]::Max($TrackTimeoutMinutes, $T2WaitMinutes + 65 + 30 + $ArcWaitMinutes + 30 + $TelemetryWaitMinutes + 15))
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
        # Phase 28: the status page's model, and who prompts the person at the guided stop: this process, which owns
        # the console, the clipboard, and the browser, when the tracks run in their own processes and the model exists.
        ProgressPath          = $ProgressPath
        PagePath              = $PagePath
        PromptInParent        = $false
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
    # Phase 28 (brief goal 5): with networkMode private, the policy inventory resolves nothing the template needs, so it
    # runs in its own process alongside the template and the tracks, and its results replace preflight's placeholders at
    # the end. With auto it stays in preflight, as before, and with public too (review finding 7): a Modify policy that
    # turns SQL public access off isn't a denial the what-if sees, so PREFLIGHT.POLICY.SQLPUBLIC must stop the run first.
    $deferPolicy = $useJobs -and [bool]$plan.Preflight -and -not $SkipPolicyInventory -and [string]$Config['networkMode'] -eq 'private'
    $policyJob = $null
    $policy = @{ Collected = $false; Applied = $false; Items = @() }
    $t4StartSku = ''
    # Reads the deferred policy inventory once it has finished; with -WaitMinutes, waits for it, then gives up with a Warning.
    $collectPolicy = {
        param([int] $WaitMinutes = 0)
        if ($null -eq $policyJob -or $policy.Collected) {
            return
        }
        if ($WaitMinutes -gt 0 -and $policyJob.State -in 'NotStarted', 'Running') {
            $null = Wait-Job -Job $policyJob -Timeout ($WaitMinutes * 60)
        }
        if ($policyJob.State -in 'NotStarted', 'Running') {
            if ($WaitMinutes -gt 0) {
                Stop-Job -Job $policyJob -ErrorAction SilentlyContinue
                $policy.Items = @(New-DemoResult -CheckId 'PREFLIGHT.POLICY.INVENTORY' -Area 'preflight' -Target 'subscription' -Status 'Warning' -Message 'The policy inventory, which ran alongside the deployment, didn''t finish in time. The what-if check found no policy denials before anything was created.' -Remediation 'Run ./scripts/preflight.ps1 to read it (its cache makes the next deploy.ps1 faster).')
                $policy.Collected = $true
            }
            return
        }
        $read = Receive-DemoDeploymentTrackOutput -Job $policyJob
        $policy.Items = @($read.Results)
        $policy.Collected = $true
        foreach ($item in @($policy.Items | Where-Object { [string]$_.status -in 'Fail', 'Warning', 'Manual action required' })) {
            Write-DemoLog -Level Warning -Message ('Policy inventory: {0} {1}: {2}' -f $item.checkId, $item.status, $item.message)
        }
    }
    # The deferred inventory's results replace preflight's placeholders (PREFLIGHT.POLICY.INVENTORY and SQLPUBLIC).
    $applyPolicy = {
        param([int] $WaitMinutes = 5)
        & $collectPolicy $WaitMinutes
        if (-not $policy.Collected -or $policy.Applied) {
            return
        }
        $policy.Applied = $true
        $kept = @($results | Where-Object { -not ([string]$_.checkId -in 'PREFLIGHT.POLICY.INVENTORY', 'PREFLIGHT.POLICY.SQLPUBLIC' -and [bool](Get-DemoMemberValue -InputObject $_.evidence -Name 'deferred')) })
        $results.Clear()
        & $addAll $kept
        & $addAll @($policy.Items)
    }
    # The guided stop's prompt, in this process (Phase 28): the T2 track process turns the model's guidedStop Ready, and
    # this process, which has the console, the clipboard, and the browser, hands over the credential and prompts the
    # person, then reminds them every 5 minutes until the host's setup check passes or the time limit passes.
    $guided = @{ Prompted = $false; NextReminder = [DateTime]::MinValue; Closed = $false }
    $guidedTick = {
        if (-not $ProgressPath -or $guided.Closed) {
            return
        }
        $model = Read-DemoProgress -Path $ProgressPath
        if ($null -eq $model) {
            return
        }
        $stop = $model['guidedStop']
        $stopState = [string]$stop['state']
        if ($stopState -eq 'Ready' -and [long]$stop['deadlineAt'] -gt 0) {
            $deadline = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$stop['deadlineAt']).UtcDateTime
            if (-not $guided.Prompted) {
                $guided.Prompted = $true
                try {
                    $credential = Invoke-DemoGuidedStopCredential -Config $Config -ExpiresUtc $deadline
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('The host credential for the guided stop couldn''t be prepared: {0}' -f $_.Exception.Message)
                    $credential = [pscustomobject]@{ Mode = 'unknown'; UserName = ''; Text = ''; Results = @() }
                    try {
                        # The person may reset the password in the portal now; the state makes sure it's rotated afterward.
                        Set-DemoDeploymentState -Config $Config -Value @{ HostPasswordSet = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) } -Confirm:$false
                    }
                    catch {
                        Write-DemoLog -Level Warning -Message ('The handover wasn''t recorded, so if you reset archost01''s password in the portal, reset it again afterward to a random value you don''t keep: {0}' -f $_.Exception.Message)
                    }
                }
                & $addAll @($credential.Results)
                Set-DemoProgressValue -Path $ProgressPath -Section 'guidedStop' -Value @{ credential = $credential.Mode; credentialText = $credential.Text; hostUser = $credential.UserName }
                Show-DemoGuidedStopPrompt -Url ([string]$stop['url']) -DeadlineUtc $deadline -HostVm ([string]$stop['hostVm']) -HostUser $credential.UserName -SignInWay $credential.Mode -SignInText $credential.Text -PagePath $PagePath
                $guided.NextReminder = [DateTime]::UtcNow.AddMinutes(5)
            }
            elseif ([DateTime]::UtcNow -ge $guided.NextReminder) {
                Show-DemoGuidedStopReminder -DeadlineUtc $deadline -PagePath $PagePath -Status ([string]$stop['message']) -HostVm ([string]$stop['hostVm'])
                $guided.NextReminder = [DateTime]::UtcNow.AddMinutes(5)
            }
        }
        elseif ($guided.Prompted -and $stopState -in 'Done', 'TimedOut', 'Failed') {
            $guided.Closed = $true
            $closing = switch ($stopState) {
                'Done' { 'The guided stop is done: SQL Server setup passed the host''s check. Nothing else needs you; deploy.ps1 finishes T2 on its own.' }
                'TimedOut' { 'The guided stop''s time limit passed. deploy.ps1 finishes the rest; run ./scripts/deploy.ps1 again when you have about 15 minutes, and it guides you through the step again.' }
                default { 'The guided stop couldn''t go on; the summary at the end says why and what to run.' }
            }
            Write-DemoLog -Message $closing
        }
    }
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
            try {
                & $guidedTick
                & $collectPolicy 0
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The guided stop''s prompt or the policy inventory couldn''t be read this time: {0}' -f $_.Exception.Message)
            }
            if ($null -ne $buildJob -and $buildJob.State -notin 'NotStarted', 'Running' -and -not (Test-Path -LiteralPath (Join-Path -Path $handoff -ChildPath 'artifacts.xml'))) {
                # A build process that died without a word: the tracks get its error instead of waiting.
                Write-DemoTrackHandoff -Path $handoff -Name 'artifacts' -Value ([pscustomobject]@{ Bundle = $null; Runner = $null; Error = ('the build process ended ({0}) without a result' -f $buildJob.State) }) -Confirm:$false
            }
            $running = @($jobs.Values | Where-Object { $_.State -in 'NotStarted', 'Running' })
            if ($running.Count -eq 0) {
                break
            }
            if ([DateTime]::UtcNow -ge $Deadline) {
                # Their slow Azure cleanups are skipped, so they stop within seconds (Phase 28 live finding).
                try {
                    Write-DemoTrackHandoff -Path $handoff -Name 'cancel' -Value ([pscustomobject]@{ Reason = 'deadline'; Utc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }) -Confirm:$false
                }
                catch {
                    Write-DemoLog -Level Debug -Message ('The cancel marker wasn''t written: {0}' -f $_.Exception.Message)
                }
                $null = Stop-DemoRunJob -Job $running
                $runningNames = @($running | ForEach-Object { $_.Name }) -join ', '
                $results.Add((New-DemoResult -CheckId 'DEPLOY.TRACKS' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('{0} track(s) were still running after {1} minutes and were stopped: {2}.' -f $running.Count, $TrackTimeoutMinutes, $runningNames) -Remediation 'Run deploy.ps1 -Resume: each track continues after its last finished step.'))
                break
            }
            # Ten seconds, in one-second steps: a Ctrl+C that PowerShell didn't act on ends the wait within a second
            # (Enable-DemoRunCancelWatch; Phase 28 live finding).
            for ($second = 0; $second -lt 10; $second++) {
                if (Test-DemoRunCancelled) {
                    throw [System.OperationCanceledException]::new('deploy.ps1 was stopped (Ctrl+C) before the tracks finished.')
                }
                Start-Sleep -Seconds 1
            }
        }
        & $collect
        foreach ($track in @($jobs.Keys)) {
            if (-not $summaries.Contains($track)) {
                $trackResults[$track].Add((New-DemoResult -CheckId ('DEPLOY.TRACK.{0}' -f $track.ToUpperInvariant()) -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('Track {0}''s process ended without a summary (job state {1}).' -f $track, $jobs[$track].State) -Remediation 'Run deploy.ps1 -Resume: the track continues after its last finished step.'))
                $summaries[$track] = [pscustomobject]@{ Track = $track; Status = 'Fail'; Steps = @(); Timing = @{}; ReadyUtc = @{} }
            }
            # A job whose process had to be ended still reads Running for about a minute; Remove-Job would wait for it.
            if ($jobs[$track].State -notin 'NotStarted', 'Running', 'Stopping') {
                Remove-Job -Job $jobs[$track] -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        if ($useJobs) {
            $handoff = Initialize-DemoPrivateDirectory -Prefix 'dbhub-tracks'
            # The track processes' private files go here (DBHUB_PRIVATE_ROOT), so they go with the handoff directory even
            # when a stop has to end a process (Phase 28 live finding). It inherits the handoff directory's protection.
            $null = [System.IO.Directory]::CreateDirectory((Join-Path -Path $handoff -ChildPath 'private'))
            if ($needsArtifacts) {
                $buildJob = Start-DemoArtifactBuildJob -HandoffPath $handoff -SkipRunner:$SkipRunner -Confirm:$false
            }
        }

        # 1. Preflight and the T2 source.
        if ($plan.Preflight) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Set-DemoProgressStep -Path $ProgressPath -Id 'Preflight' -State 'Running' -Message 'Checking access, quotas, sizes, Fabric, and policies before anything is created.'
            $preflight = @(Invoke-DemoPreflight -Config $Config -SkipPolicyInventory:$SkipPolicyInventory -PolicyCacheHours $PolicyCacheHours -SkipProviderRegistration:$whatIf -DeferPolicyInventory:$deferPolicy)
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
            # Where T4's Burstable fallback starts when preflight already ruled out the default (Phase 28).
            $startSkus = @(foreach ($checkId in 'PREFLIGHT.T4.SKU', 'PREFLIGHT.T4.CAPABILITY') { [string](& $pick $checkId 'startSku') })
            $t4StartSku = if ($startSkus -contains 'None') { 'None' } elseif ($startSkus -contains 'Standard_B2s') { 'Standard_B2s' } else { '' }
            if ($deferPolicy) {
                Write-DemoLog -Message ('networkMode is {0}, so the policy inventory runs alongside the deployment instead of before it; its results come at the end.' -f [string]$Config['networkMode'])
                $policyJob = Start-DemoPolicyInventoryJob -Config $Config -CacheHours $PolicyCacheHours -Confirm:$false
            }
            & $ensureContext
            $mark.Invoke('Preflight', $watch)
            & $stageResult 'Preflight' 'Pass' ('Preflight passed (network mode {0}, T3 free offer {1}, T2 source {2}).' -f $context.NetworkMode, $context.T3UseFreeLimit, $context.T2Source)
        }
        if (-not $whatIf) {
            & $ensureContext
            Set-DemoProgressPlan -Path $ProgressPath -Plan $plan -Resume:$Resume -T2Source ([string]$context.T2Source)
        }

        # 2. The track processes, a few seconds apart, so their guards run while the template deploys.
        if ($useJobs) {
            & $ensureContext
            $context['HandoffPath'] = $handoff
            $context['HandoffTimeoutMinutes'] = $TrackTimeoutMinutes
            # This process prompts the person at the guided stop ($guidedTick) when the T2 track process can tell it, through
            # the progress model, that the stop is ready; without a model (-NoStatusPage, or a page that couldn't be set
            # up) the T2 track process prompts the person itself, and its console lines reach this console.
            $context['PromptInParent'] = [bool]$ProgressPath
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
            Set-DemoProgressStep -Path $ProgressPath -Id 'Infrastructure' -State 'Running' -Message 'Deploying the template (about 7 to 9 minutes).'
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
            if ($t4StartSku) {
                $deployArguments['T4StartSku'] = $t4StartSku
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
            # What T4 got (Phase 28's Burstable fallback can change its size or leave it out): the tracks use it.
            $deployedT4 = Get-DemoMemberValue -InputObject $deployment -Name 'T4Enabled'
            if ($null -ne $deployedT4) {
                $deployedSku = [string](Get-DemoMemberValue -InputObject $deployment -Name 'T4SkuName')
                if ([bool]$deployedT4 -ne (Test-DemoT4Enabled -Config $Config) -or ([bool]$deployedT4 -and $deployedSku -and $deployedSku -ne (Get-DemoT4SkuName -Config $Config))) {
                    $copy = [ordered]@{}
                    foreach ($key in $Config.Keys) {
                        $copy[$key] = $Config[$key]
                    }
                    $copy['t4Enabled'] = [bool]$deployedT4
                    if ([bool]$deployedT4 -and $deployedSku) {
                        $copy['t4SkuName'] = $deployedSku
                    }
                    $Config = $copy
                    $skipT4 = -not [bool]$deployedT4
                }
            }
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
            & $applyPolicy 15
            $results.Add((New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status $(if (& $hasStatus $results.ToArray() 'Fail') { 'Fail' } else { 'Pass' }) -Message ('Stopped after {0} (-StopAfter).' -f $StopAfter)))
            return $results.ToArray()
        }
        & $ensureContext

        # The loader settings come from the template; a run that skipped it reads the last deployment's outputs.
        if ($null -eq $loaderSettings -and $needsArtifacts) {
            $outputs = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'sub', 'show', '--name', (Get-DemoMainDeploymentName -Config $Config), '--query', 'properties.outputs.loaderSettings.value', '--output', 'json') -AsJson -AllowFailure
            $loaderSettings = $outputs
        }
        $context['LoaderSettings'] = $loaderSettings
        if ($useJobs) {
            Write-DemoTrackHandoff -Path $handoff -Name 'infrastructure' -Value ([pscustomobject]@{ Succeeded = $true; LoaderSettings = $loaderSettings; T3UseFreeLimit = [bool]$context.T3UseFreeLimit; T4Enabled = (Test-DemoT4Enabled -Config $Config); T4SkuName = $(if (Test-DemoT4Enabled -Config $Config) { Get-DemoT4SkuName -Config $Config } else { '' }); Message = '' }) -Confirm:$false
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
        # The deferred policy inventory has had the whole run; it gets up to 5 more minutes.
        & $applyPolicy 5
    }
    finally {
        # Finished, failed, or stopped (Ctrl+C): no job process outlives deploy.ps1, within seconds, and the handoff
        # directory goes, with the tracks' private files in it. A job still running gets the cancel marker first, so its
        # slow Azure cleanups (Run Command deletes, the guided stop's Bastion removal and password rotation) are left to
        # the next deploy.ps1 or stop-demo.ps1 instead of holding the stop for minutes (Phase 28 live finding).
        $runJobs = @(@($jobs.Values) + @($buildJob) + @($policyJob) | Where-Object { $null -ne $_ })
        if ($handoff -and @($runJobs | Where-Object { $_.State -in 'NotStarted', 'Running', 'Stopping' }).Count -gt 0) {
            try {
                Write-DemoTrackHandoff -Path $handoff -Name 'cancel' -Value ([pscustomobject]@{ Reason = 'stopped'; Utc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }) -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Debug -Message ('The cancel marker wasn''t written: {0}' -f $_.Exception.Message)
            }
        }
        $ended = @(Stop-DemoRunJob -Job $runJobs)
        if ($ended.Count -gt 0) {
            Write-DemoLog -Level Warning -Message ('Stopped: {0} ended at once; the next ./scripts/deploy.ps1 continues their work.' -f ($ended -join ', '))
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
    # A track this run didn't start counts as finished when an earlier run finished it (the state's Track* tags).
    $trackFinished = {
        param([string] $Track, [string] $LastStep)
        if ($summaries.Contains($Track)) {
            return ([string]$summaries[$Track].Status -eq 'Pass')
        }
        return ([string](Get-DemoMemberValue -InputObject $state -Name ('Track{0}' -f $Track)) -eq $LastStep)
    }
    $allTracksDone = (& $trackFinished 'T1' 'Telemetry') -and (& $trackFinished 'T2' 'Telemetry') -and ($skipT4 -or (& $trackFinished 'T4' 'Telemetry')) -and ($SkipFabric -or (& $trackFinished 'Fabric' 'Fabric'))
    $installMode = if ([string]$Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $requirement = Get-DemoDoneRequirement -InstallMode $installMode -T4Off:$skipT4 -SkipFabric:$SkipFabric
    $validationStart = $results.Count
    if ($plan.Validation) {
        Set-DemoProgressStep -Path $ProgressPath -Id 'Validation' -State 'Running' -Message 'Checking Database Hub''s estate, telemetry, and metrics, and the Fabric items.'
        # T4's estate only when it's deployed: the Burstable fallback can leave it out of this run (Phase 28).
        $estateTargets = @(@(if ($t1Done) { 'T1', 'T3' }) + @(if ($t2Done) { 'T2' }) + @(if ($t4Done -and -not $skipT4) { 'T4' }))
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
        # DONE (Phase 28, brief item 16): once every track this configuration has is finished, with no Fail, each DONE
        # requirement this run's results don't show passing is checked now, read-only, so a resumed run judges every
        # target and not only the ones it worked on.
        if ($allTracksDone -and -not (& $hasStatus $results.ToArray() 'Fail')) {
            & $addAll @(Invoke-DemoDoneGate -Config $Config -Result $results.ToArray() -Requirement $requirement -TelemetryWaitMinutes $TelemetryWaitMinutes)
        }
        try {
            Set-DemoDeploymentState -Config $Config -Value @{ Stage = $(if ($allTracksDone) { 'Validation' } elseif ($t1Done) { 'Monitoring' } else { 'Infrastructure' }) } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The validation ran, but the stage wasn''t recorded: {0}' -f $_.Exception.Message)
        }
        $validationStatus = Get-DemoWorstStatus -Status @($results | Select-Object -Skip $validationStart | ForEach-Object { [string]$_.status })
        Set-DemoProgressStep -Path $ProgressPath -Id 'Validation' -Status $(if ($validationStatus) { $validationStatus } else { 'Pass' }) -Message $(if ($allTracksDone) { 'Database Hub''s estate, telemetry, and metrics checked for every target.' } else { 'Checked what finished; the rest waits for the unfinished tracks.' })
    }
    $mark.Invoke('Validation', $validationWatch)

    # 6. Timing and the summary.
    $all = $results.ToArray()
    $ready = [ordered]@{}
    foreach ($summary in $summaries.Values) {
        $readyValue = Get-DemoMemberValue -InputObject $summary -Name 'ReadyUtc'
        if ($readyValue -is [System.Collections.IDictionary]) {
            foreach ($key in $readyValue.Keys) {
                $ready[[string]$key] = [string]$readyValue[$key]
            }
        }
    }
    # The clock stops when DONE's requirements pass (ADR 0018, section 1, as amended by Phase 28: T4 included).
    $clockStopped = $allTracksDone -and (Test-DemoDoneEvidence -Result $all -Requirement $requirement).Complete
    $trackTiming = [ordered]@{}
    foreach ($track in $summaries.Keys) {
        $trackTiming[$track] = [ordered]@{ status = [string]$summaries[$track].Status; steps = $summaries[$track].Timing; startedUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'StartedUtc'); firstStepUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'FirstStepUtc'); endedUtc = [string](Get-DemoMemberValue -InputObject $summaries[$track] -Name 'EndedUtc'); early = @(Get-DemoMemberValue -InputObject $summaries[$track] -Name 'Early') }
    }
    $minutes = [math]::Round($clock.Elapsed.TotalMinutes, 1)
    $timing = [ordered]@{ startUtc = $startUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); endUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture); minutes = $minutes; phases = $phase; tracks = $trackTiming; targetReadyUtc = $ready; t2Source = $context.T2Source; clockStopped = $clockStopped; withinThirtyMinutes = ($clockStopped -and $minutes -le 30) }
    $timingMessage = if ($clockStopped) { 'Everything is deployed and populated in {0} minutes: Database Hub''s estate for every target, {1}{2}, T1''s inventory with only the engine{3}.' -f $minutes, $(if ($skipT4) { 'T1, T2, and T3 telemetry' } else { 'T1, T2, and T3 telemetry, T4''s metrics' }), $(if ($installMode -eq 'Developer') { '' } else { ', T2''s PAYG and monitoring' }), $(if ($SkipFabric) { '' } else { ', and the required Fabric items' }) } else { 'The run took {0} minutes; not every DONE requirement passed yet, so the clock didn''t stop (see DEPLOY.SUMMARY).' -f $minutes }
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
