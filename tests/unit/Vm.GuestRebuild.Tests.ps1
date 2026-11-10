BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

    # Stand-ins for Hyper-V's and the task scheduler's cmdlets, with the parameters Remove-DemoHostGuest passes, defined in
    # this file's own scope (function:local:), so Pester mocks the same commands on every OS: they shadow a real cmdlet and
    # any global stand-in an earlier test file left behind (Vm.GoldenGuest's Stop-VM has no -TurnOff: CI on Ubuntu,
    # 2026-11-09), and they don't reach later files.
    $stubs = @{
        'Get-VM'                   = '[CmdletBinding()] param([string] $Name)'
        'Stop-VM'                  = '[CmdletBinding()] param([string] $Name, [switch] $TurnOff, [switch] $Force)'
        'Remove-VM'                = '[CmdletBinding(SupportsShouldProcess = $true)] param([string] $Name, [switch] $Force)'
        'Get-ScheduledTask'        = '[CmdletBinding()] param([string] $TaskName)'
        'Unregister-ScheduledTask' = '[CmdletBinding(SupportsShouldProcess = $true)] param([string] $TaskName)'
    }
    foreach ($name in $stubs.Keys) {
        Set-Item -Path ('function:local:' + $name) -Value ([scriptblock]::Create($stubs[$name]))
    }

    function New-TestHostContext {
        param([string] $Mode = 'JumpstartImage', [string] $ModeSource = '', [string] $DataDiskTier = 'None', [System.Collections.IDictionary] $GuestSource = $null)
        $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        if ($null -ne $GuestSource) {
            Write-DemoVmJsonFile -Path (Join-Path -Path $root -ChildPath 'guest-source.json') -InputObject $GuestSource
        }
        $settings = [ordered]@{
            role             = 'ArcHost'
            t2SqlInstallMode = $Mode
            dataDiskTier     = $DataDiskTier
            seedScale        = 1
            guest            = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 }
        }
        if ($ModeSource) {
            $settings['t2SqlInstallModeSource'] = $ModeSource
        }
        Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
    }

    function New-TestFinding {
        param(
            [string] $BuildMode = 'PaygWizard',
            [bool] $Reachable = $true,
            [bool] $DefaultInstance = $false,
            [string[]] $NamedInstances = @(),
            [string[]] $SetupRunning = @(),
            [bool] $WizardCompleted = $false,
            [bool] $GuidedWaiting = $false
        )
        [pscustomobject]@{
            GuestExists     = $true
            GuestVmId       = 'aaaaaaaa-0000-4000-8000-000000000001'
            Record          = $null
            BuildMode       = $BuildMode
            WizardCompleted = $WizardCompleted
            GuidedWaiting   = $GuidedWaiting
            Reachable       = $Reachable
            DefaultInstance = $DefaultInstance
            NamedInstances  = $NamedInstances
            SetupRunning    = $SetupRunning
            Edition         = $(if ($DefaultInstance) { 'Standard Edition (64-bit)' } else { '' })
            ArcResourceId   = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01'
            Error           = $(if ($Reachable) { '' } else { 'The guest is off.' })
        }
    }

    function New-TestFile([string] $Path, [int] $Bytes = 16) {
        $folder = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folder)) {
            $null = New-Item -ItemType Directory -Path $folder -Force
        }
        [System.IO.File]::WriteAllBytes($Path, (New-Object -TypeName 'byte[]' -ArgumentList $Bytes))
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'The stand-ins for Hyper-V''s and the task scheduler''s cmdlets' {
    It 'take the parameters Remove-DemoHostGuest passes, even over a global stand-in an earlier test file left without them (CI on Ubuntu, 2026-11-09)' {
        # A module's scope sees the global scope, not this file's stand-ins. Get-Item and Remove-Item ignore a
        # 'function:global:' path, silently (checked 2026-11-09), so the global one is read and removed from there.
        $globalScope = New-Module -ScriptBlock { }
        $saved = & $globalScope { Get-Item -Path 'function:Stop-VM' -ErrorAction SilentlyContinue }
        try {
            # What Vm.GoldenGuest.Tests.ps1 left behind in a full run, until 2026-11-09.
            Set-Item -Path 'function:global:Stop-VM' -Value ([scriptblock]::Create('[CmdletBinding()] param([string] $Name, [switch] $Force, [switch] $AsJob)'))
            $expected = [ordered]@{
                'Get-VM'                   = @('Name')
                'Stop-VM'                  = @('Name', 'TurnOff', 'Force')
                'Remove-VM'                = @('Name', 'Force')
                'Get-ScheduledTask'        = @('TaskName')
                'Unregister-ScheduledTask' = @('TaskName', 'Confirm')
            }
            foreach ($name in $expected.Keys) {
                $command = Get-Command -Name $name
                $command.CommandType | Should -Be 'Function' -Because ('{0} is this file''s stand-in, not a real cmdlet or another file''s' -f $name)
                $command.ModuleName | Should -BeNullOrEmpty -Because ('{0} is this file''s stand-in, not a module''s command' -f $name)
                foreach ($parameter in $expected[$name]) {
                    $command.Parameters.Keys | Should -Contain $parameter -Because $name
                }
            }
        }
        finally {
            if ($null -ne $saved) {
                Set-Item -Path 'function:global:Stop-VM' -Value $saved.ScriptBlock
            }
            else {
                & $globalScope { Remove-Item -Path 'function:Stop-VM' -ErrorAction SilentlyContinue }
            }
        }
        # Nothing of it is left behind for later files: the global scope holds what it held before.
        $after = & $globalScope { Get-Item -Path 'function:Stop-VM' -ErrorAction SilentlyContinue }
        ($null -eq $after) | Should -Be ($null -eq $saved)
    }
}

