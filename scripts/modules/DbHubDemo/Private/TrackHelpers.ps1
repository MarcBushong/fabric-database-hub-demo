function ConvertTo-DemoPlainTree {
    <#
    .SYNOPSIS
    Copies JSON-shaped data (objects, dictionaries, and arrays) into ordered hashtables and arrays, so values
    that came back from a template output or another process can be changed and serialized again. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $InputObject
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $copy[[string]$key] = ConvertTo-DemoPlainTree -InputObject $InputObject[$key]
        }
        return $copy
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @(foreach ($item in $InputObject) { ConvertTo-DemoPlainTree -InputObject $item })
    }
    $copy = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $copy[$property.Name] = ConvertTo-DemoPlainTree -InputObject $property.Value
    }
    return $copy
}

function Invoke-DemoBootstrapLoaderRun {
    <#
    .SYNOPSIS
    Runs the bootstrap loader on one VM in a managed Run Command with the parameters
    infra/modules/bootstrap.bicep gives it, and reports INFRA.BOOTSTRAP.LOADER_<VM> (ADR 0018). Internal.

    .DESCRIPTION
    deploy.ps1's parallel tracks run each VM's loader themselves instead of deploying the template a second
    time: two tracks never deploy the template at once, T1's SQL IaaS extension isn't updated again (about 10
    minutes of Updating, Phase 13), and each VM's loader runs as soon as its own chunks have arrived. The
    settings are the template's loaderSettings output (nothing secret) with the workload runner's SHA-256 and
    chunk count filled in; the loader receives them Base64-encoded, as from the template. A new value starts a
    new bootstrap generation, which re-checks every step.

    Source: managed Run Command, https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
    (checked 2026-10-22).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('sqlvm01', 'archost01')]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string] $BundleSha256,

        [Parameter(Mandatory)]
        [ValidateRange(1, 999)]
        [int] $ChunkCount,

        [Parameter(Mandatory)]
        [object] $Settings,

        [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
        [string] $RunnerSha256 = '',

        [ValidateRange(0, 999)]
        [int] $RunnerChunkCount = 0,

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1800,

        [ValidateRange(0, 7200)]
        [int] $StartTimeoutSeconds = 0
    )

    $role = if ($VmName -eq 'sqlvm01') { 'SqlVm' } else { 'ArcHost' }
    $target = Get-DemoVmTarget -VmName $VmName
    $checkId = 'INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $tree = ConvertTo-DemoPlainTree -InputObject $Settings
    if ($tree -isnot [System.Collections.IDictionary] -or [string]$tree['role'] -ne $role) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The loader settings for {0} are missing or name another role; nothing ran.' -f $VmName) -Remediation 'Run deploy.ps1 -FromStage Infrastructure: the template returns the settings as its loaderSettings output.' -DocUrl $docUrl)
    }
    if ($null -eq $tree['workload'] -or $tree['workload'] -isnot [System.Collections.IDictionary]) {
        $tree['workload'] = [ordered]@{}
    }
    $tree['workload']['runnerSha256'] = $RunnerSha256.ToLowerInvariant()
    $tree['workload']['runnerChunkCount'] = $RunnerChunkCount
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($tree | ConvertTo-Json -Depth 20 -Compress)))
    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/bootstrap/Invoke-DemoBootstrapLoader.ps1') -Raw
    $parameters = [ordered]@{
        BundleSha256 = $BundleSha256.ToLowerInvariant()
        ChunkCount   = [string]$ChunkCount
        Role         = $role
        SettingsJson = $encoded
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $run = Invoke-DemoVmRunCommand -Config $Config -VmName $VmName -RunCommandName 'DbHubDemo-Bootstrap' -Script $script -Parameter $parameters -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds 10 -StartTimeoutSeconds $StartTimeoutSeconds -Confirm:$false
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The bootstrap loader on {0} could not run: {1}' -f $VmName, (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run deploy.ps1 -Resume; a conflict with an extension that a policy installs clears within minutes.' -DocUrl $docUrl)
    }
    $evidence = [ordered]@{ vmName = $VmName; bundle = $BundleSha256.Substring(0, 12).ToLowerInvariant(); runner = $(if ($RunnerSha256) { $RunnerSha256.Substring(0, 12).ToLowerInvariant() } else { '' }); seconds = [int]$watch.Elapsed.TotalSeconds; notStarted = [bool](Get-DemoMemberValue -InputObject $run -Name 'NotStarted') }
    if ($null -ne $run -and $run.Succeeded) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Pass' -Message ('The bootstrap loader on {0} finished in {1} seconds: the bundle is verified and installed, and a new bootstrap generation is running.' -f $VmName, $evidence['seconds']) -Evidence $evidence -DocUrl $docUrl)
    }
    if ($evidence['notStarted']) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The bootstrap loader on {0} didn''t start within {1} minutes: the VM agent is still busy with Azure-side extension work.' -f $VmName, [int]($StartTimeoutSeconds / 60)) -Evidence $evidence -Remediation 'deploy.ps1''s watchdog restarts the VM once and runs the loader again; if it stays stuck, run ./scripts/deploy.ps1 again later.' -DocUrl $docUrl)
    }
    $detail = if ($null -eq $run) { 'no result' } elseif ($run.Error) { [string]$run.Error } else { [string]$run.Output }
    if ($detail.Length -gt 1000) {
        $detail = $detail.Substring($detail.Length - 1000)
    }
    $evidence['error'] = $detail
    return (New-DemoResult -CheckId $checkId -Area 'infra' -Target $target -Status 'Fail' -Message ('The bootstrap loader on {0} failed: {1}' -f $VmName, $detail) -Evidence $evidence -Remediation 'Read C:\ProgramData\DbHubDemo\logs\loader.log on the VM, then run deploy.ps1 -Resume, which sends the bundle again and re-runs the loader (ADR 0003).' -DocUrl $docUrl)
}

function Get-DemoStateLockName {
    # A named mutex per subscription and resource group, so the track processes on this machine record the
    # deployment state one at a time. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $text = '{0}/{1}' -f ([string]$Config['subscriptionId']).ToLowerInvariant(), (Get-DemoResourceGroupName -Config $Config).ToLowerInvariant()
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    return ('Local\DbHubDemoState-{0}' -f ([System.Convert]::ToHexString($hash).Substring(0, 16)))
}

function Set-DemoDeploymentStateLocked {
    <#
    .SYNOPSIS
    Set-DemoDeploymentState under a lock that the parallel tracks on this machine share. With -AddVm, it
    adds the VM to BundleSentTo or RunnerSentTo for that SHA-256 inside the lock (a list another track may be
    extending at the same moment). Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [System.Collections.IDictionary] $Value = @{},

        [ValidateSet('', 'Bundle', 'Runner')]
        [string] $AddKind = '',

        [string] $AddVm = '',

        [string] $Sha256 = '',

        [int] $ChunkCount = 0
    )

    if (-not $PSCmdlet.ShouldProcess((Get-DemoResourceGroupName -Config $Config), 'Record the deployment state under the tracks'' lock')) {
        return
    }
    $mutex = [System.Threading.Mutex]::new($false, (Get-DemoStateLockName -Config $Config))
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
        }
        catch [System.Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) {
            throw 'Another deploy.ps1 track held the deployment state lock for 5 minutes.'
        }
        $values = @{}
        foreach ($key in $Value.Keys) {
            $values[$key] = $Value[$key]
        }
        if ($AddKind) {
            $state = Get-DemoDeploymentState -Config $Config
            $currentSha = if ($AddKind -eq 'Bundle') { $state.BundleSha256 } else { $state.RunnerSha256 }
            $list = if ($AddKind -eq 'Bundle') { @($state.BundleSentTo) } else { @($state.RunnerSentTo) }
            if ($currentSha -ne $Sha256.ToLowerInvariant()) {
                $list = @()
            }
            $list = @(@($list) + $AddVm | Where-Object { $_ } | Select-Object -Unique)
            $values[('{0}Sha256' -f $AddKind)] = $Sha256.ToLowerInvariant()
            $values[('{0}ChunkCount' -f $AddKind)] = $ChunkCount
            $values[('{0}SentTo' -f $AddKind)] = $list
        }
        if ($values.Count -gt 0) {
            Set-DemoDeploymentState -Config $Config -Value $values -Confirm:$false
        }
    }
    finally {
        if ($owned) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-DemoTrackStep {
    # The steps of deploy.ps1's parallel tracks, in order, and the sequential stage each belongs to, which maps
    # -FromStage and -StopAfter onto the tracks (ADR 0018). T1's T3Setup belongs to stage T3 but runs first:
    # T3's telemetry starts about 10 minutes after its setup (live, 2026-10-22). T4 (Phase 24, ADR 0019) has a
    # track for the server's checks and its Azure Monitor metrics; its setup is T1's T4 step, because T1's
    # runner does it through action Run Command, one at a time on sqlvm01. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T4', 'Fabric')]
        [string] $Track
    )

    switch ($Track) {
        'T1' { return [ordered]@{ T3Setup = 'T3'; Artifacts = 'Artifacts'; Bootstraps = 'Bootstraps'; T3 = 'T3'; T4 = 'T4'; Activity = 'Activity'; Monitoring = 'Monitoring'; Telemetry = 'Validation' } }
        'T2' { return [ordered]@{ Restore = 'Artifacts'; Artifacts = 'Artifacts'; Bootstraps = 'Bootstraps'; T2 = 'T2'; Telemetry = 'Validation' } }
        'T4' { return [ordered]@{ Server = 'T4'; Telemetry = 'Validation' } }
        default { return [ordered]@{ Fabric = 'Fabric' } }
    }
}

