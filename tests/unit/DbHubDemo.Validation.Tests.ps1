BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    # The guard's unit-test hook (Initialize-GuardTestContext), which the Hub helpers also load.
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # The T2 golden snapshots (ADR 0018) have their own tests (DbHubDemo.Golden.Tests.ps1); here there are none.
    Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }

    function ConvertTo-TestJsonValue {
        # The shape Read-DemoValidationAzJson returns: parsed JSON, with arrays kept whole.
        param([object] $InputObject)
        ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $InputObject -Depth 20) -Depth 20 -NoEnumerate
    }

    function Get-TestAzOk([object] $Value) {
        [pscustomobject]@{ Ok = $true; Value = (ConvertTo-TestJsonValue $Value); NotFound = $false; Error = '' }
    }

    function Get-TestAzMissing {
        [pscustomobject]@{ Ok = $false; Value = $null; NotFound = $true; Error = '(ResourceNotFound) The resource was not found.' }
    }

    function Get-TestInstanceView([string] $PowerState) {
        @{ provisioningState = 'Succeeded'; instanceView = @{ statuses = @(@{ code = 'ProvisioningState/succeeded' }, @{ code = ('PowerState/{0}' -f $PowerState) }) } }
    }

    function Get-TestAzResponse {
        # A deployed environment with both VMs in the given power state. Keys are matched against the joined
        # Azure CLI arguments, in order.
        param([string] $Power = 'deallocated', [string] $HostPower = $Power)
        $prefix = 'nsg-dbhub-demo-'
        $subnet = { param($Name, $Nsg) @{ name = $Name; networkSecurityGroup = @{ id = ('/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/networkSecurityGroups/{0}{1}' -f $prefix, $Nsg) } } }
        $response = [ordered]@{}
        $response['^group show'] = Get-TestAzOk @{ name = 'rg-dbhub-demo'; tags = @{ solution = 'fabric-database-hub-demo'; environment = 'demo'; owner = 'alias'; purpose = 'customer-demo'; costCenter = 'demo'; autoShutdown = '1900 Pacific Standard Time'; deploymentId = 'abc123'; ArcSQLServerExtensionDeployment = 'PAYG' } }
        $response['^vm get-instance-view .*--name sqlvm01'] = Get-TestAzOk (Get-TestInstanceView $Power)
        $response['^vm get-instance-view .*--name archost01'] = Get-TestAzOk (Get-TestInstanceView $HostPower)
        $response['^network vnet show'] = Get-TestAzOk @{ name = 'vnet-dbhub-demo'; subnets = @((& $subnet 'snet-sqlvm' 'sqlvm'), (& $subnet 'snet-archost' 'archost'), (& $subnet 'snet-pe' 'pe'), (& $subnet 'AzureBastionSubnet' 'bastion')) }
        $response['^sql server show'] = Get-TestAzOk @{ name = 'azuresql01-abc123'; publicNetworkAccess = 'Disabled' }
        $response['^sql db show'] = Get-TestAzOk @{ name = 'ContosoCare'; status = 'Paused' }
        return $response
    }

    function Set-TestAzResponse {
        param([System.Collections.IDictionary] $Response)
        $script:TestAz = $Response
        $script:TestAzCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Read-DemoValidationAzJson -MockWith {
            $joined = $ArgumentList -join ' '
            $script:TestAzCalls.Add($joined)
            foreach ($key in $script:TestAz.Keys) {
                if ($joined -match $key) {
                    return $script:TestAz[$key]
                }
            }
            [pscustomobject]@{ Ok = $false; Value = $null; NotFound = $false; Error = ('unexpected call: {0}' -f $joined) }
        }
    }

    function New-TestContext {
        # A real validation context, built from the mocked reads.
        param([string[]] $Target = @('T1', 'T2', 'T3'))
        InModuleScope -ModuleName DbHubDemo -Parameters @{ C = (Get-HubTestConfig); T = $Target } {
            param($C, $T)
            New-DemoValidationContext -Config $C -Target $T
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoValidation (the validate.ps1 engine)' {
    BeforeEach {
        $config = Get-HubTestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Set-TestAzResponse (Get-TestAzResponse)
        $areas = @('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown')
        foreach ($name in $areas) {
            $id = 'AREA.{0}' -f $name.ToUpperInvariant()
            Mock -ModuleName DbHubDemo -CommandName ('Invoke-DemoValidation{0}' -f $name) -MockWith ([scriptblock]::Create("New-DemoResult -CheckId '$id' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'area'"))
        }
    }

    It 'stops after a failed subscription guard' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'Subscription guard: the Azure CLI context is another subscription.' }
        $results = @(Invoke-DemoValidation -Config $config)
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Fail'
        $results[0].remediation | Should -Match 'Nothing ran'
        $results[0].remediation | Should -Not -Match 'account set' -Because 'the remediation never tells users to change their default subscription'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoValidationAzJson -Times 0
    }

    It 'gives the subscription guard the configured subscription, tenant, and account (azureAccount; ADR 0011, guard update)' {
        $config['azureAccount'] = 'operator@example.com'
        $null = @(Invoke-DemoValidation -Config $config -Area Cost)
        Should -Invoke -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' -and $TenantId -eq '66666666-7777-8888-9999-000000000000' -and $Account -eq 'operator@example.com'
        }
    }

    It 'runs the areas in catalog order, whatever order -Area lists them in' {
        $results = @(Invoke-DemoValidation -Config $config -Area Teardown, T1, Preflight, Security)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'AREA.PREFLIGHT', 'AREA.T1', 'AREA.SECURITY', 'AREA.TEARDOWN')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoValidationHub -Times 0
    }

    It 'skips a target''s own area when -Target leaves it out, and passes the targets on' {
        $null = Invoke-DemoValidation -Config $config -Area T1, T2, T3, Infrastructure -Target T3
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoValidationT1 -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoValidationT2 -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoValidationT3 -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoValidationInfrastructure -Times 1 -Exactly -ParameterFilter { @($Context.Target) -join ',' -eq 'T3' -and @($Context.VmNames.Keys).Count -eq 0 }
    }

    It 'reports a missing resource group once and runs only the areas that don''t need a deployment' {
        $response = Get-TestAzResponse
        $response['^group show'] = Get-TestAzMissing
        Set-TestAzResponse $response
        $results = @(Invoke-DemoValidation -Config $config -Area T1, Hub, Cost, Teardown)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'VALIDATE.DEPLOYMENT', 'AREA.COST', 'AREA.TEARDOWN')
        ($results | Where-Object { $_.checkId -eq 'VALIDATE.DEPLOYMENT' }).status | Should -Be 'Fail'
        $withInfrastructure = @(Invoke-DemoValidation -Config $config -Area Infrastructure, T1)
        ($withInfrastructure | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'AREA.INFRASTRUCTURE')
    }

    It 'reports an area that throws as one Fail and still runs the others' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoValidationT2 -MockWith { throw 'boom' }
        $results = @(Invoke-DemoValidation -Config $config -Area T1, T2, T3)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'AREA.T1', 'VALIDATE.T2', 'AREA.T3')
        $failed = $results | Where-Object { $_.checkId -eq 'VALIDATE.T2' }
        $failed.status | Should -Be 'Fail'
        $failed.area | Should -Be 't2'
        $failed.message | Should -Match 'boom'
    }

    It 'lets the Hub area''s P4 and P5 checks replace preflight''s manual reminders' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoValidationPreflight -MockWith {
            New-DemoResult -CheckId 'PREFLIGHT.P4.HUBSETTING' -Area 'preflight' -Target 'tenant' -Status 'Manual action required' -Message 'p4'
            New-DemoResult -CheckId 'PREFLIGHT.P5.WORKSPACE' -Area 'preflight' -Target 'fabric' -Status 'Not selected' -Message 'p5'
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoValidationHub -MockWith {
            New-DemoResult -CheckId 'FABRIC.P4.HUBSETTING' -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message 'p4'
            New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'p5'
        }
        $both = @(Invoke-DemoValidation -Config $config -Area Preflight, Hub).checkId
        $both | Should -Not -Contain 'PREFLIGHT.P4.HUBSETTING'
        $both | Should -Not -Contain 'PREFLIGHT.P5.WORKSPACE'
        @(Invoke-DemoValidation -Config $config -Area Preflight).checkId | Should -Contain 'PREFLIGHT.P4.HUBSETTING'
    }

    It 'turns T3''s failures into Warnings while T3 is removed between demos' {
        $response = Get-TestAzResponse
        $response['^sql server show'] = Get-TestAzMissing
        Set-TestAzResponse $response
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoValidationT3 -MockWith { New-DemoResult -CheckId 'T3.EXISTS' -Area 't3' -Target 'T3' -Status 'Fail' -Message 'T3''s logical server azuresql01-abc123 wasn''t found.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoValidationTelemetry -MockWith { New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'no rows' }
        $results = @(Invoke-DemoValidation -Config $config -Area T3, Telemetry)
        $t3 = $results | Where-Object { $_.checkId -eq 'T3.EXISTS' }
        $t3.status | Should -Be 'Warning'
        $t3.message | Should -Match 'stop-demo\.ps1 -RemoveT3'
        ($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be 'Fail'
    }
}

Describe 'Stopped VMs are expected (validation areas)' {
    BeforeEach {
        $config = Get-HubTestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoBootstrapLoader -MockWith { New-DemoResult -CheckId ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target 'T1' -Status 'Pass' -Message 'loader' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { throw 'should not run' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith { throw 'should not run' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith { throw 'should not run' }
    }

    It 'gives every check that needs a deallocated VM a Warning with the start command, and never runs a Run Command' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'deallocated')
        $context = New-TestContext
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationInfrastructure -Context $X; Invoke-DemoValidationWorkload -Context $X })
        $vmChecks = @($results | Where-Object { $_.checkId -like 'INFRA.VM.*' -or $_.checkId -like 'INFRA.BOOTSTRAP.*' -or $_.checkId -like 'INFRA.HEALTH.*' -or $_.checkId -like 'INFRA.GUEST.*' -or $_.checkId -like 'WORKLOAD.*' })
        $vmChecks.Count | Should -Be 10
        @($vmChecks | Where-Object { $_.status -ne 'Warning' }).Count | Should -Be 0
        ($results | Where-Object { $_.checkId -eq 'INFRA.HEALTH.SQLVM01' }).message | Should -Match 'sqlvm01 is deallocated'
        ($results | Where-Object { $_.checkId -eq 'WORKLOAD.T2.COMMAND' }).remediation | Should -Match 'az vm start --resource-group rg-dbhub-demo --name archost01 --subscription 11111111-2222-3333-4444-555555555555'
        ($results | Where-Object { $_.checkId -eq 'INFRA.NETWORK' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'INFRA.RESOURCEGROUP' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoBootstrapLoader -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 0
    }

    It 'fails a VM that doesn''t exist, and says when a VM is stopped but still billing' {
        Set-TestAzResponse (Get-TestAzResponse)
        $context = New-TestContext
        InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } {
            param($X)
            $missing = New-DemoValidationStoppedResult -CheckId 'INFRA.VM.SQLVM01' -Area 'infra' -Target 'T1' -VmState ([pscustomobject]@{ Name = 'sqlvm01'; PowerState = 'not found'; Error = '' }) -Context $X -Checks 'the checks'
            $missing.status | Should -Be 'Fail'
            $stopped = New-DemoValidationStoppedResult -CheckId 'INFRA.VM.SQLVM01' -Area 'infra' -Target 'T1' -VmState ([pscustomobject]@{ Name = 'sqlvm01'; PowerState = 'stopped'; Error = '' }) -Context $X -Checks 'the checks'
            $stopped.status | Should -Be 'Warning'
            $stopped.message | Should -Match 'still bills'
            $starting = New-DemoValidationStoppedResult -CheckId 'INFRA.VM.SQLVM01' -Area 'infra' -Target 'T1' -VmState ([pscustomobject]@{ Name = 'sqlvm01'; PowerState = 'starting'; Error = '' }) -Context $X -Checks 'the checks'
            $starting.status | Should -Be 'Warning'
            $starting.remediation | Should -Match 'few minutes'
        }
    }

    It 'reads the loader, health.json, and the nested guest once the VMs run' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            if ($VmName -eq 'archost01') {
                [pscustomobject]@{ role = 'host'; state = 'ManualActionRequired'; status = 'Manual action required'; message = 'Run the SQL Server setup wizard.'; currentStep = 'SqlSetupWizard'; guestState = 'Running' }
            }
            else {
                [pscustomobject]@{ role = 'sqlvm'; state = 'Ready'; status = 'Pass'; message = 'Ready.'; currentStep = '' }
            }
        }
        $context = New-TestContext
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationInfrastructure -Context $X })
        ($results | Where-Object { $_.checkId -eq 'INFRA.VM.SQLVM01' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'INFRA.HEALTH.SQLVM01' }).status | Should -Be 'Pass'
        $hostHealth = $results | Where-Object { $_.checkId -eq 'INFRA.HEALTH.ARCHOST01' }
        $hostHealth.status | Should -Be 'Manual action required'
        $hostHealth.message | Should -Match 'SqlSetupWizard'
        ($results | Where-Object { $_.checkId -eq 'INFRA.GUEST.ARCSQL01' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoBootstrapLoader -Times 2 -Exactly -ParameterFilter { $TimeoutSeconds -eq 30 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 2 -Exactly
    }

    It 'passes a loader that deploy.ps1''s parallel tracks ran and removed, when health.json names the recorded bundle (live, 2026-10-22)' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoBootstrapLoader -MockWith { New-DemoResult -CheckId ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target 'T1' -Status 'Fail' -Message ('{0} has no bootstrap loader Run Command (DbHubDemo-Bootstrap): ERROR: Not Found' -f $VmName) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ role = 'sqlvm'; state = 'Ready'; status = 'Pass'; message = 'Ready.'; currentStep = ''; generation = $script:generation } }
        $context = New-TestContext -Target T1
        $context.Tags['DbHubBundleSha256'] = 'abcdefabcdef' + ('0' * 52)
        $script:generation = 'abcdefabcdef-20261022161828'
        $loader = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationInfrastructure -Context $X }) | Where-Object { $_.checkId -eq 'INFRA.BOOTSTRAP.LOADER_SQLVM01' }
        $loader.status | Should -Be 'Pass'
        $loader.message | Should -Match 'runs the recorded bootstrap bundle abcdefabcdef'

        $script:generation = '123456789012-20261022161828'
        $fresh = New-TestContext -Target T1
        $fresh.Tags['DbHubBundleSha256'] = 'abcdefabcdef' + ('0' * 52)
        $other = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $fresh } { param($X) Invoke-DemoValidationInfrastructure -Context $X }) | Where-Object { $_.checkId -eq 'INFRA.BOOTSTRAP.LOADER_SQLVM01' }
        $other.status | Should -Be 'Fail'
    }

    It 'warns, with the extension-update finding, when health.json can''t be read' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { throw 'Reading health.json on sqlvm01 failed (execution state Pending, exit code ).' }
        $context = New-TestContext -Target T1
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationInfrastructure -Context $X })
        $health = $results | Where-Object { $_.checkId -eq 'INFRA.HEALTH.SQLVM01' }
        $health.status | Should -Be 'Warning'
        $health.message | Should -Match 'MDE\.Windows'
    }

    It 'names a stale Run Command result (Phase 7), not an extension update, when health.json or the isolation probe can''t be read' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        $staleError = 'The Run Command reported an earlier run with the same name instead of running the script.'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { throw ('Reading health.json on {0} failed (execution state Succeeded, exit code 0): {1}' -f $VmName, $staleError) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ VmName = $VmName; RunCommandName = $RunCommandName; Succeeded = $false; ExecutionState = 'Succeeded'; ExitCode = 0; Output = ''; Error = $staleError; Stale = $true; Removed = $true }
        }
        $context = New-TestContext -Target T1, T2
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationInfrastructure -Context $X; Invoke-DemoValidationT2 -Context $X })
        foreach ($id in 'INFRA.HEALTH.SQLVM01', 'INFRA.HEALTH.ARCHOST01', 'T2.GUEST.ISOLATION') {
            $result = $results | Where-Object { $_.checkId -eq $id }
            $result.status | Should -Be 'Warning' -Because $id
            $result.message | Should -Match 'tried twice, a minute apart' -Because $id
            $result.message | Should -Not -Match 'MDE\.Windows' -Because $id
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $RunCommandName -eq 'DbHubDemo-ValidateProbe' }
    }

    It 'reads T1''s associated services from unified inventory while sqlvm01 is deallocated: a Warning while SSAS or SSIS are listed, a Pass with only the engine' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'deallocated')
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -MockWith { New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Warning' -Message 'sqlvm01 is deallocated' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { $ArgumentList[0] -eq 'sql' } -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = "PAYG`n"; StdErr = '' } }
        $instance = {
            param([string] $Name, [string] $ServiceType, [string] $InstanceName)
            [pscustomobject]@{ name = $Name; properties = [pscustomobject]@{ serviceType = $ServiceType; instanceName = $InstanceName; edition = 'Standard'; version = 'SQL Server 2022'; patchLevel = '16.0.4255.1'; licenseType = 'LicenseOnly'; status = 'Connected' } }
        }
        $engine = & $instance 'sqlvm01' 'Engine' 'MSSQLSERVER'
        $script:TestInventory = @($engine, (& $instance 'sqlvm01_MSAS16_MSSQLSERVER' 'SSAS' 'MSAS16.MSSQLSERVER'), (& $instance 'sqlvm01_SSIS_2022' 'SSIS' '160'))
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmInventoryInstance -MockWith { $script:TestInventory }
        $context = New-TestContext -Target T1
        $before = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationT1 -Context $X })
        ($before | ForEach-Object { $_.checkId }) | Should -Be @('T1.SQLVM.MONITORING', 'T1.SQLVM.ASSOCIATEDSERVICES')
        $listed = $before | Where-Object { $_.checkId -eq 'T1.SQLVM.ASSOCIATEDSERVICES' }
        $listed.status | Should -Be 'Warning'
        $listed.message | Should -Match ([regex]::Escape('SSAS (MSAS16.MSSQLSERVER), SSIS (160)'))
        $listed.remediation | Should -Match 'AssociatedServices'
        $script:TestInventory = @($engine)
        $after = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationT1 -Context $X }) | Where-Object { $_.checkId -eq 'T1.SQLVM.ASSOCIATEDSERVICES' }
        $after.status | Should -Be 'Pass'
        $after.message | Should -Match 'only the database engine for sqlvm01'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0
    }

    It 'reports T2''s runner as the pending setup-wizard step, and checks T1''s runner and its bounds' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ state = 'ManualActionRequired'; status = 'Manual action required'; message = 'Run the SQL Server setup wizard.' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $deadline = [System.DateTime]::UtcNow.AddMinutes(20).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $started = [System.DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $stdout = '{"target":"T1","profile":{"name":"baseline","expiresAt":"' + $deadline + '"},"runs":[{"runId":"r1","scenario":"healthy-baseline","status":"Running","startedAt":"' + $started + '","deadlineAt":"' + $deadline + '","maxDurationSeconds":3600}],"demoSessions":[],"host":{"status":"Pass","message":"The profile host serves T1.","lane":{"state":"Serving","generation":1}}}'
            [pscustomobject]@{ Target = $Target; Status = 'Pass'; StdOut = $stdout; Result = (New-DemoResult -CheckId ('WORKLOAD.{0}.COMMAND' -f $Target) -Area 'workload' -Target $Target -Status 'Pass' -Message 'status') }
        }
        $context = New-TestContext -Target T1, T2
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationWorkload -Context $X })
        ($results | Where-Object { $_.checkId -eq 'WORKLOAD.T2.COMMAND' }).status | Should -Be 'Manual action required'
        ($results | Where-Object { $_.checkId -eq 'WORKLOAD.T1.COMMAND' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'WORKLOAD.T1.BOUNDS' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'WORKLOAD.T1.HOST' }).status | Should -Be 'Pass'
        @($results | Where-Object { $_.checkId -eq 'WORKLOAD.T2.HOST' }).Count | Should -Be 0 -Because 'T2''s runner waits for the setup-wizard step'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 1 -Exactly -ParameterFilter { $Target -eq 'T1' -and ($ArgumentList -join ' ') -eq 'status --json --runs 5' }
    }

    It 'turns T1''s missing extension version into a Warning while sqlvm01 is deallocated, and keeps real failures' {
        InModuleScope -ModuleName DbHubDemo {
            $flag = '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
            $state = [pscustomobject]@{
                VmName = 'sqlvm01'; SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroupName = 'rg-dbhub-demo'; Location = 'westus3'
                Setting = (Get-DemoArcSetting).SqlVm
                Extension = [pscustomobject]@{ provisioningState = 'Succeeded'; settings = $flag; instanceView = $null }
                Vm = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'SystemAssigned' } }
                PowerState = 'PowerState/deallocated'; SqlManagement = 'Full'
                Providers = [ordered]@{ 'Microsoft.Sql' = 'Registered'; 'Microsoft.AzureArcData' = 'Registered' }
                InventoryInstances = @()
            }
            $stopped = ConvertTo-DemoSqlVmMonitoringResult -State $state
            $stopped.status | Should -Be 'Warning'
            $stopped.message | Should -Match 'sqlvm01 is deallocated'
            $stopped.evidence.powerState | Should -Be 'PowerState/deallocated'
            (ConvertTo-DemoSqlVmMonitoringResult -State $state -PrerequisitesOnly).status | Should -Be 'Warning' -Because 'nothing may be written to a deallocated VM'
            $state.Extension.settings = $null
            (ConvertTo-DemoSqlVmMonitoringResult -State $state).status | Should -Be 'Fail' -Because 'a missing flag is a real failure in any power state'
            $state.Extension.settings = $flag
            $state.PowerState = 'PowerState/running'
            (ConvertTo-DemoSqlVmMonitoringResult -State $state).status | Should -Be 'Fail' -Because 'a running VM must report its version'
        }
    }
}

