BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $script:pin = @{ version = '10.0.13'; fileName = 'dotnet-runtime-10.0.13-win-x64.zip'; url = 'https://builds.dotnet.microsoft.com/x.zip'; sha512 = ('ef' * 64) }
    $script:sha = 'ab' * 32

    function New-WorkloadSetting([string] $ActivityProfile = 'baseline', [switch] $WithT3, [switch] $WithT4) {
        $settings = [ordered]@{
            role      = 'SqlVm'
            seedScale = 1
            workload  = [ordered]@{ runnerSha256 = $script:sha; runnerChunkCount = 7; activityProfile = $ActivityProfile; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' }
        }
        if ($WithT3) {
            $settings['t3'] = [ordered]@{ serverName = 'azuresql01-abc123'; serverFqdn = 'azuresql01-abc123.database.windows.net'; databaseName = 'ContosoCare' }
        }
        if ($WithT4) {
            $settings['t4'] = [ordered]@{ serverName = 'pgflex01-abc123'; serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; databaseName = 'contosocare'; runnerRole = 'contosocare_runner' }
        }
        return $settings
    }

    # Hyper-V's cmdlets exist only on a Hyper-V host; elsewhere these stand-ins let Pester mock them.
    $stubs = @{
        'Get-VM'                   = 'param([string] $Name)'
        'Stop-VM'                  = 'param([string] $Name, [switch] $Force, [switch] $AsJob)'
        'Set-VM'                   = 'param([string] $Name, [string] $AutomaticStartAction, [int] $AutomaticStartDelay, [string] $AutomaticStopAction)'
        'Start-VM'                 = 'param([string] $Name)'
        'Get-VMNetworkAdapter'     = 'param([string] $VMName)'
        'Connect-VMNetworkAdapter' = 'param([object] $VMNetworkAdapter, [string] $SwitchName)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            New-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stubs[$name])) | Out-Null
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'T1 WorkloadRunner step' {
    BeforeAll {
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-SqlVmBootstrap.ps1')

        function New-TestT1Context([System.Collections.IDictionary] $Settings) {
            $root = Join-Path -Path $TestDrive -ChildPath ('t1-' + [guid]::NewGuid().ToString('N'))
            Initialize-DemoVmContext -Root $root -Role 'SqlVm' -BundleRoot $repoRoot | Out-Null
            Get-DemoSqlVmContext -BundleRoot $repoRoot -Settings $Settings
        }

        function Set-T1WorkloadMock {
            $script:runnerInstalled = $false
            $script:setupCalls = [System.Collections.Generic.List[string]]::new()
            $script:t1SetupStatus = 'Pass'
            Mock -CommandName Get-DemoVmDotNetPin -MockWith { $script:pin }
            Mock -CommandName Test-DemoVmRunnerPackage -MockWith { $script:runnerInstalled }
            Mock -CommandName Test-DemoVmRunnerChunk -MockWith { $true }
            Mock -CommandName Get-DemoVmRunnerZip -MockWith { Join-Path -Path $TestDrive -ChildPath 'runner.zip' }
            Mock -CommandName Expand-DemoVmVerifiedZip -MockWith { $script:runnerInstalled = $true }
            Mock -CommandName Install-DemoVmDotNetRuntime -MockWith { 'runtime.zip' }
            Mock -CommandName Test-DemoVmDotNetRuntime -MockWith { $true }
            Mock -CommandName Stop-DemoVmWorkload -MockWith { }
            Mock -CommandName Start-DemoVmWorkload -MockWith { }
            Mock -CommandName Register-DemoVmWorkloadTask -MockWith { $script:taskRegistered = $true }
            Mock -CommandName Test-DemoVmWorkloadTask -MockWith { $script:taskRegistered }
            Mock -CommandName Remove-DemoVmOldRunner -MockWith { }
            Mock -CommandName Test-DemoVmNameResolve -MockWith { $script:t3Resolves }
            Mock -CommandName Invoke-DemoVmRunnerSetup -MockWith {
                $script:setupCalls.Add(('{0}:{1}{2}' -f $Target, $Server, $(if ($User) { ':' + $User } else { '' })))
                $status = if ($Target -eq 'T1') { $script:t1SetupStatus } else { 'Pass' }
                [pscustomobject]@{ Status = $status; ExitCode = 0; Message = ('setup --target {0}: {1}' -f $Target, $status); Records = @() }
            }
            $script:taskRegistered = $false
            $script:t3Resolves = $true
        }
    }

    It 'is Not selected, as before, when no runner came with the deployment' {
        $context = New-TestT1Context -Settings ([ordered]@{ role = 'SqlVm'; seedScale = 1 })
        $step = @(Get-DemoSqlVmStepPlan -Context $context) | Where-Object { $_.Name -eq 'WorkloadRunner' }
        (& $step.When $step) | Should -BeFalse
        $step.NotSelectedMessage | Should -Match 'Send-DemoWorkloadRunner'
    }

    It 'waits, without failing, while the runner''s chunks haven''t all arrived' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting)
        Set-T1WorkloadMock
        Mock -CommandName Test-DemoVmRunnerChunk -MockWith { $false }
        $result = Install-DemoSqlVmWorkload -Context $context
        $result.Outcome | Should -Be 'Waiting'
        $result.WaitState | Should -Be 'WaitingForInput'
        $result.Message | Should -Match 'Send-DemoWorkloadRunner'
        Should -Invoke -CommandName Invoke-DemoVmRunnerSetup -Times 0
    }

    It 'installs the runner and runtime, sets up T1 only, and starts DbHubDemo-Workload' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT3)
        Set-T1WorkloadMock
        $result = Install-DemoSqlVmWorkload -Context $context

        $result.Outcome | Should -Be 'Done'
        @($result.WarningMessage).Count | Should -Be 0
        $script:setupCalls | Should -Be @('T1:')
        Should -Invoke -CommandName Expand-DemoVmVerifiedZip -Times 1 -Exactly -ParameterFilter { $ExpectedSha256 -eq $script:sha }
        Should -Invoke -CommandName Register-DemoVmWorkloadTask -Times 1 -Exactly
        Should -Invoke -CommandName Start-DemoVmWorkload -Times 1 -Exactly
        $paths = Get-DemoVmWorkloadPath -Root $context.Root -RunnerSha256 $script:sha
        (Get-FileHash -LiteralPath $paths.Wrapper).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Start-DemoWorkload.ps1')).Hash
        $record = Read-DemoVmJsonFile -Path $paths.InstallRecord
        $record['primaryTarget'] | Should -Be 'T1'
        $record['runnerSha256'] | Should -Be $script:sha
        $record['activityProfile'] | Should -Be 'baseline'
        $record['t3']['serverFqdn'] | Should -Be 'azuresql01-abc123.database.windows.net'
        $record['setup']['T1']['status'] | Should -Be 'Pass'
        $record['setup'].Contains('T3') | Should -BeFalse

        # The step's check now passes, and fails again when the configured profile changes.
        Test-DemoSqlVmWorkload -Context $context | Should -BeTrue
        $changed = New-TestT1Context -Settings (New-WorkloadSetting -ActivityProfile 'business-day' -WithT3)
        $changed.Root = $context.Root
        Test-DemoSqlVmWorkload -Context $changed | Should -BeFalse
    }

    It 'sets up T3 too once Enable-DemoT3Workload has recorded T1''s access' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT3)
        Set-T1WorkloadMock
        Write-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).T3Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = 'azuresql01-abc123.database.windows.net' })
        Install-DemoSqlVmWorkload -Context $context | Out-Null
        $script:setupCalls | Should -Be @('T1:', 'T3:azuresql01-abc123.database.windows.net')
        $record = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).InstallRecord
        $record['setup']['T3']['status'] | Should -Be 'Pass'
    }

    It 'warns, without failing, when T3 was removed and its name no longer resolves' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT3)
        Set-T1WorkloadMock
        $script:t3Resolves = $false
        Write-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).T3Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = 'azuresql01-abc123.database.windows.net' })
        $result = Install-DemoSqlVmWorkload -Context $context
        $result.Outcome | Should -Be 'Done'
        ($result.WarningMessage -join ' ') | Should -Match 'RemoveT3'
        $script:setupCalls | Should -Be @('T1:')
    }

    It 'counts a failed T1 setup as a failed attempt' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting)
        Set-T1WorkloadMock
        $script:t1SetupStatus = 'Fail'
        { Install-DemoSqlVmWorkload -Context $context } | Should -Throw '*setup on T1 did not pass*'
        Should -Invoke -CommandName Register-DemoVmWorkloadTask -Times 0
    }

    It 'records T4 and leaves it alone until Enable-DemoT4Workload has recorded T1''s access' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT3 -WithT4)
        Set-T1WorkloadMock
        Install-DemoSqlVmWorkload -Context $context | Out-Null
        $script:setupCalls | Should -Be @('T1:')
        $record = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).InstallRecord
        $record['t4']['serverFqdn'] | Should -Be 'pgflex01-abc123.postgres.database.azure.com'
        $record['t4']['runnerRole'] | Should -Be 'contosocare_runner'
        $record['setup'].Contains('T4') | Should -BeFalse
    }

    It 'updates T4''s demo objects as the recorded administrator role once T4 is enabled' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT4)
        Set-T1WorkloadMock
        Write-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).T4Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; adminRole = 'DbHub T3 admins'; runnerRole = 'contosocare_runner' })
        Install-DemoSqlVmWorkload -Context $context | Out-Null
        $script:setupCalls | Should -Be @('T1:', 'T4:pgflex01-abc123.postgres.database.azure.com:DbHub T3 admins')
        Should -Invoke -CommandName Invoke-DemoVmRunnerSetup -Times 1 -Exactly -ParameterFilter { $Target -eq 'T4' -and $RunnerRole -eq 'contosocare_runner' -and -not $IncludeBaseSchema -and -not $GrantEntraObjectId }
        $record = Read-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).InstallRecord
        $record['setup']['T4']['status'] | Should -Be 'Pass'
    }

    It 'warns, without failing, when an enabled T4 doesn''t resolve' {
        $context = New-TestT1Context -Settings (New-WorkloadSetting -WithT4)
        Set-T1WorkloadMock
        $script:t3Resolves = $false
        Write-DemoVmJsonFile -Path (Get-DemoVmWorkloadPath -Root $context.Root).T4Marker -InputObject ([ordered]@{ schemaVersion = 1; serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; adminRole = 'DbHub T3 admins'; runnerRole = 'contosocare_runner' })
        $result = Install-DemoSqlVmWorkload -Context $context
        $result.Outcome | Should -Be 'Done'
        ($result.WarningMessage -join ' ') | Should -Match 'T4'
        $script:setupCalls | Should -Be @('T1:')
    }
}

