# deploy.ps1's live progress (Phase 28): one model, out/deploy-progress.json, that deploy.ps1 and every track process
# update at each step transition under a named lock and with an atomic replace; a local status page,
# out/deploy-status.html, regenerated from it every 10 seconds, which refreshes itself with a meta refresh and has no
# script and no external resource; and the same view in the console for status.ps1 -Watch. Both files are in the
# Git-ignored out/ folder, and every text passes through Protect-DemoText. Times are Unix seconds (UTC).

function Get-DemoProgressPath {
    # Where deploy.ps1's progress model and status page live. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Directory = ''
    )

    if (-not $Directory) {
        $Directory = Join-Path -Path $script:RepoRoot -ChildPath 'out'
    }
    # The model and the page are written with .NET file calls, so the directory is made absolute first (review fix 8).
    $Directory = Resolve-DemoUserPath -Path $Directory
    return [pscustomobject]@{
        Directory = $Directory
        Model     = Join-Path -Path $Directory -ChildPath 'deploy-progress.json'
        Page      = Join-Path -Path $Directory -ChildPath 'deploy-status.html'
    }
}

function Get-DemoUnixTime {
    # Now, or -Value, as Unix seconds (UTC). Internal.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [System.Nullable[datetime]] $Value = $null
    )

    if ($null -eq $Value) {
        return [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    return ([System.DateTimeOffset]([datetime]::SpecifyKind($Value.ToUniversalTime(), [System.DateTimeKind]::Utc))).ToUnixTimeSeconds()
}

function ConvertTo-DemoProgressState {
    <#
    .SYNOPSIS
    The status page's label for an ADR 0012 status, which stays underneath: Pass and Warning are Done, Fail is Failed,
    Manual action required is Action needed, and Not selected and Not supported are Skipped. Anything else is Pending.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Status
    )

    switch ([string]$Status) {
        'Pass' { return 'Done' }
        'Warning' { return 'Done' }
        'Fail' { return 'Failed' }
        'Manual action required' { return 'Action needed' }
        'Not selected' { return 'Skipped' }
        'Not supported' { return 'Skipped' }
        default { return 'Pending' }
    }
}

function Get-DemoWorstStatus {
    # The most serious ADR 0012 status among -Status: Fail, Manual action required, Warning, Pass, Not supported, then
    # Not selected; empty when there's none. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Status = @()
    )

    foreach ($candidate in 'Fail', 'Manual action required', 'Warning', 'Pass', 'Not supported', 'Not selected') {
        if (@($Status) -contains $candidate) {
            return $candidate
        }
    }
    return ''
}

function Protect-DemoProgressText {
    # One line of model text: redacted (Protect-DemoText), on one line, and at most -MaxLength characters. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [ValidateRange(20, 4000)]
        [int] $MaxLength = 400
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $safe = (Protect-DemoText -Text $Text) -replace '\s+', ' '
    $safe = $safe.Trim()
    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength - 3) + '...'
    }
    return $safe
}

function Get-DemoProgressCatalog {
    <#
    .SYNOPSIS
    The status page's ordered steps per track (Phase 28, brief item 11). Pure. Internal.

    .DESCRIPTION
    Preflight, with the start of the VMs that were stopped (StartVms; Phase 28 live finding); Infrastructure; T1
    (artifacts, bootstrap, activity, monitoring, telemetry); T3; T4; Fabric (the optional Insights app included, marked
    optional); T2 (a golden restore, or the host build, and in PaygWizard mode the guided stop and the setup check, then
    the sign-in cleanup, Arc onboarding, PAYG and monitoring, and telemetry; Set-DemoProgressPlan skips what the T2
    source doesn't use); Validation. Each step has an id, a label, and the track steps (Get-DemoTrackStep) it belongs
    to.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [ValidateSet('PaygWizard', 'ProductKey', 'Developer')]
        [string] $InstallMode = 'PaygWizard',

        [switch] $T4Enabled,

        [switch] $SkipFabric
    )

    $step = { param([string] $Id, [string] $Label, [string[]] $From, [bool] $Optional = $false) [ordered]@{ id = $Id; label = $Label; from = @($From); optional = $Optional } }
    $tracks = [System.Collections.Generic.List[object]]::new()
    $tracks.Add([ordered]@{ name = 'Preflight'; label = 'Preflight'; steps = @(
                (& $step 'StartVms' 'Start the VMs that were stopped (the nightly auto-shutdown, stop-demo.ps1)' @('StartVms'))
                (& $step 'Preflight' 'Checks before anything is created' @('Preflight'))
            )
        })
    $tracks.Add([ordered]@{ name = 'Infrastructure'; label = 'Infrastructure'; steps = @(& $step 'Infrastructure' 'Azure resources (the template)' @('Infrastructure')) })
    $tracks.Add([ordered]@{ name = 'T1'; label = 'T1: SQL Server on an Azure VM (sqlvm01)'; steps = @(
                (& $step 'T1.Artifacts' 'Artifacts to sqlvm01' @('T1/Artifacts'))
                (& $step 'T1.Bootstraps' 'Bootstrap' @('T1/Bootstraps'))
                (& $step 'T1.Activity' 'Activity profiles' @('T1/Activity'))
                (& $step 'T1.Monitoring' 'Monitoring' @('T1/Monitoring'))
                (& $step 'T1.Telemetry' 'Telemetry in Database Hub' @('T1/Telemetry'))
            )
        })
    $tracks.Add([ordered]@{ name = 'T3'; label = 'T3: Azure SQL Database'; steps = @(
                (& $step 'T3.Setup' 'Set up from T1' @('T1/T3Setup'))
                (& $step 'T3.Checks' 'Workload and checks' @('T1/T3'))
            )
        })
    if ($T4Enabled) {
        $tracks.Add([ordered]@{ name = 'T4'; label = 'T4: Azure Database for PostgreSQL'; steps = @(
                    (& $step 'T4.Server' 'Server checks' @('T4/Server'))
                    (& $step 'T4.Setup' 'Set up from T1' @('T1/T4'))
                    (& $step 'T4.Telemetry' 'Metrics in Azure Monitor' @('T4/Telemetry'))
                )
            })
    }
    if (-not $SkipFabric) {
        $tracks.Add([ordered]@{ name = 'Fabric'; label = 'Fabric'; steps = @(
                    (& $step 'Fabric.Items' 'Workspace, notebooks, and the Real-Time Dashboard' @('Fabric/Fabric'))
                    (& $step 'Fabric.Report' 'History report' @('Fabric/Fabric'))
                    (& $step 'Fabric.App' 'Insights app (optional)' @('Fabric/Fabric') $true)
                )
            })
    }
    $t2 = [System.Collections.Generic.List[object]]::new()
    $t2.Add((& $step 'T2.Restore' 'Restore from the golden snapshot' @('T2/Restore')))
    $t2.Add((& $step 'T2.Artifacts' 'Artifacts to archost01' @('T2/Artifacts')))
    $t2.Add((& $step 'T2.Bootstraps' 'Bootstrap' @('T2/Bootstraps')))
    $t2.Add((& $step 'T2.HostBuild' 'Host and guest build (about 60 to 90 minutes)' @('T2/T2')))
    if ($InstallMode -eq 'PaygWizard') {
        $t2.Add((& $step 'T2.GuidedStop' 'Guided stop: you choose pay-as-you-go and Standard (about 10 minutes)' @('T2/T2')))
        $t2.Add((& $step 'T2.SetupCheck' 'Setup check: Standard, the default instance, the Azure extension' @('T2/T2')))
    }
    $t2.Add((& $step 'T2.SignInCleanup' 'Sign-in data cleanup' @('T2/T2')))
    $t2.Add((& $step 'T2.ArcOnboarding' 'Arc onboarding' @('T2/T2')))
    $t2.Add((& $step 'T2.Monitoring' 'PAYG and monitoring' @('T2/T2')))
    $t2.Add((& $step 'T2.Telemetry' 'Telemetry in Database Hub' @('T2/Telemetry')))
    $tracks.Add([ordered]@{ name = 'T2'; label = 'T2: Arc-enabled SQL Server (arcsql01 on archost01)'; steps = $t2.ToArray() })
    $tracks.Add([ordered]@{ name = 'Validation'; label = 'Validation'; steps = @(& $step 'Validation' 'Estate, checklist, and timing' @('Validation')) })
    return $tracks.ToArray()
}