Describe 'Telemetry area' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        Set-TestAzResponse (Get-TestAzResponse -Power 'deallocated')
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith {
            New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Pass' -Message 'estate'
            New-DemoResult -CheckId 'HUB.ESTATE.T2' -Area 'hub' -Target 'T2' -Status 'Manual action required' -Message 'wizard pending'
            New-DemoResult -CheckId 'HUB.ESTATE.T3' -Area 'hub' -Target 'T3' -Status 'Pass' -Message 'estate'
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith {
            foreach ($name in 'T1', 'T2', 'T3') {
                New-DemoResult -CheckId ('TELEMETRY.{0}' -f $name) -Area 'hub' -Target $name -Status 'Fail' -Message 'no rows' -Evidence @{ rows = 0 }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith { [pscustomobject]@{ Status = 'Fail'; Reason = 'T1NotRunning'; Message = 'T1 (sqlvm01) isn''t running (deallocated).'; Rows = @() } }
        $script:gateCheck = $null
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT3Readiness -MockWith {
            $script:gateCheck = $PerformanceMonitoringCheck
            [pscustomobject]@{ Ready = $false; Results = @(New-DemoResult -CheckId 'T3.READINESS.GATE' -Area 'hub' -Target 'T3' -Status 'Warning' -Message 'gate') }
        }
    }

    It 'reads the whole retention window, and tells a quiet target and a pending manual step from a failure' {
        $context = New-TestContext
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTelemetry -Context $X })
        $t1 = $results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }
        $t1.status | Should -Be 'Warning'
        $t1.message | Should -Match 'sqlvm01 is deallocated'
        ($results | Where-Object { $_.checkId -eq 'TELEMETRY.T2' }).status | Should -Be 'Manual action required'
        $t3 = $results | Where-Object { $_.checkId -eq 'TELEMETRY.T3' }
        $t3.status | Should -Be 'Warning'
        $t3.message | Should -Match 'Paused'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -Times 1 -Exactly -ParameterFilter { $LookbackMinutes -eq 10080 }
    }

    It 'keeps a Fail when a running target sends no telemetry' {
        Set-TestAzResponse (Get-TestAzResponse -Power 'running')
        $context = New-TestContext -Target T1
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTelemetry -Context $X })
        ($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be 'Fail'
    }

    It 'gives the T3 readiness gate a property check that reports "not checked", not "not set", while T1 is deallocated' {
        $context = New-TestContext -Target T3
        $null = InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTelemetry -Context $X }
        $script:gateCheck | Should -Not -BeNullOrEmpty
        { & $script:gateCheck @{} } | Should -Throw '*isn''t running*'
        $context.Results.Add((New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Warning' -Message 'The extended property couldn''t be checked: T1 (sqlvm01) isn''t running (deallocated), so it can''t run T-SQL on T3.'))
        $null = InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTelemetry -Context $X }
        $thrown = $null
        try { & $script:gateCheck @{} } catch { $thrown = $_.Exception.Message }
        $thrown | Should -Be 'T1 (sqlvm01) isn''t running (deallocated), so it can''t run T-SQL on T3.' -Because 'Test-DemoT3Readiness adds its own prefix'
        $context.Results.Clear()
        $context.Results.Add((New-DemoResult -CheckId 'T3.PROPERTY' -Area 't3' -Target 'T3' -Status 'Pass' -Message 'set'))
        $null = InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTelemetry -Context $X }
        (& $script:gateCheck @{}).status | Should -Be 'Pass'
    }
}

