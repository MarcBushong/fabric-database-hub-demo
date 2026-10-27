function Invoke-DemoPreflight {
    <#
    .SYNOPSIS
    Checks every prerequisite before anything is deployed (ADR 0008, ADR 0012).

    .DESCRIPTION
    Runs, in order:
    - Subscription guard (Assert-DemoAzContext): the configured subscription's Azure CLI account must reach
      the configured subscription and tenant through every authentication path, without the default
      subscription.
    - P1: Contributor-level permissions on the subscription (and role-assignment rights if assignRoles is set).
    - P2: resource providers; missing ones are registered unless -SkipProviderRegistration is set.
    - P3: region, VM sizes, nested-virtualization families, vCPU quota, and public IP quota; with a zone
      configured, that both sizes and (for demo-day and enhanced-performance) Premium SSD v2 are offered in
      that zone; and the VM security types, resolving securityType.t1 = Auto from the image's features.
    - C6: Azure Hybrid Benefit only with the entitlement attestation.
    - P4 and P5: the Fabric tenant setting, reported as a manual check, and the Fabric workspace and lakehouse by
      name, read-only (Test-DemoFabricResolution, Phase 26a): your role and the capacity of a workspace that exists,
      or the capacity deploy.ps1 would create it on; the optional P11, Power BI viewer licensing on the workspace's
      capacity (Test-DemoFabricViewerLicense, a Warning below F64).
    - P6: the T3 Entra admin group exists and the caller owns it, read from Microsoft Graph with a token
      verified for the configured tenant (Invoke-DemoRestRequest). The group's display name is in the
      evidence (groupDisplayName), for T3's administrator login.
    - Policy inventory: a read-only list of the Azure Policy rules that apply to the subscription
      (Get-DemoPolicyConstraint). It resolves networkMode auto to public or private and reports
      conflicts. Unless -SkipPolicyInventory is set.
    - T3 free offer: whether the Azure SQL Database free offer is available (Get-DemoT3FreeOfferStatus,
      read-only). When it isn't, T3 falls back to regular serverless with a Warning.
    - Policy what-if: a subscription what-if of infra/main.bicep with the effective network mode and the
      free-offer result (no resources change). VMs that already exist keep osProfile out; a VM that would
      be created gets a throwaway in-memory password for the what-if only.
    - Cost: live-price estimate against the ceilings, with the subscription's Defender for Cloud plans
      (az security pricing list, read-only), the effective network mode, and the free-offer result. The
      monthly ceiling is hard: a light-use month above it is Fail.
    Every Azure CLI call goes through Invoke-DemoAz, so it carries --subscription; Microsoft Graph and
    tenant-level Resource Manager reads go through Invoke-DemoRestRequest. Nothing signs in.
    The effective network mode is in the evidence of PREFLIGHT.POLICY.SQLPUBLIC (effectiveNetworkMode),
    and the free-offer setting in the evidence of PREFLIGHT.T3.FREEOFFER (useFreeLimit), for later stages.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER SkipProviderRegistration
    Report unregistered providers instead of registering them.

    .PARAMETER SkipWhatIf
    Skip the what-if policy check.

    .PARAMETER SkipPolicyInventory
    Skip the policy inventory, which reads every policy definition that applies to the subscription and
    can take a few minutes. networkMode auto then resolves to private, which works under any policy.

    .PARAMETER PolicyCacheHours
    Reuse the last complete policy inventory when it's at most this many hours old and the policy
    assignments that apply to the subscription, the configuration it reads, and its code are unchanged
    (Get-DemoPolicyConstraint -CacheHours). The assignments are listed every time; the reused results say
    so. 0 (the default) always reads every definition and saves nothing.

    .EXAMPLE
    Invoke-DemoPreflight -Config (Get-DemoConfig -Path ./config/demo.config.json)
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $SkipProviderRegistration,

        [switch] $SkipWhatIf,

        [switch] $SkipPolicyInventory,

        [ValidateRange(0, 720)]
        [int] $PolicyCacheHours = 0
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $subscriptionId = $Config['subscriptionId']
    $location = $Config['location']

    function Add-Check {
        param([string] $CheckId, [string] $Target, [string] $Status, [string] $Message, [hashtable] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '')
        $results.Add((New-DemoResult -CheckId $CheckId -Area 'preflight' -Target $Target -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }

    function Invoke-Az {
        param([string[]] $Arguments, [switch] $Json, [switch] $AllowFailure)
        Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $Arguments -AsJson:$Json -AllowFailure:$AllowFailure
    }

    # Subscription guard. A failure here stops everything else.
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId $Config['tenantId'] -Account ([string]$Config['azureAccount'])))
    }
    catch {
        Add-Check 'PREFLIGHT.GUARD.CONTEXT' 'subscription' 'Fail' $_.Exception.Message
        return $results.ToArray()
    }

    # P1: permissions on the subscription.
    $permissionUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $permissions = @((Invoke-Az -Arguments @('rest', '--method', 'get', '--url', $permissionUrl) -Json).value)
    $requiredActions = @(
        'Microsoft.Resources/subscriptions/resourceGroups/write'
        'Microsoft.Resources/deployments/write'
        'Microsoft.Compute/virtualMachines/runCommands/write'
        'Microsoft.HybridCompute/machines/write'
        'Microsoft.Consumption/budgets/write'
    )
    $missingActions = @($requiredActions | Where-Object { -not (Test-DemoPermission -Permission $permissions -Action $_) })
    if ($missingActions.Count -eq 0) {
        Add-Check 'PREFLIGHT.P1.CONTRIBUTOR' 'subscription' 'Pass' 'The caller has Contributor-level permissions on the subscription.'
    }
    else {
        Add-Check 'PREFLIGHT.P1.CONTRIBUTOR' 'subscription' 'Fail' ('The caller is missing: {0}.' -f ($missingActions -join ', ')) -Remediation 'Ask a subscription Owner to assign Contributor on the subscription (prerequisite P1).' -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/built-in-roles'
    }

    if ($Config['assignRoles']) {
        if (Test-DemoPermission -Permission $permissions -Action 'Microsoft.Authorization/roleAssignments/write') {
            Add-Check 'PREFLIGHT.P1.ROLEASSIGNMENTS' 'subscription' 'Pass' 'assignRoles is set and the caller can create role assignments.'
        }
        else {
            Add-Check 'PREFLIGHT.P1.ROLEASSIGNMENTS' 'subscription' 'Fail' 'assignRoles is set, but the caller cannot create role assignments.' -Remediation 'Set assignRoles to false, or have an administrator grant Role Based Access Control Administrator with a condition (ADR 0008).'
        }
    }
    else {
        Add-Check 'PREFLIGHT.P1.ROLEASSIGNMENTS' 'subscription' 'Not selected' 'assignRoles is false; no role assignments will be created.'
    }

    # P2: resource providers.
    $requiredProviders = @(
        'Microsoft.Sql', 'Microsoft.SqlVirtualMachine', 'Microsoft.AzureArcData', 'Microsoft.HybridCompute',
        'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.Compute', 'Microsoft.Network',
        'Microsoft.Storage', 'Microsoft.Consumption', 'Microsoft.DevTestLab'
    ) + @(if (Test-DemoT4Enabled -Config $Config) { 'Microsoft.DBforPostgreSQL' })
    $providerStates = @{}
    foreach ($provider in @(Invoke-Az -Arguments @('provider', 'list') -Json)) {
        $providerStates[$provider.namespace] = $provider.registrationState
    }
    $unregistered = @($requiredProviders | Where-Object { $providerStates[$_] -ne 'Registered' })
    if ($unregistered.Count -eq 0) {
        Add-Check 'PREFLIGHT.P2.PROVIDERS' 'subscription' 'Pass' 'Every required resource provider is registered.'
    }
    elseif ($SkipProviderRegistration) {
        Add-Check 'PREFLIGHT.P2.PROVIDERS' 'subscription' 'Fail' ('Unregistered providers: {0}.' -f ($unregistered -join ', ')) -Remediation 'Re-run preflight without -SkipProviderRegistration, or run: az provider register --namespace <name> --subscription <id>.'
    }
    else {
        foreach ($namespace in $unregistered) {
            Invoke-Az -Arguments @('provider', 'register', '--namespace', $namespace) | Out-Null
        }
        Add-Check 'PREFLIGHT.P2.PROVIDERS' 'subscription' 'Warning' ('Registration started for: {0}. It can take several minutes; re-run preflight to confirm.' -f ($unregistered -join ', ')) -Evidence @{ registering = $unregistered }
    }

    # P3: region, sizes, families, and quota.
    $knownRegions = @('westus3', 'eastus2')
    if ($location -in $knownRegions) {
        Add-Check 'PREFLIGHT.P3.REGION' 'subscription' 'Pass' "$location is in the Database Hub performance-monitoring and SQL VM unified-inventory region lists (checked 2026-10-19)."
    }
    else {
        Add-Check 'PREFLIGHT.P3.REGION' 'subscription' 'Warning' "$location hasn't been verified against the Database Hub and SQL VM unified-inventory region lists." -DocUrl 'https://learn.microsoft.com/fabric/database/hub/monitor-sql'
    }

    $catalog = Get-DemoProfile
    $sizing = $catalog.profiles[$Config['profile']]
    $zone = if ($Config.Contains('zone') -and $Config['zone']) { [string]$Config['zone'] } else { '' }
    $vmRequests = @(
        @{ Role = 'T1'; Size = $sizing.t1.size; Family = $sizing.t1.family; Vcpus = [int]$sizing.t1.vcpus; Nested = $false }
        @{ Role = 'T2 host'; Size = $sizing.t2Host.size; Family = $sizing.t2Host.family; Vcpus = [int]$sizing.t2Host.vcpus; Nested = $true }
    )
    $skuByRole = @{}
    $zoneProblems = [System.Collections.Generic.List[string]]::new()
    # One read for every size and disk SKU of the region (Get-DemoRegionSku: seconds, where 'az vm list-skus' takes minutes).
    $regionSkus = @(Get-DemoRegionSku -SubscriptionId $subscriptionId -Location $location)
    foreach ($request in $vmRequests) {
        $sku = $regionSkus | Where-Object { [string]$_.resourceType -eq 'virtualMachines' -and [string]$_.name -eq $request.Size } | Select-Object -First 1
        $skuByRole[$request.Role] = $sku
        $checkId = 'PREFLIGHT.P3.SIZE_{0}' -f ($request.Role -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
        $restricted = $sku -and @($sku.restrictions | Where-Object { $_.reasonCode -eq 'NotAvailableForSubscription' -and $_.type -eq 'Location' }).Count -gt 0
        if (-not $sku -or $restricted) {
            Add-Check $checkId 'subscription' 'Fail' ('{0} size {1} is not available to this subscription in {2}.' -f $request.Role, $request.Size, $location) -Remediation 'Choose another profile or region; preflight checks the profiles in config/profiles.json.'
        }
        elseif ($request.Nested -and $request.Family -notin $catalog.nestedVirtualizationFamilies) {
            Add-Check $checkId 'subscription' 'Fail' ('{0} size {1} is not in a documented nested-virtualization family.' -f $request.Role, $request.Size) -Remediation 'Use a Dsv5, Dasv5, Dsv6, Esv5, or Esv6 size (ADR 0003). If none fits, the evaluation-only fallback is opt-in (ADR 0006).'
        }
        else {
            Add-Check $checkId 'subscription' 'Pass' ('{0} size {1} is available in {2}.' -f $request.Role, $request.Size, $location)
        }
        if ($zone -and $sku -and -not (Test-DemoSkuZone -Sku $sku -Zone $zone)) {
            $zoneProblems.Add(('{0} size {1}' -f $request.Role, $request.Size))
        }
        elseif ($zone -and -not $sku) {
            $zoneProblems.Add(('{0} size {1}' -f $request.Role, $request.Size))
        }
    }

    # Availability zone (ADR 0016, C10): both VMs go in the configured zone, and Premium SSD v2 data disks need it.
    # Tiers come from the same resolver as the cost estimate, which mirrors infra/modules/demo.bicep.
    $diskOverride = Get-DemoDataDiskOverride -Config $Config
    $dataDiskTiers = @(
        (Resolve-DemoDataDiskTier -VmSizing $sizing.t1 -Zone $zone -Override $diskOverride)
        (Resolve-DemoDataDiskTier -VmSizing $sizing.t2Host -Zone $zone -Override $diskOverride)
    )
    $usesPremiumV2 = $dataDiskTiers -contains 'PremiumV2'
    $tierEvidence = @{ t1DataDisk = $dataDiskTiers[0]; t2HostDataDisk = $dataDiskTiers[1]; dataDiskSku = $diskOverride }
    $tierText = if ($dataDiskTiers[0] -eq 'None' -and $dataDiskTiers[1] -eq 'None') {
        'there are no separate data disks (dataDiskSku None; the OS disks hold the data)'
    }
    else {
        $tierNames = foreach ($tier in $dataDiskTiers) { if ($tier -eq 'None') { 'no data disk' } else { $tier } }
        'the data disks use {0} (T1) and {1} (T2 host)' -f $tierNames[0], $tierNames[1]
    }
    if (-not $zone) {
        Add-Check 'PREFLIGHT.P3.ZONE' 'subscription' 'Not selected' ('No zone is configured: the VMs are regional, and {0}.' -f $tierText) -Evidence $tierEvidence
        if ($usesPremiumV2) {
            Add-Check 'PREFLIGHT.P3.PREMIUMV2' 'subscription' 'Fail' 'dataDiskSku is PremiumV2, but Premium SSD v2 needs a zonal VM and no zone is configured.' -Remediation 'Set zone to 1, 2, or 3, or set dataDiskSku to Auto, None, E10, or P10 (ADR 0016).' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/disks-deploy-premium-v2'
        }
        else {
            Add-Check 'PREFLIGHT.P3.PREMIUMV2' 'subscription' 'Not selected' 'Premium SSD v2 data disks need a zone; none is configured (ADR 0016, C10).'
        }
    }
    else {
        if ($zoneProblems.Count -eq 0) {
            Add-Check 'PREFLIGHT.P3.ZONE' 'subscription' 'Pass' ('Both VM sizes are offered in zone {0} of {1}.' -f $zone, $location) -Evidence @{ zone = $zone }
        }
        else {
            Add-Check 'PREFLIGHT.P3.ZONE' 'subscription' 'Fail' ('Not offered in zone {0} of {1}: {2}.' -f $zone, $location, ($zoneProblems -join '; ')) -Remediation 'Pick another zone, or set zone to null for regional VMs (the data disks then use the profile''s fallback tier).' -DocUrl 'https://learn.microsoft.com/azure/reliability/availability-zones-overview'
        }
        if (-not $usesPremiumV2) {
            Add-Check 'PREFLIGHT.P3.PREMIUMV2' 'subscription' 'Not selected' ('Premium SSD v2 isn''t used: {0}.' -f $tierText) -Evidence $tierEvidence
        }
        else {
            $premiumV2 = $regionSkus | Where-Object { [string]$_.resourceType -eq 'disks' -and [string]$_.name -eq 'PremiumV2_LRS' } | Select-Object -First 1
            if ($premiumV2 -and (Test-DemoSkuZone -Sku $premiumV2 -Zone $zone)) {
                Add-Check 'PREFLIGHT.P3.PREMIUMV2' 'subscription' 'Pass' ('Premium SSD v2 is available in zone {0} of {1}; the data disks use it (ADR 0016, C10).' -f $zone, $location)
            }
            else {
                Add-Check 'PREFLIGHT.P3.PREMIUMV2' 'subscription' 'Fail' ('Premium SSD v2 is not available in zone {0} of {1}.' -f $zone, $location) -Remediation 'Pick a zone that offers Premium SSD v2, set dataDiskSku to E10 (or P10, an opt-in that can exceed the monthly ceiling), or set zone to null for regional VMs (ADR 0016).' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/disks-deploy-premium-v2'
            }
        }
    }

    # Security types (ADR 0003). T1 Auto resolves from the image's features; a Trusted Launch host is warned about.
    $t1Security = Resolve-DemoT1SecurityType -Config $Config -SizeSku $skuByRole['T1']
    Add-Check 'PREFLIGHT.P3.SECURITYTYPE_T1' 'subscription' $t1Security.Status $t1Security.Message -Evidence $t1Security.Evidence -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/trusted-launch-faq'
    if ($Config['securityType']['t2Host'] -eq 'TrustedLaunch') {
        Add-Check 'PREFLIGHT.P3.SECURITYTYPE_T2HOST' 'subscription' 'Warning' 'The T2 host uses Trusted Launch, which is reported as incompatible with nested virtualization. If the host bootstrap reports that nested virtualization is unavailable, set securityType.t2Host to Standard (ADR 0003).' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/trusted-launch'
    }
    else {
        Add-Check 'PREFLIGHT.P3.SECURITYTYPE_T2HOST' 'subscription' 'Pass' 'The T2 host uses the Standard security type for nested virtualization (ADR 0003).'
    }

    # T4 (Phase 24, ADR 0019): the region offers the configured size in its tier's edition (Burstable, or General
    # Purpose for the documented D2ds_v5 option) and the pinned PostgreSQL major version, read from the documented
    # Location Based Capabilities API.
    if (Test-DemoT4Enabled -Config $Config) {
        $postgres = Get-DemoPostgresSetting
        $t4Sku = Get-DemoT4SkuName -Config $Config
        $t4Tier = (Get-DemoT4SkuSpec -SkuName $t4Sku).Tier
        $capabilityUrl = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.DBforPostgreSQL/locations/{1}/capabilities?api-version={2}' -f $subscriptionId, $location, $postgres['capabilitiesApiVersion']
        $capabilities = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', $capabilityUrl, '--output', 'json') -Json -AllowFailure
        # Get-DemoMemberList returns its list as one object: assign it before piping.
        $capabilityItems = Get-DemoMemberList -InputObject $capabilities -Name 'value'
        $capability = $capabilityItems | Select-Object -First 1
        $editions = Get-DemoMemberList -InputObject $capability -Name 'supportedServerEditions'
        $edition = $editions | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $t4Tier } | Select-Object -First 1
        $skuItems = Get-DemoMemberList -InputObject $edition -Name 'supportedServerSkus'
        $skus = @($skuItems | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $versionItems = Get-DemoMemberList -InputObject $capability -Name 'supportedServerVersions'
        $versions = @($versionItems | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $t4Evidence = @{ sku = $t4Sku; tier = $t4Tier; majorVersion = [string]$postgres['majorVersion']; editionSkus = $skus; versions = $versions }
        if ($null -eq $capability) {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Warning' ('The PostgreSQL flexible server capabilities of {0} couldn''t be read, so T4''s size and version weren''t checked.' -f $location) -Evidence $t4Evidence -Remediation 'Run preflight again once Microsoft.DBforPostgreSQL is registered.' -DocUrl 'https://learn.microsoft.com/rest/api/postgresql/flexibleserver/location-based-capabilities/execute'
        }
        elseif ($t4Sku -in $skus -and [string]$postgres['majorVersion'] -in $versions) {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Pass' ('{0} offers T4''s {1} {2} and PostgreSQL {3}.' -f $location, $t4Tier, $t4Sku, $postgres['majorVersion']) -Evidence $t4Evidence -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute'
        }
        else {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Fail' ('{0} doesn''t offer T4''s {1} {2} with PostgreSQL {3}.' -f $location, $t4Tier, $t4Sku, $postgres['majorVersion']) -Evidence $t4Evidence -Remediation 'Pick a region that offers it, or set t4Enabled to false (Phase 24, ADR 0019).' -DocUrl 'https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute'
        }
        # The capability list doesn't show a size that's temporarily unavailable: Azure refused B1ms with
        # SkuNotAvailable on 2026-10-26 while the list included it. A refusal on record for this size and zone is a
        # Fail; a first try in another zone is a Warning. Nothing upsizes T4 on its own.
        $refused = Get-DemoT4CreateFailure -Config $Config
        if ($null -ne $refused -and $refused.Sku -eq $t4Sku) {
            $t4Zone = Get-DemoT4AvailabilityZone -Config $Config
            $skuStatus = if ($t4Zone -and $t4Zone -ne $refused.Zone) { 'Warning' } else { 'Fail' }
            $results.Add((New-DemoT4SkuFailureResult -CheckId 'PREFLIGHT.T4.SKU' -Failure $refused -Status $skuStatus -NextZone $t4Zone))
        }
    }
    else {
        Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Not selected' 'T4 is off in this configuration (t4Enabled is false).'
    }

    # T2 mode (ADR 0006). The evaluation-only fallback is opt-in, and everything about it is labeled.
    if ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm') {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.T2.MODE' -Area 'preflight' -Target 'T2' -Status 'Warning' -Message 't2Mode is EvaluationOnlyAzureVm: T2 is the Azure VM arcsql01, onboarded to Azure Arc with Microsoft''s evaluation procedure, which is for evaluation and testing only. Use it only when the nested-virtualization checks fail (ADR 0006).' -Remediation 'Set t2Mode to Nested when a nested-virtualization size is available.' -DocUrl 'https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine' -EvaluationOnly))
    }
    else {
        Add-Check 'PREFLIGHT.T2.MODE' 'T2' 'Pass' 'T2 is the nested Hyper-V guest arcsql01 on archost01 (t2Mode Nested, ADR 0006).'
    }

    # Azure Hybrid Benefit fails closed without the entitlement attestation (ADR 0006, C6).
    $hybrid = $Config['hybridBenefit']
    if (-not ($hybrid['windows'] -or $hybrid['sql'])) {
        Add-Check 'PREFLIGHT.C6.HYBRIDBENEFIT' 'subscription' 'Not selected' 'Azure Hybrid Benefit is off.'
    }
    elseif ($hybrid['entitlementAttested']) {
        Add-Check 'PREFLIGHT.C6.HYBRIDBENEFIT' 'subscription' 'Pass' 'Azure Hybrid Benefit is on, and the entitlement is attested.'
    }
    else {
        Add-Check 'PREFLIGHT.C6.HYBRIDBENEFIT' 'subscription' 'Fail' 'Azure Hybrid Benefit is requested, but hybridBenefit.entitlementAttested is false.' -Remediation 'Set hybridBenefit.entitlementAttested to true only if you hold the licenses, or turn the benefit off (ADR 0006).' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/hybrid-use-benefit-licensing'
    }

    $usage = @(Invoke-Az -Arguments @('vm', 'list-usage', '--location', $location) -Json)
    $needed = @{}
    foreach ($request in $vmRequests) {
        $needed[$request.Family] = [int]$needed[$request.Family] + $request.Vcpus
    }
    $needed['cores'] = ($vmRequests | Measure-Object -Property Vcpus -Sum).Sum
    $short = foreach ($family in $needed.Keys) {
        $row = $usage | Where-Object { $_.name.value -eq $family } | Select-Object -First 1
        if (-not $row -or ([int]$row.limit - [int]$row.currentValue) -lt $needed[$family]) {
            '{0} (need {1}, available {2})' -f $family, $needed[$family], $(if ($row) { [int]$row.limit - [int]$row.currentValue } else { 0 })
        }
    }
    if (@($short).Count -eq 0) {
        Add-Check 'PREFLIGHT.P3.QUOTA' 'subscription' 'Pass' ('vCPU quota in {0} covers the {1} profile.' -f $location, $Config['profile'])
    }
    else {
        Add-Check 'PREFLIGHT.P3.QUOTA' 'subscription' 'Fail' ('Not enough vCPU quota in {0}: {1}.' -f $location, ($short -join '; ')) -Remediation 'Request a quota increase, or choose a smaller profile or another region.' -DocUrl 'https://learn.microsoft.com/azure/quotas/per-vm-quota-requests'
    }

    $networkUsage = @(Invoke-Az -Arguments @('network', 'list-usages', '--location', $location) -Json)
    $ipRow = $networkUsage | Where-Object { $_.name.value -eq 'PublicIPAddresses' } | Select-Object -First 1
    if ($ipRow -and ([int]$ipRow.limit - [int]$ipRow.currentValue) -ge 1) {
        Add-Check 'PREFLIGHT.P3.PUBLICIP' 'subscription' 'Pass' 'Public IP quota allows on-demand Bastion.'
    }
    else {
        Add-Check 'PREFLIGHT.P3.PUBLICIP' 'subscription' 'Warning' 'No public IP quota is left, so on-demand Bastion cannot be created.' -Remediation 'Request a public IP quota increase if you need interactive access.'
    }

    # P4 and P5: Fabric. No supported API reads the Hub setting without Fabric administrator rights. P5 (Phase 26a,
    # ADR 0021): the workspace and the lakehouse by name, read-only; preflight never creates them.
    Add-Check 'PREFLIGHT.P4.HUBSETTING' 'tenant' 'Manual action required' 'Confirm that a Fabric administrator enabled "Users can access the Database hub (preview)" and that Hub users have a Fabric Free license.' -DocUrl 'https://learn.microsoft.com/fabric/database/hub/overview'
    $fabricCheck = Test-DemoFabricResolution -Config $Config
    $results.Add($fabricCheck.Result)
    # P11 (optional, Phase 18): Power BI viewer licensing on the workspace's capacity; a Warning below F64.
    $results.Add((Test-DemoFabricViewerLicense -Config $fabricCheck.Config -CapacityResult $fabricCheck.CapacityResult))

    # P6: the T3 admin group exists and the caller owns it. Microsoft Graph is read with a token verified for
    # the configured tenant; 'az ad' would answer for the Azure CLI's default account, which can be in another
    # tenant. The caller's object ID comes from the subscription guard's verified token.
    $groupId = [string]$Config['t3AdminGroupObjectId']
    $groupDisplayName = ''
    $graph = 'https://graph.microsoft.com/v1.0'
    $groupRead = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'GET' -Uri ('{0}/groups/{1}?$select=id,displayName' -f $graph, $groupId)
    $group = if ($groupRead.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$groupRead.StdOut)) { [string]$groupRead.StdOut | ConvertFrom-Json -Depth 8 } else { $null }
    if (-not $group) {
        $reason = if ($groupRead.StatusCode -eq 404) { 'was not found in the configured tenant' } else { 'could not be read from Microsoft Graph ({0})' -f ([string]$groupRead.StdErr).Trim() }
        Add-Check 'PREFLIGHT.P6.GROUP' 'tenant' 'Fail' "The T3 admin group $groupId $reason." -Remediation 'Create an Entra security group you own in the demo tenant and set t3AdminGroupObjectId (prerequisite P6).' -DocUrl 'https://learn.microsoft.com/graph/api/group-get'
    }
    else {
        $groupDisplayName = [string](Get-DemoMemberValue -InputObject $group -Name 'displayName')
        $callerId = (Get-DemoCallerIdentity -SubscriptionId $subscriptionId).ObjectId
        $ownersRead = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'GET' -Uri ('{0}/groups/{1}/owners?$select=id' -f $graph, $groupId)
        $owners = if ($ownersRead.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$ownersRead.StdOut)) { @(Get-DemoMemberValue -InputObject ([string]$ownersRead.StdOut | ConvertFrom-Json -Depth 8) -Name 'value') } else { @() }
        $ownerIds = @($owners | Where-Object { $_ } | ForEach-Object { ([string](Get-DemoMemberValue -InputObject $_ -Name 'id')).ToLowerInvariant() })
        if ($callerId -and $ownerIds -contains $callerId) {
            Add-Check 'PREFLIGHT.P6.GROUP' 'tenant' 'Pass' 'The caller owns the T3 admin group, so T1 can configure T3 automatically.' -Evidence @{ groupDisplayName = $groupDisplayName }
        }
        else {
            Add-Check 'PREFLIGHT.P6.GROUP' 'tenant' 'Warning' 'The caller does not own the T3 admin group, so T1 cannot be added to it automatically. The fallback is the interactive T-SQL step (ADR 0008).' -Remediation 'Ask a group owner to add you as an owner, or plan for the fallback.' -Evidence @{ groupDisplayName = $groupDisplayName }
        }
    }

    # Policy inventory: read-only; resolves networkMode auto and reports conflicts.
    $configuredNetworkMode = if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }
    $network = $null
    if ($SkipPolicyInventory) {
        $network = Resolve-DemoNetworkMode -ConfiguredMode $configuredNetworkMode -PolicyUnknown
        $assumption = if ($network.Assumed) { ' (private works under any policy)' } else { '' }
        Add-Check 'PREFLIGHT.POLICY.INVENTORY' 'subscription' 'Not selected' 'The policy inventory was skipped (-SkipPolicyInventory). The what-if check still catches policy denials.'
        Add-Check 'PREFLIGHT.POLICY.SQLPUBLIC' 'subscription' 'Not selected' ('Without the policy inventory, networkMode {0} resolves to {1}{2}.' -f $network.ConfiguredMode, $network.EffectiveMode, $assumption) -Evidence @{ configuredNetworkMode = $network.ConfiguredMode; effectiveNetworkMode = $network.EffectiveMode; assumed = $network.Assumed; policies = @() }
    }
    else {
        try {
            $policy = Get-DemoPolicyConstraint -Config $Config -CacheHours $PolicyCacheHours
            foreach ($result in $policy.Results) {
                $results.Add($result)
            }
            $network = $policy.NetworkMode
        }
        catch {
            $network = Resolve-DemoNetworkMode -ConfiguredMode $configuredNetworkMode -PolicyUnknown
            Add-Check 'PREFLIGHT.POLICY.INVENTORY' 'subscription' 'Warning' ('The policy inventory failed ({0}). The what-if check still catches policy denials.' -f $_.Exception.Message.TrimEnd('.'))
            Add-Check 'PREFLIGHT.POLICY.SQLPUBLIC' 'subscription' $network.Status $network.Message -Evidence @{ configuredNetworkMode = $network.ConfiguredMode; effectiveNetworkMode = $network.EffectiveMode; assumed = $network.Assumed; policies = @() } -Remediation $network.Remediation
        }
    }
    $effectiveNetworkMode = $network.EffectiveMode

    # T3 free offer: read-only; decides whether T3 uses the Azure SQL Database free offer (ADR 0016, C7). It runs
    # before the what-if, which needs the result.
    $freeOfferDoc = 'https://learn.microsoft.com/azure/azure-sql/database/free-offer'
    try {
        $freeOffer = Get-DemoT3FreeOfferStatus -Config $Config
        $results.Add($freeOffer.Result)
        $t3UseFreeLimit = [bool]$freeOffer.UseFreeLimit
    }
    catch {
        $t3UseFreeLimit = [string]$Config['t3FreeOffer'] -ne 'off'
        Add-Check 'PREFLIGHT.T3.FREEOFFER' 'T3' 'Warning' ('The free-offer check failed ({0}). T3 tries the free offer, and the deployment falls back to regular serverless if Azure rejects it.' -f $_.Exception.Message.TrimEnd('.')) -Evidence @{ useFreeLimit = $t3UseFreeLimit } -DocUrl $freeOfferDoc
    }

    # Policy: what-if of the subscription deployment. No resources change.
    if ($SkipWhatIf) {
        Add-Check 'PREFLIGHT.POLICY.WHATIF' 'subscription' 'Not selected' 'The what-if policy check was skipped.'
    }
    else {
        # VMs that already exist keep their osProfile out of the template (ADR 0001). A VM that would be created
        # needs an administrator password even for what-if, so a throwaway one is generated in memory,
        # registered for redaction, and never used to create anything.
        $resourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
        $listed = Invoke-Az -Arguments @('vm', 'list', '--resource-group', $resourceGroupName, '--query', '[].name') -Json -AllowFailure
        $existingVms = @(@($listed) | Where-Object { $_ -is [string] -and $_ -in @('sqlvm01', 'archost01', 'arcsql01') })
        $parametersPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dbhub-preflight-{0}.json' -f [guid]::NewGuid())
        $whatIf = $null
        try {
            Get-DemoDeploymentParameter -Config $Config -NetworkMode $effectiveNetworkMode -ExistingVmName $existingVms -T1SecurityType $t1Security.SecurityType -T3UseFreeLimit $t3UseFreeLimit -T3AdminGroupDisplayName $groupDisplayName | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parametersPath -Encoding utf8NoBOM
            $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/main.bicep'
            $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('deployment', 'sub', 'what-if', '--location', $location, '--name', ('preflight-{0}-{1}' -f $Config['prefix'], $Config['environment']), '--template-file', $template, '--parameters', "@$parametersPath"))
            if ($existingVms.Count -lt 2) {
                $throwaway = [System.Net.NetworkCredential]::new('', (New-DemoAdminPassword)).Password
                $arguments.AddRange([string[]]@('--parameters', "adminPassword=$throwaway"))
            }
            $arguments.AddRange([string[]]@('--no-pretty-print', '--output', 'json'))
            $whatIf = Invoke-Az -Arguments $arguments.ToArray() -AllowFailure
        }
        catch {
            Add-Check 'PREFLIGHT.POLICY.WHATIF' 'subscription' 'Fail' ('The what-if could not run: {0}' -f $_.Exception.Message)
        }
        finally {
            Remove-Item -LiteralPath $parametersPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $whatIf -and $whatIf.ExitCode -eq 0) {
            $changes = @(($whatIf.StdOut | ConvertFrom-Json -Depth 64).changes)
            $summary = $changes | Group-Object -Property changeType | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
            Add-Check 'PREFLIGHT.POLICY.WHATIF' 'subscription' 'Pass' ('What-if succeeded with no policy denials: {0}.' -f ($summary -join ', ')) -Evidence @{ changes = $changes.Count }
        }
        elseif ($null -ne $whatIf -and $whatIf.StdErr -match 'RequestDisallowedByPolicy|PolicyViolation') {
            Add-Check 'PREFLIGHT.POLICY.WHATIF' 'subscription' 'Fail' 'Azure Policy would deny part of the deployment.' -Evidence @{ error = (Protect-DemoText -Text $whatIf.StdErr.Trim()) } -Remediation 'Review the policy assignment named in the error; request an exemption or adjust the configuration (plan risk R9).'
        }
        elseif ($null -ne $whatIf) {
            Add-Check 'PREFLIGHT.POLICY.WHATIF' 'subscription' 'Fail' 'What-if failed.' -Evidence @{ error = (Protect-DemoText -Text $whatIf.StdErr.Trim()) }
        }
    }

    # Cost: live retail prices against the ceilings, with the subscription's Defender for Cloud plans.
    $costParameters = @{ Config = $Config; NetworkMode = $effectiveNetworkMode; T3UseFreeLimit = $t3UseFreeLimit }
    try {
        $costParameters['DefenderPlans'] = @(Get-DemoDefenderPlan -SubscriptionId $subscriptionId)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The Defender for Cloud plans could not be read, so the cost estimate excludes them: {0}' -f $_.Exception.Message)
    }
    try {
        $costParameters['GoldenSnapshots'] = @(Get-DemoT2GoldenSnapshot -Config $Config)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The T2 golden snapshots could not be listed, so the cost estimate leaves them out: {0}' -f $_.Exception.Message)
    }
    try {
        foreach ($result in (Get-DemoCostEstimate @costParameters).Results) {
            $results.Add($result)
        }
    }
    catch {
        Add-Check 'PREFLIGHT.COST.SESSION' 'subscription' 'Warning' ('The cost estimate could not be computed: {0}' -f $_.Exception.Message)
    }

    return $results.ToArray()
}
