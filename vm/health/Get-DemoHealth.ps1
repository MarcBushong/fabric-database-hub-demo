<#
.SYNOPSIS
Prints health.json in compact form for the validator (ADR 0012). Run it through Run Command on T1 or the
T2 host.

.DESCRIPTION
Run Command keeps only the last 4 KB of output, so steps are reduced to a name-to-status map. The file is
already redacted by the bootstrap. Windows PowerShell 5.1.

With -View Summary (Phase 7), only the fields the orchestrator gates on are printed: role, state, status,
the first 500 characters of message, currentStep, generation, updatedUtc, and from details the install mode,
Arc onboarding, the guest's state, and its SQL Server edition. Since Phase 28 it also prints the PaygWizard
guided stop's state (details.guidedSetup): whether automatic sign-in is armed in the guest, deploy.ps1's
request (none, valid, expired, or invalid), setup's sign-in preparation (none, preparing, ready, or restoring:
the WebView2 runtime, IE Enhanced Security Configuration off for administrators, and the Trusted sites entries;
deploy.ps1 asks for a person only at ready), the last cleanup's reason, and up to five problems it left. Since
2026-11-05 it also prints the free space on the drive that holds the guest's disk (details.storage, for status.ps1's
early warning) and, in JumpstartImage mode, the Jumpstart image's etag, Last-Modified, and whether it's the tested one.
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

$path = Join-Path -Path $Root -ChildPath 'health.json'
$guestFacts = Get-DemoHealthGuestFact -StateRoot $Root -Guest $GuestName
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $missing = [ordered]@{ schemaVersion = 1; state = 'NotStarted'; status = 'Warning'; message = 'The bootstrap has not written health.json yet.' }
    if ($null -ne $guestFacts) {
        $missing['t2Guest'] = $guestFacts
    }
    Write-Output (ConvertTo-Json -InputObject $missing -Compress -Depth 4)
    return
}
$health = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
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
    }
    if ($null -ne $guestFacts) {
        $summary['t2Guest'] = $guestFacts
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
Write-Output ($health | ConvertTo-Json -Depth 10 -Compress)
