BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    # No test here reaches the Azure CLI (2026-11-16, tests/TestAzGuard.ps1): an az call that no test mocks gets what the
    # real CLI answered for these tests' made-up subscription, which they relied on, without leaving this process.
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
        $at = [array]::IndexOf([string[]]$ArgumentList, '--subscription')
        $subscription = if ($at -ge 0 -and $at + 1 -lt $ArgumentList.Count) { $ArgumentList[$at + 1] } else { '11111111-2222-3333-4444-555555555555' }
        [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ("ERROR: Subscription '{0}' not found. Check the spelling and casing and try again." -f $subscription) }
    }
    $exampleConfig = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')

    # Recorded-style price items keyed by a fragment of the API filter. Prices are fixtures, not real prices.
    $priceFixtures = [ordered]@{
        "armSkuName eq 'Standard_D2s_v5'"                                                     = @(
            @{ productName = 'Virtual Machines Dsv5 Series Windows'; skuName = 'D2s v5'; meterName = 'D2s v5'; retailPrice = 0.20; unitOfMeasure = '1 Hour' }
            @{ productName = 'Virtual Machines Dsv5 Series Windows'; skuName = 'D2s v5 Spot'; meterName = 'D2s v5 Spot'; retailPrice = 0.05; unitOfMeasure = '1 Hour' }
            @{ productName = 'Virtual Machines Dsv5 Series'; skuName = 'D2s v5'; meterName = 'D2s v5'; retailPrice = 0.10; unitOfMeasure = '1 Hour' }
        )
        "armSkuName eq 'Standard_E2s_v5'"                                                     = @(
            @{ productName = 'Virtual Machines Esv5 Series Windows'; skuName = 'E2s v5'; meterName = 'E2s v5'; retailPrice = 0.30; unitOfMeasure = '1 Hour' }
            @{ productName = 'Virtual Machines Esv5 Series Windows'; skuName = 'E2s v5 Low Priority'; meterName = 'E2s v5 Low Priority'; retailPrice = 0.09; unitOfMeasure = '1 Hour' }
            @{ productName = 'Virtual Machines Esv5 Series Windows'; skuName = 'E2s v5 Spot'; meterName = 'E2s v5 Spot'; retailPrice = 0.06; unitOfMeasure = '1 Hour' }
        )
        "skuName eq '1-4 vCPU VM'"                                                            = @(@{ productName = 'SQL Server Standard'; skuName = '1-4 vCPU VM'; meterName = '1-4 vCPU VM License'; retailPrice = 0.40; unitOfMeasure = '1 Hour'; armRegionName = '' })
        "skuName eq 'Std edition - PAYG'"                                                     = @(
            @{ productName = 'Azure Arc-enabled SQL Server - Arc-enabled servers'; skuName = 'Std edition - PAYG'; meterName = 'Std edition - PAYG'; retailPrice = 0.50; unitOfMeasure = '1 Hour'; armRegionName = 'US Gov' }
            @{ productName = 'Azure Arc-enabled SQL Server - Arc-enabled servers'; skuName = 'Std edition - PAYG'; meterName = 'Std edition - PAYG'; retailPrice = 0.10; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
        )
        'Serverless - Compute Gen5'                                                           = @(
            @{ productName = 'SQL Database General Purpose - Serverless - Compute Gen5'; skuName = '1 vCore'; meterName = 'vCore'; retailPrice = 0.50; unitOfMeasure = '1 Hour' }
            @{ productName = 'SQL Database General Purpose - Serverless - Compute Gen5'; skuName = '1 vCore'; meterName = '1 vCore - Free'; retailPrice = 0.0; unitOfMeasure = '1 Hour' }
        )
        "serviceName eq 'Azure Bastion'"                                                      = @(@{ productName = 'Azure Bastion'; skuName = 'Basic'; meterName = 'Basic Gateway'; retailPrice = 0.19; unitOfMeasure = '1 Hour' })
        "productName eq 'IP Addresses'"                                                       = @(@{ productName = 'IP Addresses'; skuName = 'Standard'; meterName = 'Standard IPv4 Static Public IP'; retailPrice = 0.01; unitOfMeasure = '1 Hour' })
        "skuName eq 'E10 LRS'"                                                                = @(@{ productName = 'Standard SSD Managed Disks'; skuName = 'E10 LRS'; meterName = 'E10 LRS Disk'; retailPrice = 10.0; unitOfMeasure = '1/Month' })
        "skuName eq 'P10 LRS'"                                                                = @(@{ productName = 'Premium SSD Managed Disks'; skuName = 'P10 LRS'; meterName = 'P10 LRS Disk'; retailPrice = 20.0; unitOfMeasure = '1/Month' })
        "skuName eq 'Snapshots LRS'"                                                          = @(
            @{ productName = 'Premium SSD Managed Disks'; skuName = 'Snapshots LRS'; meterName = 'LRS Snapshots'; retailPrice = 0.20; unitOfMeasure = '1 GB/Month' }
            @{ productName = 'Standard HDD Managed Disks'; skuName = 'Snapshots LRS'; meterName = 'LRS Snapshots'; retailPrice = 0.05; unitOfMeasure = '1 GB/Month' }
        )
        'General Purpose - Storage'                                                           = @(@{ productName = 'SQL Database Single/Elastic Pool General Purpose - Storage'; skuName = 'General Purpose'; meterName = 'General Purpose Data Stored'; retailPrice = 0.10; unitOfMeasure = '1 GB/Month' })
        # Published only under Global. The fixed private endpoint meter costs far more and must never be picked.
        "productName eq 'Virtual Network Private Link'"                                       = @(
            @{ productName = 'Virtual Network Private Link'; skuName = 'Fixed Private Endpoint T1'; meterName = 'Fixed Private Endpoint T1'; retailPrice = 14.0; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
            @{ productName = 'Virtual Network Private Link'; skuName = 'Standard'; meterName = 'Standard Private Endpoint'; retailPrice = 0.01; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
        )
        "meterName eq 'Private Zone'"                                                         = @(
            @{ productName = 'Azure DNS'; skuName = 'Private'; meterName = 'Private Zone'; retailPrice = 0.63; unitOfMeasure = '1'; armRegionName = 'US Gov Zone 1'; tierMinimumUnits = 0 }
            @{ productName = 'Azure DNS'; skuName = 'Private'; meterName = 'Private Zone'; retailPrice = 0.10; unitOfMeasure = '1'; armRegionName = ''; tierMinimumUnits = 25 }
            @{ productName = 'Azure DNS'; skuName = 'Private'; meterName = 'Private Zone'; retailPrice = 0.50; unitOfMeasure = '1'; armRegionName = ''; tierMinimumUnits = 0 }
        )
        "serviceName eq 'NAT Gateway'"                                                        = @(
            @{ productName = 'NAT Gateway'; skuName = 'Standard'; meterName = 'Standard Data Processed'; retailPrice = 0.045; unitOfMeasure = '1 GB'; armRegionName = 'Global' }
            @{ productName = 'NAT Gateway'; skuName = 'Standard'; meterName = 'Standard Gateway'; retailPrice = 0.045; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
        )
        "productName eq 'Microsoft Defender for Servers' and skuName eq 'Standard P2'"        = @(
            @{ productName = 'Microsoft Defender for Servers'; skuName = 'Standard P2'; meterName = 'Standard P2 Node'; retailPrice = 0.02; unitOfMeasure = '1/Hour'; armRegionName = 'Global' }
            @{ productName = 'Microsoft Defender for Servers'; skuName = 'Standard P2'; meterName = 'Standard P2 Node - MDATP Benefit'; retailPrice = 0.0137; unitOfMeasure = '1/Hour'; armRegionName = 'westus3' }
            @{ productName = 'Microsoft Defender for Servers'; skuName = 'Standard P2'; meterName = 'Standard P2 Node'; retailPrice = 0.025; unitOfMeasure = '1/Hour'; armRegionName = 'westus3' }
        )
        "productName eq 'Microsoft Defender for Servers' and skuName eq 'Standard P1'"        = @(@{ productName = 'Microsoft Defender for Servers'; skuName = 'Standard P1'; meterName = 'Standard P1 Node'; retailPrice = 0.007; unitOfMeasure = '1/Hour'; armRegionName = 'Global' })
        "productName eq 'Microsoft Defender for SQL'"                                         = @(
            @{ productName = 'Microsoft Defender for SQL'; skuName = 'Standard'; meterName = 'Standard Node'; retailPrice = 15.0; unitOfMeasure = '1/Month'; armRegionName = 'Global' }
            @{ productName = 'Microsoft Defender for SQL'; skuName = 'Standard'; meterName = 'Standard vCore'; retailPrice = 0.015; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
            @{ productName = 'Microsoft Defender for SQL'; skuName = 'Standard'; meterName = 'Standard Instance'; retailPrice = 0.02; unitOfMeasure = '1 Hour'; armRegionName = 'Global' }
        )
        "productName eq 'Microsoft Defender CSPM'"                                            = @(@{ productName = 'Microsoft Defender CSPM'; skuName = 'Standard'; meterName = 'Standard Node'; retailPrice = 0.012; unitOfMeasure = '1/Hour'; armRegionName = 'Global' })
        "productName eq 'Microsoft Defender for PostgreSQL'"                                  = @(
            @{ productName = 'Microsoft Defender for PostgreSQL'; skuName = 'Standard'; meterName = 'Standard Trial Node'; retailPrice = 0.0; unitOfMeasure = '1/Month'; armRegionName = 'westus3' }
            @{ productName = 'Microsoft Defender for PostgreSQL'; skuName = 'Standard'; meterName = 'Standard Node'; retailPrice = 15.0; unitOfMeasure = '1/Month'; armRegionName = 'westus3' }
        )
        'Flexible Server Burstable BS Series Compute'                                         = @(
            @{ productName = 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute'; skuName = 'B2S'; meterName = 'B2S'; retailPrice = 0.07; unitOfMeasure = '1 Hour' }
            @{ productName = 'Azure Database for PostgreSQL Flexible Server Burstable BS Series Compute'; skuName = 'B1MS'; meterName = 'B1MS'; retailPrice = 0.02; unitOfMeasure = '1 Hour' }
        )
        'Flexible Server General Purpose Dadsv5 Series Compute'                               = @(
            @{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Dadsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.09; unitOfMeasure = '1 Hour' }
        )
        'Flexible Server General Purpose Ddsv5 Series Compute'                                = @(
            @{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 520.0; unitOfMeasure = '1 Year' }
            @{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.09; unitOfMeasure = '1 Hour' }
        )
        "productName eq 'Azure Database for PostgreSQL Flex Server Storage'"                  = @(@{ productName = 'Azure Database for PostgreSQL Flex Server Storage'; skuName = 'Storage'; meterName = 'Storage Data Stored'; retailPrice = 0.10; unitOfMeasure = '1 GB/Month' })
        "armSkuName eq 'Standard_D4as_v5'"                                                    = @(@{ productName = 'Virtual Machines Dasv5 Series Windows'; skuName = 'D4as v5'; meterName = 'D4as v5'; retailPrice = 0.40; unitOfMeasure = '1 Hour' })
        "productName eq 'Azure Premium SSD v2'"                                               = @(
            @{ productName = 'Azure Premium SSD v2'; skuName = 'Premium LRS'; meterName = 'Premium LRS Provisioned Capacity'; retailPrice = 0.0001; unitOfMeasure = '1 GiB/Hour'; tierMinimumUnits = 0 }
            @{ productName = 'Azure Premium SSD v2'; skuName = 'Premium LRS'; meterName = 'Premium LRS Provisioned IOPS'; retailPrice = 0.0; unitOfMeasure = '1/Hour'; tierMinimumUnits = 0 }
            @{ productName = 'Azure Premium SSD v2'; skuName = 'Premium LRS'; meterName = 'Premium LRS Provisioned IOPS'; retailPrice = 0.00001; unitOfMeasure = '1/Hour'; tierMinimumUnits = 3000 }
            @{ productName = 'Azure Premium SSD v2'; skuName = 'Premium LRS'; meterName = 'Premium LRS Provisioned Throughput (MBps)'; retailPrice = 0.0; unitOfMeasure = '1/Hour'; tierMinimumUnits = 0 }
            @{ productName = 'Azure Premium SSD v2'; skuName = 'Premium LRS'; meterName = 'Premium LRS Provisioned Throughput (MBps)'; retailPrice = 0.00005; unitOfMeasure = '1/Hour'; tierMinimumUnits = 125 }
        )
        # The on-demand activity control (ADR 0020): the vault's operations and Automation's job minutes.
        "serviceName eq 'Key Vault'"                                                          = @(
            @{ productName = 'Key Vault'; skuName = 'Standard'; meterName = 'Certificate Renewal Request'; retailPrice = 3.0; unitOfMeasure = '1'; tierMinimumUnits = 0 }
            @{ productName = 'Key Vault'; skuName = 'Standard'; meterName = 'Operations'; retailPrice = 0.03; unitOfMeasure = '10K'; tierMinimumUnits = 0 }
        )
        "serviceName eq 'Azure Container Apps'"                                               = @(
            @{ productName = 'Azure Container Apps'; skuName = 'Standard'; meterName = 'Standard vCPU Active Usage'; retailPrice = 0.000024; unitOfMeasure = '1 Second' }
            @{ productName = 'Azure Container Apps'; skuName = 'Standard'; meterName = 'Standard Memory Active Usage'; retailPrice = 0.000003; unitOfMeasure = '1 GiB Second' }
        )
        "serviceName eq 'Automation'"                                                         = @(
            @{ productName = 'Automation'; skuName = 'Basic'; meterName = 'Basic Runtime'; retailPrice = 0.002; unitOfMeasure = '1 Minute'; tierMinimumUnits = 500 }
            @{ productName = 'Automation'; skuName = 'Basic'; meterName = 'Basic Runtime'; retailPrice = 0.0; unitOfMeasure = '1 Minute'; tierMinimumUnits = 0 }
        )
        # T5 (2026-11-18, ADR 0027): provisioned throughput per 100 RU/s an hour, storage, and the Free Tier meters at zero.
        "serviceName eq 'Azure Cosmos DB'"                                                    = @(
            @{ productName = 'Azure Cosmos DB'; skuName = 'RUs'; meterName = '100 RU/s'; retailPrice = 0.008; unitOfMeasure = '1/Hour' }
            @{ productName = 'Azure Cosmos DB'; skuName = 'RUs'; meterName = 'Data Stored'; retailPrice = 0.25; unitOfMeasure = '1 GB/Month' }
            @{ productName = 'Azure Cosmos DB'; skuName = 'mRUs'; meterName = '100 Multi-master RU/s'; retailPrice = 0.016; unitOfMeasure = '1/Hour' }
            @{ productName = 'Azure Cosmos DB'; skuName = 'Free Tier'; meterName = '100 RU/s'; retailPrice = 0.0; unitOfMeasure = '1/Hour' }
            @{ productName = 'Azure Cosmos DB'; skuName = 'Free Tier'; meterName = 'Data Stored'; retailPrice = 0.0; unitOfMeasure = '1 GB/Month' }
        )
        "productName eq 'Microsoft Defender for Azure Cosmos DB'"                             = @(
            @{ productName = 'Microsoft Defender for Azure Cosmos DB'; skuName = 'Standard Trial'; meterName = 'Standard Trial 100 RU/s'; retailPrice = 0.0; unitOfMeasure = '1/Hour'; armRegionName = 'westus3' }
            @{ productName = 'Microsoft Defender for Azure Cosmos DB'; skuName = 'Standard'; meterName = 'Standard 100 RU/s'; retailPrice = 0.0012; unitOfMeasure = '1/Hour'; armRegionName = 'westus3' }
        )
    }

    # The shape 'az security pricing list' returns, trimmed to the fields the estimate reads.
    $defenderPlans = @(
        [pscustomobject]@{ name = 'VirtualMachines'; pricingTier = 'Standard'; subPlan = 'P2' }
        [pscustomobject]@{ name = 'SqlServers'; pricingTier = 'Standard'; subPlan = $null }
        [pscustomobject]@{ name = 'SqlServerVirtualMachines'; pricingTier = 'Standard'; subPlan = $null }
        [pscustomobject]@{ name = 'StorageAccounts'; pricingTier = 'Standard'; subPlan = 'DefenderForStorageV2' }
        [pscustomobject]@{ name = 'CloudPosture'; pricingTier = 'Standard'; subPlan = $null }
        [pscustomobject]@{ name = 'Arm'; pricingTier = 'Standard'; subPlan = 'PerSubscription' }
        [pscustomobject]@{ name = 'KeyVaults'; pricingTier = 'Free'; subPlan = $null }
    )

    function New-TestConfig {
        param([hashtable] $Override = @{})
        $config = @{}
        foreach ($key in $exampleConfig.Keys) { $config[$key] = $exampleConfig[$key] }
        $config['hybridBenefit'] = @{ windows = $false; sql = $false; entitlementAttested = $false }
        # T4 (Phase 24) has its own tests below; the others keep their totals with T4 off. T5 (2026-11-18, ADR 0027) too.
        $config['t4Enabled'] = $false
        $config['t5Enabled'] = $false
        # Ask's relay (ADR 0028) has its own test below; the others keep their totals with it off.
        $config['ask'] = @{ enabled = $false; image = ''; githubClientId = '' }
        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return $config
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoCostEstimate' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith {
            $filter = [uri]::UnescapeDataString(($Uri -split '\$filter=')[1])
            $items = @()
            foreach ($fragment in $priceFixtures.Keys) {
                if ($filter.Contains($fragment)) {
                    $items = @($priceFixtures[$fragment] | ForEach-Object { [pscustomobject]$_ })
                    break
                }
            }
            [pscustomobject]@{ Items = $items; NextPageLink = $null }
        }
    }

    It 'prices T4: Burstable compute while running, and storage, its DNS zone, and its Defender plans all month, with the 7-day restart counted' {
        $plans = @($defenderPlans) + @([pscustomobject]@{ name = 'OpenSourceRelationalDatabases'; pricingTier = 'Standard'; subPlan = $null })
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $plans
        $t4 = @($estimate.Components | Where-Object { $_.Name -match 'T4' })
        ($t4 | Where-Object Name -EQ 'T4 compute (Standard_B1ms)').UnitPrice | Should -Be 0.02 -Because 'the B1MS meter, not another Burstable size'
        ($t4 | Where-Object Name -EQ 'T4 compute (Standard_B1ms)').Basis | Should -Be 'running'
        ($t4 | Where-Object Name -EQ 'T4 storage').Cost | Should -Be 3.2 -Because '32 GiB at 0.10'
        ($t4 | Where-Object Name -EQ 'T4 private DNS zone').Cost | Should -Be 0.5 -Because 'virtual network integration in both network modes'
        ($t4 | Where-Object Name -Match 'open-source relational').Cost | Should -Be 15.0 -Because 'the Standard Node meter, not the trial'
        ($t4 | Where-Object Name -EQ 'Defender CSPM (T4 server)').Basis | Should -Be 'idle'
        # Fixed: storage 3.20 + DNS 0.50 + Defender 15.00 + CSPM 0.012 x 730 = 27.46.
        $estimate.T4FixedMonthly | Should -Be 27.46
        # Worst case: B1MS for the 720 hours of the month the light-use estimate doesn't run it.
        $estimate.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.02 * (730 - 10), 2))
        $monthly = $estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'T4 \(PostgreSQL, Standard_B1ms\) costs 27\.46 USD a month even while stopped'
        $monthly.message | Should -Match 'whether the nightly safety stop is in place wasn''t checked, so the worst case counts it running for the rest of the month: 720 hours, 14\.40 USD of T4 compute'
        # T4 is part of every deployment (2026-11-09), so leaving it out is never a way to keep the month cheaper, and no text
        # asks for a size to be set: an agent that pinned Standard_B1ms from it left T4 out when Azure refused that size.
        $monthly.message | Should -Not -Match 't4Enabled'
        $monthly.message | Should -Not -Match 'set t4SkuName'
        $estimate.T4RestartAssumption | Should -Be 'RestOfMonth'
        $estimate.T4RestartHours | Should -Be 720
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.DEFENDER').message | Should -Match 'OpenSourceRelationalDatabases'
        @($estimate.MissingPrices) | Should -BeNullOrEmpty
    }

    It 'prices Ask''s chat relay per active second, as running cost only (it scales to zero), from the Container Apps meters' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ ask = @{ enabled = $true; image = ''; githubClientId = '' } }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $defenderPlans
        $ask = @($estimate.Components | Where-Object { $_.Name -like 'Ask relay*' })
        $ask.Count | Should -Be 2
        @($ask | Where-Object Basis -NE 'running') | Should -BeNullOrEmpty -Because 'idle, the relay has no replica and costs nothing'
        ($ask | Where-Object Name -Like '*vCPU*').Cost | Should -Be ([System.Math]::Round(0.000024 * 3600, 4)) -Because 'one vCPU for an hour'
        ($ask | Where-Object Name -Like '*memory*').Cost | Should -Be ([System.Math]::Round(0.000003 * 3600 * 2, 4)) -Because '2 GiB for an hour'
        @($estimate.MissingPrices) | Should -BeNullOrEmpty
        $off = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $defenderPlans
        @($off.Components | Where-Object { $_.Name -like 'Ask relay*' }) | Should -BeNullOrEmpty
    }

    It 'prices T4''s default, General Purpose Standard_D4ds_v5, as 4 vCore-hours, and the fallback''s Standard_D4ads_v5 from its own series (2026-11-04)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $compute = $estimate.Components | Where-Object Name -EQ 'T4 compute (Standard_D4ds_v5)'
        $compute.UnitPrice | Should -Be 0.09 -Because 'the hourly vCore meter, not the yearly one'
        $compute.Quantity | Should -Be 4
        $estimate.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.09 * 4 * (730 - 10), 2))
        $amd = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D4ads_v5' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($amd.Components | Where-Object Name -EQ 'T4 compute (Standard_D4ads_v5)').UnitPrice | Should -Be 0.09
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { [uri]::UnescapeDataString($Uri) -match "productName eq 'Azure Database for PostgreSQL Flexible Server General Purpose Dadsv5 Series Compute'" }
    }

    It 'prices the T4 size actually configured: the documented B2s fallback, with its own 7-day restart worst case (Phase 24)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B2s' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $compute = $estimate.Components | Where-Object Name -EQ 'T4 compute (Standard_B2s)'
        $compute.UnitPrice | Should -Be 0.07 -Because 'the B2S meter'
        @($estimate.Components | Where-Object Name -EQ 'T4 compute (Standard_B1ms)').Count | Should -Be 0
        $estimate.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.07 * (730 - 10), 2))
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'T4 \(PostgreSQL, Standard_B2s\)'
    }

    It 'prices the General Purpose D2ds_v5 option per vCore-hour, with its 7-day restart worst case against the ceiling (Phase 24)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $compute = $estimate.Components | Where-Object Name -EQ 'T4 compute (Standard_D2ds_v5)'
        $compute.UnitPrice | Should -Be 0.09 -Because 'the hourly vCore meter, not the reservation'
        $compute.Quantity | Should -Be 2
        $compute.Unit | Should -Be 'vCore-hour'
        $compute.Cost | Should -Be 0.18
        $estimate.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.09 * 2 * (730 - 10), 2))
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'T4 \(PostgreSQL, Standard_D2ds_v5\)'
        @($estimate.MissingPrices) | Should -BeNullOrEmpty
    }

    It 'counts each 7-day restart as about a day where a safety stop is in place, and the rest of the month otherwise (2026-11-04, ADR 0024)' {
        $config = New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }
        $counted = [pscustomobject]@{ Counts = $true; Missing = ''; Reason = 'the nightly safety stop is scheduled, its role is assigned, and its last run didn''t fail'; Fix = ''; Evidence = [ordered]@{ counts = $true } }
        $capped = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T4RestartCoverage $counted
        # 4 restarts a month (7 days stopped, then up to a day running) of 24 hours each, at 2 vCores x 0.09.
        $capped.T4RestartHours | Should -Be 96
        $capped.T4RestartAssumption | Should -Be 'SafetyStop'
        $capped.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.18 * 96, 2))
        $monthly = $capped.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'and the nightly safety stop is scheduled, its role is assigned, and its last run didn''t fail, so the worst case counts up to 4 restarts a month of about a day each, until the next safety stop: 96 hours, 17\.28 USD of T4 compute, against the ceiling\.'
        $monthly.evidence.t4RestartAssumption | Should -Be 'SafetyStop'
        $monthly.evidence.t4RestartHours | Should -Be 96

        $missing = [pscustomobject]@{ Counts = $false; Missing = 'Role'; Reason = 'the nightly safety stop can''t stop T4: its role isn''t assigned (id-dbhub-demo-safetystop doesn''t hold "DbHub Demo Safety Stop" at rg-dbhub-demo)'; Fix = 'An Owner of the subscription runs ./scripts/grant-safety-stop.ps1 -ConfigPath ./config/demo.config.json once; deploy.ps1 assigns it when the person who runs it may.'; Evidence = [ordered]@{ counts = $false; missing = 'Role' } }
        $config['monthlyCeilingUsd'] = 100
        $uncapped = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T4RestartCoverage $missing
        $uncapped.T4RestartHours | Should -Be 720
        $uncapped.T4RestartAssumption | Should -Be 'RestOfMonth'
        $uncapped.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.18 * 720, 2))
        $monthly = $uncapped.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.status | Should -Be 'Fail'
        $monthly.message | Should -Match 'and the nightly safety stop can''t stop T4: its role isn''t assigned \(.*\), so the worst case counts it running for the rest of the month: 720 hours, 129\.60 USD of T4 compute'
        $monthly.evidence.t4RestartMissing | Should -Be 'Role'
        # The ceiling to raise, since NOT DONE's next step comes from here, then the fix that caps the restart; never
        # t4Enabled, which deploy.ps1 ignores (review of 849d4c2), and never a size to set (2026-11-09).
        $monthly.remediation | Should -Match '^Raise monthlyCeilingUsd to at least \d+ in your configuration \(the budget follows it at the next deploy\.ps1 -FromStage Infrastructure\)\. Or put the nightly safety stop fully in place, so each restart counts as about a day: An Owner of the subscription runs \./scripts/grant-safety-stop\.ps1.+once; deploy\.ps1 assigns it when the person who runs it may\.$'
        $monthly.remediation | Should -Not -Match 't4Enabled'
        $monthly.remediation | Should -Not -Match 't4SkuName'
    }

    It 'says the month''s worst case it checks against the ceiling, the margin under or over it, and what it assumed (2026-11-19, the docs audit)' {
        $config = New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5'; t5Enabled = $true }
        $counted = [pscustomobject]@{ Counts = $true; Missing = ''; Reason = 'the nightly safety stop is in place'; Fix = ''; Evidence = [ordered]@{ counts = $true } }
        $text = { param([double] $Value) [regex]::Escape($Value.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture)) }
        $under = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T4RestartCoverage $counted -T5FreeTier $false
        $worst = [System.Math]::Round($under.LightUseMonthly + 0.18 * 96, 2)
        $under.MonthlyWorstCase | Should -Be $worst
        $under.MonthlyCeiling | Should -Be ([double]$config['monthlyCeilingUsd'])
        $under.MonthlyMargin | Should -Be ([System.Math]::Round([double]$config['monthlyCeilingUsd'] - $worst, 2))
        $under.MonthlyMargin | Should -BeGreaterThan 0
        $monthly = $under.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.status | Should -Be 'Pass'
        $monthly.message | Should -Match ('^lowest-cost: the month''s worst case is {0} USD, {1} USD under the hard ceiling of {2} USD\. It counts idle plus 10 hours of use, {3} USD; T4''s automatic restart for 96 hours, 17\.28 USD; and T5''s container for the running hours only \(Session\)\. ' -f (& $text $worst), (& $text $under.MonthlyMargin), (& $text $under.MonthlyCeiling), (& $text $under.LightUseMonthly))
        $monthly.evidence.monthlyWorstCase | Should -Be $worst
        $monthly.evidence.monthlyMargin | Should -Be $under.MonthlyMargin
        $monthly.evidence.monthlyCeiling | Should -Be $under.MonthlyCeiling
        # Over it: how far over, with T5's container all month and T4's restart for the rest of the month.
        $config['monthlyCeilingUsd'] = 50
        $over = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T5FreeTier $false -T5ContainerLifecycle AlwaysOn
        $overWorst = [System.Math]::Round($over.LightUseMonthly + 0.18 * 720, 2)
        $over.MonthlyMargin | Should -Be ([System.Math]::Round(50 - $overWorst, 2))
        $overMonthly = $over.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $overMonthly.status | Should -Be 'Fail'
        $overMonthly.message | Should -Match ('^lowest-cost: the month''s worst case is {0} USD, {1} USD over the hard ceiling of 50\.00 USD\. It counts idle plus 10 hours of use, {2} USD; T4''s automatic restart for 720 hours, 129\.60 USD; and T5''s container all month \(AlwaysOn\)\. ' -f (& $text $overWorst), (& $text ($overWorst - 50)), (& $text $over.LightUseMonthly))
    }

    It 'warns, and never fails, when only T5''s container priced all month while nothing automatic deletes it puts the month over the ceiling, as at 375 and 390 for a Contributor''s update (the re-review of 0590bbe)' {
        # A Contributor's environment: no nightly safety stop (T4's restart for the rest of the month), and no role to delete
        # T5's container after a session, so only stop-demo.ps1 does (-T5ManualDeleteOnly).
        $config = New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5'; t5Enabled = $true }
        $estimate = {
            param([double] $Ceiling, [string] $Lifecycle, [bool] $ManualOnly)
            $config['monthlyCeilingUsd'] = $Ceiling
            Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 0 -NetworkMode public -T5FreeTier $false -T5ContainerLifecycle $Lifecycle -T5ManualDeleteOnly:$ManualOnly
        }
        $money = { param([double] $Value) [regex]::Escape($Value.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture)) }
        $sessionMonth = (& $estimate 10000 'Session' $false).MonthlyWorstCase
        $always = & $estimate 10000 'AlwaysOn' $true
        $alwaysMonth = $always.MonthlyWorstCase
        $extra = [double]$always.T5AlwaysOnExtraMonthly
        $extra | Should -BeGreaterThan 1
        # Two ceilings between the two worst cases, as 375 and 390 lie between a Contributor's 371.48 and 398.23 at the
        # 2026-11-19 list prices (ADR 0016).
        foreach ($share in 0.13, 0.69) {
            $ceiling = [System.Math]::Round($sessionMonth + $extra * $share, 2)
            $monthly = (& $estimate $ceiling 'AlwaysOn' $true).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
            $monthly.status | Should -Be 'Warning' -Because ('a ceiling of {0} fits the month with the container for the running hours only' -f $ceiling)
            $exception = $monthly.evidence.t5CeilingException
            [System.Math]::Abs($exception.sessionMonthlyUsd - $sessionMonth) | Should -BeLessOrEqual 0.011
            $exception.t5AlwaysOnExtraMonthly | Should -Be $extra
            # After an Owner's grant: T4's restart about a day each (96 hours) instead of the rest of the month (720), at 0.18 an hour.
            [System.Math]::Abs($exception.grantMonthlyUsd - ($exception.sessionMonthlyUsd - 0.18 * 720 + 0.18 * 96)) | Should -BeLessOrEqual 0.011
            $monthly.evidence.t4AutoRestartWorstCaseMonthly | Should -Be 129.6
            $monthly.evidence.t4AutoRestartWithSafetyStopMonthly | Should -Be 17.28 -Because 'DEPLOY.T5.LIFECYCLE names the same month after a grant'
            $monthly.message | Should -Match ('^lowest-cost: the month''s worst case is {0} USD, {1} USD over the hard ceiling of {2} USD\.' -f (& $money $alwaysMonth), (& $money ($alwaysMonth - $ceiling)), (& $money $ceiling))
            $monthly.message | Should -Match 'its container exists only during a session, but only \./scripts/stop-demo\.ps1 deletes it after one, since the session control has no role and the nightly safety stop''s role can''t'
            $monthly.message | Should -Match ('This is a Warning, not a Fail: T5''s container is priced all month, {0} USD more than for the running hours only, because no role can delete it automatically after a session \(the session control has no role, and the nightly safety stop''s role can''t delete it\), so only \./scripts/stop-demo\.ps1 does; with it deleted after each session, the month would be {1} USD, within the ceiling\.$' -f (& $money $extra), (& $money $exception.sessionMonthlyUsd))
            $monthly.remediation | Should -Match ('^deploy\.ps1 and start-demo\.ps1 go on\. To clear it, any one of these: an Owner of the subscription runs, once: \./scripts/grant-safety-stop\.ps1 -ConfigPath \./config/demo\.config\.json, which gives the session control and the nightly safety stop their roles, so the worst case falls to about {0} USD; or raise monthlyCeilingUsd to at least {1} in your configuration' -f (& $money $exception.grantMonthlyUsd), [System.Math]::Ceiling($alwaysMonth))
            $monthly.remediation | Should -Match 'or set t5Enabled to false, which leaves T5 out\. Until then, run \./scripts/stop-demo\.ps1 after each session: it deletes T5''s container\.$'
            $monthly.evidence.ceilingWarning | Should -Match ('^The month''s worst case is {0} USD, {1} USD over the hard ceiling of {2} USD\. This is a Warning, not a Fail: ' -f (& $money $alwaysMonth), (& $money ($alwaysMonth - $ceiling)), (& $money $ceiling))
            $config['monthlyCeilingUsd'] | Should -Be $ceiling -Because 'the configured ceiling never changes'
        }
        # Over the ceiling even with the container for the running hours only: still a Fail.
        $over = (& $estimate ([System.Math]::Round($sessionMonth - 1, 2)) 'AlwaysOn' $true).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $over.status | Should -Be 'Fail'
        $over.message | Should -Not -Match 'This is a Warning'
        $over.evidence.Contains('t5CeilingException') | Should -BeFalse
        # All month for another reason (a session-control role without the container's actions, so no stop deletes it): a Fail.
        $kept = (& $estimate ([System.Math]::Round($sessionMonth + $extra * 0.5, 2)) 'AlwaysOn' $false).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $kept.status | Should -Be 'Fail'
        $kept.message | Should -Match 'its container stays between sessions until the session control''s role can create it'
        # Within the ceiling: a Pass, which says nothing of a Warning.
        ((& $estimate ([System.Math]::Ceiling($alwaysMonth) + 1) 'AlwaysOn' $true).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Pass'
    }

    It 'counts no Bastion hour by default, since a default deployment and session have none, and -BastionHours counts it (2026-11-19, the docs audit)' {
        # Only start-demo.ps1 -Interactive deploys Bastion, and its cost guardrail passes -BastionHours.
        $default = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -NetworkMode public
        $default.BastionHours | Should -Be 0
        $default.BastionHourly | Should -BeGreaterThan 0 -Because 'its hourly price is still read and shown'
        $with = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        [System.Math]::Abs(($with.SessionCost - $default.SessionCost) - $with.BastionHourly) | Should -BeLessOrEqual 0.011
        [System.Math]::Abs(($with.LightUseMonthly - $default.LightUseMonthly) - $with.BastionHourly) | Should -BeLessOrEqual 0.011
        (($default.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').evidence.bastionHours) | Should -Be 0
    }

    It 'counts a nightly safety stop that this run sets up, and keeps the worst case without it for DEPLOY.COST.T4RESTART (2026-11-19, the coordinator''s option 2)' {
        $config = New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }
        $planned = [pscustomobject]@{ Counts = $true; Planned = $true; Missing = ''; Reason = 'deploy.ps1 sets up the nightly safety stop in this run, right after its template, and you can assign its role'; Fix = ''; Evidence = [ordered]@{ counts = $true }; WithoutReason = 'the nightly safety stop isn''t in place yet'; WithoutFix = 'Run ./scripts/deploy.ps1.' }
        $estimate = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T4RestartCoverage $planned
        $estimate.T4RestartHours | Should -Be 96
        $monthly = $estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $without = [System.Math]::Round($estimate.LightUseMonthly + 0.18 * 720, 2)
        $monthly.evidence.t4RestartPlanned | Should -BeTrue
        $monthly.evidence.t4AutoRestartWorstCaseWithoutSafetyStopMonthly | Should -Be ([System.Math]::Round(0.18 * 720, 2))
        $monthly.evidence.monthlyWorstCaseWithoutSafetyStop | Should -Be $without
        $monthly.evidence.monthlyWorstCase | Should -Be ([System.Math]::Round($estimate.LightUseMonthly + 0.18 * 96, 2))
        $monthly.evidence.t4RestartWithoutReason | Should -Match 'isn''t in place yet'
        $monthly.message | Should -Match 'and deploy\.ps1 sets up the nightly safety stop in this run, right after its template, and you can assign its role, so the worst case counts up to 4 restarts'
        $monthly.message | Should -Match ('If its setup in this run doesn''t put it in place, the worst case is {0} USD a month, which the run then says \(DEPLOY\.COST\.T4RESTART\)\.' -f [regex]::Escape($without.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture)))
        # A safety stop that's already in place has no worst case without it.
        $inPlace = [pscustomobject]@{ Counts = $true; Missing = ''; Reason = 'the nightly safety stop is in place'; Fix = ''; Evidence = [ordered]@{ counts = $true } }
        $kept = (Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T4RestartCoverage $inPlace).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $kept.evidence.t4RestartPlanned | Should -BeFalse
        $kept.evidence.Contains('monthlyWorstCaseWithoutSafetyStop') | Should -BeFalse
        $kept.message | Should -Not -Match 'DEPLOY\.COST\.T4RESTART'
    }
    It 'keeps today''s monthly ceiling at <Ceiling> USD: a Warning only for init''s old 250 when only T4''s default size puts the month over it (R727, 2026-11-09)' -ForEach @(
        @{ Ceiling = 250; Legacy = $true }
        @{ Ceiling = 249; Legacy = $false }
        @{ Ceiling = 300; Legacy = $false }
    ) {
        # T4's default since 2026-11-04, Standard_D4ds_v5, with its 7-day restart's worst case for the rest of the month.
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; monthlyCeilingUsd = $Ceiling }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $month = [System.Math]::Round($estimate.LightUseMonthly + $estimate.T4AutoRestartWorstCaseMonthly, 2)
        $month | Should -BeGreaterThan 300 -Because 'the fixtures put the default size over every ceiling here'
        # Standard_B1ms, T4's default when init.ps1 wrote 250 (2026-10-27 to 2026-11-04), fits 250.
        $old = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms'; monthlyCeilingUsd = 250 }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($old.LightUseMonthly + $old.T4AutoRestartWorstCaseMonthly) | Should -BeLessOrEqual 250
        $monthly = $estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        if (-not $Legacy) {
            $monthly.status | Should -Be 'Fail'
            $monthly.message | Should -Not -Match 'This is a Warning'
            $monthly.evidence.Contains('ceilingReference') | Should -BeFalse
            return
        }
        $monthly.status | Should -Be 'Warning'
        $monthly.message | Should -Match ([regex]::Escape(' This is a Warning, not a Fail: monthlyCeilingUsd is 250, which init.ps1 wrote by default from 2026-10-27 to 2026-11-04, when T4''s default size was Standard_B1ms; with T4 at that size the month would be '))
        $monthly.message | Should -Match ('T4 at Standard_D4ds_v5 brings it to {0} USD\.' -f [regex]::Escape($month.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture)))
        $monthly.remediation | Should -Match ('^Raise monthlyCeilingUsd to at least {0} in your configuration \(the budget follows it at the next deploy\.ps1 -FromStage Infrastructure\), or keep it: deploy\.ps1 and start-demo\.ps1 go on, the Azure budget alerts at 50, 80, and 100 percent of it, and start-demo\.ps1 stops starting the demo once this month''s actual cost reaches it\.' -f [System.Math]::Ceiling($month))
        $monthly.remediation | Should -Not -Match 't4SkuName'
        $monthly.evidence.ceilingReference.skuName | Should -Be 'Standard_B1ms'
        $monthly.evidence.ceilingReference.reason | Should -Be 'init250'
        # Only the default size: a t4SkuName you set keeps the Fail.
        $pinned = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D4ds_v5'; monthlyCeilingUsd = 250 }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($pinned.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
    }

    It 'makes the monthly ceiling a Warning when only a size the fallback chose for t4SkuName puts the month over it, and a Fail otherwise (2026-11-09)' {
        $config = New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms'; monthlyCeilingUsd = 150 }
        # Azure refused Standard_B1ms, and the fallback created Standard_D2ds_v5, which the record stands in with.
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5'; T4Refused = 'Standard_B1ms@any;2026-11-09T21:25:00Z' }) }
        $resolved['t4SkuName'] | Should -Be 'Standard_D2ds_v5'
        $estimate = Get-DemoCostEstimate -Config $resolved -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($estimate.LightUseMonthly + $estimate.T4AutoRestartWorstCaseMonthly) | Should -BeGreaterThan 150
        $monthly = $estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.status | Should -Be 'Warning'
        $monthly.message | Should -Match ' This is a Warning, not a Fail: T4 runs as Standard_D2ds_v5 only because Azure refused Standard_B1ms, the size t4SkuName sets \(deploy\.ps1''s fallback chose Standard_D2ds_v5\), and with T4 at Standard_B1ms the month would be \d+\.\d\d USD, within the ceiling; Standard_D2ds_v5 brings it to \d+\.\d\d USD\.'
        $monthly.evidence.ceilingReference.reason | Should -Be 'fallback'
        # The same size set on purpose is over the ceiling: a Fail, as before.
        $chosen = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5'; monthlyCeilingUsd = 150 }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($chosen.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
        # And a month over the ceiling even at the asked size stays a Fail.
        $tight = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms'; monthlyCeilingUsd = 20 }) } { Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5'; T4Refused = 'Standard_B1ms@any' }) }
        $strict = Get-DemoCostEstimate -Config $tight -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($strict.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
    }
    It 'fails the monthly ceiling when T4''s restart worst case pushes the estimate over it' {
        $first = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        # A ceiling above the light-use month but below it plus the 14.40 USD worst case.
        $ceiling = [System.Math]::Ceiling($first.LightUseMonthly) + 1
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; monthlyCeilingUsd = $ceiling }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $estimate.LightUseMonthly | Should -BeLessThan $ceiling
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
    }

    It 'prices T4''s General Purpose fallback for its cost check: every hour of a month, with storage, DNS, and the Defender plans, against both ceilings (Phase 28 follow-up)' {
        $plans = @($defenderPlans) + @([pscustomobject]@{ name = 'OpenSourceRelationalDatabases'; pricingTier = 'Standard'; subPlan = $null })
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDefenderPlan -MockWith { $plans }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $config = New-TestConfig -Override @{ t4Enabled = $true }
        $cost = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode public -T3UseFreeLimit $false }
        $cost.SkuName | Should -Be 'Standard_D2ds_v5'
        $cost.HourlyUsd | Should -Be 0.18 -Because '2 vCores at the fixture''s hourly vCore meter, not the reservation'
        # T4 alone, every hour: storage 3.20 + DNS 0.50 + Defender for open-source relational databases 15.00 + CSPM
        # 0.012 x 730 (27.46 fixed), plus 730 hours of compute.
        $cost.T4MonthlyWorstCaseUsd | Should -Be ([System.Math]::Round(27.46 + 0.18 * 730, 2))
        $cost.DefenderIncluded | Should -BeTrue
        @($cost.Unpriced) | Should -BeNullOrEmpty
        # The demo's month with it is what PREFLIGHT.COST.MONTHLY checks: the light-use month plus the restart's worst case,
        # without T4's read replica's share, which never changes a size verdict (ADR 0025, 2026-11-13).
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }) -NetworkMode public -DefenderPlans $plans -T3UseFreeLimit $false
        $cost.MonthlyWorstCaseUsd | Should -Be ([System.Math]::Round($estimate.LightUseMonthlyWithoutReplica + $estimate.T4AutoRestartWorstCaseMonthly, 2))
        $cost.SessionUsd | Should -Be $estimate.SessionCostWithoutReplica
        $estimate.SessionCostWithoutReplica | Should -BeLessThan $estimate.SessionCost -Because 'the estimate itself counts the replica'
        $cost.Allowed | Should -Be ($cost.MonthlyWorstCaseUsd -le 250 -and $cost.SessionUsd -le 15)
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { [uri]::UnescapeDataString($Uri) -match "productName eq 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'" }

        # Defender for Cloud plans that can't be read are named, never guessed.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDefenderPlan -MockWith { throw 'AuthorizationFailed' }
        $unread = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode public -T3UseFreeLimit $false }
        $unread.DefenderIncluded | Should -BeFalse
        @($unread.Unpriced) | Should -Contain 'Microsoft Defender for Cloud (the subscription''s plans weren''t read)'
    }

    It 'prices T4''s read replica for each session only: its compute at T4''s size, its storage by the hour, and its Defender plans, with no restart to count (ADR 0025)' {
        $plans = @($defenderPlans) + @([pscustomobject]@{ name = 'OpenSourceRelationalDatabases'; pricingTier = 'Standard'; subPlan = $null })
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $plans
        $replica = @($estimate.Components | Where-Object Name -Match 'T4 read replica')
        $compute = $replica | Where-Object Name -EQ 'T4 read replica compute (Standard_D4ds_v5; for each session only)'
        $compute.Basis | Should -Be 'running'
        $compute.UnitPrice | Should -Be 0.09 -Because 'T4''s own vCore meter: the replica follows T4''s size'
        $compute.Quantity | Should -Be 4
        $storage = $replica | Where-Object Name -EQ 'T4 read replica storage (for each session only)'
        $storage.Basis | Should -Be 'running'
        $storage.Quantity | Should -Be (32 / 730) -Because '32 GiB for one of the month''s 730 hours'
        ($replica | Where-Object Name -Match 'open-source relational').Quantity | Should -Be (1 / 730)
        ($replica | Where-Object Name -Match 'Defender CSPM').Cost | Should -Be 0.012
        @($replica | Where-Object Basis -NE 'running').Count | Should -Be 0 -Because 'nothing of it bills between sessions'
        $hourly = 0.36 + [System.Math]::Round(0.10 * 32 / 730, 4) + [System.Math]::Round(15.0 / 730, 4) + 0.012
        $estimate.T4ReplicaIncluded | Should -BeTrue
        $estimate.T4ReplicaHourly | Should -Be ([System.Math]::Round($hourly, 4))
        $estimate.T4ReplicaSession | Should -Be ([System.Math]::Round($hourly * 5, 2))
        $estimate.T4ReplicaMonthly | Should -Be ([System.Math]::Round($hourly * 10, 2))
        $estimate.SessionCost | Should -BeGreaterThan $estimate.SessionCostWithoutReplica
        [System.Math]::Abs($estimate.SessionCost - ($estimate.SessionCostWithoutReplica + $hourly * 5)) | Should -BeLessOrEqual 0.011 -Because 'both totals are rounded to the cent'
        [System.Math]::Abs($estimate.LightUseMonthly - ($estimate.LightUseMonthlyWithoutReplica + $hourly * 10)) | Should -BeLessOrEqual 0.011
        # It's deleted, not stopped, after a session, so T4's restart worst case and fixed costs stay T4's own.
        $estimate.T4AutoRestartWorstCaseMonthly | Should -Be ([System.Math]::Round(0.09 * 4 * (730 - 10), 2))
        $estimate.T4FixedMonthly | Should -Be 27.46
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').message | Should -Match ('T4''s read replica, which exists only during a session, is {0:N2} USD of it \(start-demo\.ps1 -SkipT4Replica starts a session without it\)' -f $estimate.T4ReplicaSession)
        ($estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'T4''s read replica exists only during a session .+ nothing between sessions, with no automatic restart to count'

        # A Burstable T4 has none: Azure doesn't support read replicas there.
        $burstable = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $plans
        @($burstable.Components | Where-Object Name -Match 'read replica').Count | Should -Be 0
        $burstable.T4ReplicaIncluded | Should -BeFalse
        $burstable.SessionCost | Should -Be $burstable.SessionCostWithoutReplica
        ($burstable.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').message | Should -Not -Match 'read replica'
    }

    It 'leaves T4''s read replica out of T4''s size verdicts: a demo-day session that only its share puts over sessionCeilingUsd warns, and T4''s one-time move to the default is still allowed (2026-11-13)' {
        $plans = @($defenderPlans) + @([pscustomobject]@{ name = 'OpenSourceRelationalDatabases'; pricingTier = 'Standard'; subPlan = $null })
        $config = New-TestConfig -Override @{ t4Enabled = $true }
        $priced = Get-DemoCostEstimate -Config $config -ProfileName 'demo-day' -NetworkMode public -DefenderPlans $plans -T3UseFreeLimit $false
        # The session ceiling between the two totals, as demo-day's 2026-11-13 example had it: 14.75 USD without the
        # replica, 16.56 with it, against 15.
        $config['sessionCeilingUsd'] = [System.Math]::Round(($priced.SessionCostWithoutReplica + $priced.SessionCost) / 2, 2)
        $config['monthlyCeilingUsd'] = 100000
        $estimate = Get-DemoCostEstimate -Config $config -ProfileName 'demo-day' -NetworkMode public -DefenderPlans $plans -T3UseFreeLimit $false
        $session = $estimate.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION'
        $session.status | Should -Be 'Warning' -Because 'the session with the replica is over the ceiling'
        $session.message | Should -Match ('is {0:N2} USD of it \(start-demo\.ps1 -SkipT4Replica' -f $estimate.T4ReplicaSession)
        # deploy.ps1's move of an older T4 to Standard_D4ds_v5 is gated on this verdict (Invoke-DemoTemplateDeployment), as
        # before the replica.
        $move = InModuleScope DbHubDemo -Parameters @{ Estimate = $estimate; Config = $config } { ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $Config -SkuName 'Standard_D4ds_v5' }
        $move.Allowed | Should -BeTrue
        $move.SkipReason | Should -Be ''
        $move.SessionUsd | Should -Be $estimate.SessionCostWithoutReplica
        $move.LightUseMonthlyUsd | Should -Be $estimate.LightUseMonthlyWithoutReplica
        # An estimate without the replica's totals (from before it) is read as before.
        $older = [pscustomobject]@{ LightUseMonthly = 50.0; T4AutoRestartWorstCaseMonthly = 100.0; SessionCost = 9.0; T4FixedMonthly = 5.0; DefenderIncluded = $true; MissingPrices = @(); Components = @([pscustomobject]@{ Name = 'T4 compute (Standard_D4ds_v5)'; UnitPrice = 0.09; Quantity = 4 }) }
        $read = InModuleScope DbHubDemo -Parameters @{ Estimate = $older; Config = $config } { ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $Config -SkuName 'Standard_D4ds_v5' }
        $read.SessionUsd | Should -Be 9.0
        $read.MonthlyWorstCaseUsd | Should -Be 150.0
    }

    It 'reads each price once for estimates that share a price cache, as preflight''s General Purpose check does (Phase 28 follow-up)' {
        $script:priceUris = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith {
            $script:priceUris.Add($Uri)
            $filter = [uri]::UnescapeDataString(($Uri -split '\$filter=')[1])
            $items = @()
            foreach ($fragment in $priceFixtures.Keys) {
                if ($filter.Contains($fragment)) {
                    $items = @($priceFixtures[$fragment] | ForEach-Object { [pscustomobject]$_ })
                    break
                }
            }
            [pscustomobject]@{ Items = $items; NextPageLink = $null }
        }
        $cache = @{}
        Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_B1ms' }) -NetworkMode public -PriceCache $cache | Out-Null
        $first = $script:priceUris.Count
        $generalPurpose = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }) -NetworkMode public -PriceCache $cache
        @($script:priceUris | Select-Object -Skip $first).Count | Should -Be 1 -Because 'only T4''s General Purpose compute is new'
        [uri]::UnescapeDataString($script:priceUris[-1]) | Should -Match 'General Purpose Ddsv5 Series Compute'
        ($generalPurpose.Components | Where-Object Name -EQ 'T4 compute (Standard_D2ds_v5)').UnitPrice | Should -Be 0.09
        # Without a shared cache, each estimate reads its own prices, as before.
        $script:priceUris.Clear()
        Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }) -NetworkMode public | Out-Null
        $script:priceUris.Count | Should -Be $first
    }

    It 'prices the lowest-cost profile from retail prices' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        # Running: T1 0.20 + SQL 0.40 + host 0.30 + Arc 0.10 x 4 cores (the per-OSE minimum for the 2-vCPU guest)
        # + T3 0.50 x 2 vCores (since 2026-11-18: Database Agents doesn't support one-vCore serverless databases) = 2.30 per hour.
        $estimate.HourlyRunning | Should -Be 2.3
        ($estimate.Components | Where-Object Name -EQ 'T3 compute (serverless)').Quantity | Should -Be 2
        $estimate.BastionHourly | Should -Be 0.2
        # Idle: 2 x E10 OS disks at 10.00 (lowest-cost has no data disks) + T3 32 GB x 0.10 = 23.20 per month, and the session
        # control's vault operations, 0.03 (every deployment since 2026-11-14). There's no artifact cache.
        $estimate.IdleMonthly | Should -Be 23.23
        $estimate.SessionCost | Should -Be 11.7
        $estimate.LightUseMonthly | Should -Be 46.43
        $estimate.MissingPrices | Should -BeNullOrEmpty
        $estimate.Components.Name | Should -Not -Match 'cache|data disk'
    }

    It 'prices T5''s container for the running hours only with the Session lifecycle, the default, and its private endpoint and DNS zone all month (2026-11-19, ADR 0027)' {
        # 40 running hours a month, so the container's share differs from the 10-hour default's.
        $base = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public
        $session = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public -T5FreeTier $false
        $t5 = @($session.Components | Where-Object Name -Match '^T5 ')
        # 400 RU/s = 4 x 100 RU/s at 0.008 for each hour the container exists; about 1 GB at 0.25 a GB-month, by the hour.
        $throughput = $t5 | Where-Object Name -Match '^T5 throughput'
        $throughput.Basis | Should -Be 'running'
        $throughput.Quantity | Should -Be 4
        $throughput.Cost | Should -Be 0.032
        $storage = $t5 | Where-Object Name -Match '^T5 storage'
        $storage.Basis | Should -Be 'running'
        $storage.Quantity | Should -Be (1.0 / 730)
        # The account's private endpoint (in public mode too: 0.01 x 730) and its DNS zone stay between sessions.
        ($t5 | Where-Object Name -EQ 'T5 private endpoint').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -EQ 'T5 private endpoint').Cost | Should -Be 7.3
        ($t5 | Where-Object Name -EQ 'T5 private DNS zone').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -EQ 'T5 private DNS zone').Cost | Should -Be 0.5
        $session.T5ContainerLifecycle | Should -Be 'Session'
        $session.T5FixedMonthly | Should -Be 7.8
        $session.T5RunningHourly | Should -Be 0.0323
        $session.IdleMonthly | Should -Be ([System.Math]::Round($base.IdleMonthly + 7.8, 2))
        # The light-use month bills the container for its 40 running hours only, and a 5-hour session for 5.
        [System.Math]::Round($session.LightUseMonthly - $base.LightUseMonthly, 2) | Should -Be ([System.Math]::Round(7.8 + 0.0323 * 40, 2))
        [System.Math]::Round($session.SessionCost - $base.SessionCost, 2) | Should -Be ([System.Math]::Round(0.0323 * 5, 2))
        # What AlwaysOn adds: the container's month, 23.36 + 0.25, less its 40 running hours.
        $session.T5AlwaysOnExtraMonthly | Should -Be ([System.Math]::Round(23.61 - 0.0323 * 40, 2))
        $monthly = $session.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'T5 \(Azure Cosmos DB\) costs 7\.80 USD a month whether the demo runs or not \(its private endpoint and private DNS zone\)\. Its container exists only during a session \(.+\), so its 400 RU/s of throughput and its storage add 0\.032 USD a running hour\.'
        $monthly.message | Should -Match 'doesn''t have the free tier'
        $monthly.message | Should -Match 'If the session control holds a role without the container''s actions \(an update by someone who isn''t an Owner, until an Owner runs \./scripts/grant-safety-stop\.ps1 once\), the container stays between sessions and adds about 22\.32 USD a month\.'
        $monthly.evidence.monthlyWorstCase | Should -Be $session.LightUseMonthly -Because 'without T4, the worst case is the light-use month'
        $monthly.evidence.t5ContainerLifecycle | Should -Be 'Session'
        @($session.MissingPrices) | Should -BeNullOrEmpty

        $unchecked = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public
        $unchecked.T5RunningHourly | Should -Be 0.0323 -Because 'an unchecked free tier is priced at list price, an upper bound'
        $unchecked.T5FreeTier | Should -BeNullOrEmpty
        ($unchecked.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'wasn''t checked, so its throughput is at list price, an upper bound'
    }

    It 'prices T5''s container all month with the AlwaysOn lifecycle, while the session control''s role can''t create it (2026-11-19, ADR 0027)' {
        $base = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public
        $alwaysOn = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public -T5FreeTier $false -T5ContainerLifecycle AlwaysOn
        $t5 = @($alwaysOn.Components | Where-Object Name -Match '^T5 ')
        # 400 RU/s = 4 x 100 RU/s for 730 hours at 0.008; 1 GB at 0.25; the private endpoint and its DNS zone as with Session.
        ($t5 | Where-Object Name -Match '^T5 throughput').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -Match '^T5 throughput').Cost | Should -Be 23.36
        ($t5 | Where-Object Name -Match '^T5 storage').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -Match '^T5 storage').Cost | Should -Be 0.25
        ($t5 | Where-Object Name -EQ 'T5 private endpoint').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -EQ 'T5 private endpoint').Cost | Should -Be 7.3
        ($t5 | Where-Object Name -EQ 'T5 private DNS zone').Basis | Should -Be 'idle'
        ($t5 | Where-Object Name -EQ 'T5 private DNS zone').Cost | Should -Be 0.5
        $alwaysOn.T5ContainerLifecycle | Should -Be 'AlwaysOn'
        $alwaysOn.T5FixedMonthly | Should -Be 31.41
        $alwaysOn.T5RunningHourly | Should -Be 0
        $alwaysOn.HourlyRunning | Should -Be $base.HourlyRunning -Because 'nothing of T5 is a running cost while its container stays'
        [System.Math]::Round($alwaysOn.LightUseMonthly - $base.LightUseMonthly, 2) | Should -Be 31.41 -Because 'all month, however many hours the demo runs'
        $alwaysOn.T5AlwaysOnExtraMonthly | Should -Be ([System.Math]::Round(23.61 - 0.0323 * 40, 2)) -Because 'what the Session lifecycle saves'
        $monthly = $alwaysOn.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'T5 \(Azure Cosmos DB\) costs 31\.41 USD a month whether the demo runs or not \(its 400 RU/s of throughput, storage, private endpoint, and private DNS zone\): its container stays between sessions until the session control''s role can create it\.'
        $monthly.message | Should -Match 'Once \./scripts/deploy\.ps1 runs as an Owner of the subscription, or an Owner runs \./scripts/grant-safety-stop\.ps1 once, the container exists only during a session, which saves about 22\.32 USD a month\.'
        $monthly.evidence.t5ContainerLifecycle | Should -Be 'AlwaysOn'
    }

    It 'prices T5''s throughput at zero on the free tier with the <Lifecycle> lifecycle, so its private endpoint and DNS zone are all it bills (2026-11-19, ADR 0027)' -ForEach @(
        @{ Lifecycle = 'Session'; Basis = 'running' }
        @{ Lifecycle = 'AlwaysOn'; Basis = 'idle' }
    ) {
        $free = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 40 -BastionHours 1 -NetworkMode public -T5FreeTier $true -T5ContainerLifecycle $Lifecycle
        $throughput = $free.Components | Where-Object Name -Match '^T5 throughput'
        $throughput.Meter | Should -Match 'Free Tier'
        $throughput.Basis | Should -Be $Basis
        $throughput.Cost | Should -Be 0
        ($free.Components | Where-Object Name -EQ 'T5 private endpoint').Basis | Should -Be 'idle'
        ($free.Components | Where-Object Name -EQ 'T5 private DNS zone').Basis | Should -Be 'idle'
        $free.T5FixedMonthly | Should -Be 7.8 -Because 'the private endpoint and its DNS zone still bill'
        $free.T5RunningHourly | Should -Be 0
        $free.T5AlwaysOnExtraMonthly | Should -Be 0 -Because 'the free tier covers the container whenever it exists'
        $monthly = ($free.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message
        $monthly | Should -Match 'has the subscription''s free tier'
        $monthly | Should -Not -Match 'adds about|saves about'
    }

    It 'prices Defender for Azure Cosmos DB on T5''s provisioned throughput while its container exists, and attributes the plan (2026-11-19, ADR 0027)' {
        $plans = @($defenderPlans) + @([pscustomobject]@{ name = 'CosmosDbs'; pricingTier = 'Standard'; subPlan = $null })
        $session = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $plans -T5FreeTier $true
        $defender = $session.Components | Where-Object Name -Match 'Defender for Azure Cosmos DB'
        $defender.Meter | Should -Match 'Standard 100 RU/s$' -Because 'the Standard meter, not the trial'
        $defender.Basis | Should -Be 'running'
        $defender.Cost | Should -Be 0.0048 -Because '4 x 100 RU/s at 0.0012 for each hour the container exists, free tier or not'
        $session.T5FixedMonthly | Should -Be 7.8
        $session.T5RunningHourly | Should -Be 0.0048
        $session.T5AlwaysOnExtraMonthly | Should -Be ([System.Math]::Round(3.504 - 0.0048 * 10, 2))
        ($session.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'so its 400 RU/s of throughput, its storage, and Defender for Azure Cosmos DB add 0\.005 USD a running hour\.'
        $message = ($session.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.DEFENDER').message
        $message | Should -Match 'CosmosDbs'
        $message | Should -Not -Match 'not attributed to the demo: [^.]*CosmosDbs'
        @($session.Components | Where-Object { $_.Name -match 'CSPM' -and $_.Name -match 'T5' }) | Should -BeNullOrEmpty -Because 'Defender CSPM doesn''t bill Cosmos DB accounts'

        $alwaysOn = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t5Enabled = $true }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $plans -T5FreeTier $true -T5ContainerLifecycle AlwaysOn
        $defender = $alwaysOn.Components | Where-Object Name -Match 'Defender for Azure Cosmos DB'
        $defender.Basis | Should -Be 'idle'
        $defender.Cost | Should -Be 3.504 -Because '4 x 100 RU/s for 730 hours at 0.0012, free tier or not'
        $alwaysOn.T5FixedMonthly | Should -Be 11.3
        [System.Math]::Abs(($alwaysOn.DefenderMonthly - $session.DefenderMonthly) - (3.504 - 0.0048 * 10)) | Should -BeLessOrEqual 0.011
    }

    It 'counts business-day''s T3 incidents, which the shipped share already prices at T3''s maximum, so both ceilings hold as before (2026-11-03)' {
        $unset = New-TestConfig
        $unset.Remove('activityProfile')
        $default = Get-DemoCostEstimate -Config $unset -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $quiet = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ activityProfile = 'baseline' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $default.ActivityProfile | Should -Be 'business-day'
        $quiet.ActivityProfile | Should -Be 'baseline'
        # T3 at its maximum, 2 vCores x 0.50, for every running hour already (t3ActiveShareOfMaxVcores 1.0): nothing to add.
        $default.T3BusinessDaySession | Should -Be 0
        $default.T3BusinessDayMonthly | Should -Be 0
        $default.SessionCost | Should -Be $quiet.SessionCost
        $default.LightUseMonthly | Should -Be $quiet.LightUseMonthly
        @($default.Components | Where-Object Name -Match 'business-day') | Should -BeNullOrEmpty
        $session = $default.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION'
        $session.status | Should -Be 'Pass'
        $session.message | Should -Match 'With activityProfile business-day, T3''s incidents run at its maximum vCores 10 of every 60 minutes; the estimate already prices T3 at its maximum for every running hour, so they add nothing\.'
        $monthly = $default.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY'
        $monthly.status | Should -Be 'Pass'
        $monthly.message | Should -Match 'they add nothing'
        $session.evidence.activityProfile | Should -Be 'business-day'
        $session.evidence.activityProfileSource | Should -Be 'default'
        $session.evidence.t3IncidentShare | Should -Be 0.1667
        ($quiet.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').message | Should -Not -Match 'business-day'
    }

    It 'adds the T3 increment from the retail price when the assumed share is below the maximum, and -ActivityProfile picks the profile (2026-11-03)' {
        $catalog = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable
        $catalog['assumptions']['t3ActiveShareOfMaxVcores'] = 0.5
        $script:halfShare = $catalog
        Mock -ModuleName DbHubDemo -CommandName Get-DemoProfile -MockWith { $script:halfShare }
        $businessDay = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $baseline = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -ActivityProfile 'baseline'
        # 2 vCores x (1 - 0.5) x 10/60 of each hour at the fixture's 0.50 per vCore-hour: about 0.0833 an hour.
        $increment = $businessDay.Components | Where-Object Name -EQ 'T3 compute, business-day incidents (10 of every 60 minutes at the maximum vCores)'
        $increment.UnitPrice | Should -Be 0.5
        [System.Math]::Round([double]$increment.Quantity, 4) | Should -Be 0.1667
        $businessDay.T3BusinessDaySession | Should -Be 0.42 -Because '0.1667 x 5 hours x 0.50'
        $businessDay.T3BusinessDayMonthly | Should -Be 0.83 -Because '0.1667 x 10 hours x 0.50'
        [System.Math]::Round($businessDay.SessionCost - $baseline.SessionCost, 2) | Should -Be 0.42
        [System.Math]::Round($businessDay.LightUseMonthly - $baseline.LightUseMonthly, 2) | Should -Be 0.83
        @($baseline.Components | Where-Object Name -Match 'business-day') | Should -BeNullOrEmpty
        ($businessDay.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').message | Should -Match 'adds 0\.42 USD to a session and 0\.83 USD to the light-use month before the free allowance'
        ($businessDay.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').status | Should -Be 'Pass'
        ($businessDay.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { [uri]::UnescapeDataString($Uri) -match 'Serverless - Compute Gen5' }

        # The free offer's allowance covers the increment too, and is used faster.
        $free = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T3UseFreeLimit $true
        $freeBaseline = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T3UseFreeLimit $true -ActivityProfile 'baseline'
        $free.T3FreeOfferCreditMonthly | Should -BeGreaterThan $freeBaseline.T3FreeOfferCreditMonthly
        $free.LightUseMonthly | Should -Be $freeBaseline.LightUseMonthly -Because 'at light use the allowance covers T3 either way'
    }

    It 'prices T2 golden snapshots per GB-month on their provisioned size, as Standard HDD when incremental (ADR 0018)' {
        $snapshot = [pscustomobject]@{ Name = 'snap-dbhub-t2golden-202610221306'; Sku = 'Standard_LRS'; SizeGiB = 128; UsedGiB = 37; Incremental = $true }
        $without = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $with = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -GoldenSnapshots @($snapshot)
        $component = $with.Components | Where-Object { $_.Name -like 'T2 golden snapshot*' }
        $component.Quantity | Should -Be 128
        $component.UnitPrice | Should -Be 0.05
        $component.Basis | Should -Be 'idle'
        $component.Name | Should -Match 'about 37 GiB used'
        $with.IdleMonthly | Should -Be ([System.Math]::Round($without.IdleMonthly + 6.4, 2))
        $with.SessionCost | Should -Be $without.SessionCost
        $with.MissingPrices | Should -BeNullOrEmpty
    }

    It 'adds the nightly safety stop''s job minutes to every estimate, at the included tier (ADR 0024)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $minutes = $estimate.Components | Where-Object { $_.Name -like 'Nightly safety stop job minutes*' }
        @($minutes).Count | Should -Be 1
        # The first 500 job minutes a month are included: the tier that starts at 0 is the one priced, so it adds nothing.
        $minutes.UnitPrice | Should -Be 0
        $minutes.Quantity | Should -Be 120
        $minutes.Basis | Should -Be 'idle'
        $minutes.Cost | Should -Be 0
        $estimate.MissingPrices | Should -BeNullOrEmpty
    }
    It 'adds the session control''s vault operations and job minutes to every estimate, whatever an older configuration says (ADR 0026)' {
        $with = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ control = @{ enabled = $false } }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $operations = $with.Components | Where-Object { $_.Name -eq 'Activity control vault operations' }
        $operations.Meter | Should -Be 'Key Vault / Standard / Operations'
        $operations.Quantity | Should -Be 1
        $operations.Basis | Should -Be 'idle'
        # The first 500 job minutes a month are included: the tier that starts at 0 is the one priced. Two sessions in the
        # light-use month (10 hours of 5), at 80 minutes each, with the nightly stop's 120, stay within them.
        $minutes = $with.Components | Where-Object { $_.Name -like 'Activity control job minutes*' }
        @($minutes).Count | Should -Be 1
        $minutes.UnitPrice | Should -Be 0
        $minutes.Quantity | Should -Be 160
        $operations.Cost | Should -Be 0.03
        $with.MissingPrices | Should -BeNullOrEmpty
    }

    It 'prices the session control''s job minutes past the 500 included at the next tier, 80 a session, with the time it follows T2 after a cold start (2026-11-20)' {
        # Business hours: 176 hours of 5 are 36 sessions, 2,880 minutes; the nightly stop's 120 leave 380 of the 500.
        $busy = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 176 -BastionHours 1 -NetworkMode public
        $included = $busy.Components | Where-Object { $_.Name -eq 'Activity control job minutes (the first 500 a month are included)' }
        $included.Quantity | Should -Be 380
        $included.Cost | Should -Be 0
        $paid = $busy.Components | Where-Object { $_.Name -eq 'Activity control job minutes past the 500 included' }
        $paid.Quantity | Should -Be 2500
        $paid.UnitPrice | Should -Be 0.002
        $paid.Cost | Should -Be 5
        $busy.MissingPrices | Should -BeNullOrEmpty
    }

    It 'subtracts the free-offer allowance from the light-use month and keeps the session at list price' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T3UseFreeLimit $true
        # Storage: the offer covers 32 GB, so idle is 2 x E10 at 10.00 = 20.00.
        $estimate.IdleMonthly | Should -Be 20.03
        # The session stays at list price: 2.30 x 5 + 0.20 = 11.70.
        $estimate.SessionCost | Should -Be 11.7
        # Allowance: 10 hours x 2 vCores = 20 vCore-hours (72,000 vCore-seconds, within the 100,000) x 0.50 = 10.00.
        # Month: 20 + 2.30 x 10 + 0.20 - 10.00 = 33.20, as at 1 vCore: the allowance covers T3 at light use either way.
        $estimate.T3FreeOfferCreditMonthly | Should -Be 10
        $estimate.LightUseMonthly | Should -Be 33.23
        $estimate.T3FreeOffer | Should -BeTrue
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'free offer'
    }

    It 'caps the free-offer allowance at 100,000 vCore-seconds a month' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -LightUseHoursPerMonth 50 -NetworkMode public -T3UseFreeLimit $true
        # 100,000 / 3,600 = 27.78 vCore-hours x 0.50 = 13.89.
        $estimate.T3FreeOfferCreditMonthly | Should -Be 13.89
    }

    It 'prices T3 as regular serverless when the free offer is unavailable' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T3UseFreeLimit $false
        $estimate.LightUseMonthly | Should -Be 46.43
        $estimate.T3FreeOffer | Should -BeFalse
        $estimate.T3FreeOfferUnchecked | Should -BeFalse
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Not -Match 'free offer'
    }

    It 'prices T3 as regular serverless and says so when the free offer was not checked' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $estimate.LightUseMonthly | Should -Be 46.43
        $estimate.T3FreeOfferUnchecked | Should -BeTrue
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'free offer wasn''t checked'
    }

    It 'does not mention the free offer when t3FreeOffer is off' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t3FreeOffer = 'off' }) -ProfileName 'lowest-cost' -NetworkMode public
        $estimate.T3FreeOfferUnchecked | Should -BeFalse
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Not -Match 'free offer'
    }

    It 'uses the Global Arc meter, not a sovereign-cloud one' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost'
        ($estimate.Components | Where-Object Name -eq 'T2 Arc SQL Standard PAYG').UnitPrice | Should -Be 0.10
    }

    It 'bills the four-core minimum per OSE by default for the 2-vCPU guest' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost'
        ($estimate.Components | Where-Object Name -eq 'T2 Arc SQL Standard PAYG').Quantity | Should -Be 4
    }

    It 'bills the configured Arc core count when t2ArcBillableCores is set' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t2ArcBillableCores = 8 }) -ProfileName 'lowest-cost'
        ($estimate.Components | Where-Object Name -eq 'T2 Arc SQL Standard PAYG').Quantity | Should -Be 8
    }

    It 'uses Spot prices only when Spot is selected' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ hostPriority = 'Spot'; t1Priority = 'Spot' }) -ProfileName 'lowest-cost'
        ($estimate.Components | Where-Object Name -eq 'T2 host compute').UnitPrice | Should -Be 0.06
        ($estimate.Components | Where-Object Name -eq 'T1 compute').UnitPrice | Should -Be 0.05
    }

    It 'applies Azure Hybrid Benefit: Linux-rate compute and no SQL license charge' {
        $config = New-TestConfig -Override @{ hybridBenefit = @{ windows = $true; sql = $true; entitlementAttested = $true } }
        $estimate = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost'
        ($estimate.Components | Where-Object Name -eq 'T1 compute').UnitPrice | Should -Be 0.10
        ($estimate.Components | Where-Object Name -eq 'T1 SQL Server license').Cost | Should -Be 0
    }

    It 'leaves out Arc billing in Developer mode' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'Developer' }) -ProfileName 'lowest-cost'
        $estimate.Components.Name | Should -Not -Contain 'T2 Arc SQL Standard PAYG'
    }

    It 'adds the private endpoint and DNS zone in private mode and the NAT gateway in NatGateway mode' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ networkMode = 'private'; outboundMode = 'NatGateway' }) -ProfileName 'lowest-cost'
        $estimate.Components.Name | Should -Contain 'T3 private endpoint'
        $estimate.Components.Name | Should -Contain 'T3 private DNS zone'
        $estimate.Components.Name | Should -Contain 'NAT gateway'
        $estimate.Components.Name | Should -Contain 'NAT gateway public IP'
        $estimate.NetworkModeAssumed | Should -BeFalse
    }

    It 'prices the private endpoint and the NAT gateway from their Global meters' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ outboundMode = 'NatGateway' }) -ProfileName 'lowest-cost' -NetworkMode private
        $endpoint = $estimate.Components | Where-Object Name -eq 'T3 private endpoint'
        $endpoint.Meter | Should -Be 'Virtual Network Private Link / Standard / Standard Private Endpoint'
        $endpoint.UnitPrice | Should -Be 0.01
        ($estimate.Components | Where-Object Name -eq 'NAT gateway').Meter | Should -Be 'NAT Gateway / Standard / Standard Gateway'
        $estimate.MissingPrices | Should -BeNullOrEmpty
    }

    It 'prices the private DNS zone from the first tier of the commercial meter' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode private
        $zone = $estimate.Components | Where-Object Name -eq 'T3 private DNS zone'
        $zone.UnitPrice | Should -Be 0.50
        $zone.Basis | Should -Be 'idle'
        ($estimate.Components | Where-Object Name -eq 'T3 private endpoint').Cost | Should -Be 7.3
    }

    It 'uses the effective network mode over the configuration: public adds no private endpoint' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ networkMode = 'private' }) -ProfileName 'lowest-cost' -NetworkMode public
        $estimate.NetworkMode | Should -Be 'public'
        $estimate.Components.Name | Should -Not -Contain 'T3 private endpoint'
        $estimate.Components.Name | Should -Not -Contain 'T3 private DNS zone'
    }

    It 'assumes private mode when networkMode auto is unresolved, and says so' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ networkMode = 'auto' }) -ProfileName 'lowest-cost'
        $estimate.NetworkMode | Should -Be 'private'
        $estimate.NetworkModeAssumed | Should -BeTrue
        $estimate.Components.Name | Should -Contain 'T3 private DNS zone'
        $monthly = $estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'assumes private mode'
        $monthly.evidence.networkModeAssumed | Should -BeTrue
    }

    It 'warns that Defender for Cloud is excluded when no plans are given' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode public
        $estimate.DefenderIncluded | Should -BeFalse
        @($estimate.Components | Where-Object Defender) | Should -BeNullOrEmpty
        $defender = $estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.DEFENDER'
        $defender.status | Should -Be 'Warning'
        $defender.message | Should -Match 'excludes Microsoft Defender for Cloud'
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Not -Match 'Defender'
    }

    It 'prices the Defender plans that bill the demo''s resources on their billing basis' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 4 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -DefenderPlans $defenderPlans
        $servers = @($estimate.Components | Where-Object Name -like 'Defender for Servers P2 *')
        $servers.Name | Should -Be @('Defender for Servers P2 (T1)', 'Defender for Servers P2 (T2 host)', 'Defender for Servers P2 (Arc machine arcsql01)')
        # The regional meter wins over Global, and the MDATP benefit meter is never used.
        $servers.UnitPrice | Should -Be @(0.025, 0.025, 0.025)
        $servers.Basis | Should -Be @('running', 'running', 'running')
        @($estimate.Components | Where-Object Name -like 'Defender for SQL on machines *').Basis | Should -Be @('running', 'running')
        $t3 = $estimate.Components | Where-Object Name -eq 'Defender for Azure SQL (T3 server)'
        $t3.Basis | Should -Be 'idle'
        $t3.Quantity | Should -Be 730
        $t3.Cost | Should -Be 14.6
        @($estimate.Components | Where-Object Name -like 'Defender CSPM *').Basis | Should -Be @('running', 'running', 'idle')
        $estimate.Components.Name | Should -Not -Match 'Defender for Storage|Resource Manager|Key Vault'

        # Running: 2.30 + Servers 3 x 0.025 + SQL 2 x 0.02 + CSPM 2 x 0.012 = 2.439 per hour.
        $estimate.HourlyRunning | Should -Be 2.44
        # Idle: 23.20 + Defender for Azure SQL 0.02 x 730 + CSPM 0.012 x 730 = 46.56 per month.
        $estimate.IdleMonthly | Should -Be 46.59
        $estimate.SessionCost | Should -Be 9.96
        $estimate.LightUseMonthly | Should -Be 71.18
        $estimate.DefenderSession | Should -Be 0.56
        $estimate.DefenderMonthly | Should -Be 24.75
    }

    It 'reports the Arc SQL worst case without adding it to the totals' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -LightUseHoursPerMonth 10 -NetworkMode public -DefenderPlans $defenderPlans
        # 0.02 per instance-hour for the 720 hours a month the Arc SQL instance isn't running.
        $estimate.ArcSqlDefenderWorstCaseMonthly | Should -Be 14.4
        $monthly = $estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY'
        $monthly.message | Should -Match 'of which Defender for Cloud: 24\.75 USD'
        $monthly.message | Should -Match '14\.40 USD'
        $monthly.evidence.arcSqlDefenderWorstCaseMonthly | Should -Be 14.4
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.SESSION').message | Should -Match 'of which Defender for Cloud'
    }

    It 'explains the Defender plans it included and left out' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans $defenderPlans
        $defender = $estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.DEFENDER'
        $defender.status | Should -Be 'Pass'
        $defender.message | Should -Match 'VirtualMachines \(P2\), SqlServerVirtualMachines, SqlServers, CloudPosture'
        $defender.message | Should -Match 'creates no storage accounts'
        $defender.message | Should -Match 'attributed to the demo: Arm\.'
        $defender.evidence.notAttributed | Should -Be 'Arm'
    }

    It 'prices Defender for Servers Plan 1 with the P1 meter' {
        $plans = @([pscustomobject]@{ name = 'VirtualMachines'; pricingTier = 'Standard'; subPlan = 'P1' })
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans $plans
        @($estimate.Components | Where-Object Name -like 'Defender for Servers P1 *').UnitPrice | Should -Be @(0.007, 0.007, 0.007)
    }

    It 'ignores plans on the Free tier and accepts an empty plan list' {
        $free = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans @([pscustomobject]@{ name = 'VirtualMachines'; pricingTier = 'Free'; subPlan = $null })
        $none = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans @()
        foreach ($estimate in $free, $none) {
            $estimate.DefenderIncluded | Should -BeTrue
            @($estimate.Components | Where-Object Defender) | Should -BeNullOrEmpty
            ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.DEFENDER').message | Should -Match 'Defender adds nothing'
        }
    }

    It 'checks the hard monthly ceiling against totals that include Defender' {
        # Without Defender the light-use month is 46.43; with it, 71.18.
        $config = New-TestConfig -Override @{ monthlyCeilingUsd = 50 }
        $without = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans @()
        ($without.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Pass'
        $with = Get-DemoCostEstimate -Config $config -ProfileName 'lowest-cost' -NetworkMode public -DefenderPlans $defenderPlans
        ($with.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
    }

    It 'fails a light-use month above the hard monthly ceiling, and only warns about a long session' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ sessionCeilingUsd = 1; monthlyCeilingUsd = 10 }) -ProfileName 'lowest-cost'
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.SESSION').status | Should -Be 'Warning'
        $monthly = $estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY'
        $monthly.status | Should -Be 'Fail'
        $monthly.message | Should -Match 'hard ceiling of 10\.00 USD'
        $monthly.remediation | Should -Match 'cheaper profile or options'
        $monthly.remediation | Should -Match 'raise monthlyCeilingUsd'
    }

    It 'uses a 415 USD monthly ceiling and a 20 USD session ceiling by default (415 since 2026-11-19, 375 before; 20 since 2026-11-18)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DefenderPlans $defenderPlans
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'hard ceiling of 415\.00 USD'
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.SESSION').message | Should -Match 'ceiling of 20\.00 USD'
    }

    It 'checks a session against 20 USD for a configuration that still says 15, the default before 2026-11-18, and against any other value as set' {
        $legacyPath = Join-Path -Path $TestDrive -ChildPath 'legacy-session-ceiling.json'
        $file = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $file['sessionCeilingUsd'] = 15
        $file | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyPath -Encoding utf8NoBOM
        $legacy = Get-DemoConfig -Path $legacyPath
        $legacy['t4Enabled'] = $false
        # T5's container bills by the running hour since 2026-11-19 (ADR 0027); off here, as in New-TestConfig.
        $legacy['t5Enabled'] = $false
        # Ask's relay is priced in its own test; this one checks the ceiling, at the figure below without it.
        $legacy['ask'] = @{ enabled = $false; image = ''; githubClientId = '' }
        # The fixture's lowest-cost session, 11.70 USD, is between the two ceilings: a Pass against 20, not a Warning against 15.
        $session = (Get-DemoCostEstimate -Config $legacy -ProfileName 'lowest-cost' -DemoHours 5 -BastionHours 1 -NetworkMode public -DefenderPlans @()).Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION'
        $session.status | Should -Be 'Pass'
        $session.message | Should -Match 'is estimated at 11\.70 USD \(of which Defender for Cloud: 0\.00 USD\) against a ceiling of 20\.00 USD'
        $set = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ sessionCeilingUsd = 11 }) -ProfileName 'lowest-cost' -DemoHours 5 -BastionHours 1 -NetworkMode public -DefenderPlans @()
        ($set.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').status | Should -Be 'Warning' -Because 'a value someone set stays'
        # T4's cost checks (ConvertTo-DemoT4FallbackCost) read the same configuration.
        $verdict = InModuleScope DbHubDemo -Parameters @{ Config = $legacy } { ConvertTo-DemoT4FallbackCost -Estimate ([pscustomobject]@{ LightUseMonthly = 50.0; T4AutoRestartWorstCaseMonthly = 100.0; SessionCost = 18.0; T4FixedMonthly = 5.0; DefenderIncluded = $true; MissingPrices = @(); Components = @([pscustomobject]@{ Name = 'T4 compute (Standard_D4ds_v5)'; UnitPrice = 0.09; Quantity = 4 }) }) -Config $Config -SkuName 'Standard_D4ds_v5' }
        $verdict.SessionCeilingUsd | Should -Be 20
        $verdict.SkipReason | Should -Be ''
    }

    It 'passes when estimates are within the ceilings' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -DefenderPlans @()
        ($estimate.Results | Where-Object checkId -like 'PREFLIGHT.COST.*').status | Should -Not -Contain 'Warning'
    }

    It 'reports missing prices as a Warning instead of guessing' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { [pscustomobject]@{ Items = @(); NextPageLink = $null } }
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DefenderPlans $defenderPlans
        $estimate.HourlyRunning | Should -Be 0
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.PRICES').status | Should -Be 'Warning'
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.PRICES').message | Should -Match 'Defender for Servers P2 \(T1\)'
    }

    It 'prices demo-day data disks as Premium SSD v2 with a zone, with baseline IOPS and throughput free' {
        $hoursPerMonth = (Get-DemoProfile).assumptions.hoursPerMonth
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = '1' }) -ProfileName 'demo-day'
        foreach ($name in 'T1 data disk (Premium SSD v2, 128 GiB)', 'T2 host data disk (Premium SSD v2, 128 GiB)') {
            $disk = $estimate.Components | Where-Object Name -eq $name
            $disk.UnitPrice | Should -Be 0.0001
            $disk.Quantity | Should -Be (128 * $hoursPerMonth)
            $disk.Cost | Should -Be ([System.Math]::Round(0.0001 * 128 * $hoursPerMonth, 4))
        }
        ($estimate.Components.Name -join '|') | Should -Not -Match 'above baseline'
        ($estimate.Components | Where-Object Name -eq 'T1 OS disk (E10)').Cost | Should -Be 10
        $estimate.MissingPrices | Should -BeNullOrEmpty
    }

    It 'defaults demo-day data disks to Standard SSD (E10) without a zone, within the monthly ceiling' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = $null }) -ProfileName 'demo-day'
        ($estimate.Components | Where-Object Name -eq 'T1 data disk (E10)').Cost | Should -Be 10
        ($estimate.Components | Where-Object Name -eq 'T2 host data disk (E10)').Cost | Should -Be 10
        ($estimate.Components.Name -join '|') | Should -Not -Match 'P10|Premium SSD v2'
    }

    It 'uses Premium SSD P10 data disks only when dataDiskSku opts in' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = $null; dataDiskSku = 'P10' }) -ProfileName 'demo-day'
        ($estimate.Components | Where-Object Name -eq 'T1 data disk (P10)').Cost | Should -Be 20
        ($estimate.Components | Where-Object Name -eq 'T2 host data disk (P10)').Cost | Should -Be 20
    }

    It 'fails when the P10 opt-in pushes the light-use month over the hard monthly ceiling' {
        $config = New-TestConfig -Override @{ zone = $null; dataDiskSku = 'P10' }
        $standard = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = $null }) -ProfileName 'demo-day' -DemoHours 5 -LightUseHoursPerMonth 10
        # Put the ceiling between the E10 and P10 light-use months, so only the opt-in crosses it.
        $config['monthlyCeilingUsd'] = $standard.LightUseMonthly + 1
        $premium = Get-DemoCostEstimate -Config $config -ProfileName 'demo-day' -DemoHours 5 -LightUseHoursPerMonth 10
        $premium.LightUseMonthly | Should -BeGreaterThan $config['monthlyCeilingUsd']
        ($premium.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').status | Should -Be 'Fail'
    }

    It 'forces Standard SSD even with a zone when dataDiskSku is E10' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = '1'; dataDiskSku = 'E10' }) -ProfileName 'demo-day'
        ($estimate.Components | Where-Object Name -eq 'T1 data disk (E10)').Cost | Should -Be 10
        ($estimate.Components.Name -join '|') | Should -Not -Match 'Premium SSD v2'
    }

    It 'prices Premium SSD v2 for a profile without a zonal tier when dataDiskSku is PremiumV2 and a zone is set' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = '3'; dataDiskSku = 'PremiumV2' }) -ProfileName 'lowest-cost'
        $estimate.Components.Name | Should -Contain 'T1 data disk (Premium SSD v2, 128 GiB)'
        $estimate.Components.Name | Should -Contain 'T2 host data disk (Premium SSD v2, 128 GiB)'
    }

    It 'keeps the lowest-cost profile without data disks, even with a zone' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = '2' }) -ProfileName 'lowest-cost'
        ($estimate.Components.Name -join '|') | Should -Not -Match 'data disk|Premium SSD v2'
        ($estimate.Components | Where-Object Name -eq 'T1 OS disk (E10)').Cost | Should -Be 10
        ($estimate.Components | Where-Object Name -eq 'T2 host OS disk (E10)').Cost | Should -Be 10
        $estimate.MissingPrices | Should -BeNullOrEmpty
    }

    It 'adds Standard SSD data disks to lowest-cost only when dataDiskSku is E10' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ dataDiskSku = 'E10' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        ($estimate.Components | Where-Object Name -eq 'T1 data disk (E10)').Cost | Should -Be 10
        ($estimate.Components | Where-Object Name -eq 'T2 host data disk (E10)').Cost | Should -Be 10
        # The two data disks add 2 x 10.00 to the default 46.43.
        $estimate.LightUseMonthly | Should -Be 66.43
    }

    It 'removes the demo-day data disks when dataDiskSku is None' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ zone = '1'; dataDiskSku = 'None' }) -ProfileName 'demo-day'
        ($estimate.Components.Name -join '|') | Should -Not -Match 'data disk'
        $estimate.MissingPrices | Should -BeNullOrEmpty
    }
}

