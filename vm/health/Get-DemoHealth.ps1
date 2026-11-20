<#
.SYNOPSIS
Prints health.json in compact form for the validator (ADR 0012). Run it through Run Command on T1 or the
T2 host.

.DESCRIPTION
Run Command keeps only the last 4 KB of output, so steps are reduced to a name-to-status map. The file is
already redacted by the bootstrap. Windows PowerShell 5.1.

With -View Summary (Phase 7), only the fields the orchestrator gates on are printed: role, state, status,
the first 500 characters of message, currentStep, generation, updatedUtc, and from details the install mode,
Arc onboarding, the guest's state, and its SQL Server edition. Since 2026-11-20 (F24) it also prints the first two
warnings, each cut to 240 characters and naming the step it came from, and how many there are (warningCount): a Ready VM
with warnings reports Warning, and the validator says which step warned. Since 2026-11-09 it also prints the configured install
mode, whether the configuration names it (modeSource), whether the host kept an existing guest's mode (modeAdopted), the
guest's own mode (guestMode) and whether a pass saw SQL Server set up in it (guestSetUp), and the last rebuild of an
unfinished guest, read from guest-rebuild.json itself (guestRebuild: Removing, Removed, or Done once the new guest
passed ArcOnboarding; rebuildUtc, rebuildMode, rebuildArcId, the old guest's Arc machine, and rebuildArcNew, whether
the Arc marker is already for the guest that exists now: true, false only on positive evidence, or null when that
can't be told; the Full view adds them as t2Rebuild). Since Phase 28 it also prints the PaygWizard
guided stop's state (details.guidedSetup): whether automatic sign-in is armed in the guest, deploy.ps1's
request (none, valid, expired, or invalid), setup's sign-in preparation (none, preparing, ready, or restoring:
the WebView2 runtime, IE Enhanced Security Configuration off for administrators, and the Trusted sites entries;
deploy.ps1 asks for a person only at ready), the last cleanup's reason, and up to five problems it left. Since
2026-11-05 it also prints the free space on the drive that holds the guest's disk (details.storage, for status.ps1's
early warning) and, in JumpstartImage mode, the Jumpstart image's etag, Last-Modified, and whether it's the tested one.
Since 2026-11-18 both views also print guestRecovery, the last restart that cleared a broken PowerShell Direct channel
into the T2 guest, read from guest-recovery.json itself (issue #65): when, by whom, its run key, how long it took, how
the guest stopped, whether it answered again, and the first 200 characters of the error.
Since 2026-11-19, on the T2 host (role ArcHost), both views report a bootstrap generation that the loader started in the
last 30 minutes and health.json doesn't report yet as InProgress (status Warning), with that generation, state.json's
current step once its pass has started, generationPending, and health.json's own generation and state
(reportedGeneration, reportedState): that pass checks every step again and writes health.json only when a step
converges or when it ends, so health.json's "Ready" is still the pass before's (#65 follow-up).
That always fits in 4 KB, even when instructions are long.

.PARAMETER Root
State folder. Defaults to C:\ProgramData\DbHubDemo.

.PARAMETER View
Full (default) or Summary.

.PARAMETER GuestName
The nested T2 guest on a Hyper-V host (archost01), whose live state both views add as t2Guest (2026-11-03):
present, state, heartbeat, startAction, adapters, connected, and with a golden capture record its golden state
(released, reset, and role: Source or Copy, from the host's Azure VM ID through the installed golden script, as its
Release decides it; no ID is printed). Nothing on a VM without Hyper-V.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\ProgramData\DbHubDemo',

    [ValidateSet('Full', 'Summary')]
    [string] $View = 'Full',

    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string] $GuestName = 'arcsql01'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DemoHealthGuestFact {
    # The T2 guest as Hyper-V sees it now; health.json's copy can be minutes old. $null without Hyper-V (sqlvm01).
    param([string] $StateRoot, [string] $Guest)

    if (-not (Get-Command -Name 'Get-VM' -ErrorAction SilentlyContinue)) {
        return $null
    }
    $facts = [ordered]@{ present = $false }
    try {
        $vm = Get-VM -Name $Guest -ErrorAction SilentlyContinue
        if ($vm) {
            $adapters = @(Get-VMNetworkAdapter -VMName $Guest -ErrorAction SilentlyContinue)
            $facts['present'] = $true
            $facts['state'] = [string]$vm.State
            $facts['heartbeat'] = [string]$vm.Heartbeat
            $facts['startAction'] = [string]$vm.AutomaticStartAction
            $facts['adapters'] = $adapters.Count
            $facts['connected'] = @($adapters | Where-Object { [string]$_.SwitchName }).Count
        }
        $goldenFolder = [System.IO.Path]::Combine($StateRoot, 'golden')
        $capturePath = [System.IO.Path]::Combine($goldenFolder, 'capture.json')
        $markerPath = [System.IO.Path]::Combine($goldenFolder, 'capture-in-progress.json')
        $capture = $null
        $marker = $null
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            $capture = [System.IO.File]::ReadAllText($capturePath) | ConvertFrom-Json
        }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $marker = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
            }
            catch {
                $marker = $null
            }
            if ($null -eq $marker) {
                # A marker that exists but can't be read names nothing: Unreadable, which fails closed.
                $marker = New-Object -TypeName 'psobject'
            }
        }
        $golden = $null
        if ($null -ne $capture) {
            $read = { param([string] $Name) $property = $capture.PSObject.Properties[$Name]; if ($property -and $null -ne $property.Value) { [string]$property.Value } else { '' } }
            $golden = [ordered]@{ released = ((& $read 'released') -eq 'True'); reset = [bool](& $read 'resetUtc'); role = '' }
        }
        # The host's role as the golden Release and T2's relay decide it, from its Azure VM ID (IMDS): needed for a record
        # that isn't released, for one that says released without a reset (only the source's may; review, 2026-11-04),
        # and for a capture marker, which counts only on the host it names.
        if ($null -ne $marker -or ($null -ne $golden -and -not ($golden['released'] -and $golden['reset']))) {
            if ($null -ne $golden) {
                $golden['role'] = 'Unknown'
            }
            $settingsPath = Join-Path -Path $StateRoot -ChildPath 'settings.json'
            $bundle = ''
            if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
                $property = ([System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json).PSObject.Properties['bundlePath']
                if ($property -and $property.Value) {
                    $bundle = [string]$property.Value
                }
            }
            $goldenScript = if ($bundle) { [System.IO.Path]::Combine($bundle, 'vm', 'bootstrap', 'Invoke-DemoGoldenGuest.ps1') } else { '' }
            if ($goldenScript -and (Test-Path -LiteralPath $goldenScript -PathType Leaf)) {
                . $goldenScript -GuestName $Guest -Root $StateRoot
                $azureVmId = ''
                try {
                    $azureVmId = Get-GoldenImdsVmId
                }
                catch {
                    $azureVmId = ''
                }
                if ($null -ne $golden) {
                    $source = & $read 'sourceAzureVmId'
                    if ($azureVmId -and $source) {
                        $golden['role'] = if ([string]::Equals($azureVmId, $source, [System.StringComparison]::OrdinalIgnoreCase)) { 'Source' } else { 'Copy' }
                    }
                }
                # An installed bundle from before 2026-11-04 has no marker reader; its relay doesn't read markers either.
                if ($null -ne $marker -and (Get-Command -Name 'Get-GoldenCaptureProgress' -ErrorAction SilentlyContinue)) {
                    $progress = Get-GoldenCaptureProgress -Marker $marker -AzureVmId $azureVmId -NowUtc ([DateTime]::UtcNow)
                    if ($progress.State -ne 'None') {
                        $facts['capture'] = [ordered]@{ state = $progress.State; snapshotName = $progress.SnapshotName; sinceUtc = $progress.SinceUtc; untilUtc = $progress.UntilUtc }
                    }
                }
            }
        }
        if ($null -ne $golden) {
            $facts['golden'] = $golden
        }
    }
    catch {
        $facts['error'] = ([string]$_.Exception.Message) -replace '[\r\n]+', ' '
    }
    return $facts
}