function Get-DemoProgressStepId {
    # The status page's step ids for one of a track's steps (Get-DemoTrackStep). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Track,

        [Parameter(Mandatory)]
        [string] $Step
    )

    switch ('{0}/{1}' -f $Track, $Step) {
        'T1/T3Setup' { return @('T3.Setup') }
        'T1/Artifacts' { return @('T1.Artifacts') }
        'T1/Bootstraps' { return @('T1.Bootstraps') }
        'T1/T3' { return @('T3.Checks') }
        'T1/T4' { return @('T4.Setup') }
        'T1/Activity' { return @('T1.Activity') }
        'T1/Monitoring' { return @('T1.Monitoring') }
        'T1/Telemetry' { return @('T1.Telemetry') }
        'T2/Restore' { return @('T2.Restore') }
        'T2/Artifacts' { return @('T2.Artifacts') }
        'T2/Bootstraps' { return @('T2.Bootstraps') }
        'T2/T2' { return @('T2.HostBuild', 'T2.GuidedStop', 'T2.SetupCheck', 'T2.SignInCleanup', 'T2.ArcOnboarding', 'T2.Monitoring') }
        'T2/Telemetry' { return @('T2.Telemetry') }
        'T4/Server' { return @('T4.Server') }
        'T4/Telemetry' { return @('T4.Telemetry') }
        'Fabric/Fabric' { return @('Fabric.Items', 'Fabric.Report', 'Fabric.App') }
        default { return @() }
    }
}

function Set-DemoProgressPlan {
    <#
    .SYNOPSIS
    Marks the progress model's steps by this run's plan (Resolve-DemoTrackPlan): a step a resumed run picks up after is
    Done (an earlier run finished it), a step outside the run is Skipped, and the T2 steps its source doesn't use are
    Skipped (a golden restore has no build or guided stop; a build has no restore). Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Plan,

        [switch] $Resume,

        [AllowEmptyString()]
        [string] $T2Source = ''
    )

    if (-not $Path) {
        return
    }
    $map = @{}
    foreach ($track in 'T1', 'T2', 'T4', 'Fabric') {
        $names = @((Get-DemoTrackStep -Track $track).Keys)
        $planned = @($Plan.Tracks[$track])
        $firstIndex = if ($planned.Count -gt 0) { [array]::IndexOf($names, [string]$planned[0]) } else { $names.Count }
        for ($i = 0; $i -lt $names.Count; $i++) {
            $verdict = if ($names[$i] -in $planned) { 'Run' } elseif ($Resume -and $i -lt $firstIndex) { 'Earlier' } else { 'Skip' }
            foreach ($id in @(Get-DemoProgressStepId -Track $track -Step $names[$i])) {
                $map[$id] = $verdict
            }
        }
    }
    $map['Preflight'] = if ($Plan.Preflight) { 'Run' } elseif ($Resume) { 'Earlier' } else { 'Skip' }
    $map['Infrastructure'] = if ($Plan.Infrastructure) { 'Run' } elseif ($Resume) { 'Earlier' } else { 'Skip' }
    $map['Validation'] = if ($Plan.Validation) { 'Run' } else { 'Skip' }
    if ($T2Source -in 'golden', 'existing-golden') {
        foreach ($id in 'T2.HostBuild', 'T2.GuidedStop', 'T2.SetupCheck', 'T2.SignInCleanup') {
            if ($map[$id] -eq 'Run') {
                $map[$id] = 'Golden'
            }
        }
    }
    elseif ($T2Source) {
        if ($map['T2.Restore'] -eq 'Run') {
            $map['T2.Restore'] = 'Build'
        }
    }
    Update-DemoProgress -Path $Path -Data @{ Map = $map } -Action {
        param($Model, $Change)
        $now = Get-DemoUnixTime
        foreach ($track in @($Model['tracks'])) {
            foreach ($item in @($track['steps'])) {
                $verdict = [string]$Change['Map'][[string]$item['id']]
                $text = switch ($verdict) {
                    'Earlier' { 'Finished in an earlier run.' }
                    'Skip' { 'Not part of this run.' }
                    'Golden' { 'Restored from the golden snapshot: no build and no guided stop.' }
                    'Build' { 'No golden snapshot: the host builds its guest instead.' }
                    default { '' }
                }
                if (-not $text) {
                    continue
                }
                $item['state'] = if ($verdict -eq 'Earlier') { 'Done' } else { 'Skipped' }
                $item['message'] = $text
                $item['startedAt'] = 0
                $item['endedAt'] = $now
            }
        }
    }
}

