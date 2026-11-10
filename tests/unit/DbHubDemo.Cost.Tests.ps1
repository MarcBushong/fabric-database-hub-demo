BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
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
        "serviceName eq 'Automation'"                                                         = @(
            @{ productName = 'Automation'; skuName = 'Basic'; meterName = 'Basic Runtime'; retailPrice = 0.002; unitOfMeasure = '1 Minute'; tierMinimumUnits = 500 }
            @{ productName = 'Automation'; skuName = 'Basic'; meterName = 'Basic Runtime'; retailPrice = 0.0; unitOfMeasure = '1 Minute'; tierMinimumUnits = 0 }
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
        # T4 (Phase 24) has its own tests below; the others keep their totals with T4 off.
        $config['t4Enabled'] = $false
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
        # The demo's month with it is what PREFLIGHT.COST.MONTHLY checks: the light-use month plus the restart's worst case.
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ t4Enabled = $true; t4SkuName = 'Standard_D2ds_v5' }) -NetworkMode public -DefenderPlans $plans -T3UseFreeLimit $false
        $cost.MonthlyWorstCaseUsd | Should -Be ([System.Math]::Round($estimate.LightUseMonthly + $estimate.T4AutoRestartWorstCaseMonthly, 2))
        $cost.SessionUsd | Should -Be $estimate.SessionCost
        $cost.Allowed | Should -Be ($cost.MonthlyWorstCaseUsd -le 250 -and $cost.SessionUsd -le 15)
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -ParameterFilter { [uri]::UnescapeDataString($Uri) -match "productName eq 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'" }

        # Defender for Cloud plans that can't be read are named, never guessed.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDefenderPlan -MockWith { throw 'AuthorizationFailed' }
        $unread = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode public -T3UseFreeLimit $false }
        $unread.DefenderIncluded | Should -BeFalse
        @($unread.Unpriced) | Should -Contain 'Microsoft Defender for Cloud (the subscription''s plans weren''t read)'
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
        # + T3 0.50 x 1 vCore = 1.80 per hour.
        $estimate.HourlyRunning | Should -Be 1.8
        $estimate.BastionHourly | Should -Be 0.2
        # Idle: 2 x E10 OS disks at 10.00 (lowest-cost has no data disks) + T3 32 GB x 0.10 = 23.20 per month.
        # There's no artifact cache.
        $estimate.IdleMonthly | Should -Be 23.2
        $estimate.SessionCost | Should -Be 9.2
        $estimate.LightUseMonthly | Should -Be 41.4
        $estimate.MissingPrices | Should -BeNullOrEmpty
        $estimate.Components.Name | Should -Not -Match 'cache|data disk'
    }

    It 'counts business-day''s T3 incidents, which the shipped share already prices at T3''s maximum, so both ceilings hold as before (2026-11-03)' {
        $unset = New-TestConfig
        $unset.Remove('activityProfile')
        $default = Get-DemoCostEstimate -Config $unset -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $quiet = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ activityProfile = 'baseline' }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $default.ActivityProfile | Should -Be 'business-day'
        $quiet.ActivityProfile | Should -Be 'baseline'
        # T3 at its maximum, 1 vCore x 0.50, for every running hour already (t3ActiveShareOfMaxVcores 1.0): nothing to add.
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
        # 1 vCore x (1 - 0.5) x 10/60 of each hour at the fixture's 0.50 per vCore-hour: about 0.0417 an hour.
        $increment = $businessDay.Components | Where-Object Name -EQ 'T3 compute, business-day incidents (10 of every 60 minutes at the maximum vCores)'
        $increment.UnitPrice | Should -Be 0.5
        [System.Math]::Round([double]$increment.Quantity, 4) | Should -Be 0.0833
        $businessDay.T3BusinessDaySession | Should -Be 0.21 -Because '0.0833 x 5 hours x 0.50'
        $businessDay.T3BusinessDayMonthly | Should -Be 0.42 -Because '0.0833 x 10 hours x 0.50'
        [System.Math]::Round($businessDay.SessionCost - $baseline.SessionCost, 2) | Should -Be 0.21
        [System.Math]::Round($businessDay.LightUseMonthly - $baseline.LightUseMonthly, 2) | Should -Be 0.42
        @($baseline.Components | Where-Object Name -Match 'business-day') | Should -BeNullOrEmpty
        ($businessDay.Results | Where-Object checkId -EQ 'PREFLIGHT.COST.SESSION').message | Should -Match 'adds 0\.21 USD to a session and 0\.42 USD to the light-use month before the free allowance'
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
    It 'adds the on-demand activity control''s vault operations and job minutes only when control.enabled is true (ADR 0020)' {
        $without = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $without.Components.Name | Should -Not -Match 'Activity control'
        $with = Get-DemoCostEstimate -Config (New-TestConfig -Override @{ control = @{ enabled = $true } }) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $operations = $with.Components | Where-Object { $_.Name -eq 'Activity control vault operations' }
        $operations.Meter | Should -Be 'Key Vault / Standard / Operations'
        $operations.Quantity | Should -Be 1
        $operations.Basis | Should -Be 'idle'
        # The first 500 job minutes a month are included: the tier that starts at 0 is the one priced.
        $minutes = $with.Components | Where-Object { $_.Name -like 'Activity control job minutes*' }
        $minutes.UnitPrice | Should -Be 0
        $minutes.Quantity | Should -Be 60
        $with.IdleMonthly | Should -Be ([System.Math]::Round($without.IdleMonthly + 0.03, 2))
        $with.SessionCost | Should -Be $without.SessionCost
        $with.MissingPrices | Should -BeNullOrEmpty
    }

    It 'subtracts the free-offer allowance from the light-use month and keeps the session at list price' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public -T3UseFreeLimit $true
        # Storage: the offer covers 32 GB, so idle is 2 x E10 at 10.00 = 20.00.
        $estimate.IdleMonthly | Should -Be 20
        # The session stays at list price: 1.80 x 5 + 0.20 = 9.20.
        $estimate.SessionCost | Should -Be 9.2
        # Allowance: 10 vCore-hours x 0.50 = 5.00. Month: 20 + 1.80 x 10 + 0.20 - 5.00 = 33.20.
        $estimate.T3FreeOfferCreditMonthly | Should -Be 5
        $estimate.LightUseMonthly | Should -Be 33.2
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
        $estimate.LightUseMonthly | Should -Be 41.4
        $estimate.T3FreeOffer | Should -BeFalse
        $estimate.T3FreeOfferUnchecked | Should -BeFalse
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Not -Match 'free offer'
    }

    It 'prices T3 as regular serverless and says so when the free offer was not checked' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DemoHours 5 -LightUseHoursPerMonth 10 -BastionHours 1 -NetworkMode public
        $estimate.LightUseMonthly | Should -Be 41.4
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

        # Running: 1.80 + Servers 3 x 0.025 + SQL 2 x 0.02 + CSPM 2 x 0.012 = 1.939 per hour.
        $estimate.HourlyRunning | Should -Be 1.94
        # Idle: 23.20 + Defender for Azure SQL 0.02 x 730 + CSPM 0.012 x 730 = 46.56 per month.
        $estimate.IdleMonthly | Should -Be 46.56
        $estimate.SessionCost | Should -Be 7.96
        $estimate.LightUseMonthly | Should -Be 66.15
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
        # Without Defender the light-use month is 41.40; with it, 66.15.
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

    It 'uses a 375 USD monthly ceiling and a 15 USD session ceiling by default (375 since 2026-11-04)' {
        $estimate = Get-DemoCostEstimate -Config (New-TestConfig) -ProfileName 'lowest-cost' -DefenderPlans $defenderPlans
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.MONTHLY').message | Should -Match 'hard ceiling of 375\.00 USD'
        ($estimate.Results | Where-Object checkId -eq 'PREFLIGHT.COST.SESSION').message | Should -Match 'ceiling of 15\.00 USD'
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
        # The two data disks add 2 x 10.00 to the default 41.40.
        $estimate.LightUseMonthly | Should -Be 61.4
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