Describe 'Workload bounds' {
    It 'passes bounded runs, warns on a late run or an endless profile, and fails a run beyond its maximum' {
        InModuleScope -ModuleName DbHubDemo {
            $now = [datetime]::new(2026, 10, 21, 12, 0, 0, [System.DateTimeKind]::Utc)
            $document = {
                param([string] $Expires, [string] $Started, [string] $Deadline, [int] $Maximum = 3600)
                $profileText = if ($Expires) { '"expiresAt":"{0}"' -f $Expires } else { '"expiresAt":null' }
                '{{"profile":{{"name":"baseline",{0}}},"runs":[{{"runId":"r1","scenario":"cpu-pressure","status":"Running","startedAt":"{1}","deadlineAt":"{2}","maxDurationSeconds":{3}}}],"demoSessions":[{{"sessionId":51}}]}}' -f $profileText, $Started, $Deadline, $Maximum
            }
            $pass = Test-DemoValidationWorkloadBound -Target T1 -StdOut (& $document '2026-10-21T22:58:00.000Z' '2026-10-21T11:50:00.000Z' '2026-10-21T12:20:00.000Z') -NowUtc $now
            $pass.status | Should -Be 'Pass'
            $pass.evidence.demoSessions | Should -Be 1
            (Test-DemoValidationWorkloadBound -Target T1 -StdOut (& $document '2026-10-21T22:58:00.000Z' '2026-10-21T10:00:00.000Z' '2026-10-21T10:30:00.000Z') -NowUtc $now).status | Should -Be 'Warning'
            (Test-DemoValidationWorkloadBound -Target T1 -StdOut (& $document '' '2026-10-21T11:50:00.000Z' '2026-10-21T12:20:00.000Z') -NowUtc $now).status | Should -Be 'Warning'
            (Test-DemoValidationWorkloadBound -Target T1 -StdOut (& $document '2026-10-21T22:58:00.000Z' '2026-10-21T11:50:00.000Z' '2026-10-21T14:20:00.000Z' 1800) -NowUtc $now).status | Should -Be 'Fail'
            (Test-DemoValidationWorkloadBound -Target T1 -StdOut '...truncated output' -NowUtc $now).status | Should -Be 'Warning'
        }
    }
}