function New-DemoProgressModel {
    <#
    .SYNOPSIS
    A new progress model for one deploy.ps1 run: the catalog's steps, each Pending, or Done when the plan resumes after
    it (an earlier run finished it), or Skipped when this run doesn't reach it. Pure. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Catalog,

        [System.Collections.IDictionary] $Plan = @{},

        [string] $Environment = '',

        [string] $ResourceGroup = '',

        [string] $Command = './scripts/deploy.ps1',

        [string] $PagePath = '',

        [System.Collections.IDictionary] $Expect = @{},

        [ValidateSet('NotSelected', 'Pending')]
        [string] $GuidedStop = 'NotSelected',

        [long] $NowUnix = 0
    )

    if ($NowUnix -le 0) {
        $NowUnix = Get-DemoUnixTime
    }
    $tracks = [System.Collections.Generic.List[object]]::new()
    foreach ($track in $Catalog) {
        $steps = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($track['steps'])) {
            $state = 'Pending'
            $message = ''
            if ($Plan.Count -gt 0) {
                $planned = @(foreach ($from in @($item['from'])) { if ($Plan.Contains($from)) { [string]$Plan[$from] } })
                if ($planned -contains 'Run') {
                    $state = 'Pending'
                }
                elseif ($planned -contains 'Earlier') {
                    $state = 'Done'
                    $message = 'Finished in an earlier run.'
                }
                elseif ($planned.Count -gt 0) {
                    $state = 'Skipped'
                    $message = 'Not part of this run.'
                }
            }
            $steps.Add([ordered]@{ id = [string]$item['id']; label = [string]$item['label']; optional = [bool]$item['optional']; state = $state; status = ''; startedAt = 0; endedAt = 0; message = $message; azureSide = $false })
        }
        $tracks.Add([ordered]@{ name = [string]$track['name']; label = [string]$track['label']; steps = $steps.ToArray() })
    }
    $expectation = [ordered]@{ firstRun = $false; minutesLow = 0; minutesHigh = 0; guidedStop = ($GuidedStop -eq 'Pending'); humanText = ''; text = '' }
    foreach ($key in $Expect.Keys) {
        $expectation[[string]$key] = $Expect[$key]
    }
    return [ordered]@{
        schemaVersion = 1
        runId         = [guid]::NewGuid().ToString()
        title         = 'Fabric Database Hub demo: deploy.ps1'
        environment   = $Environment
        resourceGroup = $ResourceGroup
        command       = $Command
        pagePath      = $PagePath
        startedAt     = $NowUnix
        updatedAt     = $NowUnix
        heartbeatAt   = $NowUnix
        expect        = $expectation
        run           = [ordered]@{ state = 'Running'; endedAt = 0; reason = ''; next = ''; nextCommand = ''; exitCode = $null; diagnostics = '' }
        guidedStop    = [ordered]@{ state = $GuidedStop; message = ''; url = ''; deadlineAt = 0; promptedAt = 0; hostVm = 'archost01'; hostUser = ''; credential = ''; credentialText = '' }
        optional      = @()
        tracks        = $tracks.ToArray()
    }
}

function Read-DemoProgress {
    # The progress model at -Path as nested hashtables, or $null when there's none or it doesn't parse. Reads with
    # sharing, so a writer can replace the file meanwhile. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowEmptyString()]
        [string] $Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally {
                $stream.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($text)) {
                return $null
            }
            return ($text | ConvertFrom-Json -AsHashtable -Depth 20)
        }
        catch {
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    return $null
}

function Save-DemoProgressFile {
    # Writes -Text to -Path atomically: a temporary file beside it, then a replace, retried while a reader holds it. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress files only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temporary = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::Move($temporary, $Path, $true)
            return
        }
        catch {
            if ($attempt -ge 10) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                throw
            }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Get-DemoProgressLockName {
    # The named lock for one progress model: every process on this machine that updates it takes it. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($Path).ToLowerInvariant()))
    return ('Local\DbHubDemoProgress-{0}' -f ([System.Convert]::ToHexString($hash).Substring(0, 16)))
}

function Initialize-DemoProgress {
    # Writes a new progress model (New-DemoProgressModel) to -Path, replacing an earlier run's. Internal.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the deployment''s progress model')) {
        return
    }
    Save-DemoProgressFile -Path $Path -Text (ConvertTo-Json -InputObject $Model -Depth 20)
}

function Update-DemoProgress {
    <#
    .SYNOPSIS
    Changes the progress model at -Path under its lock: reads it, runs -Action with it and -Data, and writes it back
    atomically. Does nothing without a model (a track started by a test, or -NoStatusPage). Never throws: progress is
    never worth failing a deployment for. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [scriptblock] $Action,

        [System.Collections.IDictionary] $Data = @{},

        [switch] $Heartbeat
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $mutex = $null
    $owned = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, (Get-DemoProgressLockName -Path $Path))
        try {
            $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [System.Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) {
            Write-Debug -Message 'The progress model''s lock was busy; this update was skipped.'
            return
        }
        $model = Read-DemoProgress -Path $Path
        if ($null -eq $model) {
            return
        }
        & $Action $model $Data
        $now = Get-DemoUnixTime
        $model['heartbeatAt'] = $now
        if (-not $Heartbeat) {
            $model['updatedAt'] = $now
        }
        Save-DemoProgressFile -Path $Path -Text (ConvertTo-Json -InputObject $model -Depth 20)
    }
    catch {
        Write-Debug -Message ('The progress model wasn''t updated: {0}' -f $_.Exception.Message)
    }
    finally {
        if ($owned) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Find-DemoProgressStep {
    # The step with -Id in a progress model, or $null. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model,

        [Parameter(Mandatory)]
        [string] $Id
    )

    foreach ($track in @($Model['tracks'])) {
        foreach ($item in @($track['steps'])) {
            if ([string]$item['id'] -eq $Id) {
                return $item
            }
        }
    }
    return $null
}