Describe 'The mode the T2 host runs (2026-11-09)' {
    It 'keeps a finished PaygWizard guest in its mode in JumpstartImage mode, and nothing else: <Case>' -ForEach @(
        @{ Case = 'a finished PaygWizard guest'; Configured = 'JumpstartImage'; Source = 'configuration'; Record = @{ source = 'Build'; installMode = 'PaygWizard'; sqlSetUp = $true }; Mode = 'PaygWizard'; Adopted = $true }
        @{ Case = 'the same under an older configuration''s PaygWizard'; Configured = 'JumpstartImage'; Source = 'legacy'; Record = @{ source = 'Build'; installMode = 'PaygWizard'; sqlSetUp = $true }; Mode = 'PaygWizard'; Adopted = $true }
        @{ Case = 'the same with no mode in the configuration'; Configured = 'JumpstartImage'; Source = 'default'; Record = @{ source = 'Build'; installMode = 'PaygWizard'; sqlSetUp = $true }; Mode = 'PaygWizard'; Adopted = $true }
        @{ Case = 'a PaygWizard guest not seen set up'; Configured = 'JumpstartImage'; Source = 'legacy'; Record = @{ source = 'Build'; installMode = 'PaygWizard' }; Mode = 'JumpstartImage'; Adopted = $false }
        @{ Case = 'a finished ProductKey guest, a deliberate choice'; Configured = 'JumpstartImage'; Source = 'configuration'; Record = @{ source = 'Build'; installMode = 'ProductKey'; sqlSetUp = $true }; Mode = 'JumpstartImage'; Adopted = $false }
        @{ Case = 'a finished Developer guest, a deliberate choice'; Configured = 'JumpstartImage'; Source = 'configuration'; Record = @{ source = 'Build'; installMode = 'Developer'; sqlSetUp = $true }; Mode = 'JumpstartImage'; Adopted = $false }
        @{ Case = 'a guest made from the image'; Configured = 'JumpstartImage'; Source = 'configuration'; Record = @{ source = 'JumpstartImage'; installMode = 'JumpstartImage' }; Mode = 'JumpstartImage'; Adopted = $false }
        @{ Case = 'PaygWizard chosen on purpose'; Configured = 'PaygWizard'; Source = 'configuration'; Record = @{ source = 'Build'; installMode = 'PaygWizard'; sqlSetUp = $true }; Mode = 'PaygWizard'; Adopted = $false }
        @{ Case = 'no mode and no guest'; Configured = ''; Source = 'default'; Record = $null; Mode = 'JumpstartImage'; Adopted = $false }
    ) {
        $effective = Get-DemoHostEffectiveMode -ConfiguredMode $Configured -Record $Record
        $effective.Mode | Should -Be $Mode
        $effective.Adopted | Should -Be $Adopted
    }

    It 'takes the mode''s source from the settings, legacy included, and reports what it runs' {
        $context = New-TestHostContext -ModeSource 'legacy' -GuestSource ([ordered]@{ source = 'Build'; installMode = 'PaygWizard'; recordedUtc = '2026-10-30T10:00:00Z'; sqlSetUp = $true })
        $context.ConfiguredMode | Should -Be 'JumpstartImage'
        $context.ModeSource | Should -Be 'legacy'
        $context.Mode | Should -Be 'PaygWizard'
        $context.ModeAdopted | Should -BeTrue
        (New-TestHostContext -ModeSource 'record').ModeSource | Should -Be 'configuration' -Because 'an unknown source counts as the configuration''s'
        (New-TestHostContext).ModeSource | Should -Be 'configuration' -Because 'the template''s own loader (deploy.ps1 -Sequential) passes no source'
    }
}