Describe 'Workload host' {
    It 'takes the host lane''s status from the runner''s status, even from a tail cut by a Run Command' {
        InModuleScope -ModuleName DbHubDemo {
            $hostNode = '"host": {{ "status": "{0}", "message": "{1}", "file": "C:\\ProgramData\\DbHubDemo\\host-lanes.json", "processId": 7132, "heartbeatAgeSeconds": 4, "processAlive": true, "lane": {{ "state": "{2}", "generation": 2, "restarts": 1, "restartsLastHour": 1, "lastRestartReason": "no poll finished for 301 s; it was reading the profile {{since 20:06}}", "lastPollAgeSeconds": 3, "operation": "waiting for the next poll", "consecutiveFailures": 0, "runningRuns": 2 }} }}'
            $whole = '{{ "target": "T1", "profile": {{ "name": "baseline" }}, "runs": [], {0} }}' -f ($hostNode -f 'Warning', 'The host restarted the T1 lane 1 time(s) in the last hour.', 'Serving')
            $result = Test-DemoValidationWorkloadHost -Target T1 -StdOut $whole -VmName 'sqlvm01'
            $result.checkId | Should -Be 'WORKLOAD.T1.HOST'
            $result.status | Should -Be 'Warning'
            $result.message | Should -Be 'T1: The host restarted the T1 lane 1 time(s) in the last hour.'
            $result.evidence.generation | Should -Be 2
            $result.evidence.lastRestartReason | Should -Match 'since 20:06'
            $result.remediation | Should -Match 'stop-demo.ps1, then start-demo.ps1'

            $tail = '...' + ('"outcome": "cut", "status": "Running" }}, ], "demoSessions": [ {{ "sessionId": 61 }} ], {0}' -f ($hostNode -f 'Fail', 'The profile host (process 7132) ended without a clean stop.', 'Serving')) + "`n}"
            $cut = Test-DemoValidationWorkloadHost -Target T3 -StdOut $tail
            $cut.status | Should -Be 'Fail'
            $cut.message | Should -Match '^T3: The profile host \(process 7132\)'
            $cut.remediation | Should -Match 'on sqlvm01'

            $pass = Test-DemoValidationWorkloadHost -Target T2 -StdOut ('{{ {0} }}' -f ($hostNode -f 'Pass', 'The profile host serves T2.', 'Serving')) -VmName 'archost01'
            $pass.status | Should -Be 'Pass'
            $pass.remediation | Should -BeNullOrEmpty

            (Test-DemoValidationWorkloadHost -Target T1 -StdOut ('{{ {0} }}' -f ($hostNode -f 'Mostly fine', 'x', 'Serving'))).status | Should -Be 'Warning'
            $old = Test-DemoValidationWorkloadHost -Target T2 -StdOut '{ "target": "T2", "profile": { "name": "off" } }' -VmName 'archost01'
            $old.status | Should -Be 'Warning'
            $old.message | Should -Match 'in the guest on archost01 predates Phase 25b'
            (Test-DemoValidationWorkloadHost -Target T1 -StdOut '').status | Should -Be 'Warning'
        }
    }

    It 'reads T4''s host lane and its server block from the same tail: the host node comes after the server block' {
        InModuleScope -ModuleName DbHubDemo {
            # T4's 'status --json' (Cli/CommandLine.Postgres.cs) ends with the server block, then the host node.
            $t4 = '{ "target": "T4", "profile": { "name": "incident:idle-in-transaction" }, "runs": [], "demoSessions": [], "server": { "maxConnections": 50, "clientConnections": 12, "availableConnections": 35, "active": 3, "idleInTransaction": 2, "blocked": 1, "longestTransactionSeconds": 75, "deadlocks": 0 }, "host": { "status": "Pass", "message": "The profile host serves T4.", "file": "C:\\ProgramData\\DbHubDemo\\host-lanes.json", "processId": 7132, "lane": { "state": "Serving", "generation": 1, "restarts": 0, "runningRuns": 1 } } }'
            $hostResult = Test-DemoValidationWorkloadHost -Target T4 -StdOut $t4 -VmName 'sqlvm01'
            $hostResult.checkId | Should -Be 'WORKLOAD.T4.HOST'
            $hostResult.status | Should -Be 'Pass'
            $server = ConvertFrom-DemoT4ServerJson -Text ('...cut "runs": [], ' + $t4.Substring($t4.IndexOf('"demoSessions"')))
            $server.clientConnections | Should -Be 12
            $server.idleInTransaction | Should -Be 2
        }
    }
}