function Set-DemoProgressStep {
    <#
    .SYNOPSIS
    Moves one step of the progress model: its state (Pending, Running, Done, Action needed, Failed, or Skipped, or from
    -Status, an ADR 0012 status), a one-line message, and -AzureSide when it waits for Azure (no action needed). A
    step's clock starts when it first runs and stops when it ends. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Id,

        [ValidateSet('', 'Pending', 'Running', 'Done', 'Action needed', 'Failed', 'Skipped')]
        [string] $State = '',

        [AllowEmptyString()]
        [string] $Status = '',

        [AllowEmptyString()]
        [AllowNull()]
        [string] $Message = $null,

        [switch] $AzureSide
    )

    if (-not $Path -or @($Id | Where-Object { $_ }).Count -eq 0) {
        return
    }
    if (-not $State) {
        $State = ConvertTo-DemoProgressState -Status $Status
    }
    $data = @{
        Ids     = @($Id)
        State   = $State
        Status  = $Status
        Side    = [bool]$AzureSide
        HasText = ($null -ne $Message)
        Text    = $(if ($null -ne $Message) { Protect-DemoProgressText -Text $Message } else { '' })
    }
    Update-DemoProgress -Path $Path -Data $data -Action {
        param($Model, $Change)
        $now = Get-DemoUnixTime
        foreach ($stepId in $Change['Ids']) {
            $item = Find-DemoProgressStep -Model $Model -Id $stepId
            if ($null -eq $item) {
                continue
            }
            $newState = [string]$Change['State']
            if ($newState -eq 'Running' -and [long]$item['startedAt'] -le 0) {
                $item['startedAt'] = $now
            }
            if ($newState -in 'Done', 'Failed', 'Skipped', 'Action needed') {
                if ([long]$item['startedAt'] -le 0 -and $newState -ne 'Skipped') {
                    $item['startedAt'] = $now
                }
                $item['endedAt'] = $now
            }
            elseif ($newState -eq 'Running') {
                $item['endedAt'] = 0
            }
            $item['state'] = $newState
            $item['status'] = [string]$Change['Status']
            $item['azureSide'] = [bool]$Change['Side']
            if ($Change['HasText']) {
                $item['message'] = [string]$Change['Text']
            }
        }
    }
}

function Set-DemoProgressStopped {
    <#
    .SYNOPSIS
    After a stop (Ctrl+C), moves every step that was still running, or waiting for a person, back to Pending with
    -Message, so the status page shows where the next run continues, not steps that run on (Phase 28 live finding). A
    step that ended with a status keeps it. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Path) {
        return
    }
    Update-DemoProgress -Path $Path -Data @{ Text = (Protect-DemoProgressText -Text $Message) } -Action {
        param($Model, $Change)
        $now = Get-DemoUnixTime
        foreach ($track in @($Model['tracks'])) {
            foreach ($item in @($track['steps'])) {
                $open = [string]$item['state'] -eq 'Running' -or ([string]$item['state'] -eq 'Action needed' -and -not [string]$item['status'])
                if ($open) {
                    $item['state'] = 'Pending'
                    $item['status'] = ''
                    $item['azureSide'] = $false
                    # Its clock stops at the stop: the time shown is how long it ran.
                    $item['endedAt'] = if ([long]$item['startedAt'] -gt 0) { $now } else { 0 }
                    $item['message'] = [string]$Change['Text']
                }
            }
        }
    }
}

function Set-DemoProgressValue {
    # Merges -Value into one section of the progress model: run, guidedStop, or expect; or replaces optional. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local progress model only.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('run', 'guidedStop', 'expect', 'optional')]
        [string] $Section,

        [Parameter(Mandatory)]
        [object] $Value
    )

    if (-not $Path) {
        return
    }
    $clean = $Value
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $item = $Value[$key]
            $clean[[string]$key] = if ($item -is [string] -and [string]$key -notin 'url', 'state', 'credential', 'hostVm', 'hostUser', 'nextCommand') { Protect-DemoProgressText -Text $item -MaxLength 1200 } else { $item }
        }
    }
    elseif ($Section -eq 'optional') {
        $clean = @(foreach ($entry in @($Value)) {
                [ordered]@{ name = Protect-DemoProgressText -Text ([string]$entry['name']); message = Protect-DemoProgressText -Text ([string]$entry['message']) -MaxLength 600; howTo = Protect-DemoProgressText -Text ([string]$entry['howTo']) -MaxLength 1200 }
            })
    }
    Update-DemoProgress -Path $Path -Data @{ Section = $Section; Value = $clean } -Action {
        param($Model, $Change)
        if ($Change['Section'] -eq 'optional') {
            $Model['optional'] = @($Change['Value'])
            return
        }
        foreach ($key in $Change['Value'].Keys) {
            $Model[$Change['Section']][[string]$key] = $Change['Value'][$key]
        }
    }
}

function Format-DemoProgressDuration {
    # Seconds as "45s", "12m 05s", or "1h 03m". Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [long] $Seconds
    )

    if ($Seconds -lt 0) {
        $Seconds = 0
    }
    if ($Seconds -lt 60) {
        return ('{0}s' -f $Seconds)
    }
    if ($Seconds -lt 3600) {
        return ('{0}m {1:00}s' -f [System.Math]::Floor($Seconds / 60), ($Seconds % 60))
    }
    return ('{0}h {1:00}m' -f [System.Math]::Floor($Seconds / 3600), [System.Math]::Floor(($Seconds % 3600) / 60))
}

