BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig([switch] $WithT4) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        # T4 (Phase 24) has its own tests below; the others keep their focus with T4 off.
        $config['t4Enabled'] = [bool]$WithT4
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status)
    }

    function New-TestSnapshot {
        param([int] $DaysLeft = 179, [bool] $BootVerified = $true, [string] $Location = 'westus3')
        [pscustomobject]@{
            Name = 'snap-dbhub-t2golden-202610221306'; Id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap-dbhub-t2golden-202610221306'
            Location = $Location; NetworkAccessPolicy = 'DenyAll'; ProvisioningState = 'Succeeded'; InstallMode = 'PaygWizard'; SecurityType = 'Standard'
            CapturedUtc = [datetime]::new(2026, 10, 22, 13, 6, 0, [System.DateTimeKind]::Utc); BootVerifiedUtc = $(if ($BootVerified) { [datetime]::new(2026, 10, 22, 14, 30, 0, [System.DateTimeKind]::Utc) } else { $null })
            OnboardVerifiedUtc = $null; EvalExpiresUtc = [datetime]::new(2027, 4, 19, 13, 46, 0, [System.DateTimeKind]::Utc); EvalDaysLeft = $DaysLeft
        }
    }

    # What deploy.ps1 hands the track processes (Write-DemoTrackHandoff's file format).
    function Write-TestHandoff([string] $Name, [object] $Value) {
        $file = Join-Path -Path $script:handoffDir -ChildPath ('{0}.xml' -f $Name)
        [System.IO.File]::WriteAllText($file, [System.Management.Automation.PSSerializer]::Serialize($Value, 20))
    }

    function New-TestState {
        [pscustomobject]@{
            Exists = $true; Stage = ''; StageUtc = ''; BundleSha256 = ('a' * 64); BundleChunkCount = 1; RunnerSha256 = ('b' * 64); RunnerChunkCount = 7
            BundleSentTo = @('sqlvm01', 'archost01'); RunnerSentTo = @('sqlvm01', 'archost01'); NetworkMode = 'private'; T3UseFreeLimit = $true; T3AdminGroupName = 'sg-t3'
            BastionExpiresUtc = ''; HostPasswordUtc = ''; TrackT1 = ''; TrackT2 = ''; TrackT4 = ''; TrackFabric = ''; T2Source = ''; Tags = @{}
        }
    }
}

Describe 'Resolve-DemoTrackPlan' {
    It 'runs everything by default: Preflight and Infrastructure here, every track step, and the validation' {
        $plan = InModuleScope DbHubDemo { Resolve-DemoTrackPlan }
        $plan.Preflight | Should -BeTrue
        $plan.Infrastructure | Should -BeTrue
        $plan.Validation | Should -BeTrue
        $plan.Tracks['T1'] | Should -Be @('T3Setup', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'Telemetry')
        $plan.Tracks['T2'] | Should -Be @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry')
        $plan.Tracks['T4'] | Should -Be @('Server', 'Telemetry')
        $plan.Tracks['Fabric'] | Should -Be @('Fabric')
    }

    It 'maps -FromStage T4 onto T1''s T4 step and the T4 track, and leaves the T4 track empty with -SkipT4' {
        $plan = InModuleScope DbHubDemo { Resolve-DemoTrackPlan -FromStage 'T4' -StopAfter 'T4' }
        $plan.Tracks['T1'] | Should -Be @('T4')
        $plan.Tracks['T4'] | Should -Be @('Server')
        @((InModuleScope DbHubDemo { Resolve-DemoTrackPlan -SkipT4 }).Tracks['T4']).Count | Should -Be 0
    }

    It 'keeps T3Setup in stage T3: -StopAfter Bootstraps leaves it out, -FromStage T3 keeps it before the T3 step' {
        (InModuleScope DbHubDemo { Resolve-DemoTrackPlan -StopAfter 'Bootstraps' }).Tracks['T1'] | Should -Be @('Artifacts', 'Bootstraps')
        (InModuleScope DbHubDemo { Resolve-DemoTrackPlan -FromStage 'T3' -StopAfter 'T3' }).Tracks['T1'] | Should -Be @('T3Setup', 'T3')
    }

    It 'maps -FromStage T2 onto the T2 track, Fabric, and the telemetry checks, as the sequential stages did' {
        $plan = InModuleScope DbHubDemo { Resolve-DemoTrackPlan -FromStage 'T2' }
        $plan.Preflight | Should -BeFalse
        $plan.Infrastructure | Should -BeFalse
        $plan.Tracks['T1'] | Should -Be @('Telemetry')
        $plan.Tracks['T2'] | Should -Be @('T2', 'Telemetry')
        $plan.Tracks['Fabric'] | Should -Be @('Fabric')
    }

    It 'stops after the infrastructure with -StopAfter Infrastructure' {
        $plan = InModuleScope DbHubDemo { Resolve-DemoTrackPlan -StopAfter 'Infrastructure' }
        $plan.Infrastructure | Should -BeTrue
        @($plan.Tracks['T1']).Count + @($plan.Tracks['T2']).Count + @($plan.Tracks['Fabric']).Count | Should -Be 0
        $plan.Validation | Should -BeFalse
    }

    It 'leaves the Fabric track out with -SkipFabric' {
        $plan = InModuleScope DbHubDemo { Resolve-DemoTrackPlan -SkipFabric }
        @($plan.Tracks['Fabric']).Count | Should -Be 0
    }

    It 'resumes each track after the last step it recorded' {
        $state = New-TestState
        $state.Stage = 'Infrastructure'
        $state.TrackT1 = 'T3'
        $state.TrackT4 = 'Server'
        $state.TrackFabric = 'Fabric'
        $plan = InModuleScope DbHubDemo -Parameters @{ State = $state } { Resolve-DemoTrackPlan -Resume -State $State }
        $plan.Preflight | Should -BeFalse
        $plan.Infrastructure | Should -BeFalse
        $plan.Tracks['T1'] | Should -Be @('T4', 'Activity', 'Monitoring', 'Telemetry')
        $plan.Tracks['T2'] | Should -Be @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry')
        $plan.Tracks['T4'] | Should -Be @('Telemetry')
        @($plan.Tracks['Fabric']).Count | Should -Be 0
    }
}

Describe 'Resolve-DemoT2Source' {
    BeforeEach {
        $config = New-TestConfig
        $script:vm = $null
        $script:snapshots = @(New-TestSnapshot)
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { $script:vm }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { $script:snapshots }
    }

    It 'keeps an existing host restored from a golden disk on that disk' {
        $script:vm = [pscustomobject]@{ name = 'archost01'; osProfile = $null }
        $source = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }
        $source.Source | Should -Be 'existing-golden'
        $source.AttachExisting | Should -BeTrue
        $source.Result.status | Should -Be 'Pass'
    }

    It 'keeps an existing host built from the image' {
        $script:vm = [pscustomobject]@{ name = 'archost01'; osProfile = [pscustomobject]@{ computerName = 'archost01' } }
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }).Source | Should -Be 'existing-build'
    }

    It 'restores a new host from the newest boot-verified snapshot' {
        $source = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }
        $source.Source | Should -Be 'golden'
        $source.SnapshotName | Should -Be 'snap-dbhub-t2golden-202610221306'
        $source.SnapshotId | Should -Match '/snapshots/snap-dbhub-t2golden-202610221306$'
        $source.Result.status | Should -Be 'Pass'
    }

    It 'builds a new host when the snapshot isn''t boot-verified, and says why' {
        $script:snapshots = @(New-TestSnapshot -BootVerified $false)
        $source = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }
        $source.Source | Should -Be 'build'
        $source.Result.message | Should -Match 'not boot-verified'
    }

    It 'fails with t2Source golden and no usable snapshot' {
        $config['t2Source'] = 'golden'
        $script:snapshots = @(New-TestSnapshot -Location 'eastus2')
        $source = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }
        $source.Result.status | Should -Be 'Fail'
    }

    It 'always builds with t2Source build' {
        $config['t2Source'] = 'build'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }).Source | Should -Be 'build'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -Times 0 -Exactly
    }

    It 'warns 30 days and 7 days before the guest''s evaluation ends' {
        $script:snapshots = @(New-TestSnapshot -DaysLeft 20)
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }).Result.status | Should -Be 'Warning'
        $script:snapshots = @(New-TestSnapshot -DaysLeft 5)
        $source = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoT2Source -Config $Config }
        $source.Result.status | Should -Be 'Warning'
        $source.Result.message | Should -Match 're-capture now'
    }
}