Describe 'Cost area' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        $script:schedule = @{ properties = @{ status = 'Enabled'; dailyRecurrence = @{ time = '1900' }; timeZoneId = 'Pacific Standard Time' } }
        $script:costResponse = Get-TestAzResponse
        $script:costResponse['^consumption budget list'] = Get-TestAzOk @(@{ name = 'budget-dbhub-demo'; amount = '250.0'; timeGrain = 'Monthly' })
        $script:costResponse['^resource show --resource-group rg-dbhub-demo --name shutdown-computevm-.* --resource-type Microsoft\.DevTestLab/schedules'] = Get-TestAzOk $script:schedule
        $script:costResponse['^resource list .*bastionHosts'] = Get-TestAzOk @()
        $script:costResponse['^network public-ip list'] = Get-TestAzOk @()
        Set-TestAzResponse $script:costResponse
    }

    It 'reuses preflight''s estimate and passes the budget, the schedules, and no Bastion' {
        $context = New-TestContext
        $context.Results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'estimate'))
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { throw 'should not run' }
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationCost -Context $X })
        ($results | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('COST.BUDGET=Pass', 'COST.AUTOSHUTDOWN=Pass', 'COST.BASTION=Pass')
        @($script:TestAzCalls | Where-Object { $_ -match '^resource show .*shutdown-computevm-' }).Count | Should -Be 2
        @($script:TestAzCalls | Where-Object { $_ -match '(^| )--ids( |$)' }).Count | Should -Be 0 -Because 'Invoke-DemoAz adds --subscription, which --ids would bypass'
    }

    It 'reports a Bastion left running, and a public IP an interrupted delete left behind, with the delete command' {
        $script:costResponse['^resource list .*bastionHosts'] = Get-TestAzOk @(@{ name = 'bas-dbhub-demo' })
        $script:costResponse['^network public-ip list'] = Get-TestAzOk @(@{ name = 'pip-dbhub-demo-bastion' })
        $context = New-TestContext
        $context.Results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'estimate'))
        $bastion = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationCost -Context $X }) | Where-Object { $_.checkId -eq 'COST.BASTION' }
        $bastion.status | Should -Be 'Warning'
        $bastion.message | Should -Match 'bas-dbhub-demo'
        $script:costResponse['^resource list .*bastionHosts'] = Get-TestAzOk @()
        $orphan = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationCost -Context $X }) | Where-Object { $_.checkId -eq 'COST.BASTION' }
        $orphan.status | Should -Be 'Warning'
        $orphan.message | Should -Match 'interrupted delete'
        $orphan.remediation | Should -Match 'az network public-ip delete --resource-group rg-dbhub-demo --name pip-dbhub-demo-bastion'
    }

    It 'fails a missing budget or schedule, and warns on a different amount or a disabled schedule' {
        $script:costResponse['^consumption budget list'] = Get-TestAzOk @()
        $script:costResponse.Insert(0, '^resource show .*--name shutdown-computevm-archost01 ', (Get-TestAzMissing))
        $context = New-TestContext
        $context.Results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'estimate'))
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationCost -Context $X })
        ($results | Where-Object { $_.checkId -eq 'COST.BUDGET' }).status | Should -Be 'Fail'
        ($results | Where-Object { $_.checkId -eq 'COST.AUTOSHUTDOWN' }).status | Should -Be 'Fail'
        $script:costResponse['^consumption budget list'] = Get-TestAzOk @(@{ name = 'budget-dbhub-demo'; amount = '75.0'; timeGrain = 'Monthly' })
        $script:costResponse.Remove('^resource show .*--name shutdown-computevm-archost01 ')
        $script:schedule.properties.status = 'Disabled'
        $script:costResponse['^resource show --resource-group rg-dbhub-demo --name shutdown-computevm-.* --resource-type Microsoft\.DevTestLab/schedules'] = Get-TestAzOk $script:schedule
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationCost -Context $X })
        ($results | Where-Object { $_.checkId -eq 'COST.BUDGET' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'COST.AUTOSHUTDOWN' }).status | Should -Be 'Warning'
    }
}