function Format-DemoProgressClock {
    # Unix seconds as local wall-clock time, HH:mm (or HH:mm:ss). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [long] $Unix,

        [switch] $Seconds
    )

    if ($Unix -le 0) {
        return ''
    }
    $format = if ($Seconds) { 'HH:mm:ss' } else { 'HH:mm' }
    return [System.DateTimeOffset]::FromUnixTimeSeconds($Unix).ToLocalTime().ToString($format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-DemoProgressStale {
    <#
    .SYNOPSIS
    Whether a running deployment's model went quiet: Heartbeat when deploy.ps1 stopped updating it (its window closed
    or the PC restarted) for more than -HeartbeatMinutes, and Progress when no step changed for more than -StepMinutes
    while nobody is asked for anything. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model,

        [long] $NowUnix = 0,

        [ValidateRange(1, 1440)]
        [int] $StepMinutes = 20,

        [ValidateRange(1, 1440)]
        [int] $HeartbeatMinutes = 3
    )

    if ($NowUnix -le 0) {
        $NowUnix = Get-DemoUnixTime
    }
    $running = [string]$Model['run']['state'] -eq 'Running'
    $quietBeat = $NowUnix - [long]$Model['heartbeatAt']
    $quietStep = $NowUnix - [long]$Model['updatedAt']
    $waiting = [string]$Model['guidedStop']['state'] -eq 'Ready'
    return [pscustomobject]@{
        Heartbeat        = $running -and $quietBeat -gt ($HeartbeatMinutes * 60)
        Progress         = $running -and -not $waiting -and $quietStep -gt ($StepMinutes * 60)
        HeartbeatMinutes = [int][System.Math]::Floor([System.Math]::Max(0, $quietBeat) / 60)
        StepMinutes      = [int][System.Math]::Floor([System.Math]::Max(0, $quietStep) / 60)
    }
}

function Get-DemoGuidedStopInstruction {
    <#
    .SYNOPSIS
    The person's steps at the PaygWizard guided stop, for the console prompt, the status page, and the reminders: the
    Bastion sign-in to the host with the credential's way in, then the pre-filled setup's two choices and the Azure
    sign-in. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string] $HostVm = 'archost01',

        [string] $GuestName = 'arcsql01',

        [AllowEmptyString()]
        [string] $HostUser = '',

        [ValidateSet('', 'clipboard', 'keyVault', 'portalReset', 'unknown')]
        [string] $SignInWay = '',

        [AllowEmptyString()]
        [string] $SignInText = ''
    )

    $user = if ($HostUser) { $HostUser } else { 'the VM''s administrator (Azure portal: {0}, Settings, Reset password shows its user name)' -f $HostVm }
    $password = switch ($SignInWay) {
        'clipboard' { 'The one-time password is on your clipboard: paste it into the Password field. It''s never shown or saved, and it''s rotated afterward.' }
        'keyVault' { if ($SignInText) { $SignInText } else { 'The one-time password is in the demo''s key vault; see the console for where.' } }
        'portalReset' { 'This session has no working clipboard, so no password was set or shown. First, in the Azure portal, open {0}, then Help, then Reset password: keep the user name {1}, type a password of your own choosing twice, and select Update (about a minute). Use that password. It''s rotated afterward.' -f $HostVm, $user }
        default { 'If you don''t have its password, set one of your own: in the Azure portal, open {0}, then Help, then Reset password (keep the user name). ./scripts/stop-demo.ps1 rotates it afterward.' -f $HostVm }
    }
    return @(
        ('1. Sign in to {0} through Bastion: in the Azure portal, open {0}, select Connect, then Bastion (the browser opens {0}''s page). User name: {1}. {2}' -f $HostVm, $user, $password)
        ('2. {0} opens Virtual Machine Connection to {1} by itself. {1} is already signed in, and SQL Server setup is open and pre-filled.' -f $HostVm, $GuestName)
        '3. On the Edition page, select "Use pay-as-you-go billing through Microsoft Azure", then Standard. Select Next.'
        '4. Accept the license terms, then select Next.'
        '5. On the Azure Extension for SQL Server page, select "Use Azure Login" and sign in with your own Azure account. Never enter a service principal secret.'
        '6. Select Next on the pre-filled pages, then Install (about 10 to 15 minutes). When setup says Complete, select Close.'
        ('7. Close the Bastion tab. deploy.ps1 checks what was installed (Standard, the default instance, the Azure extension) and continues on its own; if something''s wrong, the host''s message here says how to fix it.')
    )
}

