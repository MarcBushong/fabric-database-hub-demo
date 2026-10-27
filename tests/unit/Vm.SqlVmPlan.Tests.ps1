BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the T1 bootstrap's functions (and imports DbHubDemo.Vm) without running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-SqlVmBootstrap.ps1')

    function New-TestSqlVmContext {
        param([string] $DataDiskTier = '')
        $root = Join-Path -Path $TestDrive -ChildPath ('sqlvm-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'SqlVm' -BundleRoot $repoRoot | Out-Null
        $settings = [ordered]@{ role = 'SqlVm'; seedScale = 1 }
        if ($DataDiskTier) {
            $settings['dataDiskTier'] = $DataDiskTier
        }
        Get-DemoSqlVmContext -BundleRoot $repoRoot -Settings $settings
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'T1 data disk' {
    BeforeEach {
        Mock -CommandName Invoke-DemoVmSql -MockWith {
            [pscustomobject]@{ data_path = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\'; log_path = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\' }
        }
    }

    It 'marks the DataDisk step Not selected without a data disk' {
        $context = New-TestSqlVmContext -DataDiskTier 'None'
        Mock -CommandName Test-DemoSqlVmDataDisk -MockWith { throw 'There is no data disk to check.' }
        Mock -CommandName Initialize-DemoSqlVmDataDisk -MockWith { throw 'There is no data disk to format.' }
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
        $plan = @(Get-DemoSqlVmStepPlan -Context $context)
        $plan[0].Name | Should -Be 'DataDisk'

        Invoke-DemoVmStateMachine -Step @($plan[0]) -Generation 'g1' | Should -Be 'Ready'

        $step = (Get-DemoVmState)['steps']['DataDisk']
        $step['status'] | Should -Be 'NotSelected'
        $step['message'] | Should -Match 'default data and log folders on the OS disk'
        Should -Invoke -CommandName Test-DemoSqlVmDataDisk -Times 0
        Should -Invoke -CommandName Initialize-DemoSqlVmDataDisk -Times 0
    }

    It 'creates ContosoCare in SQL Server''s default folders when there is no data disk' {
        $context = New-TestSqlVmContext -DataDiskTier 'None'
        Mock -CommandName Get-DemoVmDataVolume -MockWith { throw 'There is no data disk to look for.' }
        Mock -CommandName Invoke-DemoVmSqlScript -MockWith { }

        $folders = Get-DemoSqlVmFolder -Context $context
        $folders.Data | Should -Be 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'
        $folders.Log | Should -Be 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'

        Initialize-DemoSqlVmDatabase -Context $context
        Should -Invoke -CommandName Invoke-DemoVmSqlScript -Times 1 -Exactly -ParameterFilter {
            $Path -like '*000-create-database.sql' -and $Token['DATA_DIRECTORY'] -eq 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'
        }
        Should -Invoke -CommandName Get-DemoVmDataVolume -Times 0
    }

    It 'uses the folders on the data disk when the profile has one' {
        $context = New-TestSqlVmContext -DataDiskTier 'E10'
        Mock -CommandName Get-DemoVmDataVolume -MockWith { [pscustomobject]@{ DriveLetter = 'F'; FileSystemLabel = 'DbHubSqlData' } }
        $folders = Get-DemoSqlVmFolder -Context $context
        $folders.Data | Should -Be 'F:\SQLData'
        $folders.Log | Should -Be 'F:\SQLLog'
        Should -Invoke -CommandName Invoke-DemoVmSql -Times 0
    }

    It 'treats a missing tier as a data disk, as before the lowest-cost change' {
        Test-DemoSqlVmHasDataDisk -Context (New-TestSqlVmContext) | Should -BeTrue
        Test-DemoSqlVmHasDataDisk -Context (New-TestSqlVmContext -DataDiskTier 'None') | Should -BeFalse
    }
}

Describe 'T1 associated services (Analysis Services and Integration Services)' {
    BeforeEach {
        $script:services = [ordered]@{
            MSSQLServerOLAPService = @{ Status = 'Stopped'; StartType = 'Manual' }
            MsDtsServer160         = @{ Status = 'Running'; StartType = 'Automatic' }
            SSASTELEMETRY          = @{ Status = 'Running'; StartType = 'Automatic' }
            SSISTELEMETRY160       = @{ Status = 'Running'; StartType = 'Automatic' }
        }
        $script:uninstallExit = 0
        Mock -CommandName Get-DemoSqlVmAssociatedService -MockWith {
            @($script:services.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Status = $script:services[$_].Status; StartType = $script:services[$_].StartType } })
        }
        Mock -CommandName Disable-DemoSqlVmService -MockWith {
            $script:services[$Service.Name] = @{ Status = 'Stopped'; StartType = 'Disabled' }
        }
        Mock -CommandName Invoke-DemoSqlVmFeatureUninstall -MockWith {
            if ($script:uninstallExit -in 0, 3010) {
                $script:services.Clear()
            }
            $script:uninstallExit
        }
        Mock -CommandName Get-DemoSqlVmSetupFinalResult -MockWith { if ($script:uninstallExit -in 0, 3010) { 'Passed' } else { 'Failed: see details below' } }
        Mock -CommandName Test-Path -ParameterFilter { $LiteralPath -eq 'C:\SQLServerFull\setup.exe' } -MockWith { $true }
        Mock -ModuleName DbHubDemo.Vm -CommandName Invoke-DemoVmRestart -MockWith { }
        $script:agentRestarts = 0
        Mock -CommandName Restart-DemoSqlVmIaasAgent -MockWith {
            $script:agentRestarts++
            Set-Content -LiteralPath (Join-Path -Path $Context.Root -ChildPath $Context.Config.AssociatedServices.InventoryMarker) -Value '{}'
        }
    }

    It 'runs right after SqlService, before any database work' {
        $names = @(Get-DemoSqlVmStepPlan -Context (New-TestSqlVmContext -DataDiskTier 'None')).Name
        $names | Should -Be @('DataDisk', 'SqlService', 'AssociatedServices', 'SqlAdminAccess', 'ConfigureSql', 'SeedDatabase', 'WorkloadRunner')
    }

    It 'reads its settings from vm/dsc/sqlvm.psd1' {
        $settings = (New-TestSqlVmContext).Config.AssociatedServices
        $settings.ServiceNames | Should -Be @('MSSQLServerOLAPService', 'MsDtsServer160', 'SSASTELEMETRY', 'SSISTELEMETRY160')
        $settings.Uninstall | Should -BeTrue
        $settings.Features | Should -Be 'AS,IS'
        $settings.InstanceName | Should -Be 'MSSQLSERVER'
        $settings.AgentServiceName | Should -Be 'SQLIaaSExtension'
        $settings.InventoryMarker | Should -Be 'associated-services.json'
    }

    It 'passes its check only when every service is gone or stopped and disabled' {
        $context = New-TestSqlVmContext
        Test-DemoSqlVmAssociatedServiceState -Context $context | Should -BeFalse
        foreach ($name in @($script:services.Keys)) {
            $script:services[$name] = @{ Status = 'Stopped'; StartType = 'Disabled' }
        }
        Test-DemoSqlVmAssociatedServiceState -Context $context | Should -BeTrue
        $script:services.Clear()
        Test-DemoSqlVmAssociatedServiceState -Context $context | Should -BeTrue
    }

    It 'disables every service, uninstalls the features, restarts the SQL IaaS Agent, and converges without a warning' {
        $context = New-TestSqlVmContext
        $step = @(Get-DemoSqlVmStepPlan -Context $context | Where-Object Name -eq 'AssociatedServices')
        Invoke-DemoVmStateMachine -Step $step -Generation 'g1' | Should -Be 'Ready'

        (Get-DemoVmState)['steps']['AssociatedServices']['status'] | Should -Be 'Succeeded'
        Should -Invoke -CommandName Disable-DemoSqlVmService -Times 4 -Exactly
        Should -Invoke -CommandName Invoke-DemoSqlVmFeatureUninstall -Times 1 -Exactly -ParameterFilter { $Settings.Features -eq 'AS,IS' -and $Settings.InstanceName -eq 'MSSQLSERVER' }
        $script:agentRestarts | Should -Be 1
        @((Get-DemoVmState)['warnings'] | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'converges a VM whose features an earlier run removed without restarting the agent (live, 2026-10-22)' {
        # deploy.ps1's parallel path has no second template deployment to restart the agent, so inventory kept
        # listing Analysis Services and Integration Services for 46 minutes after a clean uninstall.
        $script:services.Clear()
        $context = New-TestSqlVmContext
        $step = @(Get-DemoSqlVmStepPlan -Context $context | Where-Object Name -eq 'AssociatedServices')
        Test-DemoSqlVmInventoryRefreshed -Context $context | Should -BeFalse
        Invoke-DemoVmStateMachine -Step $step -Generation 'g2' | Should -Be 'Ready'

        (Get-DemoVmState)['steps']['AssociatedServices']['status'] | Should -Be 'Succeeded'
        $script:agentRestarts | Should -Be 1
        Test-DemoSqlVmInventoryRefreshed -Context $context | Should -BeTrue
        Should -Invoke -CommandName Invoke-DemoSqlVmFeatureUninstall -Times 0
    }

    It 'keeps the services disabled and only warns when the uninstall fails' {
        $script:uninstallExit = 1
        $context = New-TestSqlVmContext
        $step = @(Get-DemoSqlVmStepPlan -Context $context | Where-Object Name -eq 'AssociatedServices')
        Invoke-DemoVmStateMachine -Step $step -Generation 'g1' | Should -Be 'Ready'

        (Get-DemoVmState)['steps']['AssociatedServices']['status'] | Should -Be 'Succeeded'
        (@((Get-DemoVmState)['warnings']) -join ' ') | Should -Match 'didn''t pass \(exit code 1'
        @($script:services.Values | Where-Object { $_.StartType -ne 'Disabled' -or $_.Status -ne 'Stopped' }).Count | Should -Be 0
        $script:agentRestarts | Should -Be 0
    }

    It 'warns without trying to uninstall when the image has no setup media' {
        Mock -CommandName Test-Path -ParameterFilter { $LiteralPath -eq 'C:\SQLServerFull\setup.exe' } -MockWith { $false }
        $result = Disable-DemoSqlVmAssociatedService -Context (New-TestSqlVmContext)
        $result.WarningMessage | Should -Match 'no SQL Server setup media'
        Should -Invoke -CommandName Invoke-DemoSqlVmFeatureUninstall -Times 0
    }

    It 'only makes sure inventory saw the features go once they''re gone, and then does nothing more' {
        $script:services.Clear()
        $context = New-TestSqlVmContext
        Disable-DemoSqlVmAssociatedService -Context $context | Should -BeNullOrEmpty
        $script:agentRestarts | Should -Be 1
        Disable-DemoSqlVmAssociatedService -Context $context | Should -BeNullOrEmpty
        $script:agentRestarts | Should -Be 1
        Should -Invoke -CommandName Disable-DemoSqlVmService -Times 0
        Should -Invoke -CommandName Invoke-DemoSqlVmFeatureUninstall -Times 0
    }

    It 'needs no agent restart while the features are installed or the uninstall is turned off' {
        $context = New-TestSqlVmContext
        Test-DemoSqlVmInventoryRefreshed -Context $context | Should -BeTrue
        $script:services.Clear()
        Test-DemoSqlVmInventoryRefreshed -Context $context | Should -BeFalse
        $context.Config.AssociatedServices.Uninstall = $false
        Test-DemoSqlVmInventoryRefreshed -Context $context | Should -BeTrue
    }
}

Describe 'Restart-DemoSqlVmIaasAgent' {
    BeforeAll {
        # The service cmdlets exist only on Windows. Elsewhere, or where another test file left a narrower stub (CI on
        # Linux: a Restart-Service stub without -Force), stubs with the parameters the bootstrap uses are defined
        # before they're mocked, and the earlier definitions come back afterwards.
        $script:previousServiceStubs = @{}
        foreach ($stub in @(
                @{ Name = 'Get-Service'; Parameters = 'param([string] $Name)' },
                @{ Name = 'Restart-Service'; Parameters = 'param([string] $Name, [switch] $Force)' })) {
            $existing = Get-Command -Name $stub.Name -ErrorAction SilentlyContinue
            if ($null -eq $existing -or $existing.CommandType -eq 'Function') {
                $script:previousServiceStubs[$stub.Name] = if ($null -ne $existing) { $existing.ScriptBlock } else { $null }
                Set-Item -Path ('function:global:' + $stub.Name) -Value ([scriptblock]::Create('[CmdletBinding()] ' + $stub.Parameters))
            }
        }
    }

    AfterAll {
        foreach ($name in $script:previousServiceStubs.Keys) {
            if ($null -ne $script:previousServiceStubs[$name]) {
                Set-Item -Path ('function:global:' + $name) -Value $script:previousServiceStubs[$name]
            }
            else {
                Remove-Item -Path ('function:global:' + $name) -ErrorAction SilentlyContinue
            }
        }
    }

    BeforeEach {
        $script:context = New-TestSqlVmContext
        $script:marker = Join-Path -Path $script:context.Root -ChildPath 'associated-services.json'
        Mock -CommandName Restart-Service -MockWith { }
    }

    It 'restarts the running agent service and records it' {
        Mock -CommandName Get-Service -ParameterFilter { $Name -eq 'SQLIaaSExtension' } -MockWith { [pscustomobject]@{ Name = 'SQLIaaSExtension'; Status = 'Running' } }
        Restart-DemoSqlVmIaasAgent -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Restart-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SQLIaaSExtension' }
        ([System.IO.File]::ReadAllText($script:marker) | ConvertFrom-Json).action | Should -Be 'Restarted'
    }

    It 'leaves an agent service that isn''t running alone, and records it' {
        Mock -CommandName Get-Service -ParameterFilter { $Name -eq 'SQLIaaSExtension' } -MockWith { [pscustomobject]@{ Name = 'SQLIaaSExtension'; Status = 'Stopped' } }
        Restart-DemoSqlVmIaasAgent -Context $script:context | Should -BeNullOrEmpty
        Should -Invoke -CommandName Restart-Service -Times 0
        ([System.IO.File]::ReadAllText($script:marker) | ConvertFrom-Json).action | Should -Be 'NotRunning'
    }

    It 'only warns, and still records the attempt, when the restart fails' {
        Mock -CommandName Get-Service -ParameterFilter { $Name -eq 'SQLIaaSExtension' } -MockWith { [pscustomobject]@{ Name = 'SQLIaaSExtension'; Status = 'Running' } }
        Mock -CommandName Restart-Service -MockWith { throw 'Service cannot be stopped.' }
        Restart-DemoSqlVmIaasAgent -Context $script:context | Should -Match 'couldn''t be restarted'
        ([System.IO.File]::ReadAllText($script:marker) | ConvertFrom-Json).action | Should -Be 'Failed'
    }
}

Describe 'SQL Server setup summary' {
    It 'reads the final result from setup''s summary' {
        $summary = Join-Path -Path $TestDrive -ChildPath 'Summary.txt'
        Set-Content -LiteralPath $summary -Value @('Overall summary:', '  Final result:                  Passed', '  Exit code (Decimal):           0')
        Get-DemoSqlVmSetupFinalResult -Path $summary | Should -Be 'Passed'
        Get-DemoSqlVmSetupFinalResult -Path (Join-Path -Path $TestDrive -ChildPath 'missing.txt') | Should -Be ''
    }
}