Describe 'The mode a build guest was made in' {
    It 'tells it from <Case>' -ForEach @(
        @{ Case = 'its record'; Record = @{ source = 'Build'; installMode = 'PaygWizard' }; Steps = $null; Edition = ''; Expected = 'PaygWizard' }
        @{ Case = 'the Arc onboarding before the wizard'; Record = $null; Steps = @{ ArcOnboardingBeforeWizard = @{ status = 'Succeeded'; firstStartedUtc = '2026-10-30T10:00:00Z' } }; Edition = ''; Expected = 'PaygWizard' }
        @{ Case = 'the setup-wizard step'; Record = $null; Steps = @{ SqlSetupWizard = @{ status = 'Pending'; firstStartedUtc = '2026-10-30T10:00:00Z' } }; Edition = ''; Expected = 'PaygWizard' }
        @{ Case = 'an unattended install of Developer edition'; Record = $null; Steps = @{ SqlUnattendedInstall = @{ status = 'Succeeded'; firstStartedUtc = '2026-10-30T10:00:00Z' } }; Edition = 'Developer Edition (64-bit)'; Expected = 'Developer' }
        @{ Case = 'an unattended install of Standard edition'; Record = $null; Steps = @{ SqlUnattendedInstall = @{ status = 'Succeeded'; firstStartedUtc = '2026-10-30T10:00:00Z' } }; Edition = 'Standard Edition (64-bit)'; Expected = 'ProductKey' }
        @{ Case = 'an unattended install with no edition known'; Record = $null; Steps = @{ SqlUnattendedInstall = @{ status = 'Failed'; firstStartedUtc = '2026-10-30T10:00:00Z' } }; Edition = ''; Expected = '' }
        @{ Case = 'records of both kinds'; Record = $null; Steps = @{ SqlSetupWizard = @{ firstStartedUtc = '2026-10-30T10:00:00Z' }; SqlUnattendedInstall = @{ firstStartedUtc = '2026-10-31T10:00:00Z' } }; Edition = ''; Expected = '' }
        @{ Case = 'steps that never started'; Record = $null; Steps = @{ SqlSetupWizard = @{ status = 'Pending'; firstStartedUtc = '' } }; Edition = ''; Expected = '' }
        @{ Case = 'nothing'; Record = $null; Steps = $null; Edition = ''; Expected = '' }
    ) {
        Get-DemoHostGuestBuildMode -Record $Record -Steps $Steps -Edition $Edition | Should -Be $Expected
    }
}

Describe 'What the GuestSource step plans for a build guest in JumpstartImage mode: fail safe' {
    It '<Case>: <Action>' -ForEach @(
        @{ Case = 'an unfinished PaygWizard guest'; Finding = @{}; Action = 'Rebuild' }
        @{ Case = 'a PaygWizard guest with SQL Server in it'; Finding = @{ DefaultInstance = $true }; Action = 'Adopt' }
        @{ Case = 'a PaygWizard guest with only a named instance'; Finding = @{ NamedInstances = @('SQLEXPRESS') }; Action = 'Adopt' }
        @{ Case = 'setup completed by the records, the guest unreadable'; Finding = @{ WizardCompleted = $true; Reachable = $false }; Action = 'Adopt' }
        @{ Case = 'a finished ProductKey guest'; Finding = @{ BuildMode = 'ProductKey'; DefaultInstance = $true }; Action = 'Refuse' }
        @{ Case = 'a finished Developer guest'; Finding = @{ BuildMode = 'Developer'; DefaultInstance = $true }; Action = 'Refuse' }
        @{ Case = 'a finished guest of unknown mode'; Finding = @{ BuildMode = ''; DefaultInstance = $true }; Action = 'Refuse' }
        @{ Case = 'a guest that couldn''t be read'; Finding = @{ Reachable = $false }; Action = 'Wait' }
        @{ Case = 'setup running in the guest'; Finding = @{ SetupRunning = @('setup.exe') }; Action = 'Wait' }
        @{ Case = 'a guided stop waiting for a person'; Finding = @{ GuidedWaiting = $true }; Action = 'Wait' }
        @{ Case = 'an unfinished Developer guest'; Finding = @{ BuildMode = 'Developer' }; Action = 'Refuse' }
        @{ Case = 'an unfinished guest of unknown mode'; Finding = @{ BuildMode = '' }; Action = 'Refuse' }
    ) {
        $plan = Get-DemoHostGuestSourcePlan -Finding (New-TestFinding @Finding)
        $plan.Action | Should -Be $Action
        $plan.Reason | Should -Not -BeNullOrEmpty
    }

    It 'says what it keeps, and why, in its reason' {
        (Get-DemoHostGuestSourcePlan -Finding (New-TestFinding -DefaultInstance $true)).Reason | Should -Match 'keeps it as it is, in that mode, with no setup wizard'
        (Get-DemoHostGuestSourcePlan -Finding (New-TestFinding -BuildMode 'ProductKey' -DefaultInstance $true)).Reason | Should -Match 'deliberate choice'
        (Get-DemoHostGuestSourcePlan -Finding (New-TestFinding)).Reason | Should -Match 'never finished'
        (Get-DemoHostGuestSourcePlan -Finding (New-TestFinding -Reachable $false)).Reason | Should -Match 'nothing is deleted'
    }
}