function Get-DemoProgressBanner {
    <#
    .SYNOPSIS
    The status page's top banner, in exactly one of four states (brief item 11): Deploying (no action needed), Waiting
    (for you, at the guided stop), Done, or Stopped (not done). A running model whose heartbeat went quiet is Stopped:
    deploy.ps1 isn't running any more. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model,

        [long] $NowUnix = 0,

        [ValidateRange(1, 1440)]
        [int] $HeartbeatMinutes = 3
    )

    if ($NowUnix -le 0) {
        $NowUnix = Get-DemoUnixTime
    }
    $run = $Model['run']
    $guided = $Model['guidedStop']
    $command = if ([string]$run['nextCommand']) { [string]$run['nextCommand'] } elseif ([string]$Model['command']) { [string]$Model['command'] } else { './scripts/deploy.ps1' }
    $resume = 'If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped.'
    $state = [string]$run['state']
    if ($state -eq 'Done') {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('The demo is complete.')
        if ([string]$run['reason']) {
            $lines.Add([string]$run['reason'])
        }
        $lines.Add('Where to look: open Database Hub in the Fabric portal and look at Estate and Performance; then start an incident (./scripts/demo-control.ps1) and investigate it with the Database Agent.')
        foreach ($entry in @($Model['optional'])) {
            $lines.Add(('Optional, not needed for the demo: {0}. {1} {2}' -f [string]$entry['name'], [string]$entry['message'], [string]$entry['howTo']))
        }
        $lines.Add('Capture a golden snapshot with ./scripts/capture-t2-golden.ps1 to make future redeploys skip the build and the guided stop.')
        return [pscustomobject]@{ Kind = 'Done'; Title = 'Done'; Lines = $lines.ToArray(); Command = ''; Link = ''; Countdown = '' }
    }
    $stale = Test-DemoProgressStale -Model $Model -NowUnix $NowUnix -HeartbeatMinutes $HeartbeatMinutes
    if ($state -eq 'NotDone' -or $stale.Heartbeat) {
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($state -eq 'NotDone') {
            if ([string]$run['reason']) {
                $lines.Add([string]$run['reason'])
            }
            if ([string]$run['next']) {
                $lines.Add(('Next: {0}' -f [string]$run['next']))
            }
        }
        else {
            $lines.Add(('deploy.ps1 stopped updating this page {0} minutes ago (at {1}): its window closed, or the PC slept or restarted.' -f $stale.HeartbeatMinutes, (Format-DemoProgressClock -Unix ([long]$Model['heartbeatAt']))))
        }
        $lines.Add(('Run: {0}' -f $command))
        $lines.Add($resume)
        $lines.Add('For help, attach the redacted bundle from ./scripts/collect-diagnostics.ps1 to a Deployment problem issue.')
        return [pscustomobject]@{ Kind = 'Stopped'; Title = 'Stopped, not done'; Lines = $lines.ToArray(); Command = $command; Link = ''; Countdown = '' }
    }
    if ([string]$guided['state'] -eq 'Ready') {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('One step needs you now, for about 10 minutes: SQL Server setup in the T2 guest, through Bastion. Nothing else needs you.')
        foreach ($line in @(Get-DemoGuidedStopInstruction -HostVm ([string]$guided['hostVm']) -HostUser ([string]$guided['hostUser']) -SignInWay ([string]$guided['credential']) -SignInText ([string]$guided['credentialText']))) {
            $lines.Add($line)
        }
        if ([string]$guided['message']) {
            $lines.Add(('Now: {0}' -f [string]$guided['message']))
        }
        $countdown = ''
        $deadline = [long]$guided['deadlineAt']
        if ($deadline -gt 0) {
            $left = [System.Math]::Max(0, $deadline - $NowUnix)
            $countdown = 'Time limit: {0} left (until {1}). After that, deploy.ps1 stops; run ./scripts/deploy.ps1 again and it waits for this step again.' -f (Format-DemoProgressDuration -Seconds $left), (Format-DemoProgressClock -Unix $deadline)
        }
        return [pscustomobject]@{ Kind = 'Waiting'; Title = 'Waiting for you'; Lines = $lines.ToArray(); Command = ''; Link = [string]$guided['url']; Countdown = $countdown }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('You can step away. Keep this PC on and this window open; deploy.ps1 keeps the PC awake while it runs.')
    $expect = $Model['expect']
    if ([string]$expect['text']) {
        $lines.Add([string]$expect['text'])
    }
    if ([bool]$expect['guidedStop'] -and [string]$guided['state'] -in 'Pending', 'Preparing') {
        $lines.Add(('A person is needed once: {0}' -f $(if ([string]$expect['humanText']) { [string]$expect['humanText'] } else { 'about 60 to 90 minutes after the start, for about 10 minutes.' })))
    }
    if ([string]$guided['state'] -eq 'Preparing' -and [string]$guided['message']) {
        $lines.Add(('Guided stop: {0}' -f [string]$guided['message']))
    }
    $active = @(foreach ($track in @($Model['tracks'])) { foreach ($item in @($track['steps'])) { if ([string]$item['state'] -eq 'Running') { $item } } })
    foreach ($item in $active) {
        $side = if ([bool]$item['azureSide']) { ' (Azure-side, no action needed)' } else { '' }
        $lines.Add(('Running: {0}{1}{2}' -f [string]$item['label'], $side, $(if ([string]$item['message']) { ': ' + [string]$item['message'] } else { '' })))
    }
    return [pscustomobject]@{ Kind = 'Deploying'; Title = 'Deploying, no action needed'; Lines = $lines.ToArray(); Command = ''; Link = ''; Countdown = '' }
}