Describe 'Invoke-DemoBootstrapLoaderRun' {
    BeforeEach {
        $config = New-TestConfig
        $script:run = [pscustomobject]@{ Succeeded = $true; Output = 'DbHubDemo loader finished: role SqlVm'; Error = '' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith { $script:runParameter = $Parameter; $script:run }
    }

    It 'runs the loader with the template''s settings and the runner filled in' {
        $settings = @{ role = 'SqlVm'; workload = @{ runnerSha256 = ''; runnerChunkCount = 0; activityProfile = 'baseline' }; t3 = @{ serverName = 'azuresql01-abc123' } }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config; Settings = $settings } { Invoke-DemoBootstrapLoaderRun -Config $Config -VmName 'sqlvm01' -BundleSha256 ('A' * 64) -ChunkCount 1 -Settings $Settings -RunnerSha256 ('B' * 64) -RunnerChunkCount 7 }
        $result.checkId | Should -Be 'INFRA.BOOTSTRAP.LOADER_SQLVM01'
        $result.status | Should -Be 'Pass'
        $script:runParameter['Role'] | Should -Be 'SqlVm'
        $script:runParameter['BundleSha256'] | Should -Be ('a' * 64)
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:runParameter['SettingsJson'])) | ConvertFrom-Json
        $decoded.workload.runnerSha256 | Should -Be ('b' * 64)
        $decoded.workload.runnerChunkCount | Should -Be 7
        $decoded.t3.serverName | Should -Be 'azuresql01-abc123'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $RunCommandName -eq 'DbHubDemo-Bootstrap' -and $VmName -eq 'sqlvm01' -and $Script -match 'Invoke-DemoBootstrapLoader' }
    }

    It 'refuses settings for another role' {
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoBootstrapLoaderRun -Config $Config -VmName 'archost01' -BundleSha256 ('a' * 64) -ChunkCount 1 -Settings @{ role = 'SqlVm' } }
        $result.status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
    }

    It 'reports a failed loader' {
        $script:run = [pscustomobject]@{ Succeeded = $false; Output = ''; Error = 'chunk 1 missing' }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoBootstrapLoaderRun -Config $Config -VmName 'archost01' -BundleSha256 ('a' * 64) -ChunkCount 1 -Settings @{ role = 'ArcHost' } }
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'chunk 1 missing'
    }
}