Describe 'T2 host WorkloadRunner step' {
    BeforeAll {
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

        function New-TestHostWorkloadContext([string] $Mode = 'PaygWizard', [switch] $WithoutRunner) {
            $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
            Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
            $settings = [ordered]@{
                role             = 'ArcHost'
                t2SqlInstallMode = $Mode
                seedScale        = 1
                guest            = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 }
            }
            if (-not $WithoutRunner) {
                $settings['workload'] = [ordered]@{ runnerSha256 = $script:sha; runnerChunkCount = 7; activityProfile = 'baseline'; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' }
            }
            Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
        }

        function Set-HostWorkloadMock {
            $script:guestCalls = [System.Collections.Generic.List[object]]::new()
            $script:guestReachable = $true
            $script:sqlInstance = [pscustomobject]@{ ServiceExists = $true; Running = $true; Edition = 'Standard Edition (64-bit)'; ProductVersion = '16.0'; IsSysAdmin = $true; Error = '' }
            Mock -CommandName Test-DemoHostGuestReachable -MockWith { $script:guestReachable }
            Mock -CommandName Get-DemoGuestCredential -MockWith {
                $secure = [System.Security.SecureString]::new()
                foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
                [System.Management.Automation.PSCredential]::new('Administrator', $secure)
            }
            Mock -CommandName Get-DemoGuestSqlInstance -MockWith { $script:sqlInstance }
            Mock -CommandName Test-DemoVmRunnerChunk -MockWith { $true }
            Mock -CommandName Get-DemoVmRunnerZip -MockWith { Join-Path -Path $TestDrive -ChildPath 'runner-abababababab.zip' }
            Mock -CommandName Get-DemoVmDotNetPin -MockWith { $script:pin }
            Mock -CommandName Test-DemoVmFileHash -MockWith { $true }
            Mock -CommandName Save-DemoVmDownload -MockWith { }
            Mock -CommandName Get-DemoVmFileSha256 -MockWith { 'cd' * 32 }
            Mock -CommandName Copy-DemoGuestTool -MockWith { }
            Mock -CommandName Copy-DemoGuestFile -MockWith { $script:guestCalls.Add([pscustomobject]@{ Kind = 'copy'; Source = $SourcePath; Destination = $DestinationPath }) }
            Mock -CommandName Invoke-Command -MockWith {
                $script:guestCalls.Add([pscustomobject]@{ Kind = 'install'; Arguments = $ArgumentList })
                [pscustomobject]@{ Status = 'Pass'; Message = 'setup --target T2: Pass (2 check(s) passed).' }
            }
        }
    }

    It 'keeps the ADR 0003 order with WorkloadRunner last, Not selected without a runner' {
        $context = New-TestHostWorkloadContext -WithoutRunner
        $plan = Get-DemoHostStepPlan -Context $context
        $plan[-1].Name | Should -Be 'WorkloadRunner'
        (& $plan[-1].When $plan[-1]) | Should -BeFalse
        $selected = Get-DemoHostStepPlan -Context (New-TestHostWorkloadContext)
        (& $selected[-1].When $selected[-1]) | Should -BeTrue
    }

    It 'waits for the guest (WaitingForGuestSql), not Failed, while it doesn''t answer' {
        $context = New-TestHostWorkloadContext
        Set-HostWorkloadMock
        $script:guestReachable = $false
        $result = Install-DemoHostGuestWorkload -Context $context
        $result.Outcome | Should -Be 'Waiting'
        $result.WaitState | Should -Be 'WaitingForGuestSql'
        Should -Invoke -CommandName Invoke-Command -Times 0
    }

    It 'waits for SQL Server in the guest, such as before the setup-wizard step' {
        $context = New-TestHostWorkloadContext
        Set-HostWorkloadMock
        $script:sqlInstance = [pscustomobject]@{ ServiceExists = $false; Running = $false; Edition = ''; ProductVersion = ''; IsSysAdmin = $false; Error = '' }
        $result = Install-DemoHostGuestWorkload -Context $context
        $result.Outcome | Should -Be 'Waiting'
        $result.WaitState | Should -Be 'WaitingForGuestSql'
        $result.Message | Should -Match 'SQL Server in arcsql01'
        Should -Invoke -CommandName Copy-DemoGuestFile -Times 0
    }

    It 'waits for the runner''s chunks on the host' {
        $context = New-TestHostWorkloadContext
        Set-HostWorkloadMock
        Mock -CommandName Test-DemoVmRunnerChunk -MockWith { $false }
        $result = Install-DemoHostGuestWorkload -Context $context
        $result.WaitState | Should -Be 'WaitingForInput'
    }

    It 'copies the runner, the runtime, and the wrapper into the guest, and installs for T2 with SYSTEM mapped in PaygWizard mode' {
        $context = New-TestHostWorkloadContext -Mode 'PaygWizard'
        Set-HostWorkloadMock
        $result = Install-DemoHostGuestWorkload -Context $context
        $result | Should -BeNullOrEmpty -Because 'a Pass setup returns nothing, which the runner reads as Done'

        $copies = @($script:guestCalls | Where-Object Kind -eq 'copy')
        $copies.Count | Should -Be 3
        ($copies.Destination -join ' ') | Should -Match 'runner-abababababab\.zip'
        ($copies.Destination -join ' ') | Should -Match 'dotnet-runtime-10\.0\.13-win-x64\.zip'
        ($copies.Destination -join ' ') | Should -Match 'Start-DemoWorkload\.ps1'
        $install = @($script:guestCalls | Where-Object Kind -eq 'install')[0]
        $install.Arguments[0] | Should -Be 'C:\ProgramData\DbHubDemo'
        $install.Arguments[1] | Should -Be $script:sha
        $install.Arguments[4] | Should -Be $script:pin.sha512
        $install.Arguments[6]['primaryTarget'] | Should -Be 'T2'
        $install.Arguments[7] | Should -Be 'NT AUTHORITY\SYSTEM'
        $hostRecord = Read-DemoVmJsonFile -Path (Join-Path -Path $context.Root -ChildPath 'guest-workload.json')
        $hostRecord['setupT2'] | Should -Be 'Pass'
    }

    It 'maps no login in the unattended modes, where SYSTEM is a sysadmin through BUILTIN\Administrators' {
        $context = New-TestHostWorkloadContext -Mode 'ProductKey'
        Set-HostWorkloadMock
        Install-DemoHostGuestWorkload -Context $context | Out-Null
        $install = @($script:guestCalls | Where-Object Kind -eq 'install')[0]
        $install.Arguments[7] | Should -Be ''
    }

    It 'computes the guest''s paths on the host without resolving the guest''s drive' {
        # Join-Path resolved the guest's C: on the machine running the step, which failed on Linux CI. A drive
        # letter that doesn't exist here reproduces that on any OS.
        $letter = [char[]](90..68) | Where-Object { -not (Test-Path -LiteralPath ([string]$_ + ':\')) } | Select-Object -First 1
        $context = New-TestHostWorkloadContext
        $context.Guest.ToolsFolder = '{0}:\ProgramData\DbHubDemo' -f $letter
        Set-HostWorkloadMock
        Install-DemoHostGuestWorkload -Context $context | Out-Null
        $copies = @($script:guestCalls | Where-Object Kind -eq 'copy')
        $copies.Destination | Should -Contain ('{0}:\ProgramData\DbHubDemo\downloads\runner-abababababab.zip' -f $letter)
        $copies.Destination | Should -Contain ('{0}:\ProgramData\DbHubDemo\downloads\dotnet-runtime-10.0.13-win-x64.zip' -f $letter)
        $copies.Destination | Should -Contain ('{0}:\ProgramData\DbHubDemo\runner\Start-DemoWorkload.ps1' -f $letter)
        @($script:guestCalls | Where-Object Kind -eq 'install')[0].Arguments[2] | Should -Be ('{0}:\ProgramData\DbHubDemo\downloads\runner-abababababab.zip' -f $letter)
    }

    It 'fails the attempt when the setup in the guest doesn''t pass' {
        $context = New-TestHostWorkloadContext
        Set-HostWorkloadMock
        Mock -CommandName Invoke-Command -MockWith { [pscustomobject]@{ Status = 'Fail'; Message = 'setup --target T2 failed with exit code 1' } }
        { Install-DemoHostGuestWorkload -Context $context } | Should -Throw '*setup on T2 did not pass*'
    }
}

Describe 'Start-DemoWorkload.ps1' {
    BeforeAll {
        $wrapperRoot = Join-Path -Path $TestDrive -ChildPath 'wrapper-default'
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Start-DemoWorkload.ps1') -Root $wrapperRoot

        function New-WrapperRoot([string] $ActivityProfile = 'baseline', [string] $PrimaryTarget = 'T1', [switch] $WithT3Marker, [object] $ProfileOnBoot = $true) {
            $root = Join-Path -Path $TestDrive -ChildPath ('wrapper-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'runner/abababababab') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'dotnet') -Force | Out-Null
            $dotnet = Join-Path -Path $root -ChildPath 'dotnet/dotnet.exe'
            $runner = Join-Path -Path $root -ChildPath 'runner/abababababab/ContosoCare.Workload.dll'
            Set-Content -LiteralPath $dotnet -Value 'host'
            Set-Content -LiteralPath $runner -Value 'runner'
            $install = [ordered]@{
                schemaVersion = 1; primaryTarget = $PrimaryTarget; runnerSha256 = $script:sha; runnerDll = $runner; dotnetExe = $dotnet
                activityProfile = $ActivityProfile; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC'; installedUtc = '2026-10-20T10:00:00.0000000Z'
                t3 = $null
            }
            if ($null -ne $ProfileOnBoot) {
                $install.profileOnBoot = [bool]$ProfileOnBoot
            }
            if ($PrimaryTarget -eq 'T1') {
                $install.t3 = [ordered]@{ serverFqdn = 'azuresql01-abc123.database.windows.net' }
            }
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Value ($install | ConvertTo-Json -Depth 5)
            if ($WithT3Marker) {
                Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 't3-workload.json') -Value (@{ serverFqdn = 'azuresql01-abc123.database.windows.net' } | ConvertTo-Json)
            }
            return $root
        }

        $script:noon = [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)
    }

    BeforeEach {
        $script:runs = [System.Collections.Generic.List[string]]::new()
        $script:bootTime = '2026-10-20T11:00:00.0000000Z'
        $script:resolves = $true
        Mock -CommandName Invoke-DemoWorkloadRunner -MockWith { $script:runs.Add(($ArgumentList -join ' ')); 0 }
        Mock -CommandName Get-DemoWorkloadBootTime -MockWith { $script:bootTime }
        Mock -CommandName Test-DemoWorkloadNameResolve -MockWith { $script:resolves }
        Mock -CommandName Start-Sleep -MockWith { }
    }

    It 'stops with exit code 1 when the runner isn''t installed' {
        $root = Join-Path -Path $TestDrive -ChildPath 'empty'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 1
        $script:runs.Count | Should -Be 0
    }

    It 'starts no activity when the next auto-shutdown is less than 10 minutes away' {
        $root = New-WrapperRoot
        Invoke-DemoWorkloadHost -StateRoot $root -Now ([datetime]::new(2026, 10, 20, 18, 55, 0, [System.DateTimeKind]::Utc)) | Should -Be 0
        $script:runs.Count | Should -Be 0
    }

    It 'applies the profile after an install, but not at a later boot when activityProfileOnBoot is false or missing' {
        foreach ($onBoot in @($false, $null)) {
            $root = New-WrapperRoot -WithT3Marker -ProfileOnBoot $onBoot
            $script:runs.Clear()
            $script:bootTime = '2026-10-20T11:00:00.0000000Z'
            Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 0
            @($script:runs | Where-Object { $_ -like 'profile set*' }).Count | Should -Be 2 -Because 'an install (a deployment) applies the configured profile'

            # The next boot sets nothing: T1 and T3 stay as stop-demo.ps1 or start-demo.ps1 left them.
            $script:runs.Clear()
            $script:bootTime = '2026-10-21T08:00:00.0000000Z'
            Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 0
            $script:runs.Count | Should -Be 1
            $script:runs[0] | Should -Match '^profile run --target T1 --not-after 2026-10-20T19:00:00\+00:00 --log-file .+ --t3-server azuresql01-abc123\.database\.windows\.net$'
            $applied = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-boot.json') -Raw | ConvertFrom-Json
            $applied.applied | Should -BeFalse
            $applied.reason | Should -Match 'activityProfileOnBoot'

            # A restart of the task in the same boot doesn't log the skip again or set anything.
            $script:runs.Clear()
            Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
            $script:runs.Count | Should -Be 1
        }
    }

    It 'applies the configured profile to T1 and T3 once per boot when activityProfileOnBoot is true, then hosts both until the shutdown' {
        $root = New-WrapperRoot -WithT3Marker
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 0
        $script:runs.Count | Should -Be 3
        $script:runs[0] | Should -Be 'profile set --target T1 --name baseline --requested-by DbHubDemo-Workload --not-after 2026-10-20T19:00:00+00:00'
        $script:runs[1] | Should -Be 'profile set --target T3 --name baseline --requested-by DbHubDemo-Workload --not-after 2026-10-20T19:00:00+00:00 --server azuresql01-abc123.database.windows.net'
        $script:runs[2] | Should -Match '^profile run --target T1 --not-after 2026-10-20T19:00:00\+00:00 --log-file .+ --t3-server azuresql01-abc123\.database\.windows\.net$'

        # A restart of the task in the same boot keeps the profiles someone set since.
        $script:runs.Clear()
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 0
        $script:runs.Count | Should -Be 1
        $script:runs[0] | Should -Match '^profile run --target T1'

        # The next boot applies the configured profile again.
        $script:runs.Clear()
        $script:bootTime = '2026-10-21T08:00:00.0000000Z'
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
        $script:runs.Count | Should -Be 3
    }

    It 'applies the profile again after a new install in the same boot' {
        $root = New-WrapperRoot
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
        $install = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Raw | ConvertFrom-Json
        $install.installedUtc = '2026-10-20T11:30:00.0000000Z'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Value ($install | ConvertTo-Json -Depth 5)
        $script:runs.Clear()
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
        $script:runs[0] | Should -Match '^profile set --target T1'
    }

    It 'hosts only T1 while T3 isn''t enabled or doesn''t resolve' {
        $root = New-WrapperRoot
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
        ($script:runs -join "`n") | Should -Not -Match 'T3|t3-server'

        $marked = New-WrapperRoot -WithT3Marker
        $script:resolves = $false
        $script:runs.Clear()
        Invoke-DemoWorkloadHost -StateRoot $marked -Now $script:noon | Out-Null
        ($script:runs -join "`n") | Should -Not -Match 'T3|t3-server'
    }

    It 'gives the off profile no end time, and hosts T2 alone in the guest' {
        $root = New-WrapperRoot -ActivityProfile 'off' -PrimaryTarget 'T2'
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Out-Null
        $script:runs[0] | Should -Be 'profile set --target T2 --name off --requested-by DbHubDemo-Workload'
        $script:runs[1] | Should -Match '^profile run --target T2 --not-after '
    }

    It 'retries a profile while SQL Server is still starting after a boot' {
        $root = New-WrapperRoot
        $script:failures = 2
        Mock -CommandName Invoke-DemoWorkloadRunner -MockWith {
            $script:runs.Add(($ArgumentList -join ' '))
            if ($ArgumentList[0] -eq 'profile' -and $ArgumentList[1] -eq 'set' -and $script:failures -gt 0) {
                $script:failures--
                return 1
            }
            0
        }
        Invoke-DemoWorkloadHost -StateRoot $root -Now $script:noon | Should -Be 0
        @($script:runs | Where-Object { $_ -like 'profile set*' }).Count | Should -Be 3
        $applied = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-boot.json') -Raw | ConvertFrom-Json
        $applied.exitCodes.T1 | Should -Be 0
    }
}

Describe 'Invoke-DemoWorkloadControl.ps1' {
    BeforeAll {
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1')

        function New-ControlRoot([string] $Role = 'SqlVm', [switch] $NoInstall) {
            $root = Join-Path -Path $TestDrive -ChildPath ('control-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $settings = [ordered]@{ role = $Role; workload = [ordered]@{ runnerSha256 = $script:sha; runnerChunkCount = 7; activityProfile = 'baseline'; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' } }
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'settings.json') -Value ($settings | ConvertTo-Json -Depth 5)
            if (-not $NoInstall) {
                $dotnet = Join-Path -Path $root -ChildPath 'dotnet.exe'
                $runner = Join-Path -Path $root -ChildPath 'ContosoCare.Workload.dll'
                Set-Content -LiteralPath $dotnet -Value 'host'
                Set-Content -LiteralPath $runner -Value 'runner'
                $install = [ordered]@{ primaryTarget = 'T1'; runnerDll = $runner; dotnetExe = $dotnet; activityProfile = 'baseline'; autoShutdownTime = '2359'; autoShutdownTimeZone = 'UTC'; installedUtc = 'x'; t3 = [ordered]@{ serverFqdn = 'azuresql01-abc123.database.windows.net' }; t4 = [ordered]@{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; runnerRole = 'contosocare_runner' }; setup = [ordered]@{ T1 = [ordered]@{ status = 'Pass' } } }
                Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Value ($install | ConvertTo-Json -Depth 5)
            }
            return $root
        }

        function ConvertTo-Request([hashtable] $Request) {
            [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 5 -Compress)))
        }

        function New-RunnerStatus([int] $Runs, [string] $Target = 'T1') {
            # The runner's 'status --json' as it writes it, indented: the profile near the top, one node per run (each with
            # its own "profile" string), and the host node last (CommandLine.cs). 2 runs make 2,128 characters, 5 make 3,584,
            # with the line breaks the runner writes on the Windows VMs (System.Text.Json's indented output uses
            # Environment.NewLine).
            $scenarios = 'cpu-pressure', 'missing-index', 'io-pressure', 'inefficient-query', 'healthy-baseline'
            $runNodes = foreach ($index in 1..$Runs) {
                $scenario = $scenarios[($index - 1) % $scenarios.Count]
                $start = [datetime]::new(2026, 11, 3, 13, 5, 0, [System.DateTimeKind]::Utc).AddMinutes(15 * ($index - 1))
                [ordered]@{
                    runId              = ('{0:yyyyMMddTHHmmss}-{1}' -f $start, $scenario)
                    scenario           = $scenario
                    target             = $Target
                    status             = $(if ($index -eq $Runs) { 'Running' } else { 'Completed' })
                    startedAt          = $start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    deadlineAt         = $start.AddMinutes(8).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    stoppedAt          = $(if ($index -eq $Runs) { $null } else { $start.AddMinutes(8).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') })
                    maxDurationSeconds = 600
                    concurrency        = 8
                    intensity          = 5
                    profile            = 'business-day'
                    requestedBy        = 'profile-host'
                    outcome            = $(if ($index -eq $Runs) { $null } else { 'Completed' })
                }
            }
            $document = [ordered]@{
                target         = $Target
                profile        = [ordered]@{ name = 'business-day'; setAt = '2026-11-03T13:01:12.000Z'; setBy = 'deploy'; expiresAt = '2099-11-03T21:01:12.000Z'; description = 'business-day: incidents at :05, :20, :35, and :50 past each UTC hour.' }
                runs           = @($runNodes)
                stopRequests   = @()
                demoSessions   = @()
                dataHeadroomMb = 1834
                logHeadroomMb  = 912
                host           = [ordered]@{ status = 'Fail'; message = ('The {0} lane keeps failing: the host restarted it 3 times in the last hour.' -f $Target); file = 'C:\ProgramData\DbHubDemo\host-lanes.json'; processId = 4312; hostStartedAt = '2026-11-03T12:58:40.000Z'; heartbeatAt = '2026-11-03T14:06:58.000Z'; heartbeatAgeSeconds = 2; processAlive = $true; stoppedAt = $null; stopReason = $null; lane = [ordered]@{ state = 'Serving'; generation = 4; restarts = 3; restartsLastHour = 3; lastRestartReason = 'no poll finished for 301 s'; lastPollAt = '2026-11-03T14:06:50.000Z'; lastPollAgeSeconds = 10; operation = 'polling'; consecutiveFailures = 0; lastError = $null; runningRuns = 1 } }
            }
            return (($document | ConvertTo-Json -Depth 8) -replace '\r?\n', "`r`n")
        }
    }

    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-DemoControlLine -MockWith { $script:lines.Add($Line) }
        Mock -CommandName Stop-DemoVmWorkload -MockWith { }
        Mock -CommandName Start-DemoVmWorkload -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }

        function Get-ControlResult {
            $script:lines.Count | Should -Be 1
            $script:lines[0] | Should -Match '^DBHUBDEMO-WORKLOAD \{'
            $script:lines[0].Substring('DBHUBDEMO-WORKLOAD '.Length) | ConvertFrom-Json
        }
    }

    It 'EnableT3: sets up T3, records the marker, sets T3''s profile, and restarts the host' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerSetup -MockWith { [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Message = 'setup --target T3: Pass'; Records = @() } }
        Mock -CommandName Set-DemoVmActivityProfile -MockWith { [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Message = 'profile set: Pass'; Records = @() } }
        Invoke-DemoWorkloadControl -ActionName 'EnableT3' -Request (ConvertTo-Request @{ serverFqdn = 'AzureSql01-abc123.database.windows.net' }) -StateRoot $root

        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.action | Should -Be 'EnableT3'
        $result.evidence.profileSet | Should -Be 'Pass'
        Should -Invoke -CommandName Invoke-DemoVmRunnerSetup -Times 1 -Exactly -ParameterFilter { $Target -eq 'T3' -and $Server -eq 'azuresql01-abc123.database.windows.net' }
        Should -Invoke -CommandName Set-DemoVmActivityProfile -Times 1 -Exactly -ParameterFilter { $Target -eq 'T3' -and $Name -eq 'baseline' -and $NotAfter -match '23:59:00\+00:00$' }
        Should -Invoke -CommandName Start-DemoVmWorkload -Times 1 -Exactly
        (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 't3-workload.json') -Raw | ConvertFrom-Json).serverFqdn | Should -Be 'azuresql01-abc123.database.windows.net'
        (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Raw | ConvertFrom-Json).setup.T3.status | Should -Be 'Pass'
    }

    It 'EnableT3: records nothing when the setup on T3 fails' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerSetup -MockWith { [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Message = 'setup --target T3 failed with exit code 1: Login failed'; Records = @() } }
        Mock -CommandName Set-DemoVmActivityProfile -MockWith { }
        Invoke-DemoWorkloadControl -ActionName 'EnableT3' -Request (ConvertTo-Request @{ serverFqdn = 'azuresql01-abc123.database.windows.net' }) -StateRoot $root
        (Get-ControlResult).status | Should -Be 'Fail'
        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 't3-workload.json') | Should -BeFalse
        Should -Invoke -CommandName Set-DemoVmActivityProfile -Times 0
        Should -Invoke -CommandName Start-DemoVmWorkload -Times 0
    }

    It 'EnableT3: fails clearly before the runner is installed, and only on T1' {
        $root = New-ControlRoot -NoInstall
        Invoke-DemoWorkloadControl -ActionName 'EnableT3' -Request (ConvertTo-Request @{ serverFqdn = 'azuresql01-abc123.database.windows.net' }) -StateRoot $root
        (Get-ControlResult).message | Should -Match 'not installed on T1 yet'
        $script:lines.Clear()
        Invoke-DemoWorkloadControl -ActionName 'EnableT3' -Request (ConvertTo-Request @{ serverFqdn = 'x.database.windows.net' }) -StateRoot (New-ControlRoot -Role 'ArcHost')
        (Get-ControlResult).message | Should -Match 'runs on T1'
    }

    It 'Runner on T1: adds --target, adds --server for T3, and fills in the next auto-shutdown' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[{"checkId":"WORKLOAD.T3.PROFILE.SET","status":"Pass","message":"ok"}]'; StdErr = '' } }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T3'; arguments = @('profile', 'set', '--name', 'incident:resource-governance', '--not-after', '{{NEXT_SHUTDOWN}}', '--json') }) -StateRoot $root
        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.evidence.exitCode | Should -Be 0
        $result.evidence.stdout | Should -Match 'WORKLOAD.T3.PROFILE.SET'
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '^profile set --name incident:resource-governance --not-after \d{4}-\d{2}-\d{2}T19:00:00\+00:00 --json --target T3 --server azuresql01-abc123\.database\.windows\.net$'
        }
    }

    It 'Runner on T1: adds --server and the runner''s role for T4' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '{"target":"T4"}'; StdErr = '' } }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T4'; arguments = @('status', '--json') }) -StateRoot $root
        (Get-ControlResult).status | Should -Be 'Pass'
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'status --json --target T4 --server pgflex01-abc123.postgres.database.azure.com --user contosocare_runner'
        }
    }

    It 'Runner keeps the active profile''s name and expiry from the whole status, which the kept tail of one with <Runs> runs (<Size> characters) leaves out (re-review of PR 16)' -ForEach @(
        @{ Runs = 2; Size = 2128 }
        @{ Runs = 5; Size = 3584 }
    ) {
        $root = New-ControlRoot
        $script:status = New-RunnerStatus -Runs $Runs
        $script:status.Length | Should -Be $Size
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:status; StdErr = '' } }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = @('status', '--json', '--runs', '5') }) -StateRoot $root
        $script:lines[0].Length | Should -BeLessThan 3500 -Because 'the line fits the 4,096 bytes a Run Command keeps'
        $script:lines[0] | Should -Match ([regex]::Escape('"profile":{"name":"business-day","expiresAt":"2099-11-03T21:01:12.000Z"}'))
        $result = Get-ControlResult
        $result.evidence.stdout | Should -Not -Match '"description"' -Because 'the kept tail leaves the status''s own profile out'
        $result.evidence.stdout | Should -Match '"host"'
        $result.evidence.profile.name | Should -Be 'business-day'
    }

    It 'Runner adds no profile for output that has none' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[{"checkId":"WORKLOAD.T1.PROFILE.SET","status":"Pass","message":"ok"}]'; StdErr = '' } }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = @('profile', 'set', '--name', 'baseline', '--json') }) -StateRoot $root
        $script:lines[0] | Should -Not -Match '"profile":\{'
        (Get-ControlResult).status | Should -Be 'Pass'
    }

    It 'EnableT4: sets T4 up as the P6 group''s role, records the marker, sets the profile, and restarts the host' {
        $root = New-ControlRoot
        Mock -CommandName Test-DemoVmNameResolve -MockWith { $true }
        Mock -CommandName Invoke-DemoVmRunnerSetup -MockWith { [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Message = 'setup --target T4: Pass'; Records = @() } }
        Mock -CommandName Set-DemoVmActivityProfile -MockWith { [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Message = 'profile set: Pass'; Records = @() } }
        $objectId = [guid]::NewGuid().ToString()
        Invoke-DemoWorkloadControl -ActionName 'EnableT4' -Request (ConvertTo-Request @{ serverFqdn = 'PGFLEX01-abc123.postgres.database.azure.com'; adminRole = 'DbHub T3 admins'; runnerRole = 'contosocare_runner'; runnerObjectId = $objectId; seedScale = 2 }) -StateRoot $root

        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.action | Should -Be 'EnableT4'
        Should -Invoke -CommandName Invoke-DemoVmRunnerSetup -Times 1 -Exactly -ParameterFilter {
            $Target -eq 'T4' -and $Server -eq 'pgflex01-abc123.postgres.database.azure.com' -and $User -eq 'DbHub T3 admins' -and $IncludeBaseSchema -and $SeedScale -eq 2 -and $GrantEntraObjectId -eq $objectId -and $RunnerRole -eq 'contosocare_runner'
        }
        Should -Invoke -CommandName Set-DemoVmActivityProfile -Times 1 -Exactly -ParameterFilter { $Target -eq 'T4' -and $Name -eq 'baseline' }
        Should -Invoke -CommandName Start-DemoVmWorkload -Times 1 -Exactly
        $marker = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 't4-workload.json') -Raw | ConvertFrom-Json
        $marker.serverFqdn | Should -Be 'pgflex01-abc123.postgres.database.azure.com'
        $marker.adminRole | Should -Be 'DbHub T3 admins'
        (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Raw | ConvertFrom-Json).setup.T4.status | Should -Be 'Pass'
    }

    It 'EnableT4: refuses a request with a bad role or object ID, and records nothing when setup fails' {
        $root = New-ControlRoot
        Mock -CommandName Test-DemoVmNameResolve -MockWith { $true }
        Mock -CommandName Invoke-DemoVmRunnerSetup -MockWith { [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Message = 'setup --target T4 failed: password authentication failed'; Records = @() } }
        Mock -CommandName Set-DemoVmActivityProfile -MockWith { }
        Invoke-DemoWorkloadControl -ActionName 'EnableT4' -Request (ConvertTo-Request @{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; adminRole = 'x"; DROP ROLE y; --'; runnerRole = 'contosocare_runner'; runnerObjectId = [guid]::NewGuid().ToString() }) -StateRoot $root
        (Get-ControlResult).message | Should -Match 'adminRole'
        $script:lines.Clear()
        Invoke-DemoWorkloadControl -ActionName 'EnableT4' -Request (ConvertTo-Request @{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; adminRole = 'DbHub T3 admins'; runnerRole = 'contosocare_runner'; runnerObjectId = 'not-a-guid' }) -StateRoot $root
        (Get-ControlResult).message | Should -Match 'runnerObjectId'
        Should -Invoke -CommandName Invoke-DemoVmRunnerSetup -Times 0
        $script:lines.Clear()
        Invoke-DemoWorkloadControl -ActionName 'EnableT4' -Request (ConvertTo-Request @{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; adminRole = 'DbHub T3 admins'; runnerRole = 'contosocare_runner'; runnerObjectId = [guid]::NewGuid().ToString() }) -StateRoot $root
        (Get-ControlResult).status | Should -Be 'Fail'
        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 't4-workload.json') | Should -BeFalse
        Should -Invoke -CommandName Start-DemoVmWorkload -Times 0
    }

    It 'Runner refuses a target this VM doesn''t drive, and --target inside the arguments' {
        $root = New-ControlRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { throw 'must not run' }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = @('status') }) -StateRoot $root
        (Get-ControlResult).message | Should -Match 'T2 runs? .*through archost01|not driven from this VM'
        $script:lines.Clear()
        { Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = @('status', '--target', 'T2') }) -StateRoot $root } | Should -Throw '*must not set --target*'
    }

    It 'StopGuest: shuts the guest down cleanly and waits until it''s off' {
        $root = New-ControlRoot -Role 'ArcHost' -NoInstall
        $script:vmChecks = 0
        Mock -CommandName Get-VM -MockWith {
            $script:vmChecks++
            $state = if ($script:vmChecks -ge 3) { 'Off' } else { 'Running' }
            [pscustomobject]@{ Name = 'arcsql01'; State = $state }
        }
        Mock -CommandName Stop-VM -MockWith { }
        Invoke-DemoWorkloadControl -ActionName 'StopGuest' -Request (ConvertTo-Request @{ timeoutMinutes = 5 }) -StateRoot $root
        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.evidence.state | Should -Be 'Off'
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'arcsql01' -and $Force }
    }

    It 'StopGuest: passes when the guest is already off or doesn''t exist' {
        $root = New-ControlRoot -Role 'ArcHost' -NoInstall
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = 'Off' } }
        Mock -CommandName Stop-VM -MockWith { throw 'must not stop' }
        Invoke-DemoWorkloadControl -ActionName 'StopGuest' -Request '' -StateRoot $root
        (Get-ControlResult).status | Should -Be 'Pass'
    }

    It 'answers an unknown action with one Fail line' {
        $root = New-ControlRoot
        Invoke-DemoWorkloadControl -ActionName 'Format' -Request '' -StateRoot $root
        (Get-ControlResult).status | Should -Be 'Fail'
    }
}

