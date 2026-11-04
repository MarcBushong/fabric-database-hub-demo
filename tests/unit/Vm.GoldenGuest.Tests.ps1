BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the golden guest script's functions without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoGoldenGuest.ps1')
    $secure = [System.Security.SecureString]::new()
    foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
    $script:credential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
}

Describe 'Read-GoldenAgentState' {
    BeforeEach {
        Mock -CommandName Start-Sleep -MockWith { }
        $script:answers = [System.Collections.Generic.Queue[object]]::new()
        Mock -CommandName Invoke-Command -MockWith { $script:answers.Dequeue() }
    }

    It 'waits while the agent prints no JSON after a cold boot, then returns the identity it reports' {
        # Live, 2026-10-22: right after a restored copy's guest booted, azcmagent show -j printed no JSON, and the
        # Release took that for "no identity" and skipped the reset.
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = 'AZCM0064: Unable to establish communication with himds server' })
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '' })
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '{"status":"Disconnected","resourceName":"arcsql01","resourceGroup":"rg-dbhub-demo"}' })
        $state = Read-GoldenAgentState -Credential $script:credential -TimeoutSeconds 60 -PollSeconds 10
        $state.readable | Should -BeTrue
        $state.agent.resourceName | Should -Be 'arcsql01'
        $state.agent.resourceGroup | Should -Be 'rg-dbhub-demo'
        Should -Invoke -CommandName Invoke-Command -Times 3 -Exactly
        Should -Invoke -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'reports the state as unreadable, never as no identity, when the agent never answers' {
        1..6 | ForEach-Object { $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '' }) }
        $state = Read-GoldenAgentState -Credential $script:credential -TimeoutSeconds 60 -PollSeconds 10
        $state.readable | Should -BeFalse
        $state.installed | Should -BeTrue
        Should -Invoke -CommandName Invoke-Command -Times 6 -Exactly
    }

    It 'reports no identity only when the agent answers without a resource, or isn''t installed' {
        $script:answers.Enqueue([pscustomobject]@{ installed = $true; json = '{"status":"Disconnected","resourceName":""}' })
        $answered = Read-GoldenAgentState -Credential $script:credential
        $answered.readable | Should -BeTrue
        $answered.agent.status | Should -Be 'Disconnected'
        $answered.agent.resourceName | Should -BeNullOrEmpty
        $script:answers.Enqueue([pscustomobject]@{ installed = $false; json = '' })
        $missing = Read-GoldenAgentState -Credential $script:credential
        $missing.installed | Should -BeFalse
        $missing.readable | Should -BeTrue
    }
}

Describe 'Get-GoldenResetDecision' {
    BeforeAll {
        $script:capture = [pscustomobject]@{ arcResourceName = 'arcsql01'; arcResourceGroup = 'rg-dbhub-demo' }
    }

    It 'resets a copy whose agent names the captured identity' {
        (Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Disconnected'; resourceName = 'ARCSQL01'; resourceGroup = 'rg-dbhub-demo' }) -Capture $script:capture).Reason | Should -Be 'CapturedIdentity'
    }

    It 'resets a copy whose air-gapped agent names nothing, because that doesn''t prove there''s no identity (live, 2026-10-23)' {
        # The Release read {status: failed} with no resource, skipped the reset, and reconnected the guest; the onboarding's
        # probe then found the agent still configured for arcsql01.
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'failed'; resourceName = ''; resourceGroup = '' }) -Capture $script:capture
        $decision.Action | Should -Be 'Reset'
        $decision.Reason | Should -Be 'IdentityUnknown'
    }

    It 'leaves an agent that names another identity alone' {
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Connected'; resourceName = 'arcsql01'; resourceGroup = 'rg-dbhub-gtest' }) -Capture $script:capture
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Be 'OtherIdentity'
    }

    It 'skips only when the snapshot was captured without an identity and the agent names none' {
        $decision = Get-GoldenResetDecision -Agent ([pscustomobject]@{ status = 'Disconnected'; resourceName = '' }) -Capture ([pscustomobject]@{ arcResourceName = ''; arcResourceGroup = '' })
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Be 'NoCapturedIdentity'
    }
}