Describe 'Get-DemoRetailPrice' {
    It 'follows NextPageLink until the last page' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { $Uri -notmatch 'page=2' } -MockWith {
            [pscustomobject]@{ Items = @([pscustomobject]@{ meterName = 'a' }); NextPageLink = 'https://prices.azure.com/api/retail/prices?page=2' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { $Uri -match 'page=2' } -MockWith {
            [pscustomobject]@{ Items = @([pscustomobject]@{ meterName = 'b' }); NextPageLink = $null }
        }
        $items = Get-DemoRetailPrice -Filter "serviceName eq 'Azure Bastion'"
        $items.meterName | Should -Be @('a', 'b')
    }
}

Describe 'Get-DemoDefenderPlan' {
    It 'reads the plans with az security pricing list and returns name, tier, and sub-plan: <Shape>' -ForEach @(
        @{ Shape = 'a list'; Json = '[{"name":"VirtualMachines","pricingTier":"Standard","subPlan":"P2","id":"x"},{"name":"Dns","pricingTier":"Free","subPlan":null}]' }
        @{ Shape = 'a value wrapper'; Json = '{"value":[{"name":"VirtualMachines","pricingTier":"Standard","subPlan":"P2"},{"name":"Dns","pricingTier":"Free"}]}' }
    ) {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $Json; StdErr = '' } }
        $plans = @(Get-DemoDefenderPlan -SubscriptionId '11111111-2222-3333-4444-555555555555')
        $plans.Count | Should -Be 2
        $plans[0].name | Should -Be 'VirtualMachines'
        $plans[0].pricingTier | Should -Be 'Standard'
        $plans[0].subPlan | Should -Be 'P2'
        $plans[1].subPlan | Should -Be ''
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '^security pricing list --subscription 11111111-2222-3333-4444-555555555555 --output json$'
        }
    }
}

Describe 'No fix text asks for a cheaper T4 size (2026-11-09)' {
    It 'names no Burstable size to set, in the module''s scripts or the configuration schema' {
        # A tester's configuration pinned Standard_B1ms, most likely after an agent followed PREFLIGHT.COST.MONTHLY's old fix
        # "set t4SkuName to Standard_B1ms"; Azure then refused that size. Raising monthlyCeilingUsd is the fix for a cost Fail,
        # and the fallback chooses T4's size when Azure refuses one (ADR 0019).
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
        $files = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'scripts') -Recurse -File -Include '*.ps1', '*.psm1')
        $files += Get-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/environment.schema.json')
        $files.Count | Should -BeGreaterThan 50
        $hits = @($files | Select-String -Pattern 'set t4SkuName to Standard_B(1ms|2s)' | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
        $hits | Should -BeNullOrEmpty
    }
}