function Write-DemoTrackHandoff {
    <#
    .SYNOPSIS
    Writes one value for deploy.ps1's track processes into the run's private handoff directory
    (Initialize-DemoPrivateDirectory) as PSSerializer XML, under a temporary name first and then renamed, so
    a reader never sees half a file (ADR 0018). Internal.

    .DESCRIPTION
    'artifacts' comes from the build process: Bundle, Runner, and Error. 'infrastructure' comes from
    deploy.ps1 once the template finished: Succeeded, LoaderSettings, T3UseFreeLimit, and Message. 'cancel' comes from
    deploy.ps1 when it stops the tracks (Ctrl+C, or their time limit): Reason and Utc; the track processes' finally
    blocks then skip their slow Azure cleanups (Test-DemoRunCancelled; Phase 28 live finding). Nothing in any of them
    is secret.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('artifacts', 'infrastructure', 'cancel')]
        [string] $Name,

        [Parameter(Mandatory)]
        [object] $Value
    )

    if (-not $PSCmdlet.ShouldProcess($Path, ('Hand {0} to the track processes' -f $Name))) {
        return
    }
    $xml = [System.Management.Automation.PSSerializer]::Serialize($Value, 20)
    $temporary = Write-DemoPrivateFile -Directory $Path -Name ('{0}.tmp' -f $Name) -Content $xml
    Move-Item -LiteralPath $temporary -Destination (Join-Path -Path $Path -ChildPath ('{0}.xml' -f $Name)) -Force
}

function Read-DemoTrackHandoff {
    <#
    .SYNOPSIS
    Reads a value that Write-DemoTrackHandoff wrote, waiting up to -TimeoutSeconds for it; $null when it isn't
    there in time. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('artifacts', 'infrastructure')]
        [string] $Name,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 2
    )

    $file = Join-Path -Path $Path -ChildPath ('{0}.xml' -f $Name)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            return [System.Management.Automation.PSSerializer]::Deserialize([System.IO.File]::ReadAllText($file))
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return $null
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Wait-DemoTrackEarlyStart {
    <#
    .SYNOPSIS
    In a track process that deploy.ps1 started before the template, waits until -Probe returns true or the
    parent's infrastructure handoff appears, whichever comes first. Returns Ready, Handoff, or TimedOut
    (ADR 0018). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $HandoffPath,

        [Parameter(Mandatory)]
        [scriptblock] $Probe,

        [ValidateRange(1, 600)]
        [int] $TimeoutMinutes = 120,

        [ValidateRange(1, 300)]
        [int] $ProbeSeconds = 15
    )

    $file = Join-Path -Path $HandoffPath -ChildPath 'infrastructure.xml'
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $nextProbe = [DateTime]::MinValue
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            return 'Handoff'
        }
        if ([DateTime]::UtcNow -ge $nextProbe) {
            $nextProbe = [DateTime]::UtcNow.AddSeconds($ProbeSeconds)
            if ([bool](& $Probe)) {
                return 'Ready'
            }
        }
        Start-Sleep -Seconds 2
    }
    return 'TimedOut'
}

function Test-DemoTrackDeploymentDone {
    <#
    .SYNOPSIS
    True when the resource group's nested deployment -Name (a VM's module, for example archost01) succeeded at
    or after -NotBeforeUtc, so the template has deployed that VM in this run, even while its other modules
    still deploy. A read ('az deployment group show'). Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]{1,64}$')]
        [string] $Name,

        [System.Nullable[datetime]] $NotBeforeUtc = $null
    )

    $read = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('deployment', 'group', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', $Name, '--query', '{state: properties.provisioningState, timestamp: properties.timestamp}') -AsJson -AllowFailure
    if ([string](Get-DemoMemberValue -InputObject $read -Name 'state') -ne 'Succeeded') {
        return $false
    }
    if ($null -eq $NotBeforeUtc) {
        return $true
    }
    $stamp = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $read -Name 'timestamp')
    return ($null -ne $stamp -and $stamp -ge $NotBeforeUtc)
}

function Resolve-DemoTrackPlan {
    <#
    .SYNOPSIS
    What a parallel deploy.ps1 run does: the parent's Preflight and Infrastructure stages, each track's steps,
    and the validation, from -FromStage, -StopAfter, and -Resume (ADR 0018). Internal.

    .DESCRIPTION
    A step runs when its sequential stage lies between -FromStage and -StopAfter, so those switches mean what
    they meant before. -Resume continues each track after the last step it recorded (DbHubTrackT1,
    DbHubTrackT2, DbHubTrackT4, DbHubTrackFabric); a group that only has the sequential DbHubDeployStage
    resumes after it. -SkipT4 (T4 off in the configuration) leaves the T4 track empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $FromStage = '',

        [string] $StopAfter = '',

        [switch] $Resume,

        [AllowNull()]
        [object] $State,

        [switch] $SkipFabric,

        [switch] $SkipT4
    )

    $stages = @(Get-DemoDeploymentStageName)
    $from = if ($FromStage) { [array]::IndexOf($stages, $FromStage) } else { 0 }
    $resumeTracks = $false
    if (-not $FromStage -and $Resume -and $null -ne $State) {
        $recorded = [string](Get-DemoMemberValue -InputObject $State -Name 'Stage')
        if ($recorded -and $recorded -in $stages) {
            $from = [System.Math]::Min([array]::IndexOf($stages, $recorded) + 1, [array]::IndexOf($stages, 'Validation'))
        }
        # Past the infrastructure, each track picks up after its own last step.
        if ($from -ge [array]::IndexOf($stages, 'Artifacts')) {
            $resumeTracks = $true
        }
    }
    $stop = if ($StopAfter) { [array]::IndexOf($stages, $StopAfter) } else { $stages.Count - 1 }
    $inRange = { param([string] $Stage) $i = [array]::IndexOf($stages, $Stage); $i -ge $from -and $i -le $stop }
    $tracks = [ordered]@{}
    foreach ($track in 'T1', 'T2', 'T4', 'Fabric') {
        if (($track -eq 'Fabric' -and $SkipFabric) -or ($track -eq 'T4' -and $SkipT4)) {
            $tracks[$track] = @()
            continue
        }
        $map = Get-DemoTrackStep -Track $track
        $names = @($map.Keys)
        $first = 0
        if ($resumeTracks) {
            $last = [string](Get-DemoMemberValue -InputObject $State -Name ('Track{0}' -f $track))
            if ($last -and $last -in $names) {
                $first = [array]::IndexOf($names, $last) + 1
            }
        }
        $tracks[$track] = @(for ($i = $first; $i -lt $names.Count; $i++) {
                $stage = $map[$names[$i]]
                # A resumed track's own record wins over the group's stage, except for the range -StopAfter ends.
                if (($resumeTracks -or (& $inRange $stage)) -and [array]::IndexOf($stages, $stage) -le $stop) {
                    $names[$i]
                }
            })
    }
    return [pscustomobject]@{
        Preflight      = (& $inRange 'Preflight')
        Infrastructure = (& $inRange 'Infrastructure')
        Tracks         = $tracks
        Validation     = (& $inRange 'Validation')
    }
}