Describe 'Security area' {
    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' } }
        $guarded = { param($Name, $Rules) @{ name = $Name; securityRules = @($Rules) } }
        $script:securityResponse = Get-TestAzResponse
        $script:securityResponse['^deployment group list'] = Get-TestAzOk @(@{ name = 'demo-abc123'; properties = @{ timestamp = '2026-10-20T20:58:36Z'; parameters = @{ location = @{ value = 'westus3' } }; outputs = @{} } })
        $script:securityResponse['^deployment sub list'] = Get-TestAzOk @(@{ name = 'dbhub-demo-main'; properties = @{ timestamp = '2026-10-20T20:58:38Z' } }, @{ name = 'other-team'; properties = @{ timestamp = '2026-10-20T20:58:38Z' } })
        $script:securityResponse['^role assignment list'] = Get-TestAzOk @()
        $script:securityResponse['^rest --method get --url https://management.azure.com/subscriptions/[^ ]+/providers/Microsoft.Authorization/permissions'] = Get-TestAzOk @{ value = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) }
        $script:securityResponse['^resource list .*KeyVault'] = Get-TestAzOk @()
        $script:securityResponse['^network nic list'] = Get-TestAzOk @(@{ name = 'nic-sqlvm01'; ipConfigurations = @(@{ name = 'ipconfig1' }) })
        $script:securityResponse['^network nsg list'] = Get-TestAzOk @((& $guarded 'nsg-dbhub-demo-sqlvm' @(@{ name = 'Allow-RDP-From-Bastion'; direction = 'Inbound'; access = 'Allow'; sourceAddressPrefix = '10.42.0.128/26' })), (& $guarded 'nsg-dbhub-demo-archost' @()), (& $guarded 'nsg-dbhub-demo-pe' @()), (& $guarded 'nsg-dbhub-demo-bastion' @(@{ name = 'AllowHttpsInbound'; direction = 'Inbound'; access = 'Allow'; sourceAddressPrefix = 'Internet' })))
        Set-TestAzResponse $script:securityResponse
        $script:scanFolder = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scanFolder | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $script:scanFolder -ChildPath 'clean.log') -Value 'All checks ran.' -Encoding utf8NoBOM
    }

    AfterEach {
        Clear-DemoSecret
    }

    It 'passes a clean, Contributor-only environment, and doesn''t treat Bastion''s required HTTPS rule as exposure' {
        $context = New-TestContext
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder } { param($X, $P) Invoke-DemoValidationSecurity -Context $X -OutputRoot $P })
        ($results | Where-Object { $_.checkId -eq 'SECURITY.SECRETSCAN.RUNCOMMANDS' }).status | Should -Be 'Warning' -Because 'both VMs are deallocated'
        foreach ($id in 'SECURITY.SECRETSCAN.OUTPUT', 'SECURITY.SECRETSCAN.DEPLOYMENTS', 'SECURITY.RBAC.ROLEASSIGNMENTS', 'SECURITY.SECRETS.KEYVAULT', 'SECURITY.NETWORK.NOPUBLICIP', 'SECURITY.NETWORK.INBOUND') {
            ($results | Where-Object { $_.checkId -eq $id }).status | Should -Be 'Pass' -Because $id
        }
        ($results | Where-Object { $_.checkId -eq 'SECURITY.RBAC.ROLEASSIGNMENTS' }).message | Should -Match 'exercises the Contributor-only path'
        ($results | Where-Object { $_.checkId -eq 'SECURITY.SECRETSCAN.DEPLOYMENTS' }).evidence.deploymentsScanned | Should -Be 2 -Because 'only the environment''s subscription deployments count'
    }

    It 'fails on a planted token in the output, and its evidence never shows the token' {
        $encode = { param([string] $Text) [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=') }
        $token = '{0}.{1}.{2}' -f (& $encode '{"alg":"HS256"}'), (& $encode ('{"oid":"' + [guid]::NewGuid().ToString() + '"}')), (& $encode ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath (Join-Path -Path $script:scanFolder -ChildPath 'leak.log') -Value ('header', ('token={0}' -f $token)) -Encoding utf8NoBOM
        $context = New-TestContext
        $output = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder } { param($X, $P) Invoke-DemoValidationSecurity -Context $X -OutputRoot $P }) | Where-Object { $_.checkId -eq 'SECURITY.SECRETSCAN.OUTPUT' }
        $output.status | Should -Be 'Fail'
        $output.message | Should -Match 'jwt'
        ($output.evidence.findings | Where-Object { $_.rule -eq 'jwt' }).line | Should -Be 2
        ($output | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($token))
    }

    It 'warns on role assignments the demo never creates and on a Key Vault, and fails on a public IP or an open inbound rule' {
        $script:securityResponse['^role assignment list'] = Get-TestAzOk @(@{ roleDefinitionName = 'Owner'; principalType = 'User'; scope = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo' }, @{ roleDefinitionName = 'Contributor'; principalType = 'User'; scope = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/other' })
        $script:securityResponse['^resource list .*KeyVault'] = Get-TestAzOk @(@{ name = 'kv-left-behind' })
        $script:securityResponse['^network nic list'] = Get-TestAzOk @(@{ name = 'nic-sqlvm01'; ipConfigurations = @(@{ name = 'ipconfig1'; publicIPAddress = @{ id = 'pip' } }) })
        $script:securityResponse['^network nsg list'] = Get-TestAzOk @(@{ name = 'nsg-dbhub-demo-sqlvm'; securityRules = @(@{ name = 'Open-RDP'; direction = 'Inbound'; access = 'Allow'; sourceAddressPrefix = 'Internet' }) }, @{ name = 'nsg-dbhub-demo-archost'; securityRules = @() }, @{ name = 'nsg-dbhub-demo-pe'; securityRules = @() })
        $context = New-TestContext
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder } { param($X, $P) Invoke-DemoValidationSecurity -Context $X -OutputRoot $P })
        $rbac = $results | Where-Object { $_.checkId -eq 'SECURITY.RBAC.ROLEASSIGNMENTS' }
        $rbac.status | Should -Be 'Warning'
        $rbac.message | Should -Match 'Owner for a User at the resource group'
        $rbac.message | Should -Not -Match 'Contributor for'
        ($results | Where-Object { $_.checkId -eq 'SECURITY.SECRETS.KEYVAULT' }).status | Should -Be 'Warning'
        ($results | Where-Object { $_.checkId -eq 'SECURITY.NETWORK.NOPUBLICIP' }).status | Should -Be 'Fail'
        $inbound = $results | Where-Object { $_.checkId -eq 'SECURITY.NETWORK.INBOUND' }
        $inbound.status | Should -Be 'Fail'
        $inbound.message | Should -Match 'nsg-dbhub-demo-sqlvm/Open-RDP'
    }

    It 'accepts the Key Vault opt-in''s vault and its two roles on that vault only (keyVault.enabled, Phase 13)' {
        $groupScope = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo'
        $vaultScope = '{0}/providers/Microsoft.KeyVault/vaults/kv-dbhubdemo-abc123' -f $groupScope
        $script:securityResponse['^role assignment list'] = Get-TestAzOk @(@{ roleDefinitionName = 'Key Vault Secrets Officer'; principalType = 'User'; scope = $vaultScope }, @{ roleDefinitionName = 'Key Vault Secrets User'; principalType = 'Group'; scope = $vaultScope })
        $script:securityResponse['^resource list .*KeyVault'] = Get-TestAzOk @(@{ name = 'kv-dbhubdemo-abc123' })
        $script:securityResponse['^keyvault show --name kv-dbhubdemo-abc123 '] = Get-TestAzOk @{ name = 'kv-dbhubdemo-abc123'; properties = @{ enableRbacAuthorization = $true; enableSoftDelete = $true; softDeleteRetentionInDays = 7; publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Deny'; ipRules = @(@{ value = '203.0.113.7/32' }) } } }
        $context = New-TestContext
        $context.Config['assignRoles'] = $true
        $context.Config['keyVault'] = @{ enabled = $true }
        $run = { @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder } { param($X, $P) Invoke-DemoValidationSecurity -Context $X -OutputRoot $P }) }
        $results = & $run
        $rbac = $results | Where-Object { $_.checkId -eq 'SECURITY.RBAC.ROLEASSIGNMENTS' }
        $rbac.status | Should -Be 'Pass'
        $rbac.evidence.keyVaultOptIn | Should -BeTrue
        $vault = $results | Where-Object { $_.checkId -eq 'SECURITY.SECRETS.KEYVAULT' }
        $vault.status | Should -Be 'Pass'
        $vault.message | Should -Match 'opt-in Key Vault kv-dbhubdemo-abc123'
        $vault.message | Should -Match 'default action Deny'
        $vault.evidence.allowedIpRules | Should -Be 1
        $vault.evidence.rbacAuthorization | Should -BeTrue

        $script:securityResponse['^role assignment list'] = Get-TestAzOk @(@{ roleDefinitionName = 'Key Vault Secrets Officer'; principalType = 'User'; scope = $groupScope })
        $results = & $run
        ($results | Where-Object { $_.checkId -eq 'SECURITY.RBAC.ROLEASSIGNMENTS' }).status | Should -Be 'Warning' -Because 'the opt-in''s roles belong on the vault, not on the resource group'

        $script:securityResponse['^role assignment list'] = Get-TestAzOk @(@{ roleDefinitionName = 'Key Vault Secrets User'; principalType = 'User'; scope = $vaultScope })
        $context.Config['keyVault'] = @{ enabled = $false }
        $results = & $run
        ($results | Where-Object { $_.checkId -eq 'SECURITY.RBAC.ROLEASSIGNMENTS' }).status | Should -Be 'Warning' -Because 'the opt-in is off'
        $vault = $results | Where-Object { $_.checkId -eq 'SECURITY.SECRETS.KEYVAULT' }
        $vault.status | Should -Be 'Warning'
        $vault.message | Should -Match 'keyVault.enabled is false'
    }

    It 'warns when the opt-in vault is missing, uses access policies, or has company' {
        $context = New-TestContext
        $context.Config['assignRoles'] = $true
        $context.Config['keyVault'] = @{ enabled = $true }
        $run = { @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder } { param($X, $P) Invoke-DemoValidationSecurity -Context $X -OutputRoot $P }) | Where-Object { $_.checkId -eq 'SECURITY.SECRETS.KEYVAULT' } }
        $vault = & $run
        $vault.status | Should -Be 'Warning'
        $vault.message | Should -Match 'opt-in vault kv-\S+-abc123 isn''t there'

        $script:securityResponse['^resource list .*KeyVault'] = Get-TestAzOk @(@{ name = 'kv-dbhubdemo-abc123' }, @{ name = 'kv-other' })
        $script:securityResponse['^keyvault show --name kv-dbhubdemo-abc123 '] = Get-TestAzOk @{ name = 'kv-dbhubdemo-abc123'; properties = @{ enableRbacAuthorization = $false; enableSoftDelete = $true; softDeleteRetentionInDays = 7; networkAcls = @{ defaultAction = 'Allow'; ipRules = @() } } }
        $vault = & $run
        $vault.status | Should -Be 'Warning'
        $vault.message | Should -Match 'uses access policies, not Azure RBAC'
        $vault.message | Should -Match 'other vaults are there too: kv-other'
        $vault.evidence.allowedIpRules | Should -Be 0
    }
}