Describe 'The GuestSource step (2026-11-09)' {
    BeforeEach {
        $script:context = New-TestHostContext
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $false; Expected = 'JumpstartImage'; Recorded = 'Build'; RecordedMode = 'PaygWizard' } }
        Mock -CommandName Get-DemoHostGuestFinding -MockWith { New-TestFinding }
        Mock -CommandName Remove-DemoHostGuest -MockWith { }
    }

    It 'needs nothing when the guest''s source fits the mode, and doesn''t look into the guest' {
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $true; Expected = 'JumpstartImage'; Recorded = ''; RecordedMode = '' } }
        Invoke-DemoHostGuestSourceStep -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Get-DemoHostGuestFinding -Times 0 -Exactly
    }

    It 'still refuses a build mode for a guest made from the image, as before' {
        $context = New-TestHostContext -Mode 'Developer'
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $false; Expected = 'Build'; Recorded = 'JumpstartImage'; RecordedMode = 'JumpstartImage' } }
        $result = Invoke-DemoHostGuestSourceStep -Context $context
        $result.Outcome | Should -Be 'Failed'
        Should -Invoke -CommandName Get-DemoHostGuestFinding -Times 0 -Exactly
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 0 -Exactly
    }

    It 'deletes an unfinished PaygWizard guest, so the image''s steps make T2 again in this pass' {
        Invoke-DemoHostGuestSourceStep -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 1 -Exactly -ParameterFilter { $Finding.BuildMode -eq 'PaygWizard' -and $Reason -match 'never finished' -and -not $Resume }
        $script:context.Mode | Should -Be 'JumpstartImage'
        $script:context.ModeAdopted | Should -BeFalse
    }

    It 'keeps a finished PaygWizard guest as it is, records it, and runs its mode from then on' {
        Mock -CommandName Get-DemoHostGuestFinding -MockWith { New-TestFinding -DefaultInstance $true }
        Invoke-DemoHostGuestSourceStep -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 0 -Exactly
        $script:context.Mode | Should -Be 'PaygWizard'
        $script:context.ModeAdopted | Should -BeTrue
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestSourcePath -Context $script:context)
        $record['source'] | Should -Be 'Build'
        $record['installMode'] | Should -Be 'PaygWizard'
        $record['sqlSetUp'] | Should -BeTrue
        # The next pass's context starts in that mode, so no rebuild, no wizard, and no guided stop.
        (Get-DemoHostEffectiveMode -ConfiguredMode 'JumpstartImage' -Record $record).Adopted | Should -BeTrue
    }

    It 'waits, deleting nothing, when it can''t tell whether setup finished' {
        Mock -CommandName Get-DemoHostGuestFinding -MockWith { New-TestFinding -Reachable $false }
        { Invoke-DemoHostGuestSourceStep -Context $script:context } | Should -Throw -ExpectedMessage '*nothing is deleted*'
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 0 -Exactly
    }

    It 'refuses a finished ProductKey guest with the fix, and deletes nothing' {
        Mock -CommandName Get-DemoHostGuestSourceState -MockWith { [pscustomobject]@{ Ok = $false; Expected = 'JumpstartImage'; Recorded = 'Build'; RecordedMode = 'ProductKey' } }
        Mock -CommandName Get-DemoHostGuestFinding -MockWith { New-TestFinding -BuildMode 'ProductKey' -DefaultInstance $true }
        $result = Invoke-DemoHostGuestSourceStep -Context $script:context
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'deliberate choice'
        $result.Message | Should -Match 'destroy\.ps1, then \./scripts/deploy\.ps1'
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 0 -Exactly
    }

    It 'finishes first a deletion that a stopped run left Removing' {
        Write-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context) -InputObject ([ordered]@{ schemaVersion = 1; state = 'Removing'; oldMode = 'PaygWizard'; removed = @() })
        Invoke-DemoHostGuestSourceStep -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Remove-DemoHostGuest -Times 1 -Exactly -ParameterFilter { $Resume }
        Should -Invoke -CommandName Get-DemoHostGuestSourceState -Times 0 -Exactly
    }
}