function Invoke-DemoDeploymentTrack {
    <#
    .SYNOPSIS
    Runs one of deploy.ps1's parallel tracks in this process (ADR 0018). Returns Track, Status (Pass, Fail,
    Open, Background, or Stopped), Steps (finished), Timing (seconds per step), ReadyUtc (when each target's
    telemetry passed), StartedUtc, FirstStepUtc, EndedUtc, Early (what it did before the template finished),
    and Results. Internal.

    .DESCRIPTION
    - T1: T3Setup (T1 joins the P6 group and sets T3 up first, because T3's telemetry starts about ten
      minutes after its setup), Artifacts (the bundle and the runner to sqlvm01 together, chunks in
      parallel), Bootstraps (the loader; then T1's monitoring merge while the bootstrap runs; then T1 Ready),
      T3 (the T3Setup results, or the same work again when they didn't pass, then T3's workload and checks),
      T4 (Enable-DemoT4Workload: T1 sets T4 up through the P6 group; a T4 failure is reported but doesn't stop
      T1's track), Activity (T1, T3, and T4), Monitoring (the plugin confirmed), Telemetry (T1 and T3 in
      Database Hub).
    - T4 (Phase 24, ADR 0019): Server (Test-DemoT4: the server, its version and size, Entra-only, the network,
      the P6 administrator, the database, the enhanced metrics), Telemetry (METRICS.T4: Azure Monitor has its
      metrics, which Database Hub's PostgreSQL dashboard charts).
    - T2: Restore (a host restored from a golden snapshot: the VM agent, the host password, then the golden
      Release, which resets a copy's Arc identity locally and rotates the guest password before the guest
      reaches the network; archost01's bundle and runner travel in their own Run Commands while the Release
      runs), Artifacts (whatever didn't arrive) and Bootstraps (archost01), T2 (configure-arc's sequence:
      onboarding, the Azure extension for SQL Server, PAYG, and monitoring; -Force for a golden host),
      Telemetry (T2). A host that builds its guest instead reports DEPLOY.T2.BACKGROUND as Manual action
      required unless the context's WaitForT2 is set.
    - Fabric: the notebooks and the Real-Time Dashboard (configure-fabric.ps1 -SkipHubChecks), the history
      report, and the Fabric app; the Hub checklist and the tile check run in the validation.
    A track that deploy.ps1 started before the template (the context's HandoffPath) waits for the parent's
    word that the template succeeded, and takes the loader settings from it; the bundle and the runner come
    from the build process the same way. Meanwhile, T1 joins the T3 group as soon as sqlvm01 has its
    identity (Microsoft Graph only), and a T2 restored from a golden snapshot (the context's EarlyT2) starts
    its Restore as soon as archost01's own nested deployment succeeded, which comes after the template's
    resource group update, so no tag it writes can be overwritten. Each step's end is recorded in the
    track's tag under the tracks' shared lock; a Fail stops the track, and an exception is a Fail for that
    step.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T4', 'Fabric')]
        [string] $Track,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Context,

        [string[]] $Step = @()
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $timing = [ordered]@{}
    $ready = [ordered]@{}
    $done = [System.Collections.Generic.List[string]]::new()
    $status = 'Pass'
    $startedUtc = [DateTime]::UtcNow
    $firstStepUtc = $null
    # True when T1's Bootstraps step merged the monitoring flag in this run: the Monitoring step then gives a NotRunning
    # plugin the longer grace before the agent's restart (Get-DemoSqlVmPluginGrace; Phase 28 live finding, 2026-10-30).
    $monitoringMerged = $false
    $early = [System.Collections.Generic.List[string]]::new()
    $option = { param([string] $Name, $Default) if ($Context.Contains($Name) -and $null -ne $Context[$Name]) { $Context[$Name] } else { $Default } }
    $addAll = { param([object[]] $Items) foreach ($item in @($Items)) { if ($null -ne $item -and [string]$item.checkId -ne 'PREFLIGHT.GUARD.CONTEXT') { $results.Add($item) } } }
    $hasStatus = { param([object[]] $Items, [string[]] $Wanted) @($Items | Where-Object { $null -ne $_ -and [string]$_.status -in $Wanted }).Count -gt 0 }
    $note = {
        param([string] $CheckId, [string] $Target, [string] $Status, [string] $Message, [string] $Remediation = '', [System.Collections.IDictionary] $Evidence = @{})
        $results.Add((New-DemoResult -CheckId $CheckId -Area 'infra' -Target $Target -Status $Status -Message $Message -Remediation $Remediation -Evidence $Evidence))
    }
    $chunkSize = [int](& $option 'ChunkSizeKiB' 512)
    $parallelism = [int](& $option 'ChunkParallelism' 8)
    $profileName = if ($Config['activityProfile']) { [string]$Config['activityProfile'] } else { 'baseline' }
    $tagKey = 'Track{0}' -f $Track
    $recordState = -not [bool](& $option 'NoState' $false)
    $handoff = [string](& $option 'HandoffPath' '')
    $handoffMinutes = [int](& $option 'HandoffTimeoutMinutes' 120)
    # The status page's model (Phase 28); empty when there's none, and every update is then a no-op.
    $progress = [string](& $option 'ProgressPath' '')
    # Phase 28's settle waits and watchdog (brief item 14); tests shorten them through the context.
    $settleMinutes = [int](& $option 'SettleMinutes' 20)
    $settleAfterMinutes = [int](& $option 'SettleAfterRestartMinutes' 10)
    $settlePoll = [int](& $option 'SettlePollSeconds' 30)
    $loaderStartSeconds = [int](& $option 'LoaderStartSeconds' 900)
    # What the closures below share and change (a closure's assignments stay in its own scope).
    $shared = @{ Infrastructure = $null; Artifacts = $null; Sent = [System.Collections.Generic.HashSet[string]]::new(); Group = $null; Setup = $null; PrincipalId = ''; Settled = [System.Collections.Generic.HashSet[string]]::new() }

    # True when the template succeeded. A track started before it waits for deploy.ps1's word, then takes the
    # loader settings and T3's free-offer choice from it; a track started after it has nothing to wait for.
    $awaitInfrastructure = {
        if (-not $handoff) {
            return $true
        }
        if ($null -eq $shared['Infrastructure']) {
            Write-DemoLog -Message ('Track {0}: waiting for the template deployment.' -f $Track)
            $value = Read-DemoTrackHandoff -Path $handoff -Name 'infrastructure' -TimeoutSeconds ($handoffMinutes * 60)
            if ($null -eq $value) {
                $value = [pscustomobject]@{ Succeeded = $false; Message = ('deploy.ps1 didn''t report the template''s result within {0} minutes.' -f $handoffMinutes) }
            }
            $shared['Infrastructure'] = $value
            if ([bool](Get-DemoMemberValue -InputObject $value -Name 'Succeeded')) {
                $loaderValue = Get-DemoMemberValue -InputObject $value -Name 'LoaderSettings'
                if ($null -ne $loaderValue) {
                    $Context['LoaderSettings'] = $loaderValue
                }
                $freeValue = Get-DemoMemberValue -InputObject $value -Name 'T3UseFreeLimit'
                if ($null -ne $freeValue) {
                    $Context['T3UseFreeLimit'] = [bool]$freeValue
                }
                # T4's size as the template settled it (Phase 28's Burstable fallback), for T4's track and T1's T4 step.
                $t4Value = Get-DemoMemberValue -InputObject $value -Name 'T4Enabled'
                if ($null -ne $t4Value) {
                    $Config['t4Enabled'] = [bool]$t4Value
                }
                $t4Sku = [string](Get-DemoMemberValue -InputObject $value -Name 'T4SkuName')
                if ($t4Sku) {
                    $Config['t4SkuName'] = $t4Sku
                }
            }
        }
        return [bool](Get-DemoMemberValue -InputObject $shared['Infrastructure'] -Name 'Succeeded')
    }
    # The bundle and the runner: from the context in this process, or from the build process's handoff.
    $resolveArtifacts = {
        if ($null -eq $shared['Artifacts']) {
            if (-not $handoff -or $Context.Contains('Bundle')) {
                $shared['Artifacts'] = [pscustomobject]@{ Bundle = (& $option 'Bundle' $null); Runner = (& $option 'Runner' $null); Error = '' }
            }
            else {
                $value = Read-DemoTrackHandoff -Path $handoff -Name 'artifacts' -TimeoutSeconds 1800
                if ($null -eq $value) {
                    $value = [pscustomobject]@{ Bundle = $null; Runner = $null; Error = 'the build process reported nothing within 30 minutes' }
                }
                $shared['Artifacts'] = $value
            }
        }
        $problem = [string](Get-DemoMemberValue -InputObject $shared['Artifacts'] -Name 'Error')
        if ($problem) {
            throw ('The bootstrap bundle or the workload runner couldn''t be built: {0}' -f $problem)
        }
        return $shared['Artifacts']
    }

    # Sends the bundle and the runner to one VM, together, unless it already has exactly those chunks. What
    # this process already sent or confirmed isn't sent or reported again. -DuringRelease (archost01's artifacts while the
    # golden Release runs on it): no extension wait and no watchdog, which could restart the host mid-Release; a send that
    # gets stuck then throws, and the Artifacts step sends what's left afterward (review finding 6).
    $send = {
        param([string] $VmName, [bool] $DuringRelease = $false)
        $target = Get-DemoVmTarget -VmName $VmName
        $artifacts = & $resolveArtifacts
        $missing = [System.Collections.Generic.List[object]]::new()
        $state = $null
        foreach ($kind in 'Bundle', 'Runner') {
            $artifact = Get-DemoMemberValue -InputObject $artifacts -Name $kind
            $checkId = 'DEPLOY.ARTIFACTS.{0}_{1}' -f $kind.ToUpperInvariant(), $VmName.ToUpperInvariant()
            if ($null -eq $artifact) {
                if ($kind -eq 'Runner' -and $shared['Sent'].Add(('Runner/{0}/skipped' -f $VmName))) {
                    & $note $checkId $target 'Not selected' 'The workload runner was skipped (-SkipRunner); the WorkloadRunner steps report Not selected.'
                }
                continue
            }
            $sha = ([string]$artifact.Sha256).ToLowerInvariant()
            $key = '{0}/{1}/{2}' -f $kind, $VmName, $sha
            if ($shared['Sent'].Contains($key)) {
                continue
            }
            if ($null -eq $state) {
                $state = Get-DemoDeploymentState -Config $Config
            }
            $has = if ($kind -eq 'Bundle') { $state.BundleSha256 -eq $sha -and $VmName -in $state.BundleSentTo } else { $state.RunnerSha256 -eq $sha -and $VmName -in $state.RunnerSentTo }
            if ($has) {
                & $note $checkId $target 'Pass' ('{0} already has {1} {2}.' -f $VmName, $kind.ToLowerInvariant(), $sha.Substring(0, 12))
                $null = $shared['Sent'].Add($key)
                continue
            }
            $missing.Add([pscustomobject]@{ Kind = $kind; Artifact = $artifact; Sha = $sha; CheckId = $checkId; Key = $key })
        }
        if ($missing.Count -eq 0) {
            return
        }
        $files = @(foreach ($item in $missing) {
                [pscustomobject]@{ Path = [string]$item.Artifact.Path; Sha256 = $item.Sha; SizeBytes = [long](Get-DemoMemberValue -InputObject $item.Artifact -Name 'SizeBytes'); Description = $(if ($item.Kind -eq 'Bundle') { 'bootstrap bundle' } else { 'workload runner' }) }
            })
        # Phase 28 (brief item 14): the VM's extensions settle first, and a stuck chunk set gets the watchdog (the VM's
        # instance view saved, one restart) and one more try, one chunk at a time.
        $progressId = '{0}.Artifacts' -f $(if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' })
        if (-not $DuringRelease -and -not (& $settle $VmName $progressId)) {
            throw ('Azure''s extension work on {0} didn''t finish, so its artifacts weren''t sent (DEPLOY.EXTENSIONS_{1}).' -f $VmName, $VmName.ToUpperInvariant())
        }
        try {
            $sent = @(Send-DemoChunkSet -Config $Config -File $files -VmName $VmName -ChunkSizeKiB $chunkSize -Parallelism $parallelism)
        }
        catch {
            $problem = Protect-DemoText -Text $_.Exception.Message
            if ($DuringRelease -or $problem -match 'isn''t running|deallocated|changed after it was built|doesn''t exist|failed on the VM') {
                throw
            }
            Write-DemoLog -Level Warning -Message ('{0}: sending the artifacts got stuck ({1}); the watchdog steps in, then they go one chunk at a time.' -f $VmName, $problem)
            $watchdog = Invoke-DemoVmWatchdog -Config $Config -VmName $VmName -Cause ('sending its artifacts got stuck ({0})' -f $problem) -ProgressPath $progress -ProgressId $progressId
            $results.Add($watchdog.Result)
            try {
                $sent = @(Send-DemoChunkSet -Config $Config -File $files -VmName $VmName -ChunkSizeKiB $chunkSize -Parallelism 1)
            }
            catch {
                $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
                $results.Add((New-DemoVmStuckResult -VmName $VmName -What 'Sending the artifacts' -Item $activity.Labels -Minutes 30 -Restarted $watchdog.Restarted))
                throw ('Sending the artifacts to {0} is still stuck after the watchdog (DEPLOY.EXTENSIONS_{1}).' -f $VmName, $VmName.ToUpperInvariant())
            }
        }
        $first = @($sent | Select-Object -First 1)
        if ($first.Count -gt 0 -and [bool](Get-DemoMemberValue -InputObject $first[0] -Name 'Stalled')) {
            & $note ('DEPLOY.ARTIFACTS.STALL_{0}' -f $VmName.ToUpperInvariant()) $target 'Warning' ('{0}: no chunk finished for 5 minutes while several ran, so the rest went one at a time. Azure was busy with the VM''s extensions (Azure-side; nothing to do).' -f $VmName)
        }
        $leftover = if ($first.Count -gt 0) { @(Get-DemoMemberValue -InputObject $first[0] -Name 'LeftoverRunCommands') | Where-Object { $_ } } else { @() }
        if (@($leftover).Count -gt 0) {
            & $note ('DEPLOY.ARTIFACTS.CLEANUP_{0}' -f $VmName.ToUpperInvariant()) $target 'Warning' ('Azure was still deleting {0} chunk Run Command(s) on {1} when its artifacts arrived ({2}). That''s Azure-side and doesn''t block the loader (a VM allows 25 managed Run Commands); the next run''s cleanup checks again.' -f @($leftover).Count, $VmName, (@($leftover) -join ', ')) 'Nothing to do; if they stay for hours, see docs/troubleshooting.md (Run Commands stuck in Deleting).'
        }
        foreach ($item in $missing) {
            $one = @($sent | Where-Object { [string]$_.Sha256 -eq $item.Sha }) | Select-Object -First 1
            if ($recordState) {
                Set-DemoDeploymentStateLocked -Config $Config -AddKind $item.Kind -AddVm $VmName -Sha256 $item.Sha -ChunkCount ([int]$one.ChunkCount) -Confirm:$false
            }
            $together = if ($missing.Count -gt 1) { ', in one wave with the other artifact' } else { '' }
            & $note $item.CheckId $target 'Pass' ('{0} {1} sent to {2} in {3} chunk(s), {4:N0} seconds{5}.' -f $item.Kind, $item.Sha.Substring(0, 12), $VmName, $one.ChunkCount, $one.Seconds, $together) '' ([ordered]@{ chunks = [int]$one.ChunkCount; seconds = $one.Seconds; parallelism = $parallelism; together = ($missing.Count -gt 1) })
            $null = $shared['Sent'].Add($item.Key)
        }
    }
    # Runs a VM's loader with the chunks that reached it, then reports the result. Its extensions settle first; a loader
    # that doesn't start within LoaderStartSeconds gets the watchdog and one more try (brief item 14).
    $load = {
        param([string] $VmName, [string] $SettingsKey)
        $state = Get-DemoDeploymentState -Config $Config
        if (-not $state.BundleSha256 -or $VmName -notin $state.BundleSentTo) {
            & $note ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) (Get-DemoVmTarget -VmName $VmName) 'Fail' ('The bootstrap bundle hasn''t reached {0}, so its loader can''t run.' -f $VmName) 'Run deploy.ps1 -FromStage Artifacts.'
            return $false
        }
        $progressId = '{0}.Bootstraps' -f $(if ($VmName -eq 'sqlvm01') { 'T1' } else { 'T2' })
        if (-not (& $settle $VmName $progressId)) {
            return $false
        }
        $settings = Get-DemoMemberValue -InputObject (& $option 'LoaderSettings' $null) -Name $SettingsKey
        $runnerSha = if ($state.RunnerSha256 -and $VmName -in $state.RunnerSentTo) { $state.RunnerSha256 } else { '' }
        $runLoader = { Invoke-DemoBootstrapLoaderRun -Config $Config -VmName $VmName -BundleSha256 $state.BundleSha256 -ChunkCount $state.BundleChunkCount -Settings $settings -RunnerSha256 $runnerSha -RunnerChunkCount $(if ($runnerSha) { $state.RunnerChunkCount } else { 0 }) -StartTimeoutSeconds $loaderStartSeconds }
        $loader = & $runLoader
        if ($loader.status -ne 'Pass' -and [bool](Get-DemoMemberValue -InputObject $loader.evidence -Name 'notStarted')) {
            $watchdog = Invoke-DemoVmWatchdog -Config $Config -VmName $VmName -Cause ('its bootstrap loader didn''t start within {0} minutes' -f [int]($loaderStartSeconds / 60)) -ProgressPath $progress -ProgressId $progressId
            $results.Add($watchdog.Result)
            $loader = & $runLoader
            if ($loader.status -ne 'Pass' -and [bool](Get-DemoMemberValue -InputObject $loader.evidence -Name 'notStarted')) {
                $activity = Get-DemoVmExtensionActivity -Config $Config -VmName $VmName
                $results.Add((New-DemoVmStuckResult -VmName $VmName -What 'The bootstrap loader' -Item $activity.Labels -Minutes ([int](2 * $loaderStartSeconds / 60)) -Restarted $watchdog.Restarted))
            }
        }
        $results.Add($loader)
        if ($VmName -eq 'archost01' -and -not [bool](Get-DemoMemberValue -InputObject $loader.evidence -Name 'notStarted')) {
            # The loader ran, so a bootstrap generation that may build the guest has started (review follow-up).
            & $recordT2Build ([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture))
        }
        return ($loader.status -eq 'Pass')
    }
    # Records when the T2 host's loader started a bootstrap generation, or clears it once nothing is building: after the
    # Release of a new golden copy and after the T2 step. While it's set, the watchdog never restarts the host; the record
    # survives a rerun that repeats earlier steps, which the track's own step tag doesn't (Get-DemoHostRestartBlocker).
    $recordT2Build = {
        param([string] $Value)
        if (-not $recordState) {
            return
        }
        try {
            Set-DemoDeploymentStateLocked -Config $Config -Value @{ T2BuildUtc = $Value } -Confirm:$false
        }
        catch {
            Write-DemoLog -Level Warning -Message ('Track T2: archost01''s bootstrap generation wasn''t recorded: {0}' -f $_.Exception.Message)
        }
    }
    # Waits for a VM's extensions to settle before its next Run Command, once per step (Invoke-DemoVmSettle).
    $settle = {
        param([string] $VmName, [string] $ProgressId)
        $key = '{0}/{1}' -f $VmName, $ProgressId
        if ($shared['Settled'].Contains($key)) {
            return $true
        }
        $wait = Invoke-DemoVmSettle -Config $Config -VmName $VmName -ProgressPath $progress -ProgressId $ProgressId -FirstMinutes $settleMinutes -AfterRestartMinutes $settleAfterMinutes -PollSeconds $settlePoll
        & $addAll @($wait.Results)
        if ($wait.Settled) {
            $null = $shared['Settled'].Add($key)
        }
        return [bool]$wait.Settled
    }
    $telemetry = {
        param([string[]] $Targets, [string] $StepId = '')
        # A target whose data didn't come gets its monitoring checked, and its telemetry once more, before the step fails
        # (Invoke-DemoTelemetryCheck; Phase 28 live finding, 2026-10-30).
        $checks = @(Invoke-DemoTelemetryCheck -Config $Config -Target $Targets -WaitMinutes ([int](& $option 'TelemetryWaitMinutes' 15)) -ProgressPath $progress -ProgressStepId $StepId)
        & $addAll $checks
        foreach ($target in $Targets) {
            if (@($checks | Where-Object { [string]$_.checkId -eq ('TELEMETRY.{0}' -f $target) -and [string]$_.status -eq 'Pass' }).Count -gt 0) {
                $ready[$target] = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        return (-not (& $hasStatus $checks 'Fail'))
    }
    # T1 joins the P6 group: early (before the template finished) when that passed, or now.
    $joinGroup = {
        $group = $shared['Group']
        if ($null -eq $group -or [string]$group.status -ne 'Pass') {
            $group = Add-DemoT1ToT3AdminGroup -Config $Config -PrincipalId (Get-DemoT1PrincipalId -Config $Config)
            $shared['Group'] = $group
        }
        return $group
    }

    # One part of a step the status page shows on its own (Phase 28): Done with its worst ADR 0012 status, and the first
    # result that isn't a Pass as its message.
    $partDone = {
        param([string[]] $Ids, [object[]] $Items)
        $worst = Get-DemoWorstStatus -Status @($Items | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.status })
        $partState = if ($worst) { ConvertTo-DemoProgressState -Status $worst } else { 'Done' }
        $firstOpen = @($Items | Where-Object { $null -ne $_ -and [string]$_.status -notin 'Pass', 'Not selected' } | Select-Object -First 1)
        Set-DemoProgressStep -Path $progress -Id $Ids -State $partState -Status $worst -Message $(if ($firstOpen.Count -gt 0) { [string]$firstOpen[0].message } else { '' })
    }

    # Before the template finished: only what can't collide with it (ADR 0018).
    $earlyRestore = $false
    if ($handoff -and @($Step).Count -gt 0) {
        if ($Track -eq 'T2' -and [bool](& $option 'EarlyT2' $false) -and @($Step)[0] -eq 'Restore') {
            $notBefore = ConvertTo-DemoRunCommandUtc -Value (& $option 'EarlyStartUtc' '')
            $probe = { Test-DemoTrackDeploymentDone -Config $Config -Name 'archost01' -NotBeforeUtc $notBefore }
            if ((Wait-DemoTrackEarlyStart -HandoffPath $handoff -Probe $probe -TimeoutMinutes $handoffMinutes) -eq 'Ready') {
                $earlyRestore = $true
                $early.Add('Restore')
                Write-DemoLog -Message 'Track T2: the template has deployed archost01, so its restore starts while the rest of the template deploys.'
            }
        }
        elseif ($Track -eq 'T1' -and 'T3Setup' -in $Step) {
            # Microsoft Graph only: T1's identity joins the T3 group while the template still deploys, so the
            # membership has settled when T3Setup asks for an Azure SQL token.
            $probe = {
                $id = Get-DemoT1PrincipalId -Config $Config
                if ($id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    $shared['PrincipalId'] = $id
                    return $true
                }
                return $false
            }
            if ((Wait-DemoTrackEarlyStart -HandoffPath $handoff -Probe $probe -TimeoutMinutes $handoffMinutes) -eq 'Ready') {
                try {
                    $shared['Group'] = Add-DemoT1ToT3AdminGroup -Config $Config -PrincipalId $shared['PrincipalId']
                    $early.Add('T3 group')
                    Write-DemoLog -Message ('Track T1: T1''s identity and the T3 group, before the template finished: {0}' -f $shared['Group'].message)
                }
                catch {
                    Write-DemoLog -Level Warning -Message ('Track T1: T1 couldn''t join the T3 group before the template finished; T3Setup tries again: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
                }
            }
        }
    }

    foreach ($name in $Step) {
        # Every step waits for the template, except the restore of a T2 host the template has already deployed.
        if (-not ($earlyRestore -and $name -eq 'Restore') -and -not (& $awaitInfrastructure)) {
            Write-DemoLog -Level Warning -Message ('Track {0} stops before {1}: {2}' -f $Track, $name, $(if ([string](Get-DemoMemberValue -InputObject $shared['Infrastructure'] -Name 'Message')) { [string]$shared['Infrastructure'].Message } else { 'the template deployment didn''t succeed.' }))
            $status = 'Stopped'
            break
        }
        if ($null -eq $firstStepUtc) {
            $firstStepUtc = [DateTime]::UtcNow
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-DemoLog -Message ('Track {0}: {1}.' -f $Track, $name)
        # The status page (Phase 28): the step runs; T2's T2 step and the Fabric step report their own parts.
        $stepIds = @(Get-DemoProgressStepId -Track $Track -Step $name)
        $ownProgress = ('{0}/{1}' -f $Track, $name) -in 'T2/T2', 'Fabric/Fabric'
        $resultsBefore = $results.Count
        if (-not $ownProgress -and $stepIds.Count -gt 0) {
            Set-DemoProgressStep -Path $progress -Id $stepIds -State 'Running' -Message ''
        }
        $outcome = 'Pass'
        try {
            switch ('{0}/{1}' -f $Track, $name) {
                'T1/T3Setup' {
                    # T3's telemetry starts about ten minutes after its setup (live, 2026-10-22), so T3 is set up
                    # before T1's artifacts. This step never stops the track: the T3 step reports its results, or
                    # does the same work again when they didn't pass.
                    try {
                        $group = & $joinGroup
                        if ([string]$group.status -eq 'Pass') {
                            $shared['Setup'] = Invoke-DemoT3SqlFromT1 -Config $Config -Name Setup
                        }
                    }
                    catch {
                        Write-DemoLog -Level Warning -Message ('Track T1: T3''s early setup failed; the T3 step runs it again: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
                    }
                }
                'T1/Artifacts' {
                    & $send 'sqlvm01'
                }
                'T1/Bootstraps' {
                    if (-not (& $load 'sqlvm01' 'sqlVm')) {
                        $outcome = 'Fail'
                        break
                    }
                    if ('Monitoring' -in $Step) {
                        # The documented feature-flag merge right after the loader started T1's bootstrap, while no
                        # Run Command runs on sqlvm01: the plugin starts during the bootstrap, and the Monitoring
                        # step confirms it (ADR 0018).
                        try {
                            $merge = Enable-DemoSqlVmMonitoring -Config $Config -WaitMinutes 0 -Confirm:$false
                            $mergeActions = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $merge -Name 'evidence') -Name 'actions'
                            $monitoringMerged = @($mergeActions | Where-Object { $_ }).Count -gt 0
                            Write-DemoLog -Message ('Track T1: T1''s monitoring, set while T1 bootstraps: {0}' -f $merge.message)
                        }
                        catch {
                            Write-DemoLog -Level Warning -Message ('Track T1: T1''s monitoring couldn''t be set while T1 bootstraps; the Monitoring step sets it: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
                        }
                    }
                    $minutes = [int](& $option 'T1WaitMinutes' 45)
                    $wait = Wait-DemoVmHealthState -Config $Config -VmName 'sqlvm01' -State @('Ready', 'Failed', 'ManualActionRequired') -MaxPolls ([System.Math]::Max(1, $minutes)) -PollSeconds 60
                    $state = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'state')
                    $message = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'message')
                    if ($state -eq 'Ready') {
                        & $note 'DEPLOY.T1.READY' 'T1' 'Pass' ('T1''s bootstrap is Ready: {0}' -f $message)
                    }
                    elseif ($state -eq 'Failed') {
                        & $note 'DEPLOY.T1.READY' 'T1' 'Fail' ('T1''s bootstrap failed: {0}' -f $message) 'Read C:\ProgramData\DbHubDemo\logs on sqlvm01 (Get-DemoVmHealth -View Full), fix the cause, then run deploy.ps1 -FromStage Artifacts.'
                        $outcome = 'Fail'
                    }
                    else {
                        & $note 'DEPLOY.T1.READY' 'T1' 'Warning' ('T1 isn''t Ready after {0} minutes (state {1}: {2}).' -f $minutes, $state, $message) 'Run deploy.ps1 -Resume later; the bootstrap keeps converging on its own.'
                        $outcome = 'Open'
                    }
                }
                'T1/T3' {
                    $group = & $joinGroup
                    $results.Add($group)
                    if ($group.status -eq 'Fail') {
                        $outcome = 'Fail'
                        break
                    }
                    if ($group.status -eq 'Manual action required') {
                        $outcome = 'Open'
                        break
                    }
                    $setup = $shared['Setup']
                    if ($null -ne $setup -and [string]$setup.Status -ne 'Pass') {
                        & $note 'DEPLOY.T3.EARLYSETUP' 'T3' 'Warning' ('T3''s setup at the start of T1''s track didn''t pass ({0}), so the T3 step ran it again.' -f [string](Get-DemoMemberValue -InputObject $setup.Result -Name 'message'))
                        $setup = $null
                    }
                    if ($null -eq $setup) {
                        $setup = Invoke-DemoT3SqlFromT1 -Config $Config -Name Setup
                    }
                    $results.Add($setup.Result)
                    if ($setup.Status -eq 'Fail') {
                        $outcome = 'Fail'
                        break
                    }
                    $current = Get-DemoDeploymentState -Config $Config
                    if ($current.RunnerSha256 -and 'sqlvm01' -in $current.RunnerSentTo) {
                        $results.Add((Enable-DemoT3Workload -Config $Config -Confirm:$false))
                    }
                    $checks = @(Test-DemoT3 -Config $Config -NetworkMode ([string]$Context['NetworkMode']) -T3UseFreeLimit ([bool]$Context['T3UseFreeLimit']))
                    & $addAll $checks
                    if (& $hasStatus $checks 'Fail') {
                        $outcome = 'Fail'
                    }
                }
                'T1/T4' {
                    # T4 (Phase 24): T1's runner sets T4 up through the P6 group. A failure is reported (and in
                    # DEPLOY.SUMMARY) but doesn't stop T1's track, so T1 to T3 still get their activity and checks.
                    if (-not (Test-DemoT4Enabled -Config $Config)) {
                        & $note 'WORKLOAD.T4.ENABLE' 'T4' 'Not selected' 'T4 is off in this configuration (t4Enabled is false).'
                        break
                    }
                    $current = Get-DemoDeploymentState -Config $Config
                    if (-not ($current.RunnerSha256 -and 'sqlvm01' -in $current.RunnerSentTo)) {
                        & $note 'WORKLOAD.T4.ENABLE' 'T4' 'Not selected' 'No workload runner was deployed to T1 (-SkipRunner), so T4 wasn''t set up.'
                        break
                    }
                    $group = & $joinGroup
                    if ([string]$group.status -notin 'Pass', 'Warning') {
                        & $note 'WORKLOAD.T4.ENABLE' 'T4' 'Manual action required' 'T1 isn''t in the P6 group yet, so it can''t sign in to T4 as the group''s role.' 'Add T1 to the group (Add-DemoT1ToT3AdminGroup describes how), then run deploy.ps1 -FromStage T4.'
                        break
                    }
                    $enable = Enable-DemoT4Workload -Config $Config -PrincipalId ([string](Get-DemoMemberValue -InputObject $group -Name 'evidence').principalId) -Confirm:$false
                    if ($enable.status -in 'Fail', 'Manual action required' -and -not $enable.remediation) {
                        $enable.remediation = 'Fix the cause, then run deploy.ps1 -FromStage T4.'
                    }
                    $results.Add($enable)
                }
                'T1/Activity' {
                    $current = Get-DemoDeploymentState -Config $Config
                    $skip = if ($current.RunnerSha256) { '' } else { 'No workload runner was deployed (-SkipRunner).' }
                    foreach ($target in @('T1', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' })) {
                        $results.Add((Set-DemoTargetProfile -Config $Config -Target $target -ProfileName $profileName -CheckPrefix 'DEPLOY' -SkipReason $skip -RequestedBy 'deploy'))
                    }
                }
                'T1/Monitoring' {
                    # Live (2026-10-30): a plugin that reports NotRunning rarely starts by itself, and the agent's restart
                    # brings it back, so the wait gives it only a short grace (3 minutes when the flag was set before this
                    # run, 5 when this run merged it), counted in elapsed time, with a console line and the status page
                    # saying so; after a restart that worked, T1.SQLVM.MONITORING is read again (Invoke-DemoSqlVmMonitoringWait).
                    $monitoring = @(Invoke-DemoSqlVmMonitoringWait -Config $Config -WaitMinutes ([int](& $option 'MonitoringWaitMinutes' 20)) -JustMerged:$monitoringMerged -ProgressPath $progress)
                    & $addAll $monitoring
                    if ([string]$monitoring[0].status -eq 'Fail') {
                        $outcome = 'Fail'
                    }
                }
                'T1/Telemetry' {
                    $targets = if ('T3' -in $done) { @('T1', 'T3') } else { @('T1') }
                    if (-not (& $telemetry $targets 'T1.Telemetry')) {
                        $outcome = 'Fail'
                    }
                }
                'T2/Restore' {
                    $source = [string](& $option 'T2Source' '')
                    if ($source -notin 'golden', 'existing-golden') {
                        # A host built from the image may be a golden snapshot's source, air-gapped by the capture.
                        $sourceRelease = if ($source -eq 'existing-build') { Invoke-DemoGoldenSourceRelease -Config $Config } else { $null }
                        if ($null -ne $sourceRelease) {
                            $results.Add($sourceRelease)
                            if ($sourceRelease.status -eq 'Fail') {
                                $outcome = 'Fail'
                            }
                            break
                        }
                        & $note 'DEPLOY.T2.RESTORE' 'T2' 'Not selected' 'archost01 is built from the image (PREFLIGHT.T2.SOURCE), so there''s nothing to restore.'
                        break
                    }
                    $agentSeconds = Wait-DemoVmAgentReady -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName 'archost01' -TimeoutMinutes 20
                    if ($source -eq 'golden') {
                        # A new host restored from a snapshot: passwords first (guardrail 5).
                        $password = Set-DemoVmLocalPassword -Config $Config -VmName 'archost01' -Rotate -Confirm:$false
                        $results.Add($password)
                        # A Warning: the password is set, and the Windows PowerShell log that recorded it was cleared (Phase 26f).
                        if ($password.status -notin 'Pass', 'Warning') {
                            $outcome = 'Fail'
                            break
                        }
                    }
                    # archost01's bundle and runner travel in their own Run Commands while the Release runs; they
                    # put nothing on the network, and the Artifacts step sends whatever didn't arrive (ADR 0018). No
                    # extension wait or watchdog meanwhile: a restart would interrupt the Release (review finding 6).
                    $alongside = if ('Artifacts' -in $Step) { { & $send 'archost01' $true } } else { $null }
                    $release = Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' -TimeoutSeconds 3600 -WhileRunning $alongside
                    if ([string](Get-DemoMemberValue -InputObject $release -Name 'WhileRunningError')) {
                        Write-DemoLog -Level Warning -Message ('Track T2: archost01''s artifacts didn''t all arrive during the Release; the Artifacts step sends them: {0}' -f $release.WhileRunningError)
                    }
                    $data = $release.Data
                    $evidence = [ordered]@{
                        agentReadySeconds    = $agentSeconds
                        seconds              = $release.Seconds
                        role                 = [string](Get-DemoMemberValue -InputObject $data -Name 'role')
                        captured             = Get-DemoMemberValue -InputObject $data -Name 'captured'
                        agentBefore          = Get-DemoMemberValue -InputObject $data -Name 'agentBefore'
                        reset                = Get-DemoMemberValue -InputObject $data -Name 'reset'
                        resetDecision        = [string](Get-DemoMemberValue -InputObject $data -Name 'resetDecision')
                        sqlService           = [string](Get-DemoMemberValue -InputObject $data -Name 'sqlService')
                        sqlEdition           = [string](Get-DemoMemberValue -InputObject $data -Name 'sqlEdition')
                        sqlWait              = Get-DemoMemberValue -InputObject $data -Name 'sqlWait'
                        guestBootSeconds     = Get-DemoMemberValue -InputObject $data -Name 'guestBootSeconds'
                        guestPassword        = [string](Get-DemoMemberValue -InputObject $data -Name 'guestPassword')
                        guestState           = [string](Get-DemoMemberValue -InputObject $data -Name 'guestState')
                        adapter              = Get-DemoMemberValue -InputObject $data -Name 'adapter'
                        artifactsAlongside   = ($null -ne $alongside)
                        beforeTemplateFinish = $earlyRestore
                    }
                    if (-not $release.Succeeded) {
                        & $note 'DEPLOY.T2.RESTORE' 'T2' 'Fail' ('archost01''s guest wasn''t released: {0}' -f $release.Error) 'Read the error, fix the cause, and run deploy.ps1 -FromStage Artifacts; the release is safe to run again.' $evidence
                        $outcome = 'Fail'
                        break
                    }
                    $resetText = switch ($(if ($evidence['resetDecision'] -eq 'IdentityUnknown') { 'IdentityUnknown' } else { [string]$evidence['reset'] })) {
                        'IdentityUnknown' { 'the guest''s Arc agent named no resource while air-gapped, so its identity was reset locally anyway' }
                        'SkippedNoIdentity' { 'the guest''s Arc agent held no identity, so there was nothing to reset' }
                        'SkippedOtherIdentity' { 'the guest''s Arc agent named another identity, not the captured one, so it wasn''t reset' }
                        default { 'the guest''s Arc identity was reset locally' }
                    }
                    # A copy that an earlier run released returns no reset, edition, or rotation: the Release only reconnected it.
                    $releasedEarlier = $evidence['role'] -eq 'Copy' -and [string]::IsNullOrEmpty([string]$evidence['reset'])
                    $message = if ($releasedEarlier) { 'archost01 is a copy of the golden snapshot that an earlier run released; its guest is on its network and starts with the host.' } elseif ($evidence['role'] -eq 'Copy') { 'archost01 is a copy of the golden snapshot: {0}, SQL Server runs {1}, the guest''s password was rotated, and the guest is back on its network.' -f $resetText, $evidence['sqlEdition'] } elseif ($evidence['captured']) { 'archost01 is the host the snapshot was taken from: its guest is reconnected and starts with the host again.' } else { 'archost01 has no capture record: nothing to release.' }
                    & $note 'DEPLOY.T2.RESTORE' 'T2' 'Pass' $message '' $evidence
                    # A copy that this Release just released runs no bootstrap generation until its loader starts one, so
                    # the record goes (review follow-up). One that an earlier run released keeps it: that run's loader may
                    # have started a generation since.
                    if ($evidence['role'] -eq 'Copy' -and -not $releasedEarlier) {
                        & $recordT2Build ''
                    }
                }
                'T2/Artifacts' {
                    & $send 'archost01'
                }
                'T2/Bootstraps' {
                    if (-not (& $load 'archost01' 'host')) {
                        $outcome = 'Fail'
                    }
                }
                'T2/T2' {
                    $source = [string](& $option 'T2Source' '')
                    $golden = $source -in 'golden', 'existing-golden'
                    $waiting = -not $golden -and [bool](& $option 'WaitForT2' $false)
                    $installMode = (Get-DemoArcTarget -Config $Config).InstallMode
                    $arcArguments = @{ Config = $Config; WaitMinutes = [int](& $option 'ArcWaitMinutes' 45); Confirm = $false }
                    if ($golden) {
                        $arcArguments['Force'] = $true
                    }
                    elseif ($waiting) {
                        # Phase 28: wait for the build (bounded by T2WaitMinutes) with progress, then, in PaygWizard mode, the
                        # guided stop; then configure-arc's sequence waits for the host to finish after setup.
                        $t2Deadline = [DateTime]::UtcNow.AddMinutes([int](& $option 'T2WaitMinutes' 180))
                        $build = Wait-DemoT2HostBuild -Config $Config -DeadlineUtc $t2Deadline -ProgressPath $progress -PollSeconds ([int](& $option 'HostPollSeconds' 300)) -StartedUtc $firstStepUtc
                        if ($build.Failed) {
                            Set-DemoProgressStep -Path $progress -Id 'T2.HostBuild' -State 'Failed' -Status 'Fail' -Message ([string](Get-DemoMemberValue -InputObject $build.Health -Name 'message'))
                            & $note 'DEPLOY.T2.HOST' 'T2' 'Fail' ('archost01 failed at step {0}: {1}' -f [string](Get-DemoMemberValue -InputObject $build.Health -Name 'currentStep'), [string](Get-DemoMemberValue -InputObject $build.Health -Name 'message')) 'Read archost01''s health (Get-DemoVmHealth -VmName archost01 -View Full) and C:\ProgramData\DbHubDemo\logs on it, fix the cause, then run ./scripts/deploy.ps1 again.'
                            $outcome = 'Fail'
                            break
                        }
                        if ($build.TimedOut) {
                            Set-DemoProgressStep -Path $progress -Id 'T2.HostBuild' -State 'Action needed' -Status 'Manual action required' -Message 'The build didn''t finish within the wait.'
                            & $note 'DEPLOY.T2.WAIT' 'T2' 'Manual action required' ('archost01''s guest build didn''t finish within {0} minutes (it reports step {1}); it goes on in the background.' -f [int](& $option 'T2WaitMinutes' 180), [string](Get-DemoMemberValue -InputObject $build.Health -Name 'currentStep')) 'Run ./scripts/deploy.ps1 again (or ./scripts/deploy.ps1 -FromStage T2): it waits for T2 again and continues. A slow first build is in docs/troubleshooting.md.'
                            $outcome = 'Open'
                            break
                        }
                        Set-DemoProgressStep -Path $progress -Id 'T2.HostBuild' -State 'Done' -Status 'Pass' -Message 'The host and its guest are built.'
                        if ($installMode -eq 'PaygWizard') {
                            $guided = Invoke-DemoT2GuidedStop -Config $Config -Context $Context -Health $build.Health -DeadlineUtc $t2Deadline
                            & $addAll @($guided.Results)
                            if ($guided.Status -eq 'Failed') {
                                $outcome = 'Fail'
                                break
                            }
                            if ($guided.Status -in 'TimedOut', 'Stopped') {
                                $outcome = 'Open'
                                break
                            }
                        }
                        $left = [int][System.Math]::Max(30, ($t2Deadline - [DateTime]::UtcNow).TotalMinutes)
                        $arcArguments['WaitForHostMinutes'] = [System.Math]::Min(360, $left)
                        Set-DemoProgressStep -Path $progress -Id 'T2.SignInCleanup' -State 'Running' -Message 'archost01 removes the sign-in data setup and Arc onboarding leave, then configures and seeds the database.'
                    }
                    else {
                        $arcArguments['WaitForHostMinutes'] = 0
                    }
                    Set-DemoProgressStep -Path $progress -Id 'T2.Monitoring' -State 'Running' -Message 'Arc onboarding, the Azure extension for SQL Server, PAYG, and monitoring.'
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
                    $onboarding = @($arc | Where-Object { [string]$_.checkId -in 'T2.ARC.ONBOARDING', 'T2.ARC.CONNECTED' })
                    if ($onboarding.Count -gt 0) {
                        & $partDone 'T2.ArcOnboarding' $onboarding
                    }
                    if (& $hasStatus $arc 'Fail') {
                        $outcome = 'Fail'
                        break
                    }
                    $connected = @($arc | Where-Object { [string]$_.checkId -eq 'T2.ARC.CONNECTED' -and $_.status -eq 'Pass' }).Count -gt 0
                    if ((& $hasStatus $arc 'Manual action required') -or -not $connected) {
                        if (-not $golden -and -not [bool](& $option 'WaitForT2' $false)) {
                            & $note 'DEPLOY.T2.BACKGROUND' 'T2' 'Manual action required' 'archost01 builds its guest in the background (-NoWaitForT2, or a run in CI); T1, T3, T4, and Fabric didn''t wait for it.' 'Run ./scripts/deploy.ps1 again in about an hour, without -NoWaitForT2: it waits for T2, guides you through its one step in PaygWizard mode, and finishes it. ./scripts/status.ps1 shows where the host is.'
                            Set-DemoProgressStep -Path $progress -Id 'T2.Monitoring' -State 'Skipped' -Message 'T2 builds in the background; a later ./scripts/deploy.ps1 finishes it.'
                            $outcome = 'Background'
                        }
                        else {
                            Set-DemoProgressStep -Path $progress -Id 'T2.Monitoring' -State 'Action needed' -Status 'Manual action required' -Message ((@($arc | Where-Object { [string]$_.status -eq 'Manual action required' } | Select-Object -First 1 | ForEach-Object { [string]$_.message })) -join '')
                            $outcome = 'Open'
                        }
                        break
                    }
                    & $partDone 'T2.Monitoring' @($arc | Where-Object { [string]$_.checkId -in 'T2.ARC.CONFIGURATION', 'T2.ARC.SQLINSTANCE', 'T2.ARC.MONITORING', 'T2.ARC.SQLEXTENSION' })
                    # The guest is built, set up, onboarded, and monitored: its bootstrap generation's record goes (review follow-up).
                    & $recordT2Build ''
                    if (-not $golden) {
                        Set-DemoProgressStep -Path $progress -Id 'T2.SignInCleanup' -State 'Done' -Message 'Done: no sign-in data is left in the guest or on the host.'
                    }
                    $current = Get-DemoDeploymentState -Config $Config
                    $skip = if (-not $current.RunnerSha256 -or 'archost01' -notin $current.RunnerSentTo) { 'T2 has no workload runner (-SkipRunner, or it wasn''t sent to archost01).' } else { '' }
                    if (-not $skip) {
                        # The host installs T2's runner in its last step, after onboarding, so the Arc checks above can
                        # pass while that step fails (live, 2026-10-27: setup --target T2 failed, and the track said
                        # Pass). Like T1, the track waits for the host's own verdict before it sets T2's profile.
                        $minutes = [int](& $option 'T2ReadyMinutes' 30)
                        $wait = Wait-DemoVmHealthState -Config $Config -VmName 'archost01' -State @('Ready', 'Failed', 'ManualActionRequired') -MaxPolls ([System.Math]::Max(1, $minutes)) -PollSeconds 60
                        $state = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'state')
                        $message = [string](Get-DemoMemberValue -InputObject $wait.Health -Name 'message')
                        if ($state -eq 'Ready') {
                            & $note 'DEPLOY.T2.READY' 'T2' 'Pass' ('T2''s host is Ready: {0}' -f $message)
                        }
                        elseif ($state -eq 'Failed') {
                            & $note 'DEPLOY.T2.READY' 'T2' 'Fail' ('T2''s host failed: {0}' -f $message) 'Read C:\ProgramData\DbHubDemo\logs on archost01 (Get-DemoVmHealth -VmName archost01 -View Full), fix the cause, then run deploy.ps1 -FromStage Artifacts.'
                            $outcome = 'Fail'
                            break
                        }
                        else {
                            & $note 'DEPLOY.T2.READY' 'T2' 'Warning' ('T2''s host isn''t Ready after {0} minutes (state {1}: {2}); its profile is set anyway.' -f $minutes, $state, $message) 'Follow it with ./scripts/status.ps1, and run deploy.ps1 -Resume if a step stays failed.'
                        }
                    }
                    $results.Add((Set-DemoTargetProfile -Config $Config -Target 'T2' -ProfileName $profileName -CheckPrefix 'DEPLOY' -SkipReason $skip -RequestedBy 'deploy'))
                }
                'T2/Telemetry' {
                    if (-not (& $telemetry @('T2') 'T2.Telemetry')) {
                        $outcome = 'Fail'
                    }
                }
                'T4/Server' {
                    $checks = @(Test-DemoT4 -Config $Config)
                    & $addAll $checks
                    if (& $hasStatus $checks 'Fail') {
                        $outcome = 'Fail'
                    }
                }
                'T4/Telemetry' {
                    if (-not (Test-DemoT4Enabled -Config $Config)) {
                        # Phase 28's Burstable fallback left T4 out of this deployment (DEPLOY.T4.SKU says why).
                        & $note 'METRICS.T4' 'T4' 'Not selected' 'T4 isn''t deployed in this run (DEPLOY.T4.SKU says why), so it has no metrics.'
                        break
                    }
                    $current = Get-DemoT4State -Config $Config
                    $metrics = Test-DemoT4MetricFlow -Config $Config -ServerId $current.Names.ServerId -State $current.State -WaitMinutes ([int](& $option 'TelemetryWaitMinutes' 15))
                    $results.Add($metrics)
                    if ($metrics.status -eq 'Pass') {
                        $ready['T4'] = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    elseif ($metrics.status -eq 'Fail') {
                        $outcome = 'Fail'
                    }
                }
                'Fabric/Fabric' {
                    $import = [bool](& $option 'ImportNotebooks' $false) -or [bool](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'importNotebooks')
                    $fabricConfigPath = [string](& $option 'ConfigPath' '')
                    Set-DemoProgressStep -Path $progress -Id 'Fabric.Items' -State 'Running' -Message ''
                    $fabric = @(Invoke-DemoFabricStage -Config $Config -ConfigPath $fabricConfigPath -ImportNotebooks:$import -NewNotebooksOnly -ImportDashboard:([bool](& $option 'ImportDashboard' $true)) -SkipHubChecks)
                    & $addAll $fabric
                    & $partDone 'Fabric.Items' $fabric
                    # The history semantic model and report (Phase 19), then the Fabric app when Phase 19b's script exists.
                    Set-DemoProgressStep -Path $progress -Id 'Fabric.Report' -State 'Running' -Message ''
                    $powerBI = @(Invoke-DemoPowerBIStage -Config $Config -ConfigPath $fabricConfigPath)
                    & $addAll $powerBI
                    & $partDone 'Fabric.Report' $powerBI
                    # The Insights app is optional and never stops the track or blocks DONE (brief item 15). It gets the
                    # workspace the step above just resolved or created, so it doesn't look it up by name again (live, a
                    # second lookup right after the creation failed, and the app was skipped), and its results are never a
                    # Fail: the status page and DONE show the actual reason and how to add it later (Phase 28 live finding).
                    Set-DemoProgressStep -Path $progress -Id 'Fabric.App' -State 'Running' -Message 'Optional.'
                    $fabricApp = @(Invoke-DemoFabricAppStage -Config $Config -ConfigPath $fabricConfigPath -WorkspaceId (Get-DemoResolvedWorkspaceId -Result $fabric))
                    & $addAll $fabricApp
                    $app = Get-DemoInsightsAppSummary -Result $fabricApp
                    if ($null -ne $app) {
                        Set-DemoProgressStep -Path $progress -Id 'Fabric.App' -State $app.State -Status $app.Status -Message $app.StepMessage
                    }
                    else {
                        Set-DemoProgressStep -Path $progress -Id 'Fabric.App' -State 'Skipped' -Status 'Not selected' -Message 'Optional: its step reported nothing.'
                    }
                    if (& $hasStatus @($fabric + $powerBI) 'Fail') {
                        $outcome = 'Fail'
                    }
                }
                default {
                    throw ('Unknown step {0} of track {1}.' -f $name, $Track)
                }
            }
        }
        catch {
            & $note ('DEPLOY.TRACK.{0}' -f $Track.ToUpperInvariant()) $(if ($Track -eq 'Fabric') { 'fabric' } else { $Track }) 'Fail' ('Track {0} stopped at {1}: {2}' -f $Track, $name, (Protect-DemoText -Text $_.Exception.Message)) ('Fix the cause, then run deploy.ps1 -Resume: the track continues at {0}.' -f $name)
            $outcome = 'Fail'
        }
        if ($Track -eq 'T2' -and $name -eq 'T2' -and @($results | Select-Object -Skip $resultsBefore | Where-Object { [string]$_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).Count -eq 0) {
            # Whatever the step reached (-NoWaitForT2, a golden redeploy, a failure), and unless the guided stop's NotNeeded
            # already did: what an earlier guided stop or session left open goes, so DONE never comes with it (Phase 28
            # review). Nothing while deploy.ps1 is being stopped.
            try {
                & $addAll @(Clear-DemoGuidedStopLeftover -Config $Config)
            }
            catch {
                & $note 'DEPLOY.T2.GUIDEDLEFTOVER' 'T2' 'Warning' ('What an earlier guided stop left open couldn''t be checked: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) 'Run ./scripts/stop-demo.ps1 -RemoveBastionOnly: it removes Bastion and rotates the host password, and leaves the VMs running.'
            }
        }
        $timing[$name] = [int]$watch.Elapsed.TotalSeconds
        if (-not $ownProgress -and $stepIds.Count -gt 0) {
            $stepResults = @($results | Select-Object -Skip $resultsBefore)
            $worst = Get-DemoWorstStatus -Status @($stepResults | ForEach-Object { [string]$_.status })
            $stepState = switch ($outcome) { 'Pass' { 'Done' } 'Background' { 'Skipped' } 'Open' { 'Action needed' } default { 'Failed' } }
            $first = @($stepResults | Where-Object { [string]$_.status -notin 'Pass', 'Not selected' } | Select-Object -First 1)
            $stepMessage = if ($first.Count -gt 0) { [string]$first[0].message } else { 'Done in {0}.' -f (Format-DemoProgressDuration -Seconds ([long]$timing[$name])) }
            Set-DemoProgressStep -Path $progress -Id $stepIds -State $stepState -Status $worst -Message $stepMessage
        }
        elseif ($ownProgress -and $outcome -eq 'Fail') {
            # A step that reports its own parts ended in an exception: the part still running shows it.
            Update-DemoProgress -Path $progress -Data @{ Ids = $stepIds } -Action {
                param($Model, $Change)
                foreach ($id in $Change['Ids']) {
                    $item = Find-DemoProgressStep -Model $Model -Id $id
                    if ($null -ne $item -and [string]$item['state'] -eq 'Running') {
                        $item['state'] = 'Failed'
                        $item['status'] = 'Fail'
                        $item['endedAt'] = Get-DemoUnixTime
                    }
                }
            }
        }
        if ($outcome -ne 'Pass') {
            $status = $outcome
            break
        }
        $done.Add($name)
        if ($recordState) {
            try {
                Set-DemoDeploymentStateLocked -Config $Config -Value @{ $tagKey = $name } -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Warning -Message ('Track {0} finished {1}, but its state wasn''t recorded: {2}' -f $Track, $name, $_.Exception.Message)
            }
        }
    }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return [pscustomobject]@{
        Track        = $Track
        Status       = $status
        Steps        = $done.ToArray()
        Timing       = $timing
        ReadyUtc     = $ready
        StartedUtc   = $startedUtc.ToString('o', $invariant)
        FirstStepUtc = $(if ($null -ne $firstStepUtc) { $firstStepUtc.ToString('o', $invariant) } else { '' })
        EndedUtc     = [DateTime]::UtcNow.ToString('o', $invariant)
        Early        = $early.ToArray()
        Results      = $results.ToArray()
    }
}