Describe 'Teardown area (read-only residual check)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        $script:graphQuery = ''
        $script:graphRows = @()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith {
            $script:graphQuery = $Query
            [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = @($script:graphRows); Truncated = $false }
        }
    }

    It 'renders the residual query with every placeholder, and matches nothing on an unknown deploymentId' {
        $query = InModuleScope -ModuleName DbHubDemo {
            Format-DemoKqlTemplate -Name 'ResourceGraph.Residual' -Parameters @{
                SubscriptionId = ConvertTo-DemoKqlLiteral -Value '11111111-2222-3333-4444-555555555555' -Type String
                ResourceGroup  = ConvertTo-DemoKqlLiteral -Value 'rg-dbhub-demo' -Type String
                ControlGroup   = ConvertTo-DemoKqlLiteral -Value 'rg-dbhub-control' -Type String
                Environment    = ConvertTo-DemoKqlLiteral -Value 'demo' -Type String
                DeploymentId   = ConvertTo-DemoKqlLiteral -Value '' -Type String
            }
        }
        $query | Should -Match "isnotempty\(''\)"
        $query | Should -Match 'resourcecontainers'
        $query | Should -Not -Match '\{\{'
    }

    It 'passes a deployed environment with nothing outside its group, and warns about what destroy wouldn''t delete' {
        Set-TestAzResponse (Get-TestAzResponse)
        $script:graphRows = @(
            [pscustomobject]@{ id = 'g'; name = 'rg-dbhub-demo'; type = 'microsoft.resources/subscriptions/resourcegroups'; resourceGroup = 'rg-dbhub-demo' }
            [pscustomobject]@{ id = 'v'; name = 'sqlvm01'; type = 'microsoft.compute/virtualmachines'; resourceGroup = 'rg-dbhub-demo' }
            [pscustomobject]@{ id = 'c'; name = 'rg-dbhub-control'; type = 'microsoft.resources/subscriptions/resourcegroups'; resourceGroup = 'rg-dbhub-control' }
        )
        $context = New-TestContext
        $pass = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTeardown -Context $X })
        $pass.status | Should -Be 'Pass'
        $pass.message | Should -Match 'kept by design'
        $script:graphQuery | Should -Match "'abc123'"
        $script:graphRows += [pscustomobject]@{ id = 'm'; name = 'arcsql01'; type = 'microsoft.hybridcompute/machines'; resourceGroup = 'rg-elsewhere' }
        $warn = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTeardown -Context $X })
        $warn.status | Should -Be 'Warning'
        $warn.message | Should -Match 'arcsql01'
    }

    It 'after destroy, fails on anything left and passes on zero residual resources' {
        $response = Get-TestAzResponse
        $response['^group show'] = Get-TestAzMissing
        Set-TestAzResponse $response
        $script:graphRows = @([pscustomobject]@{ id = 's'; name = 'arcsql01'; type = 'microsoft.azurearcdata/sqlserverinstances'; resourceGroup = 'rg-dbhub-demo' })
        $context = New-TestContext
        (@(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTeardown -Context $X })).status | Should -Be 'Fail'
        $script:graphRows = @([pscustomobject]@{ id = 'c'; name = 'rg-dbhub-control'; type = 'microsoft.resources/subscriptions/resourcegroups'; resourceGroup = 'rg-dbhub-control' })
        $clean = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context } { param($X) Invoke-DemoValidationTeardown -Context $X })
        $clean.status | Should -Be 'Pass'
        $clean.message | Should -Match 'zero residual resources'
    }
}

Describe 'Validation''s Azure CLI reads under the subscription guard (ADR 0011, guard update)' {
    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # No validated context: everything validation reads must be a read that Invoke-DemoAz allows without
        # it. Invoke-DemoAz itself runs for real; only the Azure CLI underneath it is faked.
        Initialize-GuardTestContext -Clear
        $script:cliCalls = [System.Collections.Generic.List[string]]::new()
        $script:restCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:cliCalls.Add($joined)
            foreach ($key in $script:cliResponse.Keys) {
                if ($joined -match $key) {
                    $answer = $script:cliResponse[$key]
                    if ($answer.Ok) {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $answer.Value -Depth 20); StdErr = '' }
                    }
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $answer.Error }
                }
            }
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('ERROR: unexpected call: {0}' -f $joined) }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $script:restCalls.Add(('{0} {1}' -f $Method, $Uri))
            [pscustomobject]@{ ExitCode = 0; StdOut = ([ordered]@{ totalRecords = 0; count = 0; data = @(); resultTruncated = 'false' } | ConvertTo-Json); StdErr = ''; StatusCode = 200 }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAccessToken -MockWith { throw 'validation requests no token in these areas' }
        $script:scanFolder = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:scanFolder | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $script:scanFolder -ChildPath 'clean.log') -Value 'All checks ran.' -Encoding utf8NoBOM
    }

    AfterEach {
        Clear-DemoSecret
    }

    It 'reads with the configured --subscription and nothing the guard refuses, with the VMs <_>' -ForEach @('deallocated', 'running') {
        $power = $_
        $subscription = '11111111-2222-3333-4444-555555555555'
        $script:cliResponse = Get-TestAzResponse -Power $power
        $script:cliResponse['^consumption budget list'] = Get-TestAzOk @(@{ name = 'budget-dbhub-demo'; amount = '250.0'; timeGrain = 'Monthly' })
        $script:cliResponse['^resource show --resource-group rg-dbhub-demo --name shutdown-computevm-'] = Get-TestAzOk @{ properties = @{ status = 'Enabled'; dailyRecurrence = @{ time = '1900' }; timeZoneId = 'Pacific Standard Time' } }
        $script:cliResponse['^resource list .*bastionHosts'] = Get-TestAzOk @()
        $script:cliResponse['^network public-ip list'] = Get-TestAzOk @()
        $script:cliResponse['^rest --method get --url https://management.azure.com/subscriptions/[^ ]+/runCommands\?api-version='] = Get-TestAzOk @{ value = @(@{ name = 'DbHubDemo-HealthRead' }) }
        $script:cliResponse['^rest --method get --url https://management.azure.com/subscriptions/[^ ]+/runCommands/DbHubDemo-HealthRead\?'] = Get-TestAzOk @{ name = 'DbHubDemo-HealthRead'; properties = @{ instanceView = @{ output = 'All checks ran.'; error = '' } } }
        $script:cliResponse['^deployment group list'] = Get-TestAzOk @()
        $script:cliResponse['^deployment sub list'] = Get-TestAzOk @()
        $script:cliResponse['^role assignment list'] = Get-TestAzOk @()
        $script:cliResponse['^rest --method get --url https://management.azure.com/subscriptions/[^ ]+/providers/Microsoft.Authorization/permissions'] = Get-TestAzOk @{ value = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) }
        $script:cliResponse['^resource list .*KeyVault'] = Get-TestAzOk @()
        $script:cliResponse['^network nic list'] = Get-TestAzOk @()
        $script:cliResponse['^network nsg list'] = Get-TestAzOk @()
        $context = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = (Get-HubTestConfig) } { param($C) New-DemoValidationContext -Config $C -Target @('T1', 'T2', 'T3') }
        $context.Results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'estimate'))

        # The Infrastructure area reads health.json through Run Commands on running VMs, which are writes: the
        # validated context allows them after the guard, so this test runs it only with the VMs deallocated.
        $results = @(InModuleScope -ModuleName DbHubDemo -Parameters @{ X = $context; P = $script:scanFolder; Running = ($power -eq 'running') } {
                param($X, $P, $Running)
                if (-not $Running) {
                    Invoke-DemoValidationInfrastructure -Context $X
                }
                Invoke-DemoValidationCost -Context $X
                Invoke-DemoValidationSecurity -Context $X -OutputRoot $P
                Invoke-DemoValidationTeardown -Context $X
            })

        $results.Count | Should -BeGreaterThan 0
        @($results | Where-Object { $_.message -match 'refuses' }) | Should -BeNullOrEmpty
        $script:cliCalls.Count | Should -BeGreaterThan 5
        foreach ($call in $script:cliCalls) {
            $call | Should -Match ('(^| )--subscription {0}( |$)' -f [regex]::Escape($subscription)) -Because $call
            $call | Should -Not -Match '(^| )--ids( |=|$)' -Because $call
            $call | Should -Not -Match '(?i)\{subscriptionId\}' -Because $call
            if ($call -match '^rest ') {
                $call | Should -Match ('--url https://management\.azure\.com/subscriptions/{0}/' -f [regex]::Escape($subscription)) -Because $call
                $call | Should -Match '--method get' -Because $call
            }
            if ($call -match '^role assignment list') {
                $call | Should -Match '--fill-principal-name false' -Because $call
            }
        }
        @($script:cliCalls | Where-Object { $_ -match '^(ad|account) ' }) | Should -BeNullOrEmpty
        $script:restCalls | Should -Be @('POST https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01') -Because 'Resource Graph goes through Invoke-DemoRestRequest, not az rest'
        if ($power -eq 'running') {
            @($script:cliCalls | Where-Object { $_ -match '^rest --method get --url https://management\.azure\.com/subscriptions/[^ ]+/virtualMachines/sqlvm01/runCommands' }).Count | Should -BeGreaterThan 0
            ($results | Where-Object { $_.checkId -eq 'SECURITY.SECRETSCAN.RUNCOMMANDS' }).status | Should -Be 'Pass'
        }
    }
}