Describe 'Invoke-DemoDeploymentTrack' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:state = New-TestState
        $script:arcConnected = $true
        $script:context = @{
            NetworkMode = 'private'; T3UseFreeLimit = $true; T2Source = 'golden'; ConfigPath = ''; NoState = $false
            Bundle = [pscustomobject]@{ Path = 'bundle.zip'; Sha256 = ('c' * 64); SizeBytes = 10 }
            Runner = [pscustomobject]@{ Path = 'runner.zip'; Sha256 = ('d' * 64); SizeBytes = 20 }
            LoaderSettings = @{ sqlVm = @{ role = 'SqlVm' }; host = @{ role = 'ArcHost' } }
        }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $script:state }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith {
            if ($AddKind) {
                $script:calls.Add(('state {0} {1}' -f $AddKind, $AddVm))
                if ($AddKind -eq 'Bundle') {
                    $script:state.BundleSha256 = $Sha256
                    $script:state.BundleSentTo = @($AddVm)
                } else {
                    $script:state.RunnerSha256 = $Sha256
                    $script:state.RunnerSentTo = @($AddVm)
                }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoChunkSet -MockWith {
            $script:calls.Add(('chunks {0} {1} {2}' -f $VmName, (@($File | ForEach-Object { $_.Description }) -join '+'), $Parallelism))
            @($File | ForEach-Object { [pscustomobject]@{ Description = $_.Description; Sha256 = $_.Sha256; ChunkCount = $(if ($_.Description -eq 'bootstrap bundle') { 1 } else { 7 }); Seconds = 90 } })
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoBootstrapLoaderRun -MockWith { $script:calls.Add('loader ' + $VmName); New-TestResult ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmAgentReady -MockWith { $script:calls.Add('agent'); 20 }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:calls.Add('password'); New-TestResult 'STOP.HOSTPASSWORD' }
        $script:releaseData = [pscustomobject]@{ role = 'Copy'; captured = $true; reset = [pscustomobject]@{ steps = @('disconnect --force-local-only exited 0') }; sqlService = 'Running'; sqlEdition = 'Standard Edition (64-bit)'; guestPassword = 'Rotated'; guestState = 'Running' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            $script:calls.Add('release')
            $alongside = Get-Variable -Name 'WhileRunning' -ValueOnly -ErrorAction SilentlyContinue
            $script:releaseAlongside = $null -ne $alongside
            if ($null -ne $alongside) {
                & $alongside
            }
            [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 600; Data = $script:releaseData; WhileRunningError = '' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith {
            $script:calls.Add(('arc force={0}' -f [bool](Get-Variable -Name 'Force' -ValueOnly -ErrorAction SilentlyContinue)))
            @((New-TestResult 'T2.ARC.ONBOARDING' $(if ($script:arcConnected) { 'Pass' } else { 'Warning' })), (New-TestResult 'T2.ARC.CONNECTED' $(if ($script:arcConnected) { 'Pass' } else { 'Warning' })))
        }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -MockWith { $script:calls.Add('profile ' + $Target); New-TestResult ('DEPLOY.PROFILE_{0}' -f $Target) }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:calls.Add('telemetry ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('TELEMETRY.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { $script:calls.Add('health ' + $VmName); [pscustomobject]@{ Health = [pscustomobject]@{ state = 'Ready'; message = 'Every step is in the desired state.' }; Polls = 3 } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { '99999999-9999-9999-9999-999999999999' }
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith { $script:calls.Add('group'); New-TestResult 'T3.GROUP' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith { $script:calls.Add('t3setup'); [pscustomobject]@{ Status = 'Pass'; Result = (New-TestResult 'T3.SQL') } }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoT3Workload -MockWith { $script:calls.Add('t3workload'); New-TestResult 'WORKLOAD.T3' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT3 -MockWith { $script:calls.Add('t3checks'); New-TestResult 'T3.DATABASE' }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith { $script:calls.Add('monitoring'); New-TestResult 'T1.SQLVM.MONITORING' }
        # Phase 28: the VM's extensions settle before its artifacts and its loader (brief item 14); its own tests are in DbHubDemo.OneCommand.Tests.ps1.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmSettle -MockWith { [pscustomobject]@{ Settled = $true; Results = @() } }
    }

    It 'restores a golden T2 host: passwords and the reset first, then its artifacts, loader, onboarding with -Force, profile, and telemetry' {
        $script:state.BundleSentTo = @()
        $script:state.RunnerSentTo = @()
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry') }
        $outcome.Status | Should -Be 'Pass'
        $outcome.Steps | Should -Be @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry')
        $outcome.ReadyUtc['T2'] | Should -Not -BeNullOrEmpty
        $order = @($script:calls | Where-Object { $_ -notmatch '^state' })
        # The artifacts travel while the Release runs (ADR 0018); the Artifacts step then has nothing left to send.
        $order | Should -Be @('agent', 'password', 'release', 'chunks archost01 bootstrap bundle+workload runner 8', 'loader archost01', 'arc force=True', 'health archost01', 'profile T2', 'telemetry T2')
        $script:releaseAlongside | Should -BeTrue
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).status | Should -Be 'Pass'
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).message | Should -Match 'reset locally, SQL Server runs Standard Edition'
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.READY' }).status | Should -Be 'Pass'
    }

    It 'records when archost01''s loader starts a bootstrap generation, and clears it after a new golden copy''s Release and after the T2 step (review follow-up)' {
        # The watchdog never restarts the host while that generation may still build its guest (Get-DemoHostRestartBlocker).
        $script:state.BundleSentTo = @()
        $script:state.RunnerSentTo = @()
        $script:buildMarks = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentStateLocked -MockWith {
            $value = $PesterBoundParameters['Value']
            if ($null -ne $value -and $value.Contains('T2BuildUtc')) {
                $script:buildMarks.Add($(if ($value['T2BuildUtc']) { 'set' } else { 'clear' }))
            }
            if ($PesterBoundParameters['AddKind'] -eq 'Bundle') {
                $script:state.BundleSha256 = $PesterBoundParameters['Sha256']
                $script:state.BundleSentTo = @($PesterBoundParameters['AddVm'])
            }
            elseif ($PesterBoundParameters['AddKind'] -eq 'Runner') {
                $script:state.RunnerSha256 = $PesterBoundParameters['Sha256']
                $script:state.RunnerSentTo = @($PesterBoundParameters['AddVm'])
            }
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry') }
        $outcome.Status | Should -Be 'Pass'
        $script:buildMarks | Should -Be @('clear', 'set', 'clear')

        # A copy that an earlier run released keeps the record: that run's loader may have started a generation since.
        $script:buildMarks.Clear()
        $script:releaseData = [pscustomobject]@{ role = 'Copy'; captured = $true; guestState = 'Running' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore') }
        $script:buildMarks.Count | Should -Be 0

        # A loader that never started records nothing; T1's loader never does.
        $script:buildMarks.Clear()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoBootstrapLoaderRun -MockWith { New-DemoResult -CheckId ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'not started' -Evidence @{ notStarted = $true } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmWatchdog -MockWith { [pscustomobject]@{ Restarted = $false; Saved = ''; Items = @(); Result = (New-TestResult ('DEPLOY.WATCHDOG_{0}' -f $VmName.ToUpperInvariant()) 'Warning') } }
        $script:context['T2Source'] = 'build'
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Bootstraps') }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Bootstraps') }
        $script:buildMarks.Count | Should -Be 0
    }

    It 'sends archost01''s artifacts during the Release without the extension wait or the watchdog, which wait for the Artifacts step (review finding 6)' {
        $script:state.BundleSentTo = @()
        $script:state.RunnerSentTo = @()
        $script:inRelease = $false
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            $script:calls.Add('release')
            $alongside = Get-Variable -Name 'WhileRunning' -ValueOnly -ErrorAction SilentlyContinue
            $whileError = ''
            $script:inRelease = $true
            try {
                if ($null -ne $alongside) {
                    & $alongside
                }
            }
            catch {
                $whileError = $_.Exception.Message
            }
            finally {
                $script:inRelease = $false
            }
            [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 600; Data = $script:releaseData; WhileRunningError = $whileError }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmSettle -MockWith { $script:calls.Add(('settle {0} release={1}' -f $VmName, $script:inRelease)); [pscustomobject]@{ Settled = $true; Results = @() } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmWatchdog -MockWith { $script:calls.Add(('watchdog {0} release={1}' -f $VmName, $script:inRelease)); [pscustomobject]@{ Restarted = $false; Saved = ''; Items = @(); Result = (New-TestResult ('DEPLOY.WATCHDOG_{0}' -f $VmName.ToUpperInvariant()) 'Warning') } }
        # The chunks get stuck while the Release runs, and go through afterward.
        Mock -ModuleName DbHubDemo -CommandName Send-DemoChunkSet -MockWith {
            $script:calls.Add(('chunks {0} release={1}' -f $VmName, $script:inRelease))
            if ($script:inRelease) {
                throw 'no chunk finished for 5 minutes'
            }
            @($File | ForEach-Object { [pscustomobject]@{ Description = $_.Description; Sha256 = $_.Sha256; ChunkCount = 1; Seconds = 90 } })
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps') }
        $outcome.Status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -match '^(settle|watchdog) .*release=True' }) | Should -BeNullOrEmpty
        $script:calls | Should -Contain 'chunks archost01 release=True'
        $script:calls | Should -Contain 'settle archost01 release=False'
        $script:calls | Should -Contain 'chunks archost01 release=False'
    }

    It 'fails the T2 step when the host''s own last step failed, instead of passing on the Arc checks (live, 2026-10-27)' {
        # The host installs T2's runner after onboarding; live, setup --target T2 failed while every Arc check passed.
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { $script:calls.Add('health ' + $VmName); [pscustomobject]@{ Health = [pscustomobject]@{ state = 'Failed'; message = 'Step WorkloadRunner failed: setup --target T2: Fail.' }; Polls = 4 } }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2', 'Telemetry') }
        $outcome.Status | Should -Be 'Fail'
        $ready = $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.READY' }
        $ready.status | Should -Be 'Fail'
        $ready.message | Should -Match 'WorkloadRunner failed'
        $ready.remediation | Should -Match 'Get-DemoVmHealth -VmName archost01 -View Full'
        $script:calls | Should -Not -Contain 'profile T2'
        $script:calls | Should -Not -Contain 'telemetry T2'
    }

    It 'waits for the host only when T2 has a runner, and carries on with a Warning when it isn''t Ready in time' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { $script:calls.Add('health ' + $VmName); [pscustomobject]@{ Health = [pscustomobject]@{ state = 'InProgress'; message = 'Step WorkloadRunner is running.' }; Polls = 30 } }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.READY' }).status | Should -Be 'Warning'
        $script:calls | Should -Contain 'profile T2'
        $script:calls.Clear()
        $script:state.RunnerSha256 = ''
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        $script:calls | Should -Not -Contain 'health archost01'
        $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.READY' } | Should -BeNullOrEmpty
    }

    It 'says so when an earlier run already released the copy, instead of claiming a reset (live, 2026-10-22)' {
        $script:context['T2Source'] = 'existing-golden'
        $script:releaseData = [pscustomobject]@{ role = 'Copy'; captured = $true; guestState = 'Running' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore') }
        $restore = $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }
        $restore.status | Should -Be 'Pass'
        $restore.message | Should -Match 'an earlier run released'
        $restore.message | Should -Not -Match 'reset locally'
        $script:calls | Should -Not -Contain 'password'
    }

    It 'reports a T2 that builds its guest as running in the background, without waiting' {
        $script:context['T2Source'] = 'build'
        $script:arcConnected = $false
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps', 'T2', 'Telemetry') }
        $outcome.Status | Should -Be 'Background'
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.BACKGROUND' }).status | Should -Be 'Manual action required'
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).status | Should -Be 'Not selected'
        $script:calls | Should -Contain 'arc force=False'
        $script:calls | Should -Not -Contain 'password'
        $script:calls | Should -Not -Contain 'telemetry T2'
    }

    It 'cleans up what an earlier guided stop left open at the end of the T2 step: after -NoWaitForT2, on a golden redeploy, and once when the guided stop isn''t needed (Phase 28 review)' {
        # The review: a rerun after a Ctrl+C at the guided stop, with setup finished meanwhile, could end DONE with Bastion
        # up and the handed-over host password valid.
        Mock -ModuleName DbHubDemo -CommandName Complete-DemoGuidedStop -MockWith { $script:calls.Add('cleanup'); $script:state.HostPasswordUtc = ''; @() }
        $cleanups = { @($script:calls | Where-Object { $_ -eq 'cleanup' }).Count }

        # -NoWaitForT2 (this context doesn't wait): T2 goes on in the background, and the step still cleans up.
        $script:context['T2Source'] = 'build'
        $script:arcConnected = $false
        $script:state.HostPasswordUtc = '2026-10-29T15:00:00Z'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        $outcome.Status | Should -Be 'Background'
        & $cleanups | Should -Be 1
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).status | Should -Be 'Pass'

        # A golden redeploy.
        $script:calls.Clear()
        $script:context['T2Source'] = 'golden'
        $script:arcConnected = $true
        $script:state.HostPasswordUtc = '2026-10-29T15:00:00Z'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        $outcome.Status | Should -Be 'Pass'
        & $cleanups | Should -Be 1

        # The default wait: setup finished after the Ctrl+C, so the guided stop isn't needed; it cleans up, and the step
        # doesn't again.
        $script:calls.Clear()
        $script:context['T2Source'] = 'build'
        $script:context['WaitForT2'] = $true
        $script:state.HostPasswordUtc = '2026-10-29T15:00:00Z'
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoT2HostBuild -MockWith { [pscustomobject]@{ Failed = $false; TimedOut = $false; Health = [pscustomobject]@{ state = 'Ready'; currentStep = 'WorkloadRunner'; message = 'Every step is in the desired state.' } } }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        $outcome.Status | Should -Be 'Pass'
        & $cleanups | Should -Be 1
        @($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).Count | Should -Be 1
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDSTOP' }).status | Should -Be 'Not selected'

        # Nothing open: nothing to clean up.
        $script:calls.Clear()
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('T2') }
        & $cleanups | Should -Be 0
        $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' } | Should -BeNullOrEmpty
    }

    It 'runs the Fabric track: notebooks and dashboard, the history report, then the Fabric app step' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith { $script:calls.Add('fabric stage'); New-TestResult 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith { $script:calls.Add('powerbi'); New-TestResult 'FABRIC.SEMANTICMODEL.DATA' $script:powerBIStatus }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith { $script:calls.Add('fabric app'); New-TestResult 'DEPLOY.FABRIC.APP' 'Not selected' }
        $script:powerBIStatus = 'Pass'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'Fabric' -Context $Context -Step @('Fabric') }
        $outcome.Status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -in 'fabric stage', 'powerbi', 'fabric app' }) | Should -Be @('fabric stage', 'powerbi', 'fabric app')
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.FABRIC.APP' }).status | Should -Be 'Not selected'
        $script:powerBIStatus = 'Fail'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'Fabric' -Context $Context -Step @('Fabric') }).Status | Should -Be 'Fail'
    }

    It 'gives the optional Insights app the workspace the Fabric step resolved, and shows its actual reason, never a Fail, on the status page (Phase 28 live finding)' {
        # Live: the app's own lookup by name of the workspace just created failed, and the page showed Skipped with a
        # status of Fail and a generic message about tenant settings that were on.
        $workspaceId = '44444444-4444-4444-4444-444444444444'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith {
            New-DemoResult -CheckId 'FABRIC.RESOLVE.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Created the Fabric workspace.' -Evidence ([ordered]@{ workspaceId = '44444444-4444-4444-4444-444444444444'; source = 'created' })
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith { New-TestResult 'FABRIC.REPORT' }
        $script:appWorkspace = ''
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppStage -MockWith {
            $script:appWorkspace = [string]$PesterBoundParameters['WorkspaceId']
            New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Rayfin CLI isn''t signed in, so the app can''t be deployed unattended.' -Remediation 'Run ./scripts/configure-fabric-app.ps1 -SignIn.'
            New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Not deployed: FABRIC.APP.SIGNIN needs attention first.'
        }
        $progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $progress } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        $script:context['ProgressPath'] = $progress
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'Fabric' -Context $Context -Step @('Fabric') }
        $outcome.Status | Should -Be 'Pass' -Because 'the optional app never stops the track'
        $script:appWorkspace | Should -Be $workspaceId
        $model = Get-Content -LiteralPath $progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $app = @(foreach ($track in @($model['tracks'])) { foreach ($item in @($track['steps'])) { if ([string]$item['id'] -eq 'Fabric.App') { $item } } })[0]
        $app['state'] | Should -Be 'Skipped'
        $app['status'] | Should -Be 'Manual action required'
        $app['message'] | Should -Match ([regex]::Escape('FABRIC.APP.SIGNIN: The Rayfin CLI isn''t signed in'))
        $app['message'] | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $app['message'] | Should -Not -Match 'tenant settings' -Because 'nothing says the tenant settings are the cause'
    }
    It 'reconnects a golden snapshot''s source host on an existing image-built archost01' {
        $script:context['T2Source'] = 'existing-build'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith { $script:calls.Add('source release'); New-TestResult 'T2.GOLDEN.SOURCE' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore') }
        $outcome.Status | Should -Be 'Pass'
        ($outcome.Results | Where-Object { $_.checkId -eq 'T2.GOLDEN.SOURCE' }).status | Should -Be 'Pass'
        $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' } | Should -BeNullOrEmpty
        $script:calls | Should -Contain 'source release'
    }

    It 'runs T1 from its artifacts to telemetry, with T3 set up from T1' {
        $script:state.BundleSentTo = @('archost01')
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Artifacts', 'Bootstraps', 'T3', 'Activity', 'Monitoring', 'Telemetry') }
        $outcome.Status | Should -Be 'Pass'
        $order = @($script:calls | Where-Object { $_ -notmatch '^state' })
        # One wave for both artifacts; T1's monitoring is merged right after the loader, before the health wait.
        $order[0..3] | Should -Be @('chunks sqlvm01 bootstrap bundle+workload runner 8', 'loader sqlvm01', 'monitoring', 'health sqlvm01')
        $script:calls | Should -Contain 'telemetry T1,T3'
        $outcome.ReadyUtc['T1'] | Should -Not -BeNullOrEmpty
        $outcome.ReadyUtc['T3'] | Should -Not -BeNullOrEmpty
    }

    It 'restarts T1''s monitoring agent when its plugin is still NotRunning after the Monitoring step''s wait (live, 2026-10-27)' {
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith {
            $script:calls.Add('monitoring')
            [pscustomobject]@{ checkId = 'T1.SQLVM.MONITORING'; status = 'Warning'; message = 'NotRunning'; evidence = [ordered]@{ provisioningState = 'Succeeded'; featureFlagEnabled = $true; pluginState = 'NotRunning'; powerState = 'PowerState/running'; pending = $true } }
        }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:calls.Add(('restore {0} {1}' -f $CheckId, $Occasion)); New-TestResult 'DEPLOY.T1.MONITORING' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Monitoring') }
        $outcome.Status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -notmatch '^state' }) | Should -Be @('monitoring', 'restore DEPLOY.T1.MONITORING the deployment')
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T1.MONITORING' }).status | Should -Be 'Pass'

        $script:calls.Clear()
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith {
            $script:calls.Add('monitoring')
            [pscustomobject]@{ checkId = 'T1.SQLVM.MONITORING'; status = 'Warning'; message = 'Updating'; evidence = [ordered]@{ provisioningState = 'Updating'; featureFlagEnabled = $true; pluginState = ''; powerState = 'PowerState/running'; pending = $true } }
        }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Monitoring') }
        $script:calls | Should -Not -Contain 'restore DEPLOY.T1.MONITORING the deployment'
    }

    It 'stops a track at a Fail and doesn''t run its later steps' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoBootstrapLoaderRun -MockWith { New-TestResult 'INFRA.BOOTSTRAP.LOADER_SQLVM01' 'Fail' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Artifacts', 'Bootstraps', 'T3') }
        $outcome.Status | Should -Be 'Fail'
        $outcome.Steps | Should -Be @('Artifacts')
        $script:calls | Should -Not -Contain 'group'
    }

    It 'turns an exception into a Fail for that step' {
        Mock -ModuleName DbHubDemo -CommandName Send-DemoChunkSet -MockWith { throw 'archost01 isn''t running' }
        $script:state.BundleSentTo = @()
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Artifacts') }
        $outcome.Status | Should -Be 'Fail'
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.TRACK.T1' }).message | Should -Match 'isn''t running'
    }

    It 'sets T3 up first, so its telemetry starts while T1 bootstraps, and reports that work once, at the T3 step (ADR 0018)' {
        $script:state.BundleSentTo = @()
        $script:state.RunnerSentTo = @()
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('T3Setup', 'Artifacts', 'Bootstraps', 'T3', 'Activity', 'Monitoring', 'Telemetry') }
        $outcome.Status | Should -Be 'Pass'
        $outcome.Steps | Should -Be @('T3Setup', 'Artifacts', 'Bootstraps', 'T3', 'Activity', 'Monitoring', 'Telemetry')
        $order = @($script:calls | Where-Object { $_ -notmatch '^state' })
        $order | Should -Be @('group', 't3setup', 'chunks sqlvm01 bootstrap bundle+workload runner 8', 'loader sqlvm01', 'monitoring', 'health sqlvm01', 't3workload', 't3checks', 'profile T1', 'profile T3', 'monitoring', 'telemetry T1,T3')
        $order | Should -Not -Contain 'profile T4' -Because 'T4 is off in this configuration'
        @($outcome.Results | Where-Object { $_.checkId -eq 'T3.GROUP' }).Count | Should -Be 1
        @($outcome.Results | Where-Object { $_.checkId -eq 'T3.SQL' }).Count | Should -Be 1
        @($outcome.Results | Where-Object { $_.checkId -eq 'T1.SQLVM.MONITORING' }).Count | Should -Be 1
        $outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T3.EARLYSETUP' } | Should -BeNullOrEmpty
        $outcome.Timing.Keys | Should -Contain 'T3Setup'
    }

    It 'runs T3''s setup again at the T3 step when the early one didn''t pass, and says so' {
        $script:t3Runs = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            $script:calls.Add('t3setup')
            $script:t3Runs++
            if ($script:t3Runs -eq 1) { [pscustomobject]@{ Status = 'Fail'; Result = (New-TestResult 'T3.SQL' 'Fail') } } else { [pscustomobject]@{ Status = 'Pass'; Result = (New-TestResult 'T3.SQL') } }
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('T3Setup', 'Artifacts', 'Bootstraps', 'T3') }
        $outcome.Status | Should -Be 'Pass'
        $outcome.Steps | Should -Be @('T3Setup', 'Artifacts', 'Bootstraps', 'T3')
        @($script:calls | Where-Object { $_ -eq 't3setup' }).Count | Should -Be 2
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T3.EARLYSETUP' }).status | Should -Be 'Warning'
        @($outcome.Results | Where-Object { $_.checkId -eq 'T3.SQL' } | ForEach-Object { $_.status }) | Should -Be @('Pass')
    }

    It 'keeps T1 going when T3''s early setup throws: the T3 step does that work' {
        $script:groupRuns = 0
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith {
            $script:calls.Add('group')
            $script:groupRuns++
            if ($script:groupRuns -eq 1) { throw 'Microsoft Graph is unavailable' }
            New-TestResult 'T3.GROUP'
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('T3Setup', 'Artifacts', 'Bootstraps', 'T3') }
        $outcome.Status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -eq 'group' }).Count | Should -Be 2
        @($script:calls | Where-Object { $_ -eq 't3setup' }).Count | Should -Be 1
        ($outcome.Results | Where-Object { $_.checkId -eq 'T3.GROUP' }).status | Should -Be 'Pass'
    }

    It 'sends archost01''s artifacts beside the Release only when this run has the Artifacts step' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $script:context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore') }
        $outcome.Status | Should -Be 'Pass'
        $script:releaseAlongside | Should -BeFalse
        @($script:calls | Where-Object { $_ -like 'chunks*' }).Count | Should -Be 0
        ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).evidence.artifactsAlongside | Should -BeFalse
    }

    Context 'started before the template (ADR 0018)' {
        BeforeEach {
            $script:handoffDir = Join-Path -Path $TestDrive -ChildPath ('handoff-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:handoffDir | Out-Null
            Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
            $script:templateDone = [pscustomobject]@{ Succeeded = $true; LoaderSettings = @{ sqlVm = @{ role = 'SqlVm'; marker = 'from-handoff' }; host = @{ role = 'ArcHost'; marker = 'host-from-handoff' } }; T3UseFreeLimit = $false; Message = '' }
            $script:templateFailed = [pscustomobject]@{ Succeeded = $false; Message = 'the template deployment failed (DEPLOY.TEMPLATE).' }
        }

        It 'waits for the template, then takes the loader settings, T3''s choice, and the artifacts from the handoff' {
            Write-TestHandoff 'artifacts' ([pscustomobject]@{ Bundle = [pscustomobject]@{ Path = 'bundle.zip'; Sha256 = ('e' * 64); SizeBytes = 10 }; Runner = $null; Error = '' })
            Write-TestHandoff 'infrastructure' $script:templateDone
            $context = @{ NetworkMode = 'private'; T3UseFreeLimit = $true; T2Source = 'golden'; HandoffPath = $script:handoffDir }
            $script:state.BundleSentTo = @()
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoBootstrapLoaderRun -MockWith { $script:loaderMarker = [string]$Settings['marker']; $script:calls.Add('loader ' + $VmName); New-TestResult ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) }
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Artifacts', 'Bootstraps') }
            $outcome.Status | Should -Be 'Pass'
            $script:calls | Should -Contain 'chunks sqlvm01 bootstrap bundle 8'
            ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.ARTIFACTS.RUNNER_SQLVM01' }).status | Should -Be 'Not selected'
            $script:loaderMarker | Should -Be 'from-handoff'
            $context['T3UseFreeLimit'] | Should -BeFalse
            $outcome.FirstStepUtc | Should -Not -BeNullOrEmpty
        }

        It 'fails the Artifacts step with the build''s error' {
            Write-TestHandoff 'artifacts' ([pscustomobject]@{ Bundle = $null; Runner = $null; Error = 'dotnet publish failed' })
            Write-TestHandoff 'infrastructure' $script:templateDone
            $context = @{ NetworkMode = 'private'; T2Source = 'golden'; HandoffPath = $script:handoffDir }
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('Artifacts', 'Bootstraps') }
            $outcome.Status | Should -Be 'Fail'
            ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.TRACK.T1' }).message | Should -Match 'dotnet publish failed'
            @($script:calls | Where-Object { $_ -like 'loader*' }).Count | Should -Be 0
        }

        It 'stops before its first step when the template failed' {
            Write-TestHandoff 'infrastructure' $script:templateFailed
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith { $script:calls.Add('fabric stage') }
            $context = @{ HandoffPath = $script:handoffDir }
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'Fabric' -Context $Context -Step @('Fabric') }
            $outcome.Status | Should -Be 'Stopped'
            @($outcome.Steps).Count | Should -Be 0
            $script:calls | Should -Not -Contain 'fabric stage'
        }

        It 'restores a golden T2 once the template has deployed archost01, and waits for the template only after the Restore' {
            Mock -ModuleName DbHubDemo -CommandName Test-DemoTrackDeploymentDone -MockWith { $script:calls.Add(('deployed? {0}' -f $Name)); $true }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoBootstrapLoaderRun -MockWith { $script:loaderMarker = [string]$Settings['marker']; $script:calls.Add('loader ' + $VmName); New-TestResult ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) }
            # The template finishes while the Release runs.
            $script:afterRelease = { Write-TestHandoff 'infrastructure' $script:templateDone }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
                $script:calls.Add(('release handoff={0}' -f (Test-Path -LiteralPath (Join-Path -Path $script:handoffDir -ChildPath 'infrastructure.xml'))))
                $alongside = Get-Variable -Name 'WhileRunning' -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $alongside) {
                    & $alongside
                }
                & $script:afterRelease
                [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 600; Data = $script:releaseData; WhileRunningError = '' }
            }
            $script:state.BundleSentTo = @()
            $script:state.RunnerSentTo = @()
            $context = $script:context.Clone()
            $context.Remove('LoaderSettings')
            $context['HandoffPath'] = $script:handoffDir
            $context['EarlyT2'] = $true
            $context['EarlyStartUtc'] = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps') }
            $outcome.Status | Should -Be 'Pass'
            $outcome.Early | Should -Be @('Restore')
            $order = @($script:calls | Where-Object { $_ -notmatch '^state' })
            $order | Should -Be @('deployed? archost01', 'agent', 'password', 'release handoff=False', 'chunks archost01 bootstrap bundle+workload runner 8', 'loader archost01')
            $script:loaderMarker | Should -Be 'host-from-handoff'
            ($outcome.Results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).evidence.beforeTemplateFinish | Should -BeTrue
        }

        It 'stops after an early Restore when the template then failed, and records nothing after it' {
            Mock -ModuleName DbHubDemo -CommandName Test-DemoTrackDeploymentDone -MockWith { $true }
            $script:afterRelease = { Write-TestHandoff 'infrastructure' $script:templateFailed }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
                $script:calls.Add('release')
                & $script:afterRelease
                [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 600; Data = $script:releaseData; WhileRunningError = '' }
            }
            $context = @{ NetworkMode = 'private'; T2Source = 'golden'; HandoffPath = $script:handoffDir; EarlyT2 = $true; EarlyStartUtc = [DateTime]::UtcNow.AddMinutes(-2).ToString('o') }
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T2' -Context $Context -Step @('Restore', 'Artifacts', 'Bootstraps') }
            $outcome.Status | Should -Be 'Stopped'
            $outcome.Steps | Should -Be @('Restore')
            $script:calls | Should -Not -Contain 'loader archost01'
        }

        It 'joins T1''s identity to the T3 group while the template deploys, then uses that membership for T3Setup' {
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { $script:calls.Add('identity?'); '99999999-9999-9999-9999-999999999999' }
            Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith {
                $script:calls.Add(('group handoff={0}' -f (Test-Path -LiteralPath (Join-Path -Path $script:handoffDir -ChildPath 'infrastructure.xml'))))
                Write-TestHandoff 'infrastructure' $script:templateDone
                New-TestResult 'T3.GROUP'
            }
            $context = $script:context.Clone()
            $context['HandoffPath'] = $script:handoffDir
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; Context = $context } { Invoke-DemoDeploymentTrack -Config $Config -Track 'T1' -Context $Context -Step @('T3Setup') }
            $outcome.Status | Should -Be 'Pass'
            $outcome.Early | Should -Be @('T3 group')
            @($script:calls | Where-Object { $_ -notmatch '^state' }) | Should -Be @('identity?', 'group handoff=False', 't3setup')
        }
    }
}