Describe 'Deleting an unfinished guest' {
    BeforeEach {
        $script:context = New-TestHostContext
        $script:vms = Join-Path -Path $TestDrive -ChildPath ('vms-' + [guid]::NewGuid().ToString('N'))
        $script:media = Join-Path -Path $TestDrive -ChildPath ('media-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Get-DemoHostDataPath -MockWith { if ($Kind -eq 'Vms') { $script:vms } else { $script:media } }
        Mock -CommandName Get-DemoHostMediaFile -MockWith { [pscustomobject]@{ Name = $MediaName; Url = ''; Sha256 = ''; Path = (Join-Path -Path $script:media -ChildPath ($MediaName + '.iso')) } }
        Mock -CommandName Get-DemoHostGuestRebuildSpace -MockWith { [pscustomobject]@{ Ok = $true; FreeBytes = [long]0; FreedBytes = [long]0; NeededBytes = [long]0 } }
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = 'Running'; VMId = 'aaaaaaaa-0000-4000-8000-000000000001' } }
        Mock -CommandName Stop-VM -MockWith { }
        Mock -CommandName Remove-VM -MockWith { }
        Mock -CommandName Get-ScheduledTask -MockWith { [pscustomobject]@{ TaskName = 'DbHubDemo-GuestConsole' } }
        Mock -CommandName Unregister-ScheduledTask -MockWith { }

        $root = $script:context.Root
        $guided = Get-DemoGuidedSetupPath -Root $root
        $script:disk = Join-Path -Path $script:vms -ChildPath 'arcsql01/arcsql01.vhdx'
        $script:isos = @(foreach ($name in @($script:context.Host.Media.WindowsServer, $script:context.Host.Media.SqlServer, $script:context.Host.Media.SqlDeveloper) | Where-Object { $_ } | Select-Object -Unique) { Join-Path -Path $script:media -ChildPath ($name + '.iso') })
        $script:records = @(
            (Get-DemoHostGuestSourcePath -Context $script:context), $script:context.ArcMarkerPath, (Join-Path -Path $root -ChildPath 'guest-evaluation.json'),
            $guided.HostRequest, $guided.HostArmed, $guided.HostSignIn, $guided.HostLast, $guided.HostConsoleScript, $guided.HostSteps,
            $script:context.SecretPath, ($script:context.SecretPath + '.pending'))
        $script:kept = @((Join-Path -Path $root -ChildPath 'health.json'), (Join-Path -Path $script:media -ChildPath 'ArcBox-SQL-STD.vhdx.partial'))
        foreach ($file in @($script:disk) + $script:isos + @($script:isos[0] + '.partial') + $script:records + $script:kept) {
            New-TestFile -Path $file
        }
    }

    It 'deletes the guest VM, its disk, the build media, and its records on the host, keeps the rest, and records the rebuild' {
        Remove-DemoHostGuest -Context $script:context -Finding (New-TestFinding) -Reason 'The setup wizard was never finished.' -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Stop-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'arcsql01' -and $TurnOff }
        Should -Invoke -CommandName Remove-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'arcsql01' }
        Should -Invoke -CommandName Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'DbHubDemo-GuestConsole' }
        foreach ($file in @($script:disk) + $script:isos + @($script:isos[0] + '.partial') + $script:records) {
            Test-Path -LiteralPath $file | Should -BeFalse -Because $file
        }
        Test-Path -LiteralPath (Split-Path -Path $script:disk -Parent) | Should -BeFalse
        foreach ($file in $script:kept) {
            Test-Path -LiteralPath $file | Should -BeTrue -Because ('{0} isn''t the old guest''s' -f $file)
        }
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context)
        $record['state'] | Should -Be 'Removed'
        $record['oldMode'] | Should -Be 'PaygWizard'
        $record['oldGuestVmId'] | Should -Be 'aaaaaaaa-0000-4000-8000-000000000001'
        $record['arcResourceId'] | Should -Match '/machines/arcsql01$'
        $record['removedUtc'] | Should -Not -BeNullOrEmpty
        @($record['removed']) | Should -Contain 'the guest VM arcsql01'
        @($record['removed']) | Should -Contain 'the host logon task DbHubDemo-GuestConsole'
        $detail = Get-DemoHostGuestRebuildDetail -Context $script:context
        $detail.state | Should -Be 'Removed'
        $detail.oldMode | Should -Be 'PaygWizard'
        $detail.Contains('removed') | Should -BeFalse -Because 'health.json gets the record without its file list'
    }

    It 'deletes nothing when the Jumpstart image wouldn''t fit without a data disk' {
        Mock -CommandName Get-DemoHostGuestRebuildSpace -MockWith { [pscustomobject]@{ Ok = $false; FreeBytes = [long]20GB; FreedBytes = [long]30GB; NeededBytes = [long]64GB } }
        $result = Remove-DemoHostGuest -Context $script:context -Finding (New-TestFinding) -Confirm:$false
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Nothing was deleted'
        $result.Message | Should -Match 'dataDiskSku'
        Should -Invoke -CommandName Remove-VM -Times 0 -Exactly
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Test-Path -LiteralPath $script:disk | Should -BeTrue
        Test-Path -LiteralPath (Get-DemoHostGuestRebuildPath -Context $script:context) | Should -BeFalse
    }

    It 'finishes a deletion that a stopped run left Removing, without the space check, and keeps what it already noted' {
        Write-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context) -InputObject ([ordered]@{ schemaVersion = 1; state = 'Removing'; reason = 'r'; startedUtc = '2026-11-09T10:00:00Z'; removedUtc = ''; oldMode = 'PaygWizard'; oldGuestVmId = 'old'; arcResourceId = ''; removed = @('the guest VM arcsql01') })
        Mock -CommandName Get-VM -MockWith { $null }
        Remove-DemoHostGuest -Context $script:context -Resume -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Get-DemoHostGuestRebuildSpace -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VM -Times 0 -Exactly
        Test-Path -LiteralPath $script:disk | Should -BeFalse
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context)
        $record['state'] | Should -Be 'Removed'
        ([datetime]$record['startedUtc']).ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 9, 10, 0, 0, [System.DateTimeKind]::Utc))
        @($record['removed']) | Should -Contain 'the guest VM arcsql01'
    }

    It 'turns the guest off only when it isn''t off already' {
        Mock -CommandName Get-VM -MockWith { [pscustomobject]@{ Name = 'arcsql01'; State = 'Off'; VMId = 'x' } }
        Remove-DemoHostGuest -Context $script:context -Finding (New-TestFinding) -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke -CommandName Stop-VM -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VM -Times 1 -Exactly
    }
}