Describe 'The capture marker (review, 2026-11-04)' {
    BeforeAll {
        $script:now = [datetime]::new(2026, 11, 4, 2, 0, 0, [System.DateTimeKind]::Utc)
        function New-Marker([datetime] $StartedUtc, [string] $Source = 'source-vm') {
            [pscustomobject]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202611040100'; startedUtc = $StartedUtc.ToString("yyyy-MM-dd'T'HH':'mm':'ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture); sourceAzureVmId = $Source }
        }
        # Hyper-V's cmdlets exist only on a Hyper-V host; elsewhere these stand-ins let Pester mock them.
        $stubs = @{
            'Get-VM'   = 'param([string] $Name)'
            'Stop-VM'  = 'param([string] $Name, [switch] $Force, [switch] $AsJob)'
            'Set-VM'   = 'param([string] $Name, [string] $AutomaticStartAction, [int] $AutomaticStartDelay)'
            'Start-VM' = 'param([string] $Name)'
        }
        $script:addedStubs = @()
        foreach ($name in $stubs.Keys) {
            if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
                New-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stubs[$name])) | Out-Null
                $script:addedStubs += $name
            }
        }
    }

    AfterAll {
        foreach ($name in $script:addedStubs) {
            Remove-Item -Path ('function:global:' + $name) -ErrorAction SilentlyContinue
        }
    }

    It 'counts a marker for 6 hours, and only on the host it names' {
        $active = Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddMinutes(-59)) -AzureVmId 'SOURCE-VM' -NowUtc $script:now
        $active.State | Should -Be 'Active'
        $active.SnapshotName | Should -Be 'snap-dbhub-t2golden-202611040100'
        $active.SinceUtc | Should -Be '2026-11-04T01:01:00Z'
        $active.UntilUtc | Should -Be '2026-11-04T07:01:00Z'
        (Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddMinutes(-359)) -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'Active'
        (Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddHours(-6)) -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'None'
        (Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddMinutes(-5)) -AzureVmId 'copy-vm' -NowUtc $script:now).State | Should -Be 'None'
        (Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddMinutes(-5)) -AzureVmId '' -NowUtc $script:now).State | Should -Be 'Unknown'
        (Get-GoldenCaptureProgress -Marker $null -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'None'
        # Only Prepare writes the marker, so one that can't be read fails closed (review, 2026-11-04): Windows
        # PowerShell 5.1 on fi-FI wrote 09.44.28 before the time was written in the invariant culture.
        (Get-GoldenCaptureProgress -Marker ([pscustomobject]@{ startedUtc = 'not a time'; sourceAzureVmId = 'source-vm' }) -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'Unreadable'
        (Get-GoldenCaptureProgress -Marker ([pscustomobject]@{ snapshotName = 'snap-a'; startedUtc = '2026-11-04T01.44.28Z'; sourceAzureVmId = 'source-vm' }) -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'Unreadable'
        (Get-GoldenCaptureProgress -Marker ([pscustomobject]@{ snapshotName = 'snap-a'; startedUtc = '2026-11-04T01.44.28Z'; sourceAzureVmId = 'source-vm' }) -AzureVmId '' -NowUtc $script:now).State | Should -Be 'Unreadable'
        (Get-GoldenCaptureProgress -Marker ([pscustomobject]@{ startedUtc = '2026-11-04T01:44:28Z' }) -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'Unreadable'
        (Get-GoldenCaptureProgress -Marker (New-Object -TypeName 'psobject') -AzureVmId 'source-vm' -NowUtc $script:now).State | Should -Be 'Unreadable'
        # Another host's marker means nothing there, readable or not.
        (Get-GoldenCaptureProgress -Marker ([pscustomobject]@{ startedUtc = '2026-11-04T01.44.28Z'; sourceAzureVmId = 'source-vm' }) -AzureVmId 'copy-vm' -NowUtc $script:now).State | Should -Be 'None'
    }

    It 'writes and reads the marker''s time the same way under any culture (fi-FI, review of 2026-11-04)' {
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fi-FI')
            [datetime]::new(2026, 11, 4, 9, 44, 28, [System.DateTimeKind]::Utc).ToString('HH:mm:ss') | Should -Be '09.44.28' -Because 'fi-FI uses its own time separator'
            Format-GoldenUtc -Value ([datetime]::new(2026, 11, 4, 9, 44, 28, [System.DateTimeKind]::Utc)) | Should -Be '2026-11-04T09:44:28Z'
            $progress = Get-GoldenCaptureProgress -Marker (New-Marker -StartedUtc $script:now.AddMinutes(-30)) -AzureVmId 'source-vm' -NowUtc $script:now
            $progress.State | Should -Be 'Active'
            $progress.SinceUtc | Should -Be '2026-11-04T01:30:00Z'
            $progress.UntilUtc | Should -Be '2026-11-04T07:30:00Z'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
        }
    }

    Context 'Prepare and Release' {
        BeforeEach {
            $script:root = Join-Path -Path $TestDrive -ChildPath ('golden-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'golden') -Force | Out-Null
            $script:markerPath = Join-Path -Path $script:root -ChildPath 'golden\capture-in-progress.json'
            $script:guestState = 'Running'
            $script:markerAtAirGap = $false
            Mock -CommandName Get-GoldenHostFact -MockWith { @{ guestState = 'Running'; azureVmId = 'source-vm'; guestHyperVId = 'hyper-v-id' } }
            Mock -CommandName Wait-GoldenGuest -MockWith { [pscustomobject]@{ Credential = $script:credential; Seconds = 5 } }
            Mock -CommandName Invoke-Command -MockWith {
                [pscustomobject]@{ signInCaches = @(); setupLogFilesWithToken = 0; ieEsc = 'On'; sqlEdition = 'Standard Edition (64-bit)'; agentJson = '{"status":"Connected","resourceName":"arcsql01","resourceGroup":"rg-dbhub-demo"}'; evaluationExpiresUtc = '2027-04-19T13:46:22Z'; cachesRemoved = 0; logFilesRedacted = 0 }
            }
            Mock -CommandName Set-VM -MockWith { if ($AutomaticStartAction -eq 'Nothing') { $script:markerAtAirGap = Test-Path -LiteralPath $script:markerPath } }
            Mock -CommandName Disconnect-GoldenAdapter -MockWith { }
            Mock -CommandName Connect-GoldenAdapter -MockWith { }
            Mock -CommandName Get-GoldenAdapterState -MockWith { [ordered]@{ count = 1; connected = 0 } }
            Mock -CommandName Stop-VM -MockWith { $script:guestState = 'Off' }
            Mock -CommandName Start-VM -MockWith { $script:guestState = 'Running' }
            Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = $script:guestState; AutomaticStartAction = 'Nothing' } }
            Mock -CommandName Get-GoldenImdsVmId -MockWith { 'source-vm' }
            Mock -CommandName Start-Sleep -MockWith { }
        }

        It 'Prepare writes the marker before the air gap, naming this host, the snapshot, and the time' {
            $script:Options = @{ Root = $script:root; SnapshotName = 'snap-dbhub-t2golden-202611040100'; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $false }
            $result = Invoke-GoldenPrepare -Setting @{ AdministratorName = 'Administrator' }
            $result['succeeded'] | Should -BeTrue
            $script:markerAtAirGap | Should -BeTrue
            $marker = Get-Content -LiteralPath $script:markerPath -Raw | ConvertFrom-Json
            $marker.snapshotName | Should -Be 'snap-dbhub-t2golden-202611040100'
            $marker.sourceAzureVmId | Should -Be 'source-vm'
            $result['captureSinceUtc'] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            (Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Raw | ConvertFrom-Json).released | Should -BeFalse
        }

        It 'Prepare writes the marker''s time with the invariant culture under fi-FI, so it can be read back' {
            $script:Options = @{ Root = $script:root; SnapshotName = 'snap-dbhub-t2golden-202611040100'; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $false }
            $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fi-FI')
                $null = Invoke-GoldenPrepare -Setting @{ AdministratorName = 'Administrator' }
                $marker = Get-Content -LiteralPath $script:markerPath -Raw | ConvertFrom-Json -NoEnumerate:$false
                $text = (Get-Content -LiteralPath $script:markerPath -Raw) -replace '[\s\S]*"startedUtc"\s*:\s*"([^"]+)"[\s\S]*', '$1'
                $text | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
                (Get-GoldenCaptureProgress -Marker $marker -AzureVmId 'source-vm' -NowUtc ([DateTime]::UtcNow)).State | Should -Be 'Active'
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
            }
        }

        It 'only the capture''s own Release (EndCapture), or one that found the marker''s snapshot, ends the marker; any other refuses while it counts (review, 2026-11-04)' {
            $record = [ordered]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202611040100'; sourceAzureVmId = 'source-vm'; released = $false }
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Value ($record | ConvertTo-Json)
            Set-Content -LiteralPath $script:markerPath -Value (New-Marker -StartedUtc ([DateTime]::UtcNow.AddMinutes(-20)) | ConvertTo-Json)
            $script:guestState = 'Off'
            $setting = @{ SwitchName = 'DbHubDemoNat'; AdministratorName = 'Administrator'; ArcMarkerFile = 'arc-onboarded.json' }
            # start-demo.ps1 during the capture, with an older snapshot that names this host: refused, nothing changed.
            $script:Options = @{ Root = $script:root; SnapshotName = ''; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $false; CapturedSnapshots = @('snap-dbhub-t2golden-202601020304') }
            { Invoke-GoldenRelease -Setting $setting } | Should -Throw '*A golden capture is in progress on this host (snapshot snap-dbhub-t2golden-202611040100, since *nothing was released*'
            foreach ($command in 'Connect-GoldenAdapter', 'Set-VM', 'Start-VM') {
                Should -Invoke -CommandName $command -Times 0 -Exactly
            }
            Test-Path -LiteralPath $script:markerPath | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Raw | ConvertFrom-Json).released | Should -BeFalse
            # A host whose VM ID can't be read can't be told from the source: refused too.
            Mock -CommandName Get-GoldenImdsVmId -MockWith { throw 'The Instance Metadata Service did not answer.' }
            { Invoke-GoldenRelease -Setting $setting } | Should -Throw '*golden capture is in progress on this host as far as can be told*'
            Mock -CommandName Get-GoldenImdsVmId -MockWith { 'source-vm' }
            # Once the capture's snapshot exists (start-demo.ps1 found it), the marker is over: ended, and the source released.
            $script:Options['CapturedSnapshots'] = @('snap-dbhub-t2golden-202601020304', 'snap-dbhub-t2golden-202611040100')
            $found = Invoke-GoldenRelease -Setting $setting
            $found['succeeded'] | Should -BeTrue
            $found['captureEnded'] | Should -Be 'snap-dbhub-t2golden-202611040100'
            Test-Path -LiteralPath $script:markerPath | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Raw | ConvertFrom-Json).released | Should -BeTrue
            # The capture's own Release ends a marker whatever it says.
            Set-Content -LiteralPath $script:markerPath -Value (New-Marker -StartedUtc ([DateTime]::UtcNow.AddMinutes(-5)) | ConvertTo-Json)
            $script:Options = @{ Root = $script:root; SnapshotName = ''; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $true }
            $own = Invoke-GoldenRelease -Setting $setting
            $own['captureEnded'] | Should -Be 'EndCapture'
            Test-Path -LiteralPath $script:markerPath | Should -BeFalse
        }

        It 'refuses a marker that can''t be read (fail closed), which only the capture''s own Release ends' {
            $record = [ordered]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202611040100'; sourceAzureVmId = 'source-vm'; released = $false }
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Value ($record | ConvertTo-Json)
            $setting = @{ SwitchName = 'DbHubDemoNat'; AdministratorName = 'Administrator'; ArcMarkerFile = 'arc-onboarded.json' }
            $script:Options = @{ Root = $script:root; SnapshotName = ''; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $false }
            foreach ($content in @('{"snapshotName":"snap-dbhub-t2golden-202611040100","startedUtc":"2026-11-04T09.44.28Z","sourceAzureVmId":"source-vm"}', 'not json')) {
                Set-Content -LiteralPath $script:markerPath -Value $content
                { Invoke-GoldenRelease -Setting $setting } | Should -Throw '*golden capture marker on this host can''t be read*capture-t2-golden.ps1*'
            }
            Should -Invoke -CommandName Connect-GoldenAdapter -Times 0 -Exactly
            $script:Options['EndCapture'] = $true
            $null = Invoke-GoldenRelease -Setting $setting
            Test-Path -LiteralPath $script:markerPath | Should -BeFalse
        }

        It 'releases past a marker older than 6 hours, and past a copy''s marker from the snapshot, and leaves both' {
            $setting = @{ SwitchName = 'DbHubDemoNat'; AdministratorName = 'Administrator'; ArcMarkerFile = 'arc-onboarded.json' }
            $script:Options = @{ Root = $script:root; SnapshotName = ''; ProveIsolation = $false; KeepIsolated = $false; SkipRotation = $true; EndCapture = $false }
            $record = [ordered]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202611040100'; sourceAzureVmId = 'source-vm'; released = $false; resetUtc = '2026-11-04T02:00:00Z' }
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'golden\capture.json') -Value ($record | ConvertTo-Json)
            Set-Content -LiteralPath $script:markerPath -Value (New-Marker -StartedUtc ([DateTime]::UtcNow.AddHours(-7)) | ConvertTo-Json)
            (Invoke-GoldenRelease -Setting $setting)['succeeded'] | Should -BeTrue
            Test-Path -LiteralPath $script:markerPath | Should -BeTrue
            Mock -CommandName Get-GoldenImdsVmId -MockWith { 'copy-vm' }
            Set-Content -LiteralPath $script:markerPath -Value (New-Marker -StartedUtc ([DateTime]::UtcNow.AddMinutes(-30)) | ConvertTo-Json)
            $copy = Invoke-GoldenRelease -Setting $setting
            $copy['succeeded'] | Should -BeTrue
            $copy['role'] | Should -Be 'Copy'
            Test-Path -LiteralPath $script:markerPath | Should -BeTrue
        }
    }
}
