BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        return $config
    }

    function New-TestInventoryInstance {
        param(
            [string] $Name,
            [string] $ServiceType,
            [string] $InstanceName,
            # The live engine instance used a lowercase resourcegroups segment; the others didn't (2026-10-20).
            [string] $Container = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'
        )
        [pscustomobject]@{
            name       = $Name
            type       = 'microsoft.azurearcdata/sqlserverinstances'
            properties = [pscustomobject]@{
                serviceType         = $ServiceType
                instanceName        = $InstanceName
                edition             = 'Standard'
                version             = 'SQL Server 2022'
                patchLevel          = '16.0.4255.1'
                licenseType         = 'LicenseOnly'
                status              = 'Connected'
                containerResourceId = $Container
            }
        }
    }

    $script:vmContainer = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'
    $script:engine = New-TestInventoryInstance -Name 'sqlvm01' -ServiceType 'Engine' -InstanceName 'MSSQLSERVER'
    $script:ssas = New-TestInventoryInstance -Name 'sqlvm01_MSAS16_MSSQLSERVER' -ServiceType 'SSAS' -InstanceName 'MSAS16.MSSQLSERVER' -Container $script:vmContainer
    $script:ssis = New-TestInventoryInstance -Name 'sqlvm01_SSIS_2022' -ServiceType 'SSIS' -InstanceName '160' -Container $script:vmContainer
}

Describe 'Test-DemoSqlVmAssociatedService' {
    BeforeEach {
        $script:inventory = @()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { , @($script:inventory) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { $ArgumentList[0] -eq 'sql' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = "PAYG`n"; StdErr = '' }
        }
    }

    It 'warns while unified inventory still lists the associated services the image installs (owner decision, 2026-10-21)' {
        $script:inventory = @($script:engine, $script:ssas, $script:ssis)
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig)
        $result.checkId | Should -Be 'T1.SQLVM.ASSOCIATEDSERVICES'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'database engine for sqlvm01 \(MSSQLSERVER, Standard 16\.0\.4255\.1\)'
        $result.message | Should -Match '2 associated service\(s\)'
        $result.message | Should -Match ([regex]::Escape('SSAS (MSAS16.MSSQLSERVER), SSIS (160)'))
        $result.remediation | Should -Match 'AssociatedServices'
        $result.evidence.engineInstances | Should -Be 1
        @($result.evidence.associatedServices) | Should -Be @('SSAS (MSAS16.MSSQLSERVER)', 'SSIS (160)')
        $result.evidence.sqlVirtualMachineLicenseType | Should -Be 'PAYG'
        @($result.evidence.instances).licenseType | Should -Be @('LicenseOnly', 'LicenseOnly', 'LicenseOnly')
        $result.docUrl | Should -Match 'unified-inventory-sql-vm'
    }

    It 'passes with only the engine' {
        $script:inventory = @($script:engine)
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig)
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'only the database engine'
        @($result.evidence.associatedServices).Count | Should -Be 0
    }

    It 'warns when inventory lists associated services but no engine' {
        $script:inventory = @($script:ssas, $script:ssis)
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig)
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'no database engine instance for sqlvm01 yet \(it lists only SSAS'
        $result.remediation | Should -Match '2\.0\.226\.0'
    }

    It 'ignores instances of other VMs and of Arc machines' {
        $other = New-TestInventoryInstance -Name 'sqlvm02' -ServiceType 'Engine' -InstanceName 'MSSQLSERVER' -Container ($script:vmContainer -replace 'sqlvm01$', 'sqlvm02')
        $arc = New-TestInventoryInstance -Name 'arcsql01' -ServiceType 'Engine' -InstanceName 'MSSQLSERVER' -Container '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/sqlvm01'
        $script:inventory = @($other, $arc)
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig)
        $result.status | Should -Be 'Warning'
        $result.evidence.engineInstances | Should -Be 0
    }

    It 'warns, and doesn''t fail, when inventory can''t be read' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { throw 'Reading the collection failed: AuthorizationFailed' }
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig)
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'couldn''t be read: Reading the collection failed'
    }

    It 'records Unknown when the SQL virtual machine resource can''t be read' {
        $script:inventory = @($script:engine)
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { $ArgumentList[0] -eq 'sql' } -MockWith {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ResourceNotFound' }
        }
        (Test-DemoSqlVmAssociatedService -Config (New-TestConfig)).evidence.sqlVirtualMachineLicenseType | Should -Be 'Unknown'
    }

    It 'is reported by configure-monitoring.ps1 for T1' {
        $script = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-monitoring.ps1') -Raw
        $script | Should -Match ([regex]::Escape('$results.Add((Test-DemoSqlVmAssociatedService -Config $config))'))
    }

    It 'waits for inventory to drop the associated services, then passes (deploy.ps1''s validation)' {
        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { $script:reads++; if ($script:reads -lt 3) { , @($script:engine, $script:ssas, $script:ssis) } else { , @($script:engine) } }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig) -WaitMinutes 10 -ListedStatus 'Fail'
        $result.status | Should -Be 'Pass'
        $result.evidence.waitedMinutes | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly
    }

    It 'fails deploy.ps1''s validation when inventory still lists them after the wait (live, 2026-10-22)' {
        $script:inventory = @($script:engine, $script:ssas, $script:ssis)
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $result = Test-DemoSqlVmAssociatedService -Config (New-TestConfig) -WaitMinutes 3 -ListedStatus 'Fail'
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'still listed after 3 minute'
        $result.remediation | Should -Match 'SQL IaaS Agent'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 3 -Exactly
    }
}