Describe 'The space check before a rebuild' {
    It 'counts what the deletion frees against what the image needs, without a data disk' {
        $context = New-TestHostContext
        $folder = Join-Path -Path $TestDrive -ChildPath ('freed-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path -Path $folder -ChildPath 'a.vhdx') -Bytes 1024
        New-TestFile -Path (Join-Path -Path $folder -ChildPath 'sub/b.bin') -Bytes 2048
        $iso = Join-Path -Path $TestDrive -ChildPath ('media-' + [guid]::NewGuid().ToString('N') + '.iso')
        New-TestFile -Path $iso -Bytes 4096
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { [long]10000 }
        Mock -CommandName Get-DemoHostOsDiskRequirement -MockWith { [pscustomobject]@{ TotalBytes = [long]17000 } }
        $space = Get-DemoHostGuestRebuildSpace -Context $context -Path @($folder, $iso, (Join-Path -Path $TestDrive -ChildPath 'missing.iso'))
        $space.FreedBytes | Should -Be 7168
        $space.Ok | Should -BeTrue
        Mock -CommandName Get-DemoHostOsDiskRequirement -MockWith { [pscustomobject]@{ TotalBytes = [long]17200 } }
        (Get-DemoHostGuestRebuildSpace -Context $context -Path @($folder, $iso)).Ok | Should -BeFalse
    }

    It 'needs no check with a data disk' {
        Mock -CommandName Get-DemoHostDriveFreeSpace -MockWith { throw 'unexpected' }
        (Get-DemoHostGuestRebuildSpace -Context (New-TestHostContext -DataDiskTier 'E10')).Ok | Should -BeTrue
    }
}

Describe 'What the T2 host reports to deploy.ps1' {
    It 'puts the mode, its source, the adoption, the guest''s own mode, and the rebuild in health.json''s summary' {
        $root = Join-Path -Path $TestDrive -ChildPath ('health-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        $health = [ordered]@{
            schemaVersion = 1; state = 'InProgress'; currentStep = 'GuestImage'; message = 'Downloading.'
            details       = [ordered]@{ installMode = 'JumpstartImage'; configuredInstallMode = 'JumpstartImage'; installModeSource = 'legacy'; installModeAdopted = $false; guestSource = [ordered]@{ source = 'Build'; installMode = 'PaygWizard'; sqlSetUp = $false } }
        }
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'health.json'), (ConvertTo-Json -InputObject $health -Depth 6))
        $rebuild = [ordered]@{ schemaVersion = 1; state = 'Removed'; startedUtc = '2026-11-09T10:00:00Z'; removedUtc = '2026-11-09T10:01:00Z'; oldMode = 'PaygWizard'; arcResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/arcsql01'; removed = @('the guest VM arcsql01') }
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'guest-rebuild.json'), (ConvertTo-Json -InputObject $rebuild -Depth 6))
        $summary = (& (Join-Path -Path $repoRoot -ChildPath 'vm/health/Get-DemoHealth.ps1') -Root $root -View Summary) | ConvertFrom-Json
        $summary.configuredMode | Should -Be 'JumpstartImage'
        $summary.modeSource | Should -Be 'legacy'
        $summary.modeAdopted | Should -BeFalse
        $summary.guestMode | Should -Be 'PaygWizard'
        $summary.guestRebuild | Should -Be 'Removed'
        ([datetime]$summary.rebuildUtc).ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 9, 10, 0, 0, [System.DateTimeKind]::Utc))
        $summary.rebuildMode | Should -Be 'PaygWizard'
        $summary.rebuildArcId | Should -Match '/machines/arcsql01$'
        $summary.rebuildArcNew | Should -BeFalse -Because 'no Arc marker is there for the new guest yet'
    }

    It 'says the Arc marker is the new guest''s only on evidence, and false only on evidence that it isn''t: <Case> (review of 849d4c2)' -ForEach @(
        @{ Case = 'no marker yet'; State = 'Removed'; Marker = $false; MarkerVmId = ''; Current = 'new'; Expected = $false }
        @{ Case = 'the old guest''s marker'; State = 'Removed'; Marker = $true; MarkerVmId = 'old'; Current = 'new'; Expected = $false }
        @{ Case = 'the new guest''s marker'; State = 'Done'; Marker = $true; MarkerVmId = 'new'; Current = 'new'; Expected = $true }
        @{ Case = 'a marker without a VM ID'; State = 'Removed'; Marker = $true; MarkerVmId = ''; Current = 'new'; Expected = $null }
        @{ Case = 'a marker for another guest'; State = 'Removed'; Marker = $true; MarkerVmId = 'other'; Current = 'new'; Expected = $null }
        @{ Case = 'a marker, but no guest'; State = 'Removed'; Marker = $true; MarkerVmId = 'new'; Current = ''; Expected = $null }
    ) {
        $ids = @{ old = 'aaaaaaaa-0000-4000-8000-000000000001'; new = 'aaaaaaaa-0000-4000-8000-000000000002'; other = 'aaaaaaaa-0000-4000-8000-000000000003' }
        # The health script runs as its own script, where $script: in a mock's body is that script's scope: the VM ID goes in
        # the body itself.
        $body = if ($Current) { [scriptblock]::Create(('[pscustomobject]@{{ Name = ''arcsql01''; State = ''Running''; VMId = [guid]''{0}'' }}' -f $ids[$Current])) } else { { } }
        Mock -CommandName Get-VM -MockWith $body
        $root = Join-Path -Path $TestDrive -ChildPath ('health-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'health.json'), (ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 1; state = 'InProgress'; currentStep = 'ArcOnboarding'; message = 'Onboarding.' }) -Depth 4))
        $rebuild = [ordered]@{ schemaVersion = 1; state = $State; startedUtc = '2026-11-09T10:00:00Z'; removedUtc = '2026-11-09T10:01:00Z'; oldMode = 'PaygWizard'; oldGuestVmId = $ids['old']; arcResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/arcsql01'; removed = @('the guest VM arcsql01') }
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'guest-rebuild.json'), (ConvertTo-Json -InputObject $rebuild -Depth 6))
        if ($Marker) {
            $content = [ordered]@{ schemaVersion = 1; machineName = 'arcsql01'; status = 'Connected'; resourceId = $rebuild.arcResourceId; connectedUtc = '2026-11-09T11:00:00Z' }
            if ($MarkerVmId) {
                $content['guestVmId'] = $ids[$MarkerVmId]
            }
            [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'arc-onboarded.json'), (ConvertTo-Json -InputObject $content -Depth 4))
        }
        $summary = (& (Join-Path -Path $repoRoot -ChildPath 'vm/health/Get-DemoHealth.ps1') -Root $root -View Summary) | ConvertFrom-Json
        $summary.guestRebuild | Should -Be $State
        if ($null -eq $Expected) {
            $summary.rebuildArcNew | Should -BeNullOrEmpty -Because 'deploy.ps1 deletes nothing in Azure when the host can''t tell'
        }
        else {
            $summary.rebuildArcNew | Should -Be $Expected
        }
    }

    It 'leaves the rebuild out of the summary when there''s none' {
        $root = Join-Path -Path $TestDrive -ChildPath ('health-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'health.json'), (ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 1; state = 'Ready'; currentStep = ''; message = 'Every step is in the desired state.' }) -Depth 4))
        $summary = (& (Join-Path -Path $repoRoot -ChildPath 'vm/health/Get-DemoHealth.ps1') -Root $root -View Summary) | ConvertFrom-Json
        $summary.guestRebuild | Should -BeNullOrEmpty
        $summary.rebuildArcNew | Should -BeNullOrEmpty
    }
}