Describe 'Invoke-DemoParallelDeployment' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:source = 'golden'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:calls.Add('state ' + (@($Value.Keys) -join ',')) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith { $script:calls.Add('preflight'); New-TestResult 'PREFLIGHT.P1.SUBSCRIPTION' }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT2Source -MockWith {
            [pscustomobject]@{ Source = $script:source; SnapshotId = $(if ($script:source -eq 'golden') { '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap-x' } else { '' }); SnapshotName = 'snap-x'; AttachExisting = $false; Result = (New-TestResult 'PREFLIGHT.T2.SOURCE') }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3FreeOfferStatus -MockWith { [pscustomobject]@{ UseFreeLimit = $true } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -MockWith {
            $snapshotId = Get-Variable -Name 'T2OsDiskSourceId' -ValueOnly -ErrorAction SilentlyContinue
            $script:calls.Add(('template disk={0}' -f $(if ($snapshotId) { 'golden' } else { 'image' })))
            [pscustomobject]@{ Succeeded = $true; Results = @(New-TestResult 'DEPLOY.TEMPLATE'); Outputs = @{ loaderSettings = @{ sqlVm = @{ role = 'SqlVm' }; host = @{ role = 'ArcHost' } } }; Changes = @(); T3UseFreeLimit = $true }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoKeyVaultSetting -MockWith { [pscustomobject]@{ Enabled = $false } }
        Mock -ModuleName DbHubDemo -CommandName New-DemoBootstrapBundle -MockWith { [pscustomobject]@{ Path = 'bundle.zip'; Sha256 = ('c' * 64); SizeBytes = 10 } }
        Mock -ModuleName DbHubDemo -CommandName Publish-DemoWorkloadRunner -MockWith { [pscustomobject]@{ Path = 'runner.zip'; Sha256 = ('d' * 64); SizeBytes = 20 } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -MockWith {
            $script:calls.Add(('track {0}: {1}' -f $Track, ($Step -join ',')))
            $ready = switch ($Track) { 'T1' { [ordered]@{ T1 = '2026-10-22T15:00:00Z'; T3 = '2026-10-22T15:01:00Z' } } 'T2' { [ordered]@{ T2 = '2026-10-22T15:10:00Z' } } default { [ordered]@{} } }
            $trackResults = switch ($Track) {
                'T1' { @((New-TestResult 'T3.PROPERTY'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3')) }
                'T2' { @((New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'T2.ARC.MONITORING'), (New-TestResult 'TELEMETRY.T2')) }
                default { @(New-TestResult 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT') }
            }
            [pscustomobject]@{ Track = $Track; Status = 'Pass'; Steps = @($Step); Timing = [ordered]@{}; ReadyUtc = $ready; StartedUtc = ''; EndedUtc = ''; Results = $trackResults }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith { $script:calls.Add('estate ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('HUB.ESTATE.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith { [pscustomobject]@{ Result = (New-TestResult 'WORKLOAD.T1.STATUS') } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith {
            $script:calls.Add(('fabric check={0}' -f [bool]$CheckDashboardData))
            $check = Get-Variable -Name 'T3PerformanceMonitoringCheck' -ValueOnly -ErrorAction SilentlyContinue
            $script:calls.Add(('fabric property={0}' -f $(if ($null -ne $check) { [string](& $check @{}).status } else { 'none' })))
            New-TestResult 'HUB.CHECKLIST'
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith { $script:calls.Add('t3 status from T1'); [pscustomobject]@{ Status = 'Pass'; Message = 'ok'; Rows = @([pscustomobject]@{ performance_monitoring = 'true' }) } }
        $script:inventoryStatus = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { $script:calls.Add(('inventory wait={0} listed={1}' -f $WaitMinutes, $ListedStatus)); New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' $script:inventoryStatus }
        # Phase 28's DONE gate checks the required Fabric items by name (brief item 16).
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricRequiredItem -MockWith { $script:calls.Add('fabric items'); New-TestResult 'FABRIC.ITEMS.REQUIRED' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:calls.Add('gate telemetry ' + ($Target -join ',')); foreach ($t in $Target) { New-TestResult ('TELEMETRY.{0}' -f $t) } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { $script:calls.Add('gate arc ' + ($Check -join ',')); foreach ($c in $Check) { New-TestResult ('T2.ARC.{0}' -f $c.ToUpperInvariant()) } }
    }

    It 'restores T2 from the golden snapshot, runs the three tracks, validates, and stops the clock' {
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        $script:calls | Should -Contain 'template disk=golden'
        $script:calls | Should -Contain 'track T1: T3Setup,Artifacts,Bootstraps,T3,T4,Activity,Monitoring,Telemetry'
        $script:calls | Should -Contain 'track T2: Restore,Artifacts,Bootstraps,T2,Telemetry'
        $script:calls | Should -Contain 'track Fabric: Fabric'
        $script:calls | Should -Contain 'estate T1,T3,T2'
        $script:calls | Should -Contain 'fabric check=True'
        # T1's track read T3's extended property, so the gate reuses it instead of asking for a manual check.
        $script:calls | Should -Contain 'fabric property=Pass'
        $script:calls | Should -Not -Contain 't3 status from T1'
        $script:calls | Should -Contain 'inventory wait=10 listed=Fail'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.clockStopped | Should -BeTrue
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -match '^state .*Stage' }).Count | Should -BeGreaterThan 0
    }

    It 'reads T3''s extended property from T1 for the gate when the run has no T3.PROPERTY (a resumed run)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -MockWith {
            [pscustomobject]@{ Track = $Track; Status = 'Pass'; Steps = @($Step); Timing = [ordered]@{}; ReadyUtc = [ordered]@{}; StartedUtc = ''; EndedUtc = ''; Results = @() }
        }
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess } | Out-Null
        $script:calls | Should -Contain 't3 status from T1'
        $script:calls | Should -Contain 'fabric property=Pass'
    }

    It 'fails, and leaves the clock running, when T1''s inventory still lists the associated services (live, 2026-10-22)' {
        $script:inventoryStatus = 'Fail'
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        ($results | Where-Object { $_.checkId -eq 'T1.SQLVM.ASSOCIATEDSERVICES' }).status | Should -Be 'Fail'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.clockStopped | Should -BeFalse
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Fail'
    }

    It 'deploys the image when the T2 source is build' {
        $script:source = 'build'
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess } | Out-Null
        $script:calls | Should -Contain 'template disk=image'
    }

    It 'stops before any change when preflight fails' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith { New-TestResult 'PREFLIGHT.P3.QUOTA' 'Fail' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.PREFLIGHT' }).status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -Times 0 -Exactly
    }

    It 'stops after the infrastructure with -StopAfter Infrastructure' {
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -StopAfter 'Infrastructure' -InProcess })
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -Times 0 -Exactly
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).message | Should -Match 'Infrastructure'
    }

    It 'leaves the clock running when T2 builds in the background' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -MockWith {
            $status = if ($Track -eq 'T2') { 'Background' } else { 'Pass' }
            $trackResults = if ($Track -eq 'T2') { @(New-DemoResult -CheckId 'DEPLOY.T2.BACKGROUND' -Area 'infra' -Target 'T2' -Status 'Manual action required' -Message 'building' -Remediation 'deploy.ps1 -FromStage T2') } elseif ($Track -eq 'T1') { @((New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3')) } else { @() }
            [pscustomobject]@{ Track = $Track; Status = $status; Steps = @(); Timing = [ordered]@{}; ReadyUtc = [ordered]@{}; StartedUtc = ''; EndedUtc = ''; Results = $trackResults }
        }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TRACK.T2' }).status | Should -Be 'Manual action required'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Manual action required'
        $script:calls | Should -Contain 'estate T1,T3'
        # DONE's read-only checks wait until every track finished (Phase 28).
        $script:calls | Should -Not -Contain 'fabric items'
    }

    It 'continues an unfinished deployment on its own with -AutoResume, and starts over once the last one finished (Phase 28)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $state = New-TestState; $state.Stage = 'Infrastructure'; $state.TrackT1 = 'Bootstraps'; $state }
        # A run that skips the template reads the loader settings from the last deployment's outputs.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { @{ sqlVm = @{ role = 'SqlVm' }; host = @{ role = 'ArcHost' } } }
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess -AutoResume } | Out-Null
        $script:calls | Should -Not -Contain 'preflight'
        $script:calls | Should -Contain 'track T1: T3,T4,Activity,Monitoring,Telemetry'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'continues it, as deploy\.ps1 -Resume does' }

        $script:calls.Clear()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $state = New-TestState; $state.Stage = 'Validation'; $state }
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -InProcess -AutoResume } | Out-Null
        $script:calls | Should -Contain 'preflight'
    }

    It 'starts T4''s Burstable fallback where preflight says, and DONE and the clock follow what T4 got (Phase 28)' {
        $withT4 = New-TestConfig -WithT4
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { New-TestResult 'DEPLOY.T4.START' 'Not selected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith {
            $script:calls.Add('preflight')
            New-TestResult 'PREFLIGHT.P1.SUBSCRIPTION'
            New-DemoResult -CheckId 'PREFLIGHT.T4.CAPABILITY' -Area 'preflight' -Target 'T4' -Status 'Warning' -Message 'westus3 lists neither Burstable size.' -Evidence @{ startSku = 'None' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -MockWith {
            $script:calls.Add(('template start={0}' -f (Get-Variable -Name 'T4StartSku' -ValueOnly -ErrorAction SilentlyContinue)))
            [pscustomobject]@{ Succeeded = $true; Results = @(New-TestResult 'DEPLOY.TEMPLATE'); Outputs = @{ loaderSettings = @{ sqlVm = @{ role = 'SqlVm' }; host = @{ role = 'ArcHost' } } }; Changes = @(); T3UseFreeLimit = $true; T4Enabled = $false; T4SkuName = '' }
        }
        $script:t4InTracks = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -MockWith {
            $script:t4InTracks.Add(('{0}:{1}' -f $Track, [bool]$Config['t4Enabled']))
            $trackResults = switch ($Track) {
                'T1' { @((New-TestResult 'T3.PROPERTY'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3')) }
                'T2' { @((New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'T2.ARC.MONITORING'), (New-TestResult 'TELEMETRY.T2')) }
                default { @() }
            }
            [pscustomobject]@{ Track = $Track; Status = 'Pass'; Steps = @($Step); Timing = [ordered]@{}; ReadyUtc = [ordered]@{}; StartedUtc = ''; EndedUtc = ''; Results = $trackResults }
        }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $withT4 } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        $script:calls | Should -Contain 'template start=None'
        $script:t4InTracks | Should -Contain 'T1:False'
        $script:calls | Should -Contain 'estate T1,T3,T2'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.clockStopped | Should -BeTrue -Because 'T4 isn''t deployed, so DONE doesn''t need its estate or metrics'
    }

    It 'stops the clock only when T4''s estate and metrics passed too, when T4 is on (ADR 0018 as amended)' {
        $withT4 = New-TestConfig -WithT4
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { New-TestResult 'DEPLOY.T4.START' 'Not selected' }
        $script:t4Metrics = 'Warning'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -MockWith {
            $trackResults = switch ($Track) {
                'T1' { @((New-TestResult 'T3.PROPERTY'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3')) }
                'T2' { @((New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'T2.ARC.MONITORING'), (New-TestResult 'TELEMETRY.T2')) }
                'T4' { @(New-TestResult 'METRICS.T4' $script:t4Metrics) }
                default { @() }
            }
            [pscustomobject]@{ Track = $Track; Status = 'Pass'; Steps = @($Step); Timing = [ordered]@{}; ReadyUtc = [ordered]@{}; StartedUtc = ''; EndedUtc = ''; Results = $trackResults }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ State = 'Ready'; Names = [pscustomobject]@{ ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT4MetricFlow -MockWith { $script:calls.Add('gate metrics'); New-TestResult 'METRICS.T4' $script:t4Metrics }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $withT4 } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        $script:calls | Should -Contain 'estate T1,T3,T2,T4'
        $script:calls | Should -Contain 'gate metrics'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.clockStopped | Should -BeFalse
        $script:t4Metrics = 'Pass'
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $withT4 } { Invoke-DemoParallelDeployment -Config $Config -InProcess })
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.clockStopped | Should -BeTrue
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).message | Should -Match 'T4''s metrics'
    }

    Context 'with track processes (ADR 0018)' {
        BeforeEach {
            $script:received = @{}
            $script:handoffSeen = $null
            $script:handoffDir = ''
            $script:trackStatus = 'Pass'
            Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Start-DemoArtifactBuildJob -MockWith {
                $script:calls.Add('build')
                $value = [pscustomobject]@{ Bundle = [pscustomobject]@{ Path = 'bundle.zip'; Sha256 = ('c' * 64); SizeBytes = 10 }; Runner = $null; Error = '' }
                [System.IO.File]::WriteAllText((Join-Path -Path $HandoffPath -ChildPath 'artifacts.xml'), [System.Management.Automation.PSSerializer]::Serialize($value, 5))
                Start-ThreadJob -Name 'dbhub-build-artifacts' -ScriptBlock { }
            }
            Mock -ModuleName DbHubDemo -CommandName Start-DemoDeploymentTrackJob -MockWith {
                $script:calls.Add(('job {0} delay={1} earlyT2={2} bundle={3}' -f $Track, $DelaySeconds, [bool]$Context['EarlyT2'], $Context.Contains('Bundle')))
                $script:handoffDir = [string]$Context['HandoffPath']
                Start-ThreadJob -Name ('dbhub-track-{0}' -f $Track) -ScriptBlock { }
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -MockWith {
                $script:calls.Add(('template handoff={0}' -f (Test-Path -LiteralPath (Join-Path -Path $script:handoffDir -ChildPath 'infrastructure.xml'))))
                [pscustomobject]@{ Succeeded = $script:templateSucceeds; Results = @(New-TestResult 'DEPLOY.TEMPLATE' $(if ($script:templateSucceeds) { 'Pass' } else { 'Fail' })); Outputs = @{ loaderSettings = @{ sqlVm = @{ role = 'SqlVm' }; host = @{ role = 'ArcHost' } } }; Changes = @(); T3UseFreeLimit = $true }
            }
            $script:templateSucceeds = $true
            Mock -ModuleName DbHubDemo -CommandName Receive-DemoDeploymentTrackOutput -MockWith {
                $track = $Job.Name -replace '^dbhub-track-', ''
                if ($script:received.ContainsKey($track)) {
                    return [pscustomobject]@{ Results = @(); Summary = $null }
                }
                $script:received[$track] = $true
                $file = Join-Path -Path $script:handoffDir -ChildPath 'infrastructure.xml'
                if ($null -eq $script:handoffSeen -and (Test-Path -LiteralPath $file)) {
                    $script:handoffSeen = [System.Management.Automation.PSSerializer]::Deserialize([System.IO.File]::ReadAllText($file))
                }
                $trackResults = switch ($track) {
                    'T1' { @((New-TestResult 'T3.PROPERTY'), (New-TestResult 'TELEMETRY.T1'), (New-TestResult 'TELEMETRY.T3')) }
                    'T2' { @((New-TestResult 'DEPLOY.T2.RESTORE'), (New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'T2.ARC.MONITORING'), (New-TestResult 'TELEMETRY.T2')) }
                    default { @(New-TestResult 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT') }
                }
                $status = if ($track -eq 'T2' -or $script:trackStatus -eq 'Pass') { $script:trackStatus } else { 'Stopped' }
                [pscustomobject]@{ Results = $trackResults; Summary = [pscustomobject]@{ Track = $track; Status = $status; Steps = @(); Timing = [ordered]@{ Restore = 600 }; ReadyUtc = [ordered]@{}; StartedUtc = ''; FirstStepUtc = ''; EndedUtc = ''; Early = @() } }
            }
        }

        It 'builds the artifacts and starts the track processes before the template, then hands them its result' {
            $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config })
            $order = @($script:calls | Where-Object { $_ -match '^(build|preflight|job|template)' })
            $order | Should -Be @('build', 'preflight', 'job T1 delay=0 earlyT2=True bundle=False', 'job T2 delay=5 earlyT2=True bundle=False', 'job Fabric delay=10 earlyT2=True bundle=False', 'template handoff=False')
            $script:handoffSeen.Succeeded | Should -BeTrue
            $script:handoffSeen.LoaderSettings['host']['role'] | Should -Be 'ArcHost'
            $script:handoffSeen.T3UseFreeLimit | Should -BeTrue
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.TRACK.T2' }).status | Should -Be 'Pass'
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.ARTIFACTS.BUILD' }) | Should -BeNullOrEmpty
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.TIMING' }).evidence.tracks['T2'].Contains('firstStepUtc') | Should -BeTrue
            # The run's private handoff directory is gone afterwards.
            Test-Path -LiteralPath $script:handoffDir | Should -BeFalse
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDeploymentTrack -Times 0 -Exactly
        }

        It 'hands a failed template to the track processes and reports what they finished before it' {
            $script:templateSucceeds = $false
            $script:trackStatus = 'Stopped'
            $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config })
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.INFRASTRUCTURE' }).status | Should -Be 'Fail'
            $script:handoffSeen.Succeeded | Should -BeFalse
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.T2.RESTORE' }).status | Should -Be 'Pass'
            $results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' } | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:handoffDir | Should -BeFalse
        }

        It 'starts no track process and builds nothing when preflight fails' {
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith { New-TestResult 'PREFLIGHT.P3.QUOTA' 'Fail' }
            $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config })
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.PREFLIGHT' }).status | Should -Be 'Fail'
            Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoDeploymentTrackJob -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -Times 0 -Exactly
        }

        It 'doesn''t start an early T2 restore when the T2 source isn''t a new golden host' {
            $script:source = 'build'
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config } | Out-Null
            $script:calls | Should -Contain 'job T2 delay=5 earlyT2=False bundle=False'
        }

        It 'stops the track processes within seconds when deploy.ps1 is stopped, after telling them to skip their slow cleanups (Phase 28 live finding)' {
            # Live, Ctrl+C at the guided stop seemed to do nothing: this finally block waited for the T2 track's cleanup.
            $script:t2Job = $null
            Mock -ModuleName DbHubDemo -CommandName Start-DemoDeploymentTrackJob -MockWith {
                $script:handoffDir = [string]$Context['HandoffPath']
                if ($Track -ne 'T2') {
                    return (Start-ThreadJob -Name ('dbhub-track-{0}' -f $Track) -ScriptBlock { })
                }
                # The T2 track at the guided stop: its cleanup takes minutes unless deploy.ps1 left the cancel marker.
                $guidedStopTrack = {
                    param([string] $Marker)
                    try {
                        Start-Sleep -Seconds 120
                    }
                    finally {
                        if (-not (Test-Path -LiteralPath $Marker)) {
                            [System.Threading.Thread]::Sleep(30000)
                        }
                    }
                }
                $script:t2Job = Start-ThreadJob -Name 'dbhub-track-T2' -ArgumentList (Join-Path -Path $script:handoffDir -ChildPath 'cancel.xml') -ScriptBlock $guidedStopTrack
                return $script:t2Job
            }
            # Ctrl+C, as the wait for the tracks notices it.
            Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                { InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config } } | Should -Throw -ExceptionType ([System.OperationCanceledException])
                $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
                $script:t2Job.State | Should -Be 'Stopped' -Because 'the cancel marker came first, so it skipped its cleanup and ended by itself'
                Test-Path -LiteralPath $script:handoffDir | Should -BeFalse
            }
            finally {
                if ($null -ne $script:t2Job) {
                    $null = Wait-Job -Job $script:t2Job -Timeout 40
                    Remove-Job -Job $script:t2Job -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'runs the policy inventory alongside the deployment only with networkMode private, and its results replace preflight''s placeholders (Phase 28; review finding 7)' {
            $private = New-TestConfig
            $private['networkMode'] = 'private'
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith {
                $script:calls.Add(('preflight defer={0}' -f [bool]$DeferPolicyInventory))
                New-TestResult 'PREFLIGHT.P1.SUBSCRIPTION'
                New-DemoResult -CheckId 'PREFLIGHT.POLICY.INVENTORY' -Area 'preflight' -Target 'subscription' -Status 'Not selected' -Message 'Deferred.' -Evidence @{ deferred = $true }
                New-DemoResult -CheckId 'PREFLIGHT.POLICY.SQLPUBLIC' -Area 'preflight' -Target 'subscription' -Status 'Not selected' -Message 'Deferred.' -Evidence @{ effectiveNetworkMode = 'private'; deferred = $true }
            }
            Mock -ModuleName DbHubDemo -CommandName Start-DemoPolicyInventoryJob -MockWith { $script:calls.Add('policy job'); Start-ThreadJob -Name 'dbhub-policy-inventory' -ScriptBlock { } }
            Mock -ModuleName DbHubDemo -CommandName Receive-DemoDeploymentTrackOutput -ParameterFilter { $Job.Name -eq 'dbhub-policy-inventory' } -MockWith {
                [pscustomobject]@{ Results = @((New-TestResult 'PREFLIGHT.POLICY.INVENTORY'), (New-TestResult 'PREFLIGHT.POLICY.SQLPUBLIC')); Summary = $null }
            }
            $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $private } { Invoke-DemoParallelDeployment -Config $Config })
            $script:calls | Should -Contain 'preflight defer=True'
            $script:calls | Should -Contain 'policy job'
            @($results | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.INVENTORY' }).status | Should -Be @('Pass')
            @($results | Where-Object { $_.checkId -eq 'PREFLIGHT.POLICY.SQLPUBLIC' }).status | Should -Be @('Pass')

            # networkMode public keeps the inventory in preflight: a Modify policy that turns SQL public access off, which
            # the what-if doesn't catch, must stop the run before anything is created. auto needs it too.
            foreach ($mode in 'public', 'auto') {
                $script:calls.Clear()
                $script:received = @{}
                $other = New-TestConfig
                $other['networkMode'] = $mode
                InModuleScope DbHubDemo -Parameters @{ Config = $other } { Invoke-DemoParallelDeployment -Config $Config } | Out-Null
                $script:calls | Should -Contain 'preflight defer=False' -Because $mode
                $script:calls | Should -Not -Contain 'policy job'
            }
        }

        It 'lets the T2 track process prompt the person itself when there''s no progress model (-NoStatusPage; review finding 2)' {
            $script:promptInParent = @{}
            Mock -ModuleName DbHubDemo -CommandName Start-DemoDeploymentTrackJob -MockWith {
                $script:promptInParent[$Track] = [bool]$Context['PromptInParent']
                $script:handoffDir = [string]$Context['HandoffPath']
                Start-ThreadJob -Name ('dbhub-track-{0}' -f $Track) -ScriptBlock { }
            }
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoParallelDeployment -Config $Config -WaitForT2 } | Out-Null
            $script:promptInParent['T2'] | Should -BeFalse -Because 'only a progress model tells this process that the guided stop is ready'

            $script:received = @{}
            $progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
            InModuleScope DbHubDemo -Parameters @{ Path = $progress } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog) -GuidedStop 'Pending') -Confirm:$false }
            InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $progress } { Invoke-DemoParallelDeployment -Config $Config -WaitForT2 -ProgressPath $Path } | Out-Null
            $script:promptInParent['T2'] | Should -BeTrue
        }

        It 'prompts the person in this process when the T2 track process reports the guided stop ready (Phase 28)' {
            $progress = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
            InModuleScope DbHubDemo -Parameters @{ Path = $progress } {
                $model = New-DemoProgressModel -Catalog (Get-DemoProgressCatalog) -GuidedStop 'Pending'
                $model['guidedStop']['state'] = 'Ready'
                $model['guidedStop']['url'] = 'https://portal.azure.com/#@contoso.example/resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01'
                $model['guidedStop']['deadlineAt'] = Get-DemoUnixTime -Value ([DateTime]::UtcNow.AddMinutes(45))
                Initialize-DemoProgress -Path $Path -Model $model -Confirm:$false
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGuidedStopCredential -MockWith { $script:calls.Add('credential'); [pscustomobject]@{ Mode = 'portalReset'; UserName = 'demoadmin'; Text = ''; Results = @(New-TestResult 'DEPLOY.T2.HOSTPASSWORD') } }
            Mock -ModuleName DbHubDemo -CommandName Show-DemoGuidedStopPrompt -MockWith { $script:calls.Add(('prompt {0}' -f $SignInWay)) }
            Mock -ModuleName DbHubDemo -CommandName Show-DemoGuidedStopReminder -MockWith { $script:calls.Add('reminder') }
            $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $progress } { Invoke-DemoParallelDeployment -Config $Config -ProgressPath $Path })
            @($script:calls | Where-Object { $_ -eq 'credential' }).Count | Should -Be 1
            $script:calls | Should -Contain 'prompt portalReset'
            ($results | Where-Object { $_.checkId -eq 'DEPLOY.T2.HOSTPASSWORD' }).status | Should -Be 'Pass'
            $model = Get-Content -LiteralPath $progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['guidedStop']['credential'] | Should -Be 'portalReset'
            $model['guidedStop']['hostUser'] | Should -Be 'demoadmin'
        }
    }
}

