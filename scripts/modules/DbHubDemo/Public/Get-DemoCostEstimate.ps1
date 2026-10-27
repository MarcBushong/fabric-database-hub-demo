function Get-DemoCostEstimate {
    <#
    .SYNOPSIS
    Estimates the demo's cost for one profile from live Azure retail prices (ADR 0016).

    .DESCRIPTION
    Prices come from the public Azure Retail Prices API at run time; nothing is hard-coded. SQL Server
    license meters (Virtual Machines Licenses) and Arc SQL meters (Azure Arc Enabled Databases) are
    published in the Global region. The Arc billable core count is the t2ArcBillableCores setting, or
    the larger of the guest vCPU count and the documented minimum of four cores per OSE
    (arc.billing.minimumCoresPerOse in config/versions.json).

    Microsoft Defender for Cloud is included when -DefenderPlans is given (Get-DemoDefenderPlan reads
    the plans). Only plans on the Standard tier count, on the billing basis Microsoft documents:
    - Defender for Servers (VirtualMachines, P1 or P2): T1 and the T2 host while they're running (Azure
      VMs aren't billed when deallocated), and the Arc machine arcsql01 while it's Connected, which is
      while the T2 host runs.
    - Defender for SQL servers on machines (SqlServerVirtualMachines): the T1 and Arc SQL instances while
      they run. Billing for a disconnected Arc SQL instance isn't documented, so the worst case (billed
      all month) is reported but left out of the totals.
    - Defender for Azure SQL (SqlServers): the T3 server, all month.
    - Defender for open-source relational databases (OpenSourceRelationalDatabases): the T4 server, per month,
      stopped or not (Phase 24, ADR 0019).
    - Defender CSPM (CloudPosture): T1 and the T2 host while they aren't deallocated, the T4 server all month, and the T3 server
      all month. Arc machines aren't billable resources.
    - Defender for Storage: the deployment creates no storage accounts, so it adds nothing.
    Subscription-wide plans, such as Defender for Resource Manager, aren't attributed to the demo.
    Without -DefenderPlans the estimate excludes Defender and reports a Warning.

    Returns hourly running cost, one demo-day session, idle monthly cost, and a light-use month, plus
    validation results that compare them with the configured ceilings. The monthly ceiling is hard: a
    light-use month above monthlyCeilingUsd is Fail. A session above sessionCeilingUsd is a Warning. A
    missing price is reported as a Warning and left out of the totals, never guessed. Data disk tiers
    follow the template through Resolve-DemoDataDiskTier (ADR 0016): an explicit dataDiskSku wins;
    otherwise a zone selects Premium SSD v2 (capacity per GiB-hour; the baseline IOPS and throughput are
    free), and no zone selects the profile's regional tier. Tier None, the lowest-cost default, adds no
    data disk.

    .PARAMETER NetworkMode
    The effective network mode from Resolve-DemoNetworkMode. Without it, a public or private value in
    the configuration is used, and auto is assumed to resolve to private, the more expensive mode.

    .PARAMETER DefenderPlans
    Defender for Cloud plans with name, pricingTier, and subPlan, as 'az security pricing list' returns
    them (Get-DemoDefenderPlan). An empty list means no plan is on Standard.

    .PARAMETER T3UseFreeLimit
    Whether T3 uses the Azure SQL Database free offer, from Get-DemoT3FreeOfferStatus. With it, the
    light-use month subtracts the offer's monthly allowance (100,000 vCore-seconds) and the first 32 GB of
    data storage; the session stays at list price, an upper bound. Without it, T3 is priced as regular
    serverless, and when t3FreeOffer is auto the monthly message says the offer wasn't checked.

    .PARAMETER GoldenSnapshots
    The T2 golden snapshots in rg-<prefix>-golden (Get-DemoT2GoldenSnapshot; ADR 0018). Each is an idle
    monthly cost: the snapshot price per GB-month for its storage type (incremental snapshots are stored as
    Standard HDD, LRS or ZRS) on the provisioned size, an upper bound: Azure bills an incremental snapshot's
    used size, which only the usage report shows (the used size is in the component's name).

    .EXAMPLE
    Get-DemoCostEstimate -Config (Get-DemoConfig -Path ./config/demo.config.json)

    .EXAMPLE
    Get-DemoCostEstimate -Config $config -NetworkMode private -DefenderPlans @(Get-DemoDefenderPlan -SubscriptionId $config.subscriptionId)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('lowest-cost', 'demo-day', 'enhanced-performance')]
        [string] $ProfileName,

        [ValidateRange(-1, 24)]
        [double] $DemoHours = -1,

        [ValidateRange(-1, 744)]
        [double] $LightUseHoursPerMonth = -1,

        [ValidateRange(-1, 24)]
        [double] $BastionHours = -1,

        [ValidatePattern('^[A-Z]{3}$')]
        [string] $CurrencyCode = 'USD',

        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [AllowEmptyCollection()]
        [object[]] $DefenderPlans,

        [bool] $T3UseFreeLimit,

        [AllowEmptyCollection()]
        [object[]] $GoldenSnapshots = @()
    )

    $catalog = Get-DemoProfile
    if (-not $ProfileName) {
        $ProfileName = $Config['profile']
    }
    $sizing = $catalog.profiles[$ProfileName]
    $assumptions = $catalog.assumptions
    if ($DemoHours -lt 0) { $DemoHours = $assumptions.demoHoursPerSession }
    if ($LightUseHoursPerMonth -lt 0) { $LightUseHoursPerMonth = $assumptions.lightUseHoursPerMonth }
    if ($BastionHours -lt 0) { $BastionHours = $assumptions.bastionHoursPerSession }
    $hoursPerMonth = $assumptions.hoursPerMonth
    $location = $Config['location']

    $networkModeAssumed = $false
    $effectiveNetworkMode = if ($NetworkMode) {
        $NetworkMode
    }
    elseif ($Config['networkMode'] -in 'public', 'private') {
        [string]$Config['networkMode']
    }
    else {
        $networkModeAssumed = $true
        'private'
    }

    $priceCache = @{}
    $components = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    function Get-CachedPrice([string] $Filter) {
        if (-not $priceCache.ContainsKey($Filter)) {
            $priceCache[$Filter] = @(Get-DemoRetailPrice -Filter $Filter -CurrencyCode $CurrencyCode)
        }
        return $priceCache[$Filter]
    }

    function Add-Component([string] $Name, [string] $Basis, [object] $Item, [double] $Quantity, [string] $Unit, [switch] $Defender) {
        if ($null -eq $Item) {
            $missing.Add($Name)
            return
        }
        $components.Add([pscustomobject]@{
                Name      = $Name
                Basis     = $Basis
                Meter     = ('{0} / {1} / {2}' -f $Item.productName, $Item.skuName, $Item.meterName)
                UnitPrice = [double]$Item.retailPrice
                Quantity  = $Quantity
                Unit      = $Unit
                Cost      = [System.Math]::Round([double]$Item.retailPrice * $Quantity, 4)
                Defender  = [bool]$Defender
            })
    }

    function Select-VmPrice([string] $Size, [bool] $Spot, [bool] $HybridBenefit) {
        $items = Get-CachedPrice "serviceName eq 'Virtual Machines' and armRegionName eq '$location' and armSkuName eq '$Size' and priceType eq 'Consumption'"
        $wantWindows = -not $HybridBenefit
        $candidates = @($items | Where-Object { (($_.productName -match 'Windows') -eq $wantWindows) -and $_.unitOfMeasure -eq '1 Hour' })
        if ($Spot) {
            return ($candidates | Where-Object { $_.skuName -match 'Spot' } | Select-Object -First 1)
        }
        return ($candidates | Where-Object { $_.skuName -notmatch 'Spot|Low Priority' } | Select-Object -First 1)
    }

    function Select-DiskPrice([string] $Sku) {
        $product = if ($Sku.StartsWith('P')) { 'Premium SSD Managed Disks' } else { 'Standard SSD Managed Disks' }
        $items = Get-CachedPrice "serviceName eq 'Storage' and armRegionName eq '$location' and skuName eq '$Sku LRS' and priceType eq 'Consumption'"
        return ($items | Where-Object { $_.productName -eq $product -and $_.meterName -eq "$Sku LRS Disk" } | Select-Object -First 1)
    }

    # Some meters (Defender, Private Link, NAT Gateway) are published only under Global; a regional meter
    # wins when both exist. The meter name must match exactly: other Private Link meters cost far more.
    function Select-HourlyPrice([string] $Filter, [string] $Meter) {
        $items = Get-CachedPrice "$Filter and priceType eq 'Consumption' and (armRegionName eq '$location' or armRegionName eq 'Global')"
        $candidates = @($items | Where-Object { $_.meterName -eq $Meter -and $_.unitOfMeasure -match '^1\s*/?\s*Hour$' })
        $regional = $candidates | Where-Object { $_.armRegionName -eq $location } | Select-Object -First 1
        if ($regional) {
            return $regional
        }
        return ($candidates | Where-Object { $_.armRegionName -eq 'Global' } | Select-Object -First 1)
    }

    $hybridWindows = [bool]$Config['hybridBenefit']['windows']
    $hybridSql = [bool]$Config['hybridBenefit']['sql']

    # Running (per hour)
    Add-Component 'T1 compute' 'running' (Select-VmPrice $sizing.t1.size ($Config['t1Priority'] -eq 'Spot') $hybridWindows) 1 'hour'
    if ($hybridSql) {
        $components.Add([pscustomobject]@{ Name = 'T1 SQL Server license'; Basis = 'running'; Meter = 'Azure Hybrid Benefit (AHUB)'; UnitPrice = 0.0; Quantity = 1; Unit = 'hour'; Cost = 0.0; Defender = $false })
    }
    else {
        $bucket = if ($sizing.t1.vcpus -le 4) { '1-4 vCPU VM' } else { '{0} vCPU VM' -f $sizing.t1.vcpus }
        $sqlItems = Get-CachedPrice "serviceName eq 'Virtual Machines Licenses' and productName eq 'SQL Server Standard' and skuName eq '$bucket' and priceType eq 'Consumption'"
        Add-Component 'T1 SQL Server license' 'running' ($sqlItems | Select-Object -First 1) 1 'hour'
    }

    Add-Component 'T2 host compute' 'running' (Select-VmPrice $sizing.t2Host.size ($Config['hostPriority'] -eq 'Spot') $hybridWindows) 1 'hour'
    if ($Config['t2SqlInstallMode'] -ne 'Developer') {
        # Learn's manage-license-billing (Metering section) bills at least four cores per OSE.
        $cores = if ($Config.Contains('t2ArcBillableCores') -and $Config['t2ArcBillableCores']) { [int]$Config['t2ArcBillableCores'] } else { [Math]::Max((Get-DemoArcSetting).MinimumCoresPerOse, [int]$sizing.t2Guest.vcpus) }
        $arcItems = @(Get-CachedPrice "serviceName eq 'Azure Arc Enabled Databases' and productName eq 'Azure Arc-enabled SQL Server - Arc-enabled servers' and skuName eq 'Std edition - PAYG' and priceType eq 'Consumption'")
        $arcItem = ($arcItems | Where-Object { $_.armRegionName -in '', 'Global' } | Select-Object -First 1)
        if (-not $arcItem) {
            $arcItem = ($arcItems | Where-Object { $_.armRegionName -notmatch 'Gov' } | Select-Object -First 1)
        }
        Add-Component 'T2 Arc SQL Standard PAYG' 'running' $arcItem $cores 'core-hour'
    }

    $t3Vcores = [double]$sizing.t3.maxVcores * [double]$assumptions.t3ActiveShareOfMaxVcores
    # Azure SQL Database free offer: each database gets 100,000 vCore-seconds of compute and 32 GB of data a
    # month (https://learn.microsoft.com/azure/azure-sql/database/free-offer, checked 2026-10-20). With
    # 'continue using database for additional charges', usage above that bills at serverless rates.
    $t3FreeOfferUnchecked = $false
    $t3UsesFreeOffer = if ($PSBoundParameters.ContainsKey('T3UseFreeLimit')) {
        $T3UseFreeLimit
    }
    else {
        $t3FreeOfferUnchecked = [string]$Config['t3FreeOffer'] -ne 'off'
        $false
    }
    $t3Items = Get-CachedPrice "serviceName eq 'SQL Database' and armRegionName eq '$location' and productName eq 'SQL Database General Purpose - Serverless - Compute Gen5' and skuName eq '1 vCore' and priceType eq 'Consumption'"
    $t3VcoreItem = $t3Items | Where-Object { $_.meterName -eq 'vCore' } | Select-Object -First 1
    # The session stays at list price (an upper bound); the light-use month subtracts the free allowance.
    Add-Component 'T3 compute (serverless)' 'running' $t3VcoreItem $t3Vcores 'vCore-hour'

    # Interactive access (per session)
    $bastionItems = Get-CachedPrice "serviceName eq 'Azure Bastion' and armRegionName eq '$location' and skuName eq 'Basic' and priceType eq 'Consumption'"
    Add-Component 'Bastion Basic' 'bastion' ($bastionItems | Where-Object { $_.meterName -eq 'Basic Gateway' } | Select-Object -First 1) 1 'hour'
    $ipItems = Get-CachedPrice "serviceName eq 'Virtual Network' and armRegionName eq '$location' and productName eq 'IP Addresses' and skuName eq 'Standard' and priceType eq 'Consumption'"
    $ipItem = $ipItems | Where-Object { $_.meterName -eq 'Standard IPv4 Static Public IP' } | Select-Object -First 1
    Add-Component 'Bastion public IP' 'bastion' $ipItem 1 'hour'

    # Always billed (per month). Data disk tiers match the template (Resolve-DemoDataDiskTier, ADR 0016).
    $zone = if ($Config.Contains('zone') -and $Config['zone']) { [string]$Config['zone'] } else { '' }
    $diskOverride = Get-DemoDataDiskOverride -Config $Config
    $diskTiers = $catalog.diskTiers
    $dataTier = {
        param([hashtable] $Vm)
        Resolve-DemoDataDiskTier -VmSizing $Vm -Zone $zone -Override $diskOverride
    }
    foreach ($disk in @(
            @{ Name = 'T1 OS disk'; Tier = $sizing.t1.osDisk }
            @{ Name = 'T1 data disk'; Tier = (& $dataTier $sizing.t1) }
            @{ Name = 'T2 host OS disk'; Tier = $sizing.t2Host.osDisk }
            @{ Name = 'T2 host data disk'; Tier = (& $dataTier $sizing.t2Host) }
        )) {
        if ($disk.Tier -eq 'None') {
            # No separate data disk (the lowest-cost default): the OS disk, priced above, holds the data.
            continue
        }
        if ($disk.Tier -eq 'PremiumV2') {
            $tier = $diskTiers['PremiumV2']
            $v2Items = @(Get-CachedPrice "serviceName eq 'Storage' and armRegionName eq '$location' and productName eq 'Azure Premium SSD v2' and skuName eq 'Premium LRS' and priceType eq 'Consumption'")
            $capacity = $v2Items | Where-Object { $_.meterName -eq 'Premium LRS Provisioned Capacity' } | Select-Object -First 1
            Add-Component ('{0} (Premium SSD v2, {1} GiB)' -f $disk.Name, $tier.sizeGiB) 'idle' $capacity ([double]$tier.sizeGiB * $hoursPerMonth) 'GiB-hour'
            # IOPS and throughput up to the baseline (the meters' first tier) are free; only the excess bills.
            foreach ($performance in @(
                    @{ Meter = 'Premium LRS Provisioned IOPS'; Provisioned = [double]$tier.iops; Label = 'IOPS above baseline' }
                    @{ Meter = 'Premium LRS Provisioned Throughput (MBps)'; Provisioned = [double]$tier.mbps; Label = 'throughput above baseline' }
                )) {
                $paid = $v2Items | Where-Object { $_.meterName -eq $performance.Meter -and [double]$_.tierMinimumUnits -gt 0 } | Select-Object -First 1
                if ($paid -and $performance.Provisioned -gt [double]$paid.tierMinimumUnits) {
                    Add-Component ('{0} {1}' -f $disk.Name, $performance.Label) 'idle' $paid (($performance.Provisioned - [double]$paid.tierMinimumUnits) * $hoursPerMonth) 'unit-hour'
                }
            }
        }
        else {
            Add-Component ('{0} ({1})' -f $disk.Name, $disk.Tier) 'idle' (Select-DiskPrice $disk.Tier) 1 'month'
        }
    }

    $t3StorageItems = Get-CachedPrice "serviceName eq 'SQL Database' and armRegionName eq '$location' and productName eq 'SQL Database Single/Elastic Pool General Purpose - Storage' and skuName eq 'General Purpose' and priceType eq 'Consumption'"
    $t3BillableGB = if ($t3UsesFreeOffer) { [System.Math]::Max(0.0, [double]$sizing.t3.maxSizeGB - 32.0) } else { [double]$sizing.t3.maxSizeGB }
    Add-Component 'T3 storage' 'idle' ($t3StorageItems | Where-Object { $_.meterName -eq 'General Purpose Data Stored' } | Select-Object -First 1) $t3BillableGB 'GB-month'

    # T4 (Phase 24, ADR 0019): the Burstable flexible server's compute while the demo runs, and its storage and
    # private DNS zone (virtual network integration in both network modes) all month, stopped or not. Its
    # backups stay within the free allowance (backup storage up to the provisioned size). A stopped server
    # starts on its own after seven days, so the worst case adds the rest of the month's compute.
    $t4On = Test-DemoT4Enabled -Config $Config
    $t4ComputeItem = $null
    $t4WorstCase = $null
    if ($t4On -and $null -ne $sizing.t4) {
        # The size actually deployed: the t4SkuName setting (B1ms, the B2s fallback, or the General Purpose D2ds_v5
        # option, priced per vCore-hour; Phase 24).
        $t4SkuName = Get-DemoT4SkuName -Config $Config
        $t4Spec = Get-DemoT4SkuSpec -SkuName $t4SkuName
        $t4ComputeItems = Get-CachedPrice "serviceName eq 'Azure Database for PostgreSQL' and armRegionName eq '$location' and productName eq '$($t4Spec.Product)' and priceType eq 'Consumption'"
        $t4ComputeItem = Select-DemoT4ComputePrice -Item @($t4ComputeItems) -Spec $t4Spec
        $t4ComputeQuantity = if ($t4Spec.PerVCore) { [double]$t4Spec.VCores } else { 1.0 }
        Add-Component ('T4 compute ({0})' -f $t4SkuName) 'running' $t4ComputeItem $t4ComputeQuantity $(if ($t4Spec.PerVCore) { 'vCore-hour' } else { 'hour' })
        $t4StorageItems = Get-CachedPrice "serviceName eq 'Azure Database for PostgreSQL' and armRegionName eq '$location' and productName eq 'Azure Database for PostgreSQL Flex Server Storage' and skuName eq 'Storage' and priceType eq 'Consumption'"
        Add-Component 'T4 storage' 'idle' ($t4StorageItems | Where-Object { $_.meterName -eq 'Storage Data Stored' } | Select-Object -First 1) ([double]$sizing.t4.storageSizeGB) 'GB-month'
        $t4DnsItems = Get-CachedPrice "serviceName eq 'Azure DNS' and skuName eq 'Private' and meterName eq 'Private Zone' and priceType eq 'Consumption'"
        Add-Component 'T4 private DNS zone' 'idle' ($t4DnsItems | Where-Object { $_.armRegionName -notmatch 'Gov' } | Sort-Object -Property tierMinimumUnits, armRegionName | Select-Object -First 1) 1 'zone-month'
        if ($t4ComputeItem) {
            $t4WorstCase = [System.Math]::Round([double]$t4ComputeItem.retailPrice * $t4ComputeQuantity * ($hoursPerMonth - $LightUseHoursPerMonth), 2)
        }
    }

    # T2 golden snapshots (ADR 0018): incremental snapshots are stored as Standard HDD, LRS or ZRS
    # (https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots).
    foreach ($snapshot in @($GoldenSnapshots | Where-Object { $null -ne $_ })) {
        $snapshotSku = [string](Get-DemoMemberValue -InputObject $snapshot -Name 'Sku')
        $redundancy = if ($snapshotSku -match 'ZRS') { 'ZRS' } else { 'LRS' }
        $product = if ([bool](Get-DemoMemberValue -InputObject $snapshot -Name 'Incremental') -or $snapshotSku -notmatch '^(Premium|StandardSSD)') { 'Standard HDD Managed Disks' } elseif ($snapshotSku -match '^Premium') { 'Premium SSD Managed Disks' } else { 'Standard SSD Managed Disks' }
        $snapshotItems = Get-CachedPrice "serviceName eq 'Storage' and armRegionName eq '$location' and skuName eq 'Snapshots $redundancy' and priceType eq 'Consumption'"
        $snapshotItem = $snapshotItems | Where-Object { $_.productName -eq $product -and $_.unitOfMeasure -eq '1 GB/Month' } | Select-Object -First 1
        $sizeGiB = [double](Get-DemoMemberValue -InputObject $snapshot -Name 'SizeGiB')
        $usedGiB = [double](Get-DemoMemberValue -InputObject $snapshot -Name 'UsedGiB')
        Add-Component ('T2 golden snapshot {0} ({1:N0} GiB provisioned, about {2:N0} GiB used)' -f [string](Get-DemoMemberValue -InputObject $snapshot -Name 'Name'), $sizeGiB, $usedGiB) 'idle' $snapshotItem $sizeGiB 'GB-month'
    }

    if ($effectiveNetworkMode -eq 'private') {
        $peItem = Select-HourlyPrice "serviceName eq 'Virtual Network' and productName eq 'Virtual Network Private Link' and skuName eq 'Standard'" 'Standard Private Endpoint'
        Add-Component 'T3 private endpoint' 'idle' $peItem $hoursPerMonth 'hour'
        # Azure DNS bills private zones per zone per month, in tiers; one zone is in the first tier.
        $dnsItems = Get-CachedPrice "serviceName eq 'Azure DNS' and skuName eq 'Private' and meterName eq 'Private Zone' and priceType eq 'Consumption'"
        $dnsItem = $dnsItems | Where-Object { $_.armRegionName -notmatch 'Gov' } | Sort-Object -Property tierMinimumUnits, armRegionName | Select-Object -First 1
        Add-Component 'T3 private DNS zone' 'idle' $dnsItem 1 'zone-month'
    }

    if ($Config['outboundMode'] -eq 'NatGateway') {
        $natItem = Select-HourlyPrice "serviceName eq 'NAT Gateway' and skuName eq 'Standard'" 'Standard Gateway'
        Add-Component 'NAT gateway' 'idle' $natItem $hoursPerMonth 'hour'
        Add-Component 'NAT gateway public IP' 'idle' $ipItem $hoursPerMonth 'hour'
    }

    # The optional on-demand activity control (ADR 0020), in rg-<prefix>-control: the vault bills per 10,000 operations
    # and an on-demand run reads its one secret once, and Automation includes the first 500 job minutes a month, while
    # a run's jobs take a few minutes. So these are ceilings: one block of operations, and 60 job minutes a month.
    if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        $vaultItems = Get-CachedPrice "serviceName eq 'Key Vault' and armRegionName eq '$location' and skuName eq 'Standard' and priceType eq 'Consumption'"
        Add-Component 'Activity control vault operations' 'idle' ($vaultItems | Where-Object { $_.meterName -eq 'Operations' } | Select-Object -First 1) 1 '10K operations'
        $automationItems = Get-CachedPrice "serviceName eq 'Automation' and armRegionName eq '$location' and skuName eq 'Basic' and meterName eq 'Basic Runtime' and priceType eq 'Consumption'"
        Add-Component 'Activity control job minutes (the first 500 a month are included)' 'idle' ($automationItems | Sort-Object -Property { [double]$_.tierMinimumUnits } | Select-Object -First 1) 60 'minute'
    }

    # Microsoft Defender for Cloud, from the subscription's plans.
    $defenderIncluded = $PSBoundParameters.ContainsKey('DefenderPlans')
    $standardPlans = [ordered]@{}
    foreach ($plan in @($DefenderPlans)) {
        $planName = [string](Get-DemoMemberValue -InputObject $plan -Name 'name')
        if ($planName -and [string](Get-DemoMemberValue -InputObject $plan -Name 'pricingTier') -eq 'Standard') {
            $standardPlans[$planName] = [string](Get-DemoMemberValue -InputObject $plan -Name 'subPlan')
        }
    }
    $billedPlans = [System.Collections.Generic.List[string]]::new()
    $arcSqlWorstCase = $null
    if ($standardPlans.Contains('VirtualMachines')) {
        $subPlan = if ($standardPlans['VirtualMachines'] -in 'P1', 'P2') { $standardPlans['VirtualMachines'].ToUpperInvariant() } else { 'P2' }
        $billedPlans.Add("VirtualMachines ($subPlan)")
        $item = Select-HourlyPrice "serviceFamily eq 'Security' and productName eq 'Microsoft Defender for Servers' and skuName eq 'Standard $subPlan'" "Standard $subPlan Node"
        Add-Component "Defender for Servers $subPlan (T1)" 'running' $item 1 'hour' -Defender
        Add-Component "Defender for Servers $subPlan (T2 host)" 'running' $item 1 'hour' -Defender
        Add-Component "Defender for Servers $subPlan (Arc machine arcsql01)" 'running' $item 1 'hour' -Defender
    }
    if ($standardPlans.Contains('SqlServerVirtualMachines')) {
        $billedPlans.Add('SqlServerVirtualMachines')
        $item = Select-HourlyPrice "serviceFamily eq 'Security' and productName eq 'Microsoft Defender for SQL' and skuName eq 'Standard'" 'Standard Instance'
        Add-Component 'Defender for SQL on machines (T1)' 'running' $item 1 'hour' -Defender
        Add-Component 'Defender for SQL on machines (Arc SQL arcsql01)' 'running' $item 1 'hour' -Defender
        if ($item) {
            $arcSqlWorstCase = [System.Math]::Round([double]$item.retailPrice * ($hoursPerMonth - $LightUseHoursPerMonth), 2)
        }
    }
    if ($standardPlans.Contains('SqlServers')) {
        $billedPlans.Add('SqlServers')
        $item = Select-HourlyPrice "serviceFamily eq 'Security' and productName eq 'Microsoft Defender for SQL' and skuName eq 'Standard'" 'Standard Instance'
        Add-Component 'Defender for Azure SQL (T3 server)' 'idle' $item $hoursPerMonth 'hour' -Defender
    }
    if ($standardPlans.Contains('CloudPosture')) {
        $billedPlans.Add('CloudPosture')
        $item = Select-HourlyPrice "serviceFamily eq 'Security' and productName eq 'Microsoft Defender CSPM' and skuName eq 'Standard'" 'Standard Node'
        Add-Component 'Defender CSPM (T1)' 'running' $item 1 'hour' -Defender
        Add-Component 'Defender CSPM (T2 host)' 'running' $item 1 'hour' -Defender
        Add-Component 'Defender CSPM (T3 server)' 'idle' $item $hoursPerMonth 'hour' -Defender
        if ($t4On) {
            # A stopped flexible server is still a billable CSPM resource.
            Add-Component 'Defender CSPM (T4 server)' 'idle' $item $hoursPerMonth 'hour' -Defender
        }
    }
    if ($t4On -and $standardPlans.Contains('OpenSourceRelationalDatabases')) {
        # Defender for open-source relational databases bills each PostgreSQL server per month, stopped or not.
        $billedPlans.Add('OpenSourceRelationalDatabases')
        $ossItems = Get-CachedPrice "serviceFamily eq 'Security' and productName eq 'Microsoft Defender for PostgreSQL' and skuName eq 'Standard' and priceType eq 'Consumption' and (armRegionName eq '$location' or armRegionName eq 'Global')"
        $ossItem = @($ossItems | Where-Object { $_.meterName -eq 'Standard Node' -and $_.unitOfMeasure -match 'Month' } | Sort-Object -Property @{ Expression = { $_.armRegionName -ne $location } }) | Select-Object -First 1
        Add-Component 'Defender for open-source relational databases (T4 server)' 'idle' $ossItem 1 'server-month' -Defender
    }
    $attributed = @('VirtualMachines', 'SqlServerVirtualMachines', 'SqlServers', 'CloudPosture', 'StorageAccounts') + @(if ($t4On) { 'OpenSourceRelationalDatabases' })
    $notAttributed = @($standardPlans.Keys | Where-Object { $_ -notin $attributed })

    $sum = {
        param([string] $Basis, [bool] $DefenderOnly)
        $total = 0.0
        foreach ($component in $components) {
            if ($component.Basis -eq $Basis -and (-not $DefenderOnly -or $component.Defender)) {
                $total += [double]$component.Cost
            }
        }
        $total
    }
    $running = & $sum 'running' $false
    $bastion = & $sum 'bastion' $false
    $idle = & $sum 'idle' $false
    $defenderRunning = & $sum 'running' $true
    $defenderIdle = & $sum 'idle' $true
    $hourlyRunning = [System.Math]::Round($running, 2)
    $bastionHourly = [System.Math]::Round($bastion, 2)
    $idleMonthly = [System.Math]::Round($idle, 2)
    $t3FreeCredit = 0.0
    if ($t3UsesFreeOffer -and $t3VcoreItem) {
        $t3FreeCredit = [System.Math]::Min($t3Vcores * $LightUseHoursPerMonth, 100000.0 / 3600.0) * [double]$t3VcoreItem.retailPrice
    }
    $t3FreeCreditMonthly = [System.Math]::Round($t3FreeCredit, 2)
    $sessionCost = [System.Math]::Round($running * $DemoHours + $bastion * $BastionHours, 2)
    $lightUseMonthly = [System.Math]::Round($idle + $running * $LightUseHoursPerMonth + $bastion * $BastionHours - $t3FreeCredit, 2)
    $defenderSession = [System.Math]::Round($defenderRunning * $DemoHours, 2)
    $defenderMonthly = [System.Math]::Round($defenderIdle + $defenderRunning * $LightUseHoursPerMonth, 2)
    # T4's fixed monthly cost: everything billed while it's stopped (storage, DNS zone, its Defender plans).
    $t4Fixed = 0.0
    foreach ($component in $components) {
        if ($component.Basis -eq 'idle' -and $component.Name -match '\(T4 server\)|^T4 ') {
            $t4Fixed += [double]$component.Cost
        }
    }
    $t4FixedMonthly = if ($t4On) { [System.Math]::Round($t4Fixed, 2) } else { $null }

    $results = [System.Collections.Generic.List[object]]::new()
    $evidence = @{
        profile              = $ProfileName
        currency             = $CurrencyCode
        location             = $location
        networkMode          = $effectiveNetworkMode
        networkModeAssumed   = $networkModeAssumed
        defenderIncluded     = $defenderIncluded
        t3FreeOffer          = [bool]$t3UsesFreeOffer
        t3FreeOfferUnchecked = $t3FreeOfferUnchecked
        t3FreeOfferCredit    = $t3FreeCreditMonthly
        t4Enabled            = [bool]$t4On
    }
    if ($t4On) {
        $evidence['t4FixedMonthly'] = $t4FixedMonthly
        $evidence['t4AutoRestartWorstCaseMonthly'] = $t4WorstCase
    }
    if ($defenderIncluded) {
        $evidence['defenderSession'] = $defenderSession
        $evidence['defenderMonthly'] = $defenderMonthly
        if ($null -ne $arcSqlWorstCase) {
            $evidence['arcSqlDefenderWorstCaseMonthly'] = $arcSqlWorstCase
        }
    }
    $retailPricesDoc = 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'
    if ($CurrencyCode -eq 'USD') {
        # The monthly ceiling is hard (user-directed, 2026-10-20): above it is Fail. The session ceiling is a Warning.
        $sessionCeiling = [double]$Config['sessionCeilingUsd']
        $monthlyCeiling = [double]$Config['monthlyCeilingUsd']
        $sessionStatus = if ($sessionCost -le $sessionCeiling) { 'Pass' } else { 'Warning' }
        # T4's 7-day automatic restart counts against the ceiling until a scheduled daily stop covers it.
        $monthlyStatus = if ($lightUseMonthly + [double]$t4WorstCase -le $monthlyCeiling) { 'Pass' } else { 'Fail' }
        $sessionDefender = if ($defenderIncluded) { ' (of which Defender for Cloud: {0:N2} USD)' -f $defenderSession } else { '' }
        $monthlyDefender = if ($defenderIncluded) { ' (of which Defender for Cloud: {0:N2} USD)' -f $defenderMonthly } else { '' }
        $monthlyMessage = '{0}: idle plus {1} hours of use is estimated at {2:N2} USD a month{3} against the hard ceiling of {4:N2} USD.' -f $ProfileName, $LightUseHoursPerMonth, $lightUseMonthly, $monthlyDefender, $monthlyCeiling
        if ($null -ne $arcSqlWorstCase) {
            $monthlyMessage += ' If Defender for SQL also bills the Arc SQL instance while it''s disconnected (not documented), add up to {0:N2} USD.' -f $arcSqlWorstCase
        }
        if ($t4On) {
            $monthlyMessage += ' T4 (PostgreSQL, {2}) costs {0:N2} USD a month even while stopped (storage, its private DNS zone, and its Defender plans); a stopped T4 starts on its own after 7 days, so the worst case adds up to {1:N2} USD of T4 compute at its size, which counts against the ceiling until a scheduled daily stop of T4 caps it.' -f $t4FixedMonthly, [double]$t4WorstCase, (Get-DemoT4SkuName -Config $Config)
        }
        if ($networkModeAssumed) {
            $monthlyMessage += ' networkMode auto isn''t resolved yet, so the estimate assumes private mode (private endpoint and private DNS zone).'
        }
        if ($t3UsesFreeOffer) {
            $monthlyMessage += ' T3 uses the Azure SQL Database free offer, whose monthly allowance covers {0:N2} USD of T3 compute and 32 GB of data.' -f $t3FreeCreditMonthly
        }
        elseif ($t3FreeOfferUnchecked) {
            $monthlyMessage += ' The Azure SQL Database free offer wasn''t checked, so T3 is priced as regular serverless; preflight checks it.'
        }
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.SESSION' -Area 'preflight' -Target 'subscription' -Status $sessionStatus `
                    -Message ('{0}: a {1}-hour demo session is estimated at {2:N2} USD{3} against a ceiling of {4:N2} USD.' -f $ProfileName, $DemoHours, $sessionCost, $sessionDefender, $sessionCeiling) `
                    -Evidence $evidence -Remediation 'Shorten the session, choose a smaller profile, or opt in to Spot (ADR 0016).' -DocUrl $retailPricesDoc))
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.MONTHLY' -Area 'preflight' -Target 'subscription' -Status $monthlyStatus `
                    -Message $monthlyMessage -Evidence $evidence -Remediation 'Pick a cheaper profile or options (lowest-cost, Spot, or parking T2 between demos), or raise monthlyCeilingUsd in the configuration (ADR 0016).' -DocUrl $retailPricesDoc))
    }

    if (-not $defenderIncluded) {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.DEFENDER' -Area 'preflight' -Target 'subscription' -Status 'Warning' `
                    -Message 'The estimate excludes Microsoft Defender for Cloud, because the subscription''s Defender plans weren''t read. Sign in to the configured subscription and run preflight.ps1 or estimate-cost.ps1 again; both read the plans (read-only).' `
                    -Evidence $evidence -Remediation 'Sign in yourself with az login --tenant <tenantId>; scripts never sign in.' -DocUrl 'https://learn.microsoft.com/cli/azure/security/pricing'))
    }
    else {
        $defenderMessage = if ($billedPlans.Count -gt 0) {
            'Defender for Cloud plans on Standard that bill the demo''s resources: {0}. They add {1:N2} {2} to a session and {3:N2} {2} to a light-use month.' -f ($billedPlans -join ', '), $defenderSession, $CurrencyCode, $defenderMonthly
        }
        else {
            'No Defender for Cloud plan that bills the demo''s resources is on Standard, so Defender adds nothing.'
        }
        if ($standardPlans.Contains('StorageAccounts')) {
            $defenderMessage += ' Defender for Storage adds nothing: the deployment creates no storage accounts.'
        }
        if ($null -ne $arcSqlWorstCase) {
            $defenderMessage += ' Billing for a disconnected Arc SQL instance isn''t documented; if it''s billed all month, add up to {0:N2} {1} (not in the totals).' -f $arcSqlWorstCase, $CurrencyCode
        }
        if ($notAttributed.Count -gt 0) {
            $defenderMessage += ' Subscription-wide plans aren''t attributed to the demo: {0}.' -f ($notAttributed -join ', ')
        }
        $defenderEvidence = @{}
        foreach ($key in $evidence.Keys) {
            $defenderEvidence[$key] = $evidence[$key]
        }
        $defenderEvidence['standardPlans'] = @($standardPlans.Keys)
        $defenderEvidence['billedPlans'] = $billedPlans.ToArray()
        $defenderEvidence['notAttributed'] = $notAttributed
        $defenderEvidence['note'] = 'Priced with the per-plan meters. Defender Workload Unit meters (effective 2026-10-01) may appear on the invoice instead.'
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.DEFENDER' -Area 'preflight' -Target 'subscription' -Status 'Pass' `
                    -Message $defenderMessage -Evidence $defenderEvidence -DocUrl 'https://learn.microsoft.com/azure/defender-for-cloud/faq-defender-for-servers'))
    }

    if ($missing.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.COST.PRICES' -Area 'preflight' -Target 'subscription' -Status 'Warning' `
                    -Message ('No retail price was found for: {0}. Those items are left out of the totals.' -f ($missing -join ', ')) -Evidence $evidence))
    }

    [pscustomobject]@{
        Profile                        = $ProfileName
        Location                       = $location
        Currency                       = $CurrencyCode
        QueriedOn                      = [System.DateTime]::UtcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        NetworkMode                    = $effectiveNetworkMode
        NetworkModeAssumed             = $networkModeAssumed
        DemoHours                      = $DemoHours
        LightUseHoursPerMonth          = $LightUseHoursPerMonth
        HourlyRunning                  = $hourlyRunning
        BastionHourly                  = $bastionHourly
        SessionCost                    = $sessionCost
        IdleMonthly                    = $idleMonthly
        LightUseMonthly                = $lightUseMonthly
        DefenderIncluded               = $defenderIncluded
        DefenderSession                = $defenderSession
        DefenderMonthly                = $defenderMonthly
        ArcSqlDefenderWorstCaseMonthly = $arcSqlWorstCase
        T4FixedMonthly                 = $t4FixedMonthly
        T4AutoRestartWorstCaseMonthly  = $t4WorstCase
        T3FreeOffer                    = [bool]$t3UsesFreeOffer
        T3FreeOfferUnchecked           = $t3FreeOfferUnchecked
        T3FreeOfferCreditMonthly       = $t3FreeCreditMonthly
        Components                     = $components.ToArray()
        MissingPrices                  = $missing.ToArray()
        Results                        = $results.ToArray()
    }
}