Describe 'Invoke-DemoWorkloadControl.ps1: a cold start never fails an activity (control start reliability)' {
    BeforeAll {
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1')
        # The functions the T2 relay reuses exist here too, so Pester can mock them.
        . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoGoldenGuest.ps1')
        . (Join-Path -Path $repoRoot -ChildPath 'vm/hyperv-guest/GuestVm.ps1')

        function New-ReadyRoot([string] $Role = 'SqlVm', [System.Collections.IDictionary] $Capture = $null) {
            $root = Join-Path -Path $TestDrive -ChildPath ('ready-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $settings = [ordered]@{ role = $Role; workload = [ordered]@{ runnerSha256 = $script:sha; runnerChunkCount = 7; activityProfile = 'baseline'; autoShutdownTime = '1900'; autoShutdownTimeZone = 'UTC' } }
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'settings.json') -Value ($settings | ConvertTo-Json -Depth 5)
            if ($Role -eq 'SqlVm') {
                $dotnet = Join-Path -Path $root -ChildPath 'dotnet.exe'
                $runner = Join-Path -Path $root -ChildPath 'ContosoCare.Workload.dll'
                Set-Content -LiteralPath $dotnet -Value 'host'
                Set-Content -LiteralPath $runner -Value 'runner'
                $install = [ordered]@{ primaryTarget = 'T1'; runnerDll = $runner; dotnetExe = $dotnet; t3 = [ordered]@{ serverFqdn = 'azuresql01-abc123.database.windows.net' }; t4 = [ordered]@{ serverFqdn = 'pgflex01-abc123.postgres.database.azure.com'; runnerRole = 'contosocare_runner' } }
                Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'workload-install.json') -Value ($install | ConvertTo-Json -Depth 5)
            }
            if ($null -ne $Capture) {
                New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'golden') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'golden\capture.json') -Value ($Capture | ConvertTo-Json -Depth 5)
            }
            return $root
        }

        function ConvertTo-Request([hashtable] $Request) {
            [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 5 -Compress)))
        }

        function New-Run([int] $ExitCode = 0, [string] $StdErr = '', [string] $StdOut = '[]') {
            [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
        }

        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        $script:guestCredential = [System.Management.Automation.PSCredential]::new('Administrator', $secure)
        $script:profileSet = @('profile', 'set', '--name', 'incident:cpu-pressure', '--duration', '30m', '--not-after', '{{NEXT_SHUTDOWN}}')
    }

    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-DemoControlLine -MockWith { $script:lines.Add($Line) }
        # A clock that moves only when the code sleeps.
        $script:clock = [datetime]::new(2026, 11, 3, 22, 9, 26, [System.DateTimeKind]::Utc)
        Mock -CommandName Get-DemoControlUtcNow -MockWith { $script:clock }
        $script:sleeps = [System.Collections.Generic.List[int]]::new()
        Mock -CommandName Start-Sleep -MockWith { $script:sleeps.Add([int]$Seconds); $script:clock = $script:clock.AddSeconds([int]$Seconds) }

        function Get-ControlResult {
            $script:lines.Count | Should -Be 1
            $script:lines[0] | Should -Match '^DBHUBDEMO-WORKLOAD \{'
            $script:lines[0].Substring('DBHUBDEMO-WORKLOAD '.Length) | ConvertFrom-Json
        }
    }

    It 'treats only activity as needing its target: profile set (but not off) and run' {
        Test-DemoControlActivityCommand -Arguments $script:profileSet | Should -BeTrue
        Test-DemoControlActivityCommand -Arguments @('run', 'cpu-pressure', '--duration', '5m') | Should -BeTrue
        foreach ($other in @(@('profile', 'set', '--name', 'off'), @('profile', 'get', '--json'), @('status', '--json'), @('reset', '--requested-by', 'x'), @('stop'))) {
            Test-DemoControlActivityCommand -Arguments $other | Should -BeFalse
        }
    }

    It 'calls <Text> on <Target> transient: <Transient>' -ForEach @(
        @{ Target = 'T1'; Text = 'SQL error 2: A network-related or instance-specific error occurred while establishing a connection to SQL Server. (provider: Named Pipes Provider, error: 40)'; Transient = $true }
        @{ Target = 'T1'; Text = 'SQL error 4060: Cannot open database "ContosoCare" requested by the login.'; Transient = $true }
        @{ Target = 'T1'; Text = 'SQL error -2: Execution Timeout Expired.'; Transient = $true }
        @{ Target = 'T1'; Text = 'SQL error 18456: Login failed for user.'; Transient = $false }
        @{ Target = 'T1'; Text = 'SQL error 229: The SELECT permission was denied.'; Transient = $false }
        @{ Target = 'T2'; Text = 'The virtual machine arcsql01 is not in running state.'; Transient = $true }
        @{ Target = 'T3'; Text = 'SQL error 40613: Database ContosoCare on server azuresql01-abc123 is not currently available.'; Transient = $true }
        @{ Target = 'T3'; Text = 'SQL error 2: Could not open a connection to SQL Server.'; Transient = $false }
        @{ Target = 'T3'; Text = 'ManagedIdentityCredential authentication unavailable. No response received from the managed identity endpoint.'; Transient = $true }
        @{ Target = 'T4'; Text = 'PostgreSQL error 57P03: the database system is starting up'; Transient = $true }
        @{ Target = 'T4'; Text = 'Failed to connect to 10.0.0.4:5432'; Transient = $true }
        @{ Target = 'T4'; Text = 'PostgreSQL error 28P01: password authentication failed for user "contosocare_runner"'; Transient = $false }
        @{ Target = 'T1'; Text = 'The runner (warmup --json --target T1) did not finish within 300 seconds and was stopped.'; Transient = $true }
        @{ Target = 'T1'; Text = 'Unrecognized command or argument ''warmup''.'; Transient = $false }
        @{ Target = 'T1'; Text = ''; Transient = $false }
    ) {
        Test-DemoControlTransientFailure -Target $Target -Text $Text | Should -Be $Transient
    }

    It 'waits for a cold T1 with growing delays, then sets its profile once (live, 2026-11-03: SQL error 2)' {
        $root = New-ReadyRoot
        $script:warmups = 0
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith {
            if ($ArgumentList[0] -eq 'warmup') {
                $script:warmups++
                if ($script:warmups -le 2) {
                    return (New-Run -ExitCode 1 -StdErr 'SQL error 2: A network-related or instance-specific error occurred while establishing a connection to SQL Server.')
                }
                return (New-Run)
            }
            return (New-Run -StdOut '[{"checkId":"WORKLOAD.T1.PROFILE.SET","status":"Pass","message":"ok"}]')
        }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = $script:profileSet; timeoutSeconds = 600 }) -StateRoot $root
        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.evidence.ready | Should -Be 'Ready'
        $result.evidence.readyAttempts | Should -Be 3
        $result.message | Should -Match 'T1 accepted connections after 15 seconds'
        @($script:sleeps) | Should -Be @(5, 10)
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 3 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'warmup --json --target T1' }
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'profile' }
    }

    It 'sets nothing on a target that stays unreachable, and stops waiting at its bound' {
        $root = New-ReadyRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith {
            if ($ArgumentList[0] -eq 'warmup') {
                return (New-Run -ExitCode 1 -StdErr 'SQL error 53: The network path was not found.')
            }
            throw 'profile set must not run'
        }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = $script:profileSet; readySeconds = 120 }) -StateRoot $root
        $result = Get-ControlResult
        $result.status | Should -Be 'Fail'
        $result.evidence.ready | Should -Be 'TimedOut'
        $result.message | Should -Match 'didn''t accept connections within 120 seconds'
        @($script:sleeps) | Should -Be @(5, 10, 20, 40)
    }

    It 'goes on when the target answers with an error that isn''t transient, and lets the command report it' {
        $root = New-ReadyRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith {
            if ($ArgumentList[0] -eq 'warmup') {
                return (New-Run -ExitCode 1 -StdErr 'SQL error 229: The SELECT permission was denied on the object.')
            }
            return (New-Run -StdOut '[{"status":"Pass","message":"ok"}]')
        }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T1'; arguments = $script:profileSet }) -StateRoot $root
        $result = Get-ControlResult
        $result.status | Should -Be 'Pass'
        $result.evidence.ready | Should -Be 'Answered'
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'warmup' }
        $script:sleeps.Count | Should -Be 0
    }

    It 'waits for a resuming T3 and a starting T4 with the same server options as their command' {
        $root = New-ReadyRoot
        $script:failures = @{ T3 = 'SQL error 40613: Database ContosoCare is not currently available.'; T4 = 'PostgreSQL error 57P03: the database system is starting up' }
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith {
            $target = $ArgumentList[[array]::IndexOf([object[]]$ArgumentList, '--target') + 1]
            if ($ArgumentList[0] -eq 'warmup' -and $script:failures[$target]) {
                $text = $script:failures[$target]
                $script:failures[$target] = ''
                return (New-Run -ExitCode 1 -StdErr $text)
            }
            return (New-Run -StdOut '[{"status":"Pass","message":"ok"}]')
        }
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T3'; arguments = $script:profileSet }) -StateRoot $root
        (Get-ControlResult).evidence.readyAttempts | Should -Be 2
        $script:lines.Clear()
        Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T4'; arguments = $script:profileSet }) -StateRoot $root
        (Get-ControlResult).evidence.readyAttempts | Should -Be 2
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'warmup --json --target T3 --server azuresql01-abc123.database.windows.net' }
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'warmup --json --target T4 --server pgflex01-abc123.postgres.database.azure.com --user contosocare_runner' }
    }

    It 'doesn''t wait before a read, a stop, a profile set to off, or with readySeconds 0' {
        $root = New-ReadyRoot
        Mock -CommandName Invoke-DemoVmRunnerProcess -MockWith { New-Run -StdOut '{"name":"baseline"}' }
        foreach ($request in @(
                @{ target = 'T1'; arguments = @('profile', 'get', '--json') }
                @{ target = 'T1'; arguments = @('profile', 'set', '--name', 'off') }
                @{ target = 'T3'; arguments = @('status', '--json') }
                @{ target = 'T1'; arguments = $script:profileSet; readySeconds = 0 }
            )) {
            $script:lines.Clear()
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request $request) -StateRoot $root
            (Get-ControlResult).status | Should -Be 'Pass'
        }
        Should -Invoke -CommandName Invoke-DemoVmRunnerProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'warmup' }
    }

    Context 'T2, relayed by archost01 into its guest' {
        BeforeEach {
            $script:guest = @{ State = 'Off'; Heartbeat = ''; AutomaticStartAction = 'Nothing' }
            $script:adapters = @([pscustomobject]@{ SwitchName = '' })
            $script:imds = 'source-vm'
            $script:warmupErrors = [System.Collections.Generic.Queue[string]]::new()
            $script:guestCalls = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = $script:guest.State; Heartbeat = $script:guest.Heartbeat; AutomaticStartAction = $script:guest.AutomaticStartAction; VMId = 'hyper-v-id' } }
            Mock -CommandName Set-VM -MockWith { $script:guest.AutomaticStartAction = $AutomaticStartAction }
            Mock -CommandName Start-VM -MockWith { $script:guest.State = 'Running'; $script:guest.Heartbeat = 'OkApplicationsHealthy' }
            Mock -CommandName Get-VMNetworkAdapter -MockWith { $script:adapters }
            Mock -CommandName Connect-VMNetworkAdapter -MockWith { $VMNetworkAdapter.SwitchName = $SwitchName }
            Mock -CommandName Get-GoldenImdsVmId -MockWith { if ($script:imds) { $script:imds } else { throw 'The Instance Metadata Service did not answer.' } }
            Mock -CommandName Wait-GoldenGuest -MockWith { [pscustomobject]@{ Credential = $script:guestCredential; Seconds = 20 } }
            Mock -CommandName Get-DemoGuestCredential -MockWith { $script:guestCredential }
            Mock -CommandName Invoke-DemoControlGuestCommand -MockWith {
                $text = $ScriptBlock.ToString()
                if ($text -match 'MSSQLSERVER') {
                    $script:guestCalls.Add('sql')
                    return [pscustomobject]@{ status = 'Running'; seconds = 40; startedByScript = $true }
                }
                if ($text -match "'warmup'") {
                    $script:guestCalls.Add('warmup')
                    if ($script:warmupErrors.Count -gt 0) {
                        return (New-Run -ExitCode 1 -StdErr $script:warmupErrors.Dequeue())
                    }
                    return (New-Run)
                }
                $script:guestCalls.Add('runner ' + (@($ArgumentList[1]) -join ' '))
                return (New-Run -StdOut '[{"status":"Pass","message":"ok"}]')
            }

            function New-Capture([bool] $Released = $false, [string] $ResetUtc = '') {
                $capture = [ordered]@{ schemaVersion = 1; snapshotName = 'snap-dbhub-t2golden-202601020304'; sourceAzureVmId = 'source-vm'; arcResourceName = 'arcsql01'; arcResourceGroup = 'rg-dbhub-demo'; released = $Released }
                if ($ResetUtc) {
                    $capture['resetUtc'] = $ResetUtc
                }
                return $capture
            }
        }

        It 'releases the source a golden capture left air-gapped, starts its guest, waits for SQL Server, then sets the profile (live, 2026-11-03)' {
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture)
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Pass'
            $result.evidence.golden | Should -Be 'Source'
            $result.evidence.released | Should -Be 'Source'
            $result.evidence.sqlService | Should -Be 'Running'
            Should -Invoke -CommandName Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter { $SwitchName -eq 'DbHubDemoNat' }
            Should -Invoke -CommandName Set-VM -Times 1 -Exactly -ParameterFilter { $AutomaticStartAction -eq 'Start' -and $AutomaticStartDelay -eq 0 }
            Should -Invoke -CommandName Start-VM -Times 1 -Exactly
            $capture = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'golden\capture.json') -Raw | ConvertFrom-Json
            $capture.released | Should -BeTrue
            $capture.releasedUtc | Should -Not -BeNullOrEmpty
            @($script:guestCalls)[0..1] | Should -Be @('sql', 'warmup')
            @($script:guestCalls)[2] | Should -Match '^runner profile set --name incident:cpu-pressure .* --target T2$'
        }

        It 'never starts a restored copy whose Arc identity wasn''t reset, and says to run deploy.ps1' {
            $script:imds = 'copy-vm'
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture)
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Fail'
            $result.evidence.golden | Should -Be 'CopyNotReset'
            $result.message | Should -Match 'deploy\.ps1'
            foreach ($command in 'Start-VM', 'Set-VM', 'Connect-VMNetworkAdapter', 'Invoke-DemoControlGuestCommand') {
                Should -Invoke -CommandName $command -Times 0 -Exactly
            }
            (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'golden\capture.json') -Raw | ConvertFrom-Json).released | Should -BeFalse
        }

        It 'leaves the guest off when the host''s VM ID can''t be read, because a copy can''t be told from the source' {
            $script:imds = ''
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture)
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Fail'
            $result.evidence.golden | Should -Be 'VmIdUnknown'
            Should -Invoke -CommandName Start-VM -Times 0 -Exactly
        }

        It 'finishes the release of a copy whose reset is recorded, without resetting it again' {
            $script:imds = 'copy-vm'
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture -ResetUtc '2026-10-23T14:00:00Z')
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Pass'
            $result.evidence.golden | Should -Be 'ResetCopy'
            $result.evidence.released | Should -Be 'Copy'
            Should -Invoke -CommandName Wait-GoldenGuest -Times 1 -Exactly
            Should -Invoke -CommandName Connect-VMNetworkAdapter -Times 1 -Exactly
        }

        It 'reads nothing more for a released capture and only waits for the running guest' {
            $script:guest = @{ State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; AutomaticStartAction = 'Start' }
            $script:adapters = @([pscustomobject]@{ SwitchName = 'DbHubDemoNat' })
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture -Released $true)
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Pass'
            $result.evidence.golden | Should -Be 'Released'
            foreach ($command in 'Get-GoldenImdsVmId', 'Start-VM', 'Set-VM', 'Connect-VMNetworkAdapter') {
                Should -Invoke -CommandName $command -Times 0 -Exactly
            }
        }

        It 'starts a guest that''s off, without a capture record, with its designed automatic start' {
            $script:guest = @{ State = 'Off'; Heartbeat = ''; AutomaticStartAction = 'StartIfRunning' }
            $script:adapters = @([pscustomobject]@{ SwitchName = 'DbHubDemoNat' })
            $root = New-ReadyRoot -Role 'ArcHost'
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Pass'
            $result.evidence.golden | Should -Be 'NoCapture'
            $result.evidence.started | Should -BeTrue
            $result.evidence.startActionBefore | Should -Be 'StartIfRunning'
            Should -Invoke -CommandName Set-VM -Times 1 -Exactly -ParameterFilter { $AutomaticStartAction -eq 'Start' }
            Should -Invoke -CommandName Start-VM -Times 1 -Exactly
            Should -Invoke -CommandName Connect-VMNetworkAdapter -Times 0 -Exactly
        }

        It 'waits while SQL Server in the guest refuses connections, then sets the profile' {
            $script:guest = @{ State = 'Running'; Heartbeat = 'OkApplicationsHealthy'; AutomaticStartAction = 'Start' }
            $script:warmupErrors.Enqueue('SQL error 2: A network-related or instance-specific error occurred while establishing a connection to SQL Server.')
            $script:warmupErrors.Enqueue('SQL error 4060: Cannot open database "ContosoCare" requested by the login.')
            $root = New-ReadyRoot -Role 'ArcHost'
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Pass'
            $result.evidence.ready | Should -Be 'Ready'
            $result.evidence.readyAttempts | Should -Be 3
            @($script:guestCalls | Where-Object { $_ -eq 'warmup' }).Count | Should -Be 3
        }

        It 'fails, within its bound, when the guest never reports a heartbeat, and runs nothing in it' {
            $script:guest = @{ State = 'Running'; Heartbeat = 'NoContact'; AutomaticStartAction = 'Start' }
            $root = New-ReadyRoot -Role 'ArcHost'
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = $script:profileSet; readySeconds = 120 }) -StateRoot $root
            $result = Get-ControlResult
            $result.status | Should -Be 'Fail'
            $result.message | Should -Match 'heartbeat'
            ($script:sleeps | Measure-Object -Sum).Sum | Should -BeLessOrEqual 120
            $script:guestCalls.Count | Should -Be 0
        }

        It 'changes nothing on the host for a read' {
            $root = New-ReadyRoot -Role 'ArcHost' -Capture (New-Capture)
            Invoke-DemoWorkloadControl -ActionName 'Runner' -Request (ConvertTo-Request @{ target = 'T2'; arguments = @('profile', 'get', '--json') }) -StateRoot $root
            $null = Get-ControlResult
            @($script:guestCalls) | Should -Be @('runner profile get --json --target T2')
            foreach ($command in 'Get-VM', 'Start-VM', 'Set-VM', 'Get-GoldenImdsVmId', 'Wait-GoldenGuest') {
                Should -Invoke -CommandName $command -Times 0 -Exactly
            }
        }
    }
}