Describe 'Track handoff helpers' {
    BeforeEach {
        $config = New-TestConfig
        $script:handoffDir = Join-Path -Path $TestDrive -ChildPath ('handoff-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:handoffDir | Out-Null
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
    }

    It 'round-trips a value through the handoff directory, nested settings included, and leaves no temporary file' {
        $value = [pscustomobject]@{ Succeeded = $true; LoaderSettings = @{ sqlVm = @{ role = 'SqlVm'; t3 = @{ serverName = 'azuresql01-abc123' } } }; T3UseFreeLimit = $false; Message = '' }
        InModuleScope DbHubDemo -Parameters @{ Path = $script:handoffDir; Value = $value } { Write-DemoTrackHandoff -Path $Path -Name 'infrastructure' -Value $Value -Confirm:$false }
        $read = InModuleScope DbHubDemo -Parameters @{ Path = $script:handoffDir } { Read-DemoTrackHandoff -Path $Path -Name 'infrastructure' }
        $read.Succeeded | Should -BeTrue
        $read.T3UseFreeLimit | Should -BeFalse
        $read.LoaderSettings['sqlVm']['t3']['serverName'] | Should -Be 'azuresql01-abc123'
        @(Get-ChildItem -LiteralPath $script:handoffDir -Name) | Should -Be @('infrastructure.xml')
    }

    It 'returns nothing for a value that isn''t there yet, after its timeout' {
        InModuleScope DbHubDemo -Parameters @{ Path = $script:handoffDir } { Read-DemoTrackHandoff -Path $Path -Name 'artifacts' -TimeoutSeconds 0 } | Should -BeNullOrEmpty
    }

    It 'waits for the probe or the handoff, whichever comes first' {
        $script:probes = 0
        $probe = { $script:probes++; $script:probes -ge 2 }
        $ready = InModuleScope DbHubDemo -Parameters @{ Path = $script:handoffDir; Probe = $probe } { Wait-DemoTrackEarlyStart -HandoffPath $Path -Probe $Probe -ProbeSeconds 1 -TimeoutMinutes 1 }
        $ready | Should -Be 'Ready'
        $script:probes | Should -Be 2
        [System.IO.File]::WriteAllText((Join-Path -Path $script:handoffDir -ChildPath 'infrastructure.xml'), [System.Management.Automation.PSSerializer]::Serialize([pscustomobject]@{ Succeeded = $true }, 2))
        InModuleScope DbHubDemo -Parameters @{ Path = $script:handoffDir } { Wait-DemoTrackEarlyStart -HandoffPath $Path -Probe { throw 'the handoff comes first' } } | Should -Be 'Handoff'
    }

    It 'takes a VM''s nested deployment as done only when it succeeded in this run' {
        $script:deployment = $null
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { $script:deployArguments = $ArgumentList; $script:deployment }
        $notBefore = [DateTime]::UtcNow.AddMinutes(-2)
        $check = { InModuleScope DbHubDemo -Parameters @{ Config = $config; NotBefore = $notBefore } { Test-DemoTrackDeploymentDone -Config $Config -Name 'archost01' -NotBeforeUtc $NotBefore } }
        & $check | Should -BeFalse
        $script:deployment = [pscustomobject]@{ state = 'Running'; timestamp = [DateTime]::UtcNow.ToString('o') }
        & $check | Should -BeFalse
        $script:deployment = [pscustomobject]@{ state = 'Succeeded'; timestamp = [DateTime]::UtcNow.AddHours(-20).ToString('o') }
        & $check | Should -BeFalse
        $script:deployment = [pscustomobject]@{ state = 'Succeeded'; timestamp = [DateTime]::UtcNow.ToString('o') }
        & $check | Should -BeTrue
        $script:deployArguments[0..3] | Should -Be @('deployment', 'group', 'show', '--resource-group')
        $script:deployArguments | Should -Contain 'archost01'
    }
}