function ConvertTo-DemoHtmlText {
    # HTML-encodes one text (System.Net.WebUtility.HtmlEncode). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function ConvertTo-DemoProgressHtml {
    <#
    .SYNOPSIS
    The status page for a progress model: the banner, the steps per track with their state, elapsed time, and message,
    the optional items, the last update time, and a stale warning. Every text is HTML-encoded; the page has inline CSS
    only, no script, and no external resource, and while the run goes on it refreshes itself every -RefreshSeconds.
    Only an https://portal.azure.com link is ever made a link. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model,

        [long] $NowUnix = 0,

        [ValidateRange(5, 60)]
        [int] $RefreshSeconds = 10
    )

    if ($NowUnix -le 0) {
        $NowUnix = Get-DemoUnixTime
    }
    $e = { param($Text) ConvertTo-DemoHtmlText -Text ([string]$Text) }
    $banner = Get-DemoProgressBanner -Model $Model -NowUnix $NowUnix
    $stale = Test-DemoProgressStale -Model $Model -NowUnix $NowUnix
    $running = [string]$Model['run']['state'] -eq 'Running' -and $banner.Kind -ne 'Stopped'
    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine('<!DOCTYPE html>')
    $null = $html.AppendLine('<html lang="en">')
    $null = $html.AppendLine('<head>')
    $null = $html.AppendLine('<meta charset="utf-8">')
    if ($running) {
        $null = $html.AppendLine(('<meta http-equiv="refresh" content="{0}">' -f $RefreshSeconds))
    }
    $null = $html.AppendLine(('<title>{0} - {1}</title>' -f (& $e $banner.Title), (& $e $Model['title'])))
    $null = $html.AppendLine('<style>')
    $null = $html.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fafafa}')
    $null = $html.AppendLine('.banner{padding:16px 20px;border-radius:6px;margin-bottom:16px;color:#fff}')
    $null = $html.AppendLine('.banner h1{margin:0 0 8px 0;font-size:28px}.banner p{margin:4px 0}.banner a{color:#fff;font-weight:bold}')
    $null = $html.AppendLine('.Deploying{background:#0b5cad}.Waiting{background:#b45309}.Done{background:#15803d}.Stopped{background:#b91c1c}')
    $null = $html.AppendLine('.countdown{font-size:20px;font-weight:bold}.command{font-family:Consolas,monospace;background:rgba(0,0,0,.25);padding:2px 6px;border-radius:4px}')
    $null = $html.AppendLine('table{border-collapse:collapse;width:100%;background:#fff}th,td{border-bottom:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}')
    $null = $html.AppendLine('tr.track th{background:#eef2f7;font-size:15px}.state{font-weight:bold;white-space:nowrap}')
    $null = $html.AppendLine('.s-Pending{color:#6b7280}.s-Running{color:#0b5cad}.s-Done{color:#15803d}.s-Action{color:#b45309}.s-Failed{color:#b91c1c}.s-Skipped{color:#9ca3af}')
    $null = $html.AppendLine('.meta{color:#4b5563}.warn{background:#fef3c7;border:1px solid #f59e0b;padding:8px 12px;border-radius:4px;margin:8px 0}')
    $null = $html.AppendLine('</style>')
    $null = $html.AppendLine('</head>')
    $null = $html.AppendLine('<body>')
    $null = $html.AppendLine(('<div class="banner {0}">' -f $banner.Kind))
    $null = $html.AppendLine(('<h1>{0}</h1>' -f (& $e $banner.Title)))
    if ($banner.Countdown) {
        $null = $html.AppendLine(('<p class="countdown">{0}</p>' -f (& $e $banner.Countdown)))
    }
    if ($banner.Link -and $banner.Link -match '^https://portal\.azure\.com/[^\s"<>]*$') {
        $null = $html.AppendLine(('<p><a href="{0}">Open {1} in the Azure portal, then select Connect, then Bastion</a></p>' -f (& $e $banner.Link), (& $e $Model['guidedStop']['hostVm'])))
    }
    foreach ($line in @($banner.Lines)) {
        $null = $html.AppendLine(('<p>{0}</p>' -f (& $e $line)))
    }
    if ($banner.Command) {
        $null = $html.AppendLine(('<p>Command: <span class="command">{0}</span></p>' -f (& $e $banner.Command)))
    }
    $null = $html.AppendLine('</div>')
    $updated = Format-DemoProgressClock -Unix ([long]$Model['updatedAt']) -Seconds
    $beat = Format-DemoProgressClock -Unix ([long]$Model['heartbeatAt']) -Seconds
    $null = $html.AppendLine(('<p class="meta">Environment {0}, resource group {1}. Started at {2}; the last step change at {3}; this page was written at {4} (local time).{5}</p>' -f (& $e $Model['environment']), (& $e $Model['resourceGroup']), (& $e (Format-DemoProgressClock -Unix ([long]$Model['startedAt']))), (& $e $updated), (& $e $beat), $(if ($running) { (' It refreshes every {0} seconds. If that time stops moving for a few minutes, deploy.ps1 isn''t running any more: run ./scripts/deploy.ps1 again.' -f $RefreshSeconds) } else { '' })))
    if ($stale.Progress) {
        $null = $html.AppendLine(('<div class="warn">No step has changed for {0} minutes. Long steps, such as the T2 guest build, can take that long, and deploy.ps1 is still running (it wrote this page at {1}). If nothing changes for an hour, read docs/troubleshooting.md.</div>' -f $stale.StepMinutes, (& $e $beat)))
    }
    $null = $html.AppendLine('<table>')
    $null = $html.AppendLine('<tr><th>Step</th><th>State</th><th>Time</th><th>Details</th></tr>')
    foreach ($track in @($Model['tracks'])) {
        $null = $html.AppendLine(('<tr class="track"><th colspan="4">{0}</th></tr>' -f (& $e $track['label'])))
        foreach ($item in @($track['steps'])) {
            $stateText = [string]$item['state']
            $class = ($stateText -split ' ')[0]
            $started = [long]$item['startedAt']
            $ended = [long]$item['endedAt']
            $elapsed = if ($started -gt 0) { Format-DemoProgressDuration -Seconds ($(if ($ended -gt 0) { $ended } else { $NowUnix }) - $started) } else { '' }
            $detail = [string]$item['message']
            if ([bool]$item['azureSide'] -and $stateText -eq 'Running') {
                $detail = 'Azure-side, no action needed. ' + $detail
            }
            $statusNote = if ([string]$item['status']) { ' <span class="meta">({0})</span>' -f (& $e $item['status']) } else { '' }
            $null = $html.AppendLine(('<tr><td>{0}</td><td class="state s-{1}">{2}{3}</td><td>{4}</td><td>{5}</td></tr>' -f (& $e $item['label']), (& $e $class), (& $e $stateText), $statusNote, (& $e $elapsed), (& $e $detail)))
        }
    }
    $null = $html.AppendLine('</table>')
    $optional = @($Model['optional'])
    if ($optional.Count -gt 0) {
        $null = $html.AppendLine('<h2>Optional, not needed for the demo</h2>')
        foreach ($entry in $optional) {
            $null = $html.AppendLine(('<p><b>{0}</b>: {1} {2}</p>' -f (& $e $entry['name']), (& $e $entry['message']), (& $e $entry['howTo'])))
        }
    }
    $null = $html.AppendLine('<p class="meta">This page is written by deploy.ps1 from out/deploy-progress.json on this PC; it has no secrets. ./scripts/status.ps1 -Watch shows the same in a terminal.</p>')
    $null = $html.AppendLine('</body>')
    $null = $html.AppendLine('</html>')
    return $html.ToString()
}