function Get-DemoHealthRebuildFact {
    # The last rebuild of an unfinished T2 guest (2026-11-09), read from guest-rebuild.json itself, because health.json's
    # details are written only at the end of the host's pass, which a rebuild's download keeps going for about half an hour.
    # arcCurrent, three-state: $true when the Arc marker names the VM ID of the guest that exists now (the new guest is
    # onboarded); $false only on positive evidence that it isn't (no marker, or the old guest's, oldGuestVmId); $null when
    # that can't be told (a marker without a VM ID or for another guest, Hyper-V not answering, no guest, or an error),
    # which deploy.ps1 takes as "delete nothing in Azure". $null without a record. Never throws.
    param([string] $StateRoot, [string] $Guest)

    $recordPath = Join-Path -Path $StateRoot -ChildPath 'guest-rebuild.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        return $null
    }
    $facts = [ordered]@{ state = 'Unreadable'; startedUtc = ''; oldMode = ''; arcResourceId = ''; oldGuestVmId = ''; arcCurrent = $null }
    try {
        $record = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        foreach ($name in 'state', 'startedUtc', 'oldMode', 'arcResourceId', 'oldGuestVmId') {
            $property = $record.PSObject.Properties[$name]
            if ($property -and $null -ne $property.Value) {
                # PowerShell 7's ConvertFrom-Json reads an ISO time as a DateTime; Windows PowerShell 5.1 keeps the text.
                if ($property.Value -is [datetime]) {
                    $facts[$name] = $property.Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $facts[$name] = [string]$property.Value
                }
            }
        }
        $markerPath = Join-Path -Path $StateRoot -ChildPath 'arc-onboarded.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            $facts['arcCurrent'] = $false
        }
        else {
            $marker = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
            $property = $marker.PSObject.Properties['guestVmId']
            $markerVmId = ''
            if ($property -and $null -ne $property.Value) {
                $markerVmId = [string]$property.Value
            }
            if ($markerVmId -and $facts['oldGuestVmId'] -and [string]::Equals($markerVmId, [string]$facts['oldGuestVmId'], [System.StringComparison]::OrdinalIgnoreCase)) {
                $facts['arcCurrent'] = $false
            }
            elseif ($markerVmId -and (Get-Command -Name 'Get-VM' -ErrorAction SilentlyContinue)) {
                $vm = Get-VM -Name $Guest -ErrorAction SilentlyContinue
                if ($vm -and [string]::Equals($markerVmId, [string]$vm.VMId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $facts['arcCurrent'] = $true
                }
            }
        }
    }
    catch {
        $facts['arcCurrent'] = $null
        $facts['error'] = ([string]$_.Exception.Message) -replace '[\r\n]+', ' '
    }
    return $facts
}