Describe 'The end of a rebuild (review of 849d4c2, 2026-11-09)' {
    BeforeEach {
        $script:context = New-TestHostContext
        $script:ids = @{ old = 'aaaaaaaa-0000-4000-8000-000000000001'; new = 'aaaaaaaa-0000-4000-8000-000000000002' }
        $script:currentVmId = $script:ids['new']
        Mock -CommandName Get-VM -MockWith { if ($script:currentVmId) { [pscustomobject]@{ Name = 'arcsql01'; State = 'Running'; VMId = [guid]$script:currentVmId } } }
        $script:writeRecord = {
            param([string] $State)
            Write-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context) -InputObject ([ordered]@{ schemaVersion = 1; state = $State; reason = 'r'; startedUtc = '2026-11-09T10:00:00Z'; removedUtc = '2026-11-09T10:01:00Z'; oldMode = 'PaygWizard'; oldGuestVmId = $script:ids['old']; arcResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/arcsql01'; removed = @('the guest VM arcsql01') })
        }
        $script:writeMarker = {
            param([string] $Status, [string] $GuestVmId)
            $marker = [ordered]@{ schemaVersion = 1; machineName = 'arcsql01'; status = $Status; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/arcsql01'; connectedUtc = '2026-11-09T11:00:00Z' }
            if ($GuestVmId) {
                $marker['guestVmId'] = $GuestVmId
            }
            Write-DemoVmJsonFile -Path $script:context.ArcMarkerPath -InputObject $marker
        }
    }

    It 'marks the rebuild Done once a new guest passed ArcOnboarding, and keeps the rest of its record' {
        & $script:writeRecord 'Removed'
        & $script:writeMarker 'Connected' $script:ids['new']
        Complete-DemoHostGuestRebuild -Context $script:context -Confirm:$false
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context)
        $record['state'] | Should -Be 'Done'
        $record['newGuestVmId'] | Should -Be $script:ids['new']
        $record['doneUtc'] | Should -Not -BeNullOrEmpty
        $record['oldGuestVmId'] | Should -Be $script:ids['old']
        @($record['removed']) | Should -Contain 'the guest VM arcsql01'
        $detail = Get-DemoHostGuestRebuildDetail -Context $script:context
        $detail.state | Should -Be 'Done'
        $detail.doneUtc | Should -Not -BeNullOrEmpty
    }

    It 'leaves the record as it is when <Case>' -ForEach @(
        @{ Case = 'the deletion isn''t finished'; State = 'Removing'; Marker = 'Connected'; MarkerVmId = 'new'; Current = 'new' }
        @{ Case = 'the new guest isn''t onboarded yet'; State = 'Removed'; Marker = ''; MarkerVmId = ''; Current = 'new' }
        @{ Case = 'the Arc marker is the old guest''s'; State = 'Removed'; Marker = 'Connected'; MarkerVmId = 'old'; Current = 'new' }
        @{ Case = 'the Arc marker names no guest'; State = 'Removed'; Marker = 'Connected'; MarkerVmId = ''; Current = 'new' }
        @{ Case = 'the Arc marker isn''t Connected'; State = 'Removed'; Marker = 'Pending'; MarkerVmId = 'new'; Current = 'new' }
        @{ Case = 'the guest is still the old one'; State = 'Removed'; Marker = 'Connected'; MarkerVmId = 'old'; Current = 'old' }
        @{ Case = 'there''s no guest'; State = 'Removed'; Marker = 'Connected'; MarkerVmId = 'new'; Current = '' }
        @{ Case = 'it''s Done already'; State = 'Done'; Marker = 'Connected'; MarkerVmId = 'new'; Current = 'new' }
    ) {
        $script:currentVmId = if ($Current) { $script:ids[$Current] } else { '' }
        & $script:writeRecord $State
        if ($Marker) {
            & $script:writeMarker $Marker $(if ($MarkerVmId) { $script:ids[$MarkerVmId] } else { '' })
        }
        Complete-DemoHostGuestRebuild -Context $script:context -Confirm:$false
        $record = Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context)
        $record['state'] | Should -Be $State
        $record.Contains('newGuestVmId') | Should -BeFalse
        $record.Contains('doneUtc') | Should -BeFalse
    }

    It 'changes nothing without a record, and never throws' {
        & $script:writeMarker 'Connected' $script:ids['new']
        Complete-DemoHostGuestRebuild -Context $script:context -Confirm:$false
        Test-Path -LiteralPath (Get-DemoHostGuestRebuildPath -Context $script:context) | Should -BeFalse
        & $script:writeRecord 'Removed'
        Mock -CommandName Get-VM -MockWith { throw 'Hyper-V isn''t answering.' }
        { Complete-DemoHostGuestRebuild -Context $script:context -Confirm:$false } | Should -Not -Throw
        (Read-DemoVmJsonFile -Path (Get-DemoHostGuestRebuildPath -Context $script:context))['state'] | Should -Be 'Removed'
    }
}