Describe 'Plumbing for read-only runs' {
    It 'pins $WhatIfPreference in Invoke-DemoAzCli before it does anything else (Phase 14 finding)' {
        $source = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Private/Invoke-DemoAzCli.ps1') -Raw
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DemoAzCli' }, $true)
        $function | Should -Not -BeNullOrEmpty
        $first = $function.Body.EndBlock.Statements[0]
        $first.Extent.Text | Should -Be '$WhatIfPreference = $false' -Because 'it must be pinned before the redirection, the cleanup, and the timed path run'
    }

    It 'captures az errors and the exit code, and leaves no temporary file, under a caller''s -WhatIf with a time limit of <_> seconds (0: none)' -ForEach @(0, 60) {
        $timeout = $_
        # pwsh stands in for the Azure CLI on every platform: it prints a line, writes an error, and exits 3.
        $script:fakeAzPath = (Get-Process -Id $PID).Path
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'az' } -MockWith { [pscustomobject]@{ Source = $script:fakeAzPath } }
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.WriteLine(''out''); [Console]::Error.WriteLine(''az failed''); exit 3')
        $temp = Join-Path -Path $TestDrive -ChildPath ('tmp-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $temp
        $saved = @{ TMP = $env:TMP; TEMP = $env:TEMP; TMPDIR = $env:TMPDIR }
        try {
            $env:TMP = $temp
            $env:TEMP = $temp
            $env:TMPDIR = $temp
            $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ Arguments = $arguments; Timeout = $timeout } {
                param($Arguments, $Timeout)
                $WhatIfPreference = $true
                Invoke-DemoAzCli -ArgumentList $Arguments -TimeoutSeconds $Timeout
            }
        }
        finally {
            $env:TMP = $saved['TMP']
            $env:TEMP = $saved['TEMP']
            $env:TMPDIR = $saved['TMPDIR']
        }

        $result.ExitCode | Should -Be 3
        $result.StdOut | Should -Be 'out'
        $result.StdErr | Should -Match 'az failed' -Because 'a caller''s -WhatIf must not skip the stderr capture'
        @(Get-ChildItem -LiteralPath $temp -Filter '*.tmp' -Force) | Should -BeNullOrEmpty -Because 'a caller''s -WhatIf must not skip the cleanup'
    }

    It 'adds the cost and security areas to the result schema, and only those' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/schemas/validation-result.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.area.enum | Should -Be @('static', 'preflight', 'infra', 't1', 't2', 't3', 't4', 'hub', 'workload', 'teardown', 'fabric', 'cost', 'security')
        $parameter = (Get-Command -Name New-DemoResult).Parameters['Area']
        ($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues | Should -Be $schema.properties.area.enum
    }
}

Describe 'scripts/validate.ps1 (the contract with validate.yml)' {
    BeforeAll {
        $script:scriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/validate.ps1'))
        $script:text = Get-Content -LiteralPath $script:scriptPath -Raw
        $tokens = $null
        $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$tokens, [ref]$errors)
        $script:parseErrors = $errors
        $example = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $example.Remove('$schema')
        $example['subscriptionId'] = $script:HubSubscriptionId
        $example['tenantId'] = $script:HubTenantId
        $example['t3AdminGroupObjectId'] = '44444444-4444-4444-4444-444444444444'
        $script:configPath = Join-Path -Path $TestDrive -ChildPath 'validate.config.json'
        Set-Content -LiteralPath $script:configPath -Value ($example | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'validate.jsonl'
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = $null
    }

    AfterAll {
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    }

    BeforeEach {
        # Mock bodies run in the script's scope, so they read plain variables set here.
        $validationResults = @(
            New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard'
            New-DemoResult -CheckId 'INFRA.VM.SQLVM01' -Area 'infra' -Target 'T1' -Status 'Warning' -Message 'sqlvm01 is deallocated' -Remediation 'start it'
        )
        Mock -CommandName Write-DemoLog -MockWith { }
        Mock -CommandName Invoke-DemoValidation -MockWith { $validationResults }
    }

    It 'parses, needs PowerShell 7.4, documents every parameter, and keeps the agreed parameters' {
        $script:parseErrors | Should -BeNullOrEmpty
        $script:text | Should -Match '(?m)^#Requires -Version 7\.4'
        $script:text | Should -Match '\.SYNOPSIS'
        $names = $script:ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($name in 'ConfigPath', 'Area', 'Target', 'WaitMinutes', 'OutputPath', 'TreatManualAsError', 'ScanPath', 'DeploymentId', 'FabricAdmin', 'SkipPolicyInventory') {
            $names | Should -Contain $name
            $script:text | Should -Match ('\.PARAMETER {0}\b' -f $name)
        }
        $output = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'OutputPath' }
        $output.DefaultValue.Extent.Text | Should -Match ([regex]::Escape("'../out/validate.jsonl'"))
        $area = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Area' }
        $set = $area.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($set.PositionalArguments.Value) | Should -Be @('Preflight', 'Infrastructure', 'T1', 'T2', 'T3', 'T4', 'Hub', 'Telemetry', 'Workload', 'Cost', 'Security', 'Teardown')
        $binding = $script:ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $named = @($binding.NamedArguments | ForEach-Object { $_.ArgumentName })
        $named | Should -Not -Contain 'SupportsShouldProcess' -Because 'validation never asks for -WhatIf; it changes nothing in the demo'
    }

    It 'runs the catalog through the module and makes no Azure CLI call of its own' {
        $commands = @($script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        foreach ($name in 'Get-DemoConfig', 'Invoke-DemoValidation', 'Export-DemoResult', 'Get-DemoExitCode') {
            $commands | Should -Contain $name
        }
        $commands | Should -Not -Contain 'az'
        $commands | Should -Not -Contain 'Invoke-DemoAz'
    }

    It 'writes every result as a JSON line, prints the summary, and exits 0 without a Fail' {
        $output = & $script:scriptPath -ConfigPath $script:configPath -OutputPath $script:outputPath *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $lines = @(Get-Content -LiteralPath $script:outputPath)
        $lines.Count | Should -Be 2
        ($lines[1] | ConvertFrom-Json).checkId | Should -Be 'INFRA.VM.SQLVM01'
        $output | Should -Match 'Manual action required'
        $output | Should -Match 'INFRA\.VM\.SQLVM01'
        Should -Invoke -CommandName Invoke-DemoValidation -Times 1 -Exactly -ParameterFilter {
            @($Area).Count -eq 12 -and @($Target).Count -eq 4 -and $WaitMinutes -eq 0 -and $Config['subscriptionId'] -eq $script:HubSubscriptionId
        }
    }

    It 'exits 1 on a Fail, and on Manual action required only with -TreatManualAsError' {
        $validationResults = @(New-DemoResult -CheckId 'T2.ARC.SQLINSTANCE' -Area 't2' -Target 'T2' -Status 'Manual action required' -Message 'wizard')
        $null = & $script:scriptPath -ConfigPath $script:configPath -OutputPath $script:outputPath *>&1
        $LASTEXITCODE | Should -Be 0
        $null = & $script:scriptPath -ConfigPath $script:configPath -OutputPath $script:outputPath -TreatManualAsError *>&1
        $LASTEXITCODE | Should -Be 1
        $validationResults = @(New-DemoResult -CheckId 'INFRA.NETWORK' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message 'missing')
        $null = & $script:scriptPath -ConfigPath $script:configPath -OutputPath $script:outputPath *>&1
        $LASTEXITCODE | Should -Be 1
    }

    It 'passes the areas, targets, wait, scan paths, and switches through' {
        $scan = Join-Path -Path $TestDrive -ChildPath 'actions.log'
        $null = & $script:scriptPath -ConfigPath $script:configPath -OutputPath $script:outputPath -Area Teardown, Security -Target T3 -WaitMinutes 15 -ScanPath $scan -DeploymentId abc123 -FabricAdmin -SkipPolicyInventory *>&1
        Should -Invoke -CommandName Invoke-DemoValidation -Times 1 -Exactly -ParameterFilter {
            (@($Area) -join ',') -eq 'Teardown,Security' -and (@($Target) -join ',') -eq 'T3' -and $WaitMinutes -eq 15 -and @($ScanPath)[0] -eq $scan -and $DeploymentId -eq 'abc123' -and $FabricAdmin -and $SkipPolicyInventory
        }
    }
}