function Get-DemoHealthRecoveryFact {
    # The last restart that cleared a broken PowerShell Direct channel into the T2 guest (issue #65), read from
    # guest-recovery.json itself, so a restart a Run Command made shows before the bootstrap's next pass: startedUtc, by,
    # key, seconds, stoppedBy, recovered, and the first 200 characters of its reason. $null when there's none.
    param([string] $StateRoot)

    $recordPath = Join-Path -Path $StateRoot -ChildPath 'guest-recovery.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        return $null
    }
    try {
        $record = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        $last = @($record.restarts) | Select-Object -Last 1
        if ($null -eq $last) {
            return $null
        }
        $fact = [ordered]@{}
        foreach ($name in 'startedUtc', 'endedUtc', 'by', 'key', 'seconds', 'stoppedBy', 'recovered', 'reason') {
            $property = $last.PSObject.Properties[$name]
            $fact[$name] = if ($property) { $property.Value } else { $null }
            if ($fact[$name] -is [datetime]) {
                # PowerShell 7's ConvertFrom-Json reads an ISO time as a DateTime; Windows PowerShell 5.1 keeps the text.
                $fact[$name] = $fact[$name].ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        $reason = [string]$fact['reason']
        if ($reason.Length -gt 200) {
            $fact['reason'] = $reason.Substring(0, 200)
        }
        return $fact
    }
    catch {
        return [ordered]@{ error = ([string]$_.Exception.Message) -replace '[\r\n]+', ' ' }
    }
}

function Get-DemoHealthPassFact {
    # The bootstrap generation that the loader started on the T2 host and health.json doesn't report yet (#65 follow-up).
    # A new generation's pass checks every step again, and it writes health.json only when a step converges or when it
    # ends, so until then health.json still has the pass before's report, "Ready" from the generation before; on the user's
    # update (2026-11-18), deploy.ps1's PowerShell Direct sessions into the guest went ahead on that report and broke while
    # the pass ran. Returns generation (settings.json's), reportedGeneration and reportedState (health.json's), loaderRunUtc,
    # and currentStep (state.json's, once that generation's pass has started). $null when health.json reports the newest
    # generation, on a VM that isn't the T2 host (role ArcHost), and once the loader ran more than PendingMinutes ago: a
    # pass has reported by then unless the bootstrap doesn't run, which health.json's own updatedUtc shows. Never throws.
    param([string] $StateRoot, [object] $Health, [int] $PendingMinutes = 30, [datetime] $NowUtc = [DateTime]::UtcNow)

    try {
        $settingsPath = Join-Path -Path $StateRoot -ChildPath 'settings.json'
        if ($null -eq $Health -or -not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
            return $null
        }
        $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        $text = {
            param([object] $Object, [string] $Name)
            if ($null -eq $Object) {
                return ''
            }
            $property = $Object.PSObject.Properties[$Name]
            if (-not $property -or $null -eq $property.Value) {
                return ''
            }
            # PowerShell 7's ConvertFrom-Json reads an ISO time as a DateTime; Windows PowerShell 5.1 keeps the text.
            if ($property.Value -is [datetime]) {
                return $property.Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            return [string]$property.Value
        }
        $role = & $text $settings 'role'
        if (-not $role) {
            $role = & $text $Health 'role'
        }
        $generation = & $text $settings 'generation'
        $reported = & $text $Health 'generation'
        if ($role -ne 'ArcHost' -or -not $generation -or [string]::Equals($generation, $reported, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $loaderUtc = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if (-not [datetime]::TryParse((& $text $settings 'loaderRunUtc'), [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$loaderUtc)) {
            return $null
        }
        if (($NowUtc.ToUniversalTime() - $loaderUtc).TotalMinutes -gt $PendingMinutes) {
            return $null
        }
        $fact = [ordered]@{
            generation         = $generation
            reportedGeneration = $reported
            reportedState      = & $text $Health 'state'
            loaderRunUtc       = $loaderUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            currentStep        = $null
        }
        $statePath = Join-Path -Path $StateRoot -ChildPath 'state.json'
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            $step = & $text $state 'currentStep'
            if ($step -and (& $text $state 'generation') -eq $generation) {
                $fact['currentStep'] = $step
            }
        }
        return $fact
    }
    catch {
        return $null
    }
}

$path = Join-Path -Path $Root -ChildPath 'health.json'
$guestFacts = Get-DemoHealthGuestFact -StateRoot $Root -Guest $GuestName
$rebuildFacts = Get-DemoHealthRebuildFact -StateRoot $Root -Guest $GuestName
$recoveryFacts = Get-DemoHealthRecoveryFact -StateRoot $Root
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $missing = [ordered]@{ schemaVersion = 1; state = 'NotStarted'; status = 'Warning'; message = 'The bootstrap has not written health.json yet.' }
    if ($null -ne $guestFacts) {
        $missing['t2Guest'] = $guestFacts
    }
    Write-Output (ConvertTo-Json -InputObject $missing -Compress -Depth 4)
    return
}
$health = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
# A generation whose pass hasn't reported yet is reported as in progress, with the pass's step (#65 follow-up), so no
# caller takes the pass before's "Ready" for this one.
$passFacts = Get-DemoHealthPassFact -StateRoot $Root -Health $health
if ($null -ne $passFacts) {
    $passStep = if ($passFacts['currentStep']) { 'at step {0}' -f $passFacts['currentStep'] } else { 'starting' }
    $passMessage = 'Bootstrap generation {0}, which the loader started at {1}, checks every step again ({2}); health.json still has the report of generation {3} ({4}) until that pass converges a step or ends.' -f $passFacts['generation'], $passFacts['loaderRunUtc'], $passStep, $(if ($passFacts['reportedGeneration']) { $passFacts['reportedGeneration'] } else { 'none' }), $(if ($passFacts['reportedState']) { $passFacts['reportedState'] } else { 'no state' })
    $passValues = [ordered]@{ state = 'InProgress'; status = 'Warning'; message = $passMessage; currentStep = $passFacts['currentStep']; generation = $passFacts['generation']; generationPending = $true; reportedGeneration = $passFacts['reportedGeneration']; reportedState = $passFacts['reportedState'] }
    foreach ($name in $passValues.Keys) {
        $health | Add-Member -NotePropertyName $name -NotePropertyValue $passValues[$name] -Force
    }
}
if ($View -eq 'Summary') {
    $read = {
        param($Object, [string[]] $Names)
        $value = $Object
        foreach ($name in $Names) {
            if ($null -eq $value) {
                return $null
            }
            $property = $value.PSObject.Properties[$name]
            if (-not $property) {
                return $null
            }
            $value = $property.Value
        }
        return $value
    }
    $message = [string](& $read $health @('message'))
    if ($message.Length -gt 500) {
        $message = $message.Substring(0, 500)
    }
    # The warnings that keep a Ready VM's status a Warning, each naming its step (F24, 2026-11-20): the first two, each
    # cut to 240 characters, with how many there are, so the summary still fits.
    $allWarnings = @(& $read $health @('warnings') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $shownWarnings = @($allWarnings | Select-Object -First 2 | ForEach-Object { if ($_.Length -gt 240) { $_.Substring(0, 237) + '...' } else { $_ } })
    $summary = [ordered]@{
        schemaVersion  = 1
        role           = & $read $health @('role')
        state          = & $read $health @('state')
        status         = & $read $health @('status')
        message        = $message
        currentStep    = & $read $health @('currentStep')
        generation     = & $read $health @('generation')
        updatedUtc     = & $read $health @('updatedUtc')
        installMode    = & $read $health @('details', 'installMode')
        configuredMode = & $read $health @('details', 'configuredInstallMode')
        modeSource     = & $read $health @('details', 'installModeSource')
        modeAdopted    = & $read $health @('details', 'installModeAdopted')
        guestMode      = & $read $health @('details', 'guestSource', 'installMode')
        guestSetUp     = & $read $health @('details', 'guestSource', 'sqlSetUp')
        guestRebuild   = $(if ($null -ne $rebuildFacts) { $rebuildFacts['state'] } else { $null })
        rebuildUtc     = $(if ($null -ne $rebuildFacts) { $rebuildFacts['startedUtc'] } else { $null })
        rebuildMode    = $(if ($null -ne $rebuildFacts) { $rebuildFacts['oldMode'] } else { $null })
        rebuildArcId   = $(if ($null -ne $rebuildFacts) { $rebuildFacts['arcResourceId'] } else { $null })
        rebuildArcNew  = $(if ($null -ne $rebuildFacts) { $rebuildFacts['arcCurrent'] } else { $null })
        arcOnboarded   = & $read $health @('details', 'arcOnboarded')
        guestState     = & $read $health @('details', 'guest', 'state')
        sqlEdition     = & $read $health @('details', 'guest', 'sql', 'edition')
        guidedArmed    = & $read $health @('details', 'guidedSetup', 'armed')
        guidedRequest  = & $read $health @('details', 'guidedSetup', 'request')
        guidedSignIn   = & $read $health @('details', 'guidedSetup', 'signIn')
        guidedLast     = & $read $health @('details', 'guidedSetup', 'lastReason')
        guidedLeft     = @(& $read $health @('details', 'guidedSetup', 'lastProblems') | Where-Object { $_ } | Select-Object -First 5)
        storageDrive   = & $read $health @('details', 'storage', 'drive')
        storageFreeGiB = & $read $health @('details', 'storage', 'freeGiB')
        storageWarnGiB = & $read $health @('details', 'storage', 'warnBelowGiB')
        storageLow     = & $read $health @('details', 'storage', 'low')
        imageEtag      = & $read $health @('details', 'jumpstart', 'image', 'etag')
        imageModified  = & $read $health @('details', 'jumpstart', 'image', 'lastModified')
        imagePinned    = & $read $health @('details', 'jumpstart', 'image', 'pinned')
        signInFound    = & $read $health @('details', 'signIn', 'found')
        signInNote     = & $read $health @('details', 'signIn', 'note')
        warningCount   = $allWarnings.Count
        warnings       = $shownWarnings
    }
    if ($null -ne $guestFacts) {
        $summary['t2Guest'] = $guestFacts
    }
    if ($null -ne $recoveryFacts) {
        $summary['guestRecovery'] = $recoveryFacts
    }
    if ($null -ne $passFacts) {
        $summary['generationPending'] = $true
        $summary['reportedGeneration'] = $passFacts['reportedGeneration']
        $summary['reportedState'] = $passFacts['reportedState']
    }
    Write-Output (ConvertTo-Json -InputObject $summary -Compress -Depth 4)
    return
}
$steps = [ordered]@{}
foreach ($step in @($health.steps)) {
    $steps[[string]$step.name] = [string]$step.status
}
$health.steps = $steps
if ($null -ne $guestFacts) {
    $health | Add-Member -NotePropertyName 't2Guest' -NotePropertyValue $guestFacts -Force
}
if ($null -ne $rebuildFacts) {
    $health | Add-Member -NotePropertyName 't2Rebuild' -NotePropertyValue $rebuildFacts -Force
}
if ($null -ne $recoveryFacts) {
    $health | Add-Member -NotePropertyName 'guestRecovery' -NotePropertyValue $recoveryFacts -Force
}
Write-Output ($health | ConvertTo-Json -Depth 10 -Compress)