Describe 'The guided stop''s cleanup outside PaygWizard mode (review of 849d4c2, 2026-11-09)' {
    It 'finds what an earlier guided stop left on the host: <Case>' -ForEach @(
        @{ Case = 'nothing'; Files = @(); Source = 'Build'; Expected = $false }
        @{ Case = 'the armed automatic sign-in'; Files = @('HostArmed'); Source = 'Build'; Expected = $true }
        @{ Case = 'setup''s prepared sign-in'; Files = @('HostSignIn'); Source = 'Build'; Expected = $true }
        @{ Case = 'a stopped rotation of a built guest''s password'; Files = @('Pending'); Source = 'Build'; Expected = $true }
        @{ Case = 'a stopped rotation, without a source record'; Files = @('Pending'); Source = ''; Expected = $true }
        @{ Case = 'a stopped rotation in a guest made from the image, whose first boot resolves it'; Files = @('Pending'); Source = 'JumpstartImage'; Expected = $false }
        @{ Case = 'the armed sign-in, whatever made the guest'; Files = @('HostArmed'); Source = 'JumpstartImage'; Expected = $true }
    ) {
        $record = if ($Source) { [ordered]@{ source = $Source; installMode = $(if ($Source -eq 'JumpstartImage') { 'JumpstartImage' } else { 'PaygWizard' }); recordedUtc = '2026-10-30T10:00:00Z' } } else { $null }
        $context = New-TestHostContext -GuestSource $record
        $guided = Get-DemoGuidedSetupPath -Root $context.Root
        foreach ($file in $Files) {
            New-TestFile -Path $(if ($file -eq 'Pending') { $context.SecretPath + '.pending' } else { $guided.$file })
        }
        Test-DemoHostGuidedSetupLeftover -Context $context | Should -Be $Expected
    }

    It 'says false, and never throws, when it can''t check' {
        $context = New-TestHostContext
        Mock -CommandName Get-DemoGuidedSetupPath -MockWith { throw 'The disk is busy.' }
        Test-DemoHostGuidedSetupLeftover -Context $context | Should -BeFalse
    }

    It 'runs the guard before the pass in <Mode> mode when <Case>, and the rebuild''s end after it' -ForEach @(
        @{ Mode = 'JumpstartImage'; Leftover = $true; Case = 'an earlier guided stop left something'; Expected = 'guard,pass,rebuild,unlock' }
        @{ Mode = 'JumpstartImage'; Leftover = $false; Case = 'nothing is left'; Expected = 'pass,rebuild,unlock' }
        @{ Mode = 'PaygWizard'; Leftover = $false; Case = 'it keeps a finished wizard guest'; Expected = 'guard,pass,rebuild,unlock' }
    ) {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:mode = $Mode
        $script:leftover = $Leftover
        $root = Join-Path -Path $TestDrive -ChildPath ('pass-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Initialize-DemoVmContext -MockWith { }
        $script:lockPath = Join-Path -Path $TestDrive -ChildPath ('lock-' + [guid]::NewGuid().ToString('N'))
        Mock -CommandName Enter-DemoVmLock -MockWith { [System.IO.File]::Open($script:lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        Mock -CommandName Exit-DemoVmLock -MockWith { $Lock.Dispose(); $script:calls.Add('unlock') }
        Mock -CommandName Get-DemoVmSetting -MockWith { [ordered]@{ generation = 'g1' } }
        Mock -CommandName Get-DemoHostContext -MockWith { [ordered]@{ Mode = $script:mode; Root = 'unused' } }
        Mock -CommandName Copy-Item -MockWith { }
        Mock -CommandName Get-DemoHostStepPlan -MockWith { ,@([ordered]@{ Name = 'GuestSource' }) }
        Mock -CommandName Test-DemoHostGuidedSetupLeftover -MockWith { $script:leftover }
        Mock -CommandName Invoke-DemoHostGuidedSetupGuard -MockWith { $script:calls.Add('guard') }
        Mock -CommandName Invoke-DemoVmStateMachine -MockWith { $script:calls.Add('pass'); 'InProgress' }
        Mock -CommandName Complete-DemoHostGuestRebuild -MockWith { $script:calls.Add('rebuild') }
        Mock -CommandName Invoke-DemoHostEvaluationGuard -MockWith { $script:calls.Add('evaluation') }
        Invoke-DemoHostBootstrap -StateRoot $root -BundleRoot $repoRoot | Should -Be 'InProgress'
        ($script:calls -join ',') | Should -Be $Expected
    }
}