function Format-DemoProgressConsole {
    <#
    .SYNOPSIS
    The status page as console lines, for status.ps1 -Watch: the banner, then each track's steps with their state,
    elapsed time, and message, cut to -Width. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Model,

        [long] $NowUnix = 0,

        [ValidateRange(60, 400)]
        [int] $Width = 120
    )

    if ($NowUnix -le 0) {
        $NowUnix = Get-DemoUnixTime
    }
    $cut = { param([string] $Text) if ($Text.Length -gt $Width) { $Text.Substring(0, $Width - 3) + '...' } else { $Text } }
    $banner = Get-DemoProgressBanner -Model $Model -NowUnix $NowUnix
    $rule = '=' * [System.Math]::Min($Width, 100)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($rule)
    $lines.Add((& $cut ('  {0}' -f $banner.Title.ToUpperInvariant())))
    if ($banner.Countdown) {
        $lines.Add((& $cut ('  {0}' -f $banner.Countdown)))
    }
    if ($banner.Link) {
        $lines.Add((& $cut ('  {0}' -f $banner.Link)))
    }
    foreach ($line in @($banner.Lines)) {
        $lines.Add((& $cut ('  {0}' -f $line)))
    }
    $lines.Add($rule)
    $marks = @{ 'Pending' = '[ ]'; 'Running' = '[>]'; 'Done' = '[+]'; 'Action needed' = '[!]'; 'Failed' = '[X]'; 'Skipped' = '[-]' }
    foreach ($track in @($Model['tracks'])) {
        $lines.Add([string]$track['label'])
        foreach ($item in @($track['steps'])) {
            $state = [string]$item['state']
            $started = [long]$item['startedAt']
            $ended = [long]$item['endedAt']
            $elapsed = if ($started -gt 0) { Format-DemoProgressDuration -Seconds ($(if ($ended -gt 0) { $ended } else { $NowUnix }) - $started) } else { '' }
            $detail = [string]$item['message']
            if ([bool]$item['azureSide'] -and $state -eq 'Running') {
                $detail = 'Azure-side, no action needed. ' + $detail
            }
            $lines.Add((& $cut ('  {0} {1,-14} {2,-9} {3} {4}' -f $marks[$state], $state, $elapsed, [string]$item['label'], $(if ($detail) { '- ' + $detail } else { '' }))))
        }
    }
    $stale = Test-DemoProgressStale -Model $Model -NowUnix $NowUnix
    $lines.Add(('Last step change {0}, last update {1} (local time).' -f (Format-DemoProgressClock -Unix ([long]$Model['updatedAt']) -Seconds), (Format-DemoProgressClock -Unix ([long]$Model['heartbeatAt']) -Seconds)))
    if ($stale.Progress) {
        $lines.Add(('No step has changed for {0} minutes; long steps such as the T2 guest build can take that long.' -f $stale.StepMinutes))
    }
    return $lines.ToArray()
}

function Write-DemoProgressPage {
    # Renders the model at -ModelPath to the page at -PagePath (atomic), and with -Heartbeat records that deploy.ps1 is
    # alive. Never throws. Internal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ModelPath,

        [Parameter(Mandatory)]
        [string] $PagePath,

        [switch] $Heartbeat
    )

    try {
        if ($Heartbeat) {
            Update-DemoProgress -Path $ModelPath -Heartbeat -Action { param($Model) $null = $Model }
        }
        $model = Read-DemoProgress -Path $ModelPath
        if ($null -eq $model) {
            return
        }
        Save-DemoProgressFile -Path $PagePath -Text (ConvertTo-DemoProgressHtml -Model $model)
    }
    catch {
        Write-Debug -Message ('The status page wasn''t written: {0}' -f $_.Exception.Message)
    }
}

function Start-DemoProgressPageWriter {
    <#
    .SYNOPSIS
    Regenerates the status page every -IntervalSeconds (10; the brief asks for at least every 15) in a thread job of
    this process, with the heartbeat, so the page keeps moving while deploy.ps1 waits on long Azure calls. Falls back
    to a background job where thread jobs aren't available. Returns the job. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes the Git-ignored local status page only.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [string] $ModelPath,

        [Parameter(Mandatory)]
        [string] $PagePath,

        [ValidateRange(2, 15)]
        [int] $IntervalSeconds = 10
    )

    $modulePath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    $loop = {
        param([string] $Module, [string] $Model, [string] $Page, [int] $Seconds)
        Import-Module -Name $Module -Force
        $loaded = Get-Module -Name 'DbHubDemo'
        while ($true) {
            & $loaded { param($M, $P) Write-DemoProgressPage -ModelPath $M -PagePath $P -Heartbeat } $Model $Page
            Start-Sleep -Seconds $Seconds
        }
    }
    if (Get-Command -Name 'Start-ThreadJob' -ErrorAction SilentlyContinue) {
        return (Start-ThreadJob -Name 'dbhub-status-page' -ScriptBlock $loop -ArgumentList $modulePath, $ModelPath, $PagePath, $IntervalSeconds)
    }
    return (Start-Job -Name 'dbhub-status-page' -ScriptBlock $loop -ArgumentList $modulePath, $ModelPath, $PagePath, $IntervalSeconds)
}

function Stop-DemoProgressPageWriter {
    # Stops the page writer, then writes the page once more from the final model. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops this run''s own page writer and writes the local status page only.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [System.Management.Automation.Job] $Job,

        [string] $ModelPath = '',

        [string] $PagePath = ''
    )

    if ($null -ne $Job) {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
    if ($ModelPath -and $PagePath) {
        Write-DemoProgressPage -ModelPath $ModelPath -PagePath $PagePath
    }
}

function Open-DemoProgressPage {
    <#
    .SYNOPSIS
    Opens the status page in the default browser: Start-Process on Windows, open on macOS, xdg-open where it exists. In
    GitHub Codespaces, or with no way to open it, it returns how to preview it instead. Never throws. Returns the line to
    print. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PagePath,

        [switch] $NoBrowser
    )

    $relative = 'out/deploy-status.html'
    if ([string]$env:CODESPACES -eq 'true') {
        return ('Status page: {0}. In a codespace, preview it with: python3 -m http.server 8000 --directory out (then open the forwarded port 8000 from the Ports tab, and deploy-status.html), or run ./scripts/status.ps1 -Watch in a second terminal.' -f $relative)
    }
    if ($NoBrowser) {
        return ('Status page: {0} (open it in a browser), or run ./scripts/status.ps1 -Watch in a second terminal.' -f $PagePath)
    }
    try {
        if ($IsWindows) {
            Start-Process -FilePath $PagePath
        }
        elseif ($IsMacOS) {
            Start-Process -FilePath 'open' -ArgumentList $PagePath
        }
        elseif (Get-Command -Name 'xdg-open' -ErrorAction SilentlyContinue) {
            Start-Process -FilePath 'xdg-open' -ArgumentList $PagePath
        }
        else {
            return ('Status page: {0} (open it in a browser), or run ./scripts/status.ps1 -Watch in a second terminal.' -f $PagePath)
        }
        return ('The status page is open in your browser: {0}. It updates itself; ./scripts/status.ps1 -Watch shows the same in a terminal.' -f $PagePath)
    }
    catch {
        return ('Status page: {0} (it couldn''t be opened here: open it in a browser), or run ./scripts/status.ps1 -Watch.' -f $PagePath)
    }
}
