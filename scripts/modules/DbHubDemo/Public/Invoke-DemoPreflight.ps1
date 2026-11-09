function Invoke-DemoPreflight {
    <#
    .SYNOPSIS
    Checks every prerequisite before anything is deployed (ADR 0008, ADR 0012).

    .DESCRIPTION
    Runs, in order:
    - Subscription guard (Assert-DemoAzContext): the configured subscription's Azure CLI account must reach
      the configured subscription and tenant through every authentication path, without the default
      subscription.
    - The .NET SDK that builds the workload runner (Test-DemoDotNetSdk, PREFLIGHT.TOOLS.DOTNETSDK; 2026-11-09 live
      finding): the dotnet the build runs, with --version in workload-generator, where global.json applies. A Fail
      before anything is created says which dotnet ran, which SDKs it has, what global.json needs, and the exact fix.
      Not selected with -SkipRunner. Local and read-only.
    - P1: Contributor-level permissions on the subscription (and role-assignment rights if assignRoles is set).
    - P2: resource providers; missing ones are registered unless -SkipProviderRegistration is set.
    - P3: region, VM sizes, nested-virtualization families, vCPU quota, and public IP quota; with a zone
      configured, that both sizes and (for demo-day and enhanced-performance) Premium SSD v2 are offered in
      that zone; and the VM security types, resolving securityType.t1 = Auto from the image's features.
    - C6: Azure Hybrid Benefit only with the entitlement attestation.
    - P4 and P5: the Fabric tenant setting, read through the Fabric admin API when the caller is a Fabric
      administrator, otherwise a reminder to confirm it (Test-DemoFabricHubSetting -CheckId PREFLIGHT.P4.HUBSETTING;
      Phase 28 live finding), and the Fabric workspace and lakehouse by
      name, read-only (Test-DemoFabricResolution, Phase 26a): your role and the capacity of a workspace that exists,
      or the capacity deploy.ps1 would create it on; the optional P11, Power BI viewer licensing on the workspace's
      capacity (Test-DemoFabricViewerLicense, a Warning below F64); and P12 and P13, the tenant settings the Insights
      app needs, which never block the run (Test-DemoFabricAppTenantSetting, PREFLIGHT.FABRIC.APPSETTINGS: a Pass, or a
      Warning when one is off or can't be read; 2026-11-05).
    - P6: the T3 Entra admin group exists and the caller owns it, read from Microsoft Graph with a token
      verified for the configured tenant (Invoke-DemoRestRequest). The group's display name is in the
      evidence (groupDisplayName), for T3's administrator login.
    - Policy inventory: a read-only list of the Azure Policy rules that apply to the subscription
      (Get-DemoPolicyConstraint). It resolves networkMode auto to public or private and reports
      conflicts. Unless -SkipPolicyInventory is set.
    - T3 free offer: whether the Azure SQL Database free offer is available (Get-DemoT3FreeOfferStatus,
      read-only). When it isn't, T3 falls back to regular serverless with a Warning.
    - Policy what-if: a subscription what-if of infra/main.bicep with the effective network mode, the
      free-offer result, and the existing budget's start date, as the deployment sends them (no resources change).
      VMs that already exist keep osProfile out; a VM that would be created gets a throwaway in-memory password
      for the what-if only.
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

    .PARAMETER DeferPolicyInventory
    With networkMode private, leave the policy inventory to the caller (deploy.ps1 runs it alongside the template,
    Phase 28): PREFLIGHT.POLICY.INVENTORY and PREFLIGHT.POLICY.SQLPUBLIC are Not selected, with the configured mode.
    Ignored with networkMode auto, which needs the inventory, and with public, whose conflict with a Modify policy that
    turns SQL public access off must stop the run before anything is created (review finding 7).

    .PARAMETER SkipRunner
    The run builds no workload runner (deploy.ps1 -SkipRunner), so it needs no .NET SDK: PREFLIGHT.TOOLS.DOTNETSDK is
    Not selected, and no dotnet runs.

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
        [int] $PolicyCacheHours = 0,

        [switch] $DeferPolicyInventory,

        [switch] $SkipRunner
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

    # The .NET SDK that builds the workload runner, before anything is created (2026-11-09 live finding: a runtime-only
    # dotnet first on PATH failed the Artifacts step about 15 minutes into the run). Local and read-only.
    if ($SkipRunner) {
        Add-Check 'PREFLIGHT.TOOLS.DOTNETSDK' 'repo' 'Not selected' 'The workload runner isn''t built (-SkipRunner), so no .NET SDK is needed.'
    }
    else {
        $results.Add((Test-DemoDotNetSdk))
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

    # T4 (Phase 24, ADR 0019): the region offers the configured size in its tier's edition (General Purpose for the D
    # sizes, Burstable for the B sizes) and the pinned PostgreSQL major version, read with 'az postgres flexible-server
    # list-skus' (Phase 28, brief item 10), or the documented Location Based Capabilities API when the Azure CLI can't
    # answer. When the configuration doesn't set t4SkuName and T4 doesn't exist yet, the fallback applies (since T4's
    # 4-vCore default, 2026-11-04: Standard_D4ds_v5, once more in another zone, Standard_D4ads_v5, then Standard_D2ds_v5
    # with autonomous tuning off after its cost check, then no T4), so a size the region doesn't list isn't a Fail: the
    # furthest step any check found is where deploy.ps1 starts (PREFLIGHT.T4.FALLBACK's startSku, with the cost check
    # below). An existing server keeps its own size, or moves to the default once (PREFLIGHT.T4.SIZE), so the fallback
    # doesn't apply to it. PREFLIGHT.T4.TUNING says whether the size T4 gets runs autonomous tuning.
    $t4On = Test-DemoT4Enabled -Config $Config
    $t4Explicit = Test-DemoT4SkuExplicit -Config $Config
    $t4Exists = $false
    $t4ServerSku = ''
    $t4Scale = $false
    $t4Starts = [System.Collections.Generic.List[string]]::new()
    if ($t4On) {
        $postgres = Get-DemoPostgresSetting
        if (-not $t4Explicit) {
            # One read: the server, when it exists, and its own size (Servers - Get).
            $t4Current = Get-DemoT4State -Config $Config
            $t4Exists = [bool](Get-DemoMemberValue -InputObject $t4Current -Name 'Exists')
            $t4ServerSku = Get-DemoT4ServerSku -Server (Get-DemoMemberValue -InputObject $t4Current -Name 'Server')
        }
        $t4Planned = Get-DemoT4SkuName -Config $Config
        $t4Default = Get-DemoT4DefaultSkuName -Config $Config
        # An existing server that no record keeps moves to the default at deploy.ps1's run (2026-11-04).
        $t4Scale = $t4Exists -and [bool]$t4ServerSku -and $t4ServerSku -cne $t4Default -and $t4Planned -ceq $t4Default
        $t4Sku = if ($t4ServerSku -and -not $t4Scale) { $t4ServerSku } else { $t4Planned }
        $t4Tier = (Get-DemoT4SkuSpec -SkuName $t4Sku).Tier
        $t4Ladder = -not $t4Explicit -and -not $t4Exists
        if ($t4Ladder -and $t4Sku -cin 'Standard_D4ads_v5', 'Standard_D2ds_v5') {
            # An earlier run's record (DbHubT4Size Standard_D4ads_v5, Standard_D2ds_v5, or None for a run that deploys the
            # template) for a server that wasn't created: the fallback starts there, and its cost check below decides.
            $t4Starts.Add($t4Sku)
        }
        $capabilitySource = 'az postgres flexible-server list-skus'
        $listed = @(Invoke-Az -Arguments @('postgres', 'flexible-server', 'list-skus', '--location', $location, '--output', 'json') -Json -AllowFailure | Where-Object { $null -ne $_ })
        $capabilityItems = if ($listed.Count -eq 1 -and $null -ne (Get-DemoMemberValue -InputObject $listed[0] -Name 'value')) { Get-DemoMemberList -InputObject $listed[0] -Name 'value' } else { $listed }
        # Only an answer in the shape this check reads counts (the capability's supportedServerEditions); anything else
        # falls back to the REST API at the version config/versions.json pins.
        $capabilityItems = @($capabilityItems | Where-Object { $null -ne (Get-DemoMemberValue -InputObject $_ -Name 'supportedServerEditions') })
        if (@($capabilityItems).Count -eq 0) {
            $capabilitySource = 'Location Based Capabilities'
            $capabilityUrl = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.DBforPostgreSQL/locations/{1}/capabilities?api-version={2}' -f $subscriptionId, $location, $postgres['capabilitiesApiVersion']
            $capabilities = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', $capabilityUrl, '--output', 'json') -Json -AllowFailure
            # Get-DemoMemberList returns its list as one object: assign it before piping.
            $capabilityItems = Get-DemoMemberList -InputObject $capabilities -Name 'value'
        }
        $capability = $capabilityItems | Select-Object -First 1
        $editions = Get-DemoMemberList -InputObject $capability -Name 'supportedServerEditions'
        $skusOf = {
            param([string] $Tier)
            $edition = $editions | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $Tier } | Select-Object -First 1
            $skuItems = Get-DemoMemberList -InputObject $edition -Name 'supportedServerSkus'
            @($skuItems | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        }
        $offers = { param([string] $Sku) $Sku -in @(& $skusOf (Get-DemoT4SkuSpec -SkuName $Sku).Tier) }
        $skus = @(& $skusOf $t4Tier)
        $versionItems = Get-DemoMemberList -InputObject $capability -Name 'supportedServerVersions'
        $versions = @($versionItems | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $t4Evidence = @{ sku = $t4Sku; tier = $t4Tier; majorVersion = [string]$postgres['majorVersion']; editionSkus = $skus; versions = $versions; source = $capabilitySource; explicit = $t4Explicit; exists = $t4Exists; startSku = '' }
        $capabilityDoc = 'https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-list-skus'
        $versionOffered = [string]$postgres['majorVersion'] -in $versions
        if ($null -eq $capability) {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Warning' ('The PostgreSQL flexible server sizes of {0} couldn''t be read, so T4''s size and version weren''t checked.' -f $location) -Evidence $t4Evidence -Remediation 'Run preflight again once Microsoft.DBforPostgreSQL is registered.' -DocUrl $capabilityDoc
        }
        elseif ($t4Exists -and $t4Scale) {
            $scaleStatus = if (& $offers $t4Sku) { 'Pass' } else { 'Warning' }
            $scaleMessage = if ($scaleStatus -eq 'Pass') { 'T4 exists as {0}, and {1} offers the default it moves to, {2} {3} ({4}; PREFLIGHT.T4.SIZE).' -f $t4ServerSku, $location, $t4Tier, $t4Sku, $capabilitySource } else { 'T4 exists as {0}, and {1} doesn''t list the default it would move to, {2} {3} ({4}): deploy.ps1 tries the scale, and if Azure refuses it, T4 keeps {0} (PREFLIGHT.T4.SIZE).' -f $t4ServerSku, $location, $t4Tier, $t4Sku, $capabilitySource }
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' $scaleStatus $scaleMessage -Evidence $t4Evidence -Remediation $(if ($scaleStatus -eq 'Pass') { '' } else { ('To keep T4 as it is, set t4SkuName to {0}.' -f $t4ServerSku) }) -DocUrl $capabilityDoc
        }
        elseif ($t4Exists) {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Pass' ('T4 exists as {0} {1}, and deploy.ps1 keeps its size, so the sizes {2} lists matter only for a new server.' -f $t4Tier, $t4Sku, $location) -Evidence $t4Evidence -DocUrl $capabilityDoc
        }
        elseif ((& $offers $t4Sku) -and $versionOffered) {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Pass' ('{0} offers T4''s {1} {2} and PostgreSQL {3} ({4}).' -f $location, $t4Tier, $t4Sku, $postgres['majorVersion'], $capabilitySource) -Evidence $t4Evidence -DocUrl $capabilityDoc
        }
        elseif ($t4Ladder -and $versionOffered) {
            # The fallback's next sizes after this one, in its order; the first one the region lists is where it starts.
            $steps = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
            $next = @($steps | Select-Object -Skip ([array]::IndexOf($steps, $t4Sku) + 1) | Where-Object { & $offers $_ }) | Select-Object -First 1
            # 2026-11-09 (user-directed): T4 is part of every deployment, so a region that lists none of the fallback's sizes
            # still gets every size tried (the list can lag); only Azure's refusal of them all ends the run NOT DONE.
            $start = if ($next) { [string]$next } else { '' }
            $t4Evidence['startSku'] = $start
            $t4Starts.Add($start)
            switch ($start) {
                'Standard_D4ads_v5' {
                    Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Warning' ('{0} doesn''t list T4''s default Standard_D4ds_v5, so deploy.ps1 starts with Standard_D4ads_v5, General Purpose with 4 vCores too, so autonomous tuning stays on (estimate-cost.ps1 prices it).' -f $location) -Evidence $t4Evidence -Remediation 'Nothing to do. To choose T4''s size yourself, set t4SkuName.' -DocUrl $capabilityDoc
                }
                'Standard_D2ds_v5' {
                    Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Warning' ('{0} lists neither of T4''s 4-vCore sizes (Standard_D4ds_v5, Standard_D4ads_v5), so deploy.ps1 goes to the 2-vCore fallback, Standard_D2ds_v5, with autonomous tuning off (PREFLIGHT.T4.FALLBACK gives its price).' -f $location) -Evidence $t4Evidence -Remediation 'Nothing to do: PREFLIGHT.T4.FALLBACK gives its price and worst case. To choose T4''s size yourself, set t4SkuName.' -DocUrl $capabilityDoc
                }
                default {
                    Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Warning' ('{0} lists none of the sizes T4''s fallback tries (Standard_D4ds_v5, Standard_D4ads_v5, Standard_D2ds_v5). T4 is part of every deployment, so deploy.ps1 tries them anyway, and if Azure refuses them all, the run ends NOT DONE with the fix.' -f $location) -Evidence $t4Evidence -Remediation 'Pick a region that offers one of them, ask for access with a Region access request (Learn: Resolve capacity errors), or set t4SkuName to a size the region offers.' -DocUrl $capabilityDoc
                }
            }
        }
        else {
            Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Fail' ('{0} doesn''t offer T4''s {1} {2} with PostgreSQL {3}.' -f $location, $t4Tier, $t4Sku, $postgres['majorVersion']) -Evidence $t4Evidence -Remediation 'Pick a region that offers it, or set t4SkuName to a size the region offers (Phase 24, ADR 0019). T4 is part of every deployment.' -DocUrl 'https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute'
        }
        # The capability list doesn't show a size that's temporarily unavailable: Azure refused B1ms with
        # SkuNotAvailable on 2026-10-26 while the list included it. A refusal on record for this size and zone is a
        # Fail for a size the configuration sets; otherwise deploy.ps1's fallback starts one step on, a Warning:
        # Standard_D4ds_v5 to Standard_D4ads_v5, Standard_D4ads_v5 to Standard_D2ds_v5 (after its cost check), and
        # Standard_D2ds_v5 to no T4 (ADR 0019). The retry in another zone happens only in deploy.ps1, right after a refusal.
        if (-not $t4Exists) {
            $refused = Get-DemoT4CreateFailure -Config $Config
            if ($null -ne $refused -and $refused.Sku -eq $t4Sku) {
                $t4Zone = Get-DemoT4AvailabilityZone -Config $Config
                $otherZone = $t4Zone -and $t4Zone -ne $refused.Zone
                if (-not $otherZone -and $t4Ladder) {
                    # The last size refused: every run tries the sizes again from the default (2026-11-09, T4 is required).
                    $start = switch ($t4Sku) { 'Standard_D4ds_v5' { 'Standard_D4ads_v5' } 'Standard_D4ads_v5' { 'Standard_D2ds_v5' } default { '' } }
                    $t4Starts.Add($start)
                    $what = switch ($start) {
                        'Standard_D4ads_v5' { 'starts with Standard_D4ads_v5, General Purpose with 4 vCores too' }
                        'Standard_D2ds_v5' { 'goes to the 2-vCore fallback, Standard_D2ds_v5, with autonomous tuning off (PREFLIGHT.T4.FALLBACK gives its price)' }
                        default { 'tries every size again from the default, because T4 is part of every deployment and Azure''s regional capacity changes; if Azure refuses them all, the run ends NOT DONE with the fix' }
                    }
                    $results.Add((New-DemoResult -CheckId 'PREFLIGHT.T4.SKU' -Area 'preflight' -Target 'T4' -Status 'Warning' -Message ('Azure refused T4''s {0} at {1} (SkuNotAvailable), so deploy.ps1 {2}.' -f $t4Sku, $refused.TimeUtc, $what) -Evidence ([ordered]@{ refusedSku = $refused.Sku; refusedUtc = $refused.TimeUtc; startSku = $start }) -Remediation $(if (-not $start) { 'If Azure keeps refusing them, ask for access with a Region access request (Learn: Resolve capacity errors), or set t4SkuName to a size Azure offers you here.' } else { 'Nothing to do. To choose T4''s size yourself, set t4SkuName.' }) -DocUrl 'https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors'))
                }
                else {
                    $skuStatus = if ($otherZone) { 'Warning' } else { 'Fail' }
                    $results.Add((New-DemoT4SkuFailureResult -CheckId 'PREFLIGHT.T4.SKU' -Failure $refused -Status $skuStatus -NextZone $t4Zone))
                }
            }
        }
    }
    else {
        Add-Check 'PREFLIGHT.T4.CAPABILITY' 'T4' 'Not selected' 'T4 is off in this configuration (t4Enabled is false).'
    }
    $t4Start = Select-DemoT4StartSku -Sku $t4Starts.ToArray()
    if ($t4On) {
        # The one-time move of an existing T4 to the default (2026-11-04), and whether the size T4 gets runs autonomous
        # tuning: the configured or recorded size, the server's own, or where the fallback starts.
        if ($t4Scale) {
            $results.Add((New-DemoT4SizeResult -CheckPrefix PREFLIGHT -ServerSku $t4ServerSku -SkuName $t4Sku -Outcome Scale))
        }
        if ($t4Start -in 'None', 'Refused') {
            $results.Add((New-DemoResult -CheckId 'PREFLIGHT.T4.TUNING' -Area 'preflight' -Target 'T4' -Status 'Not selected' -Message 'This run leaves T4 out (PREFLIGHT.T4.CAPABILITY or PREFLIGHT.T4.SKU says why), so autonomous tuning doesn''t apply.' -DocUrl ([string]$postgres['autonomousTuning']['docUrls']['autonomousTuning'])))
        }
        else {
            $tuningSku = if ($t4Start) { $t4Start } else { $t4Sku }
            $tuningWhy = if ($t4Start -eq 'Standard_D2ds_v5') { 'deploy.ps1''s fallback uses Standard_D2ds_v5 because the 4-vCore sizes are ruled out here (PREFLIGHT.T4.CAPABILITY or PREFLIGHT.T4.SKU).' } elseif ($t4Explicit) { ('t4SkuName sets {0}.' -f $tuningSku) } else { '' }
            $results.Add((New-DemoT4TuningResult -Config $Config -SkuName $tuningSku -Why $tuningWhy -CheckPrefix PREFLIGHT))
        }
    }
    else {
        $results.Add((New-DemoT4TuningResult -Config $Config -CheckPrefix PREFLIGHT))
    }

    # T2 mode (ADR 0006). The evaluation-only fallback is opt-in, and everything about it is labeled. The Jumpstart image
    # is a Hyper-V guest disk, so it needs the nested host; an existing guest's source is checked on the host itself
    # (its GuestSource step), which refuses a mode the guest wasn't made for.
    $installMode = if ([string]$Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'JumpstartImage' }
    if ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm' -and $installMode -eq 'JumpstartImage') {
        # 2026-11-09: no SQL Server setup wizard anywhere, so the fix names only the unattended modes this VM runs. An older
        # configuration's PaygWizard (its default before 2026-11-05) runs as JumpstartImage, which it can't.
        $unattended = 'Set t2SqlInstallMode to ProductKey (your own SQL Server Standard product key, prerequisite P10) or Developer (T2 in Database Hub''s Estate only); both install unattended on the evaluation-only Azure VM (ADR 0006).'
        if ((Get-DemoT2InstallModeSource -Config $Config) -eq 'legacy') {
            Add-Check 'PREFLIGHT.T2.MODE' 'T2' 'Fail' 't2SqlInstallMode PaygWizard in your configuration is retired: the one-click deployment has no SQL Server setup wizard, so it runs as JumpstartImage, and Arc Jumpstart''s image is a Hyper-V guest disk, which t2Mode EvaluationOnlyAzureVm can''t use: it makes T2 an Azure VM.' -Remediation $unattended -DocUrl 'https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine'
        }
        else {
            Add-Check 'PREFLIGHT.T2.MODE' 'T2' 'Fail' 't2SqlInstallMode JumpstartImage needs the nested Hyper-V host: Arc Jumpstart''s image is a Hyper-V guest disk, but t2Mode EvaluationOnlyAzureVm makes T2 an Azure VM.' -Remediation ($unattended + ' Or, to keep Arc Jumpstart''s image, use t2Mode Nested with a nested-virtualization size.') -DocUrl 'https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine'
        }
    }
    elseif ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm') {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.T2.MODE' -Area 'preflight' -Target 'T2' -Status 'Warning' -Message 't2Mode is EvaluationOnlyAzureVm: T2 is the Azure VM arcsql01, onboarded to Azure Arc with Microsoft''s evaluation procedure, which is for evaluation and testing only. Use it only when the nested-virtualization checks fail (ADR 0006).' -Remediation 'Set t2Mode to Nested when a nested-virtualization size is available.' -DocUrl 'https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine' -EvaluationOnly))
    }
    elseif ($installMode -eq 'JumpstartImage') {
        Add-Check 'PREFLIGHT.T2.MODE' 'T2' 'Pass' 'T2 is the nested Hyper-V guest arcsql01 on archost01 (t2Mode Nested), made from Arc Jumpstart''s prebuilt SQL Server 2022 Standard guest (t2SqlInstallMode JumpstartImage): no T2 step needs a person (ADR 0006).'
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
        Add-Check 'PREFLIGHT.P3.PUBLICIP' 'subscription' 'Pass' 'Public IP quota allows on-demand Bastion (the PaygWizard guided stop, or optional interactive access).'
    }
    elseif ($installMode -eq 'PaygWizard') {
        Add-Check 'PREFLIGHT.P3.PUBLICIP' 'subscription' 'Warning' 'No public IP quota is left, so on-demand Bastion, which the PaygWizard guided stop needs, cannot be created.' -Remediation 'Request a public IP quota increase, or choose t2SqlInstallMode JumpstartImage, which needs no Bastion.'
    }
    else {
        Add-Check 'PREFLIGHT.P3.PUBLICIP' 'subscription' 'Warning' 'No public IP quota is left, so optional on-demand Bastion cannot be created; the deployment itself doesn''t need it.' -Remediation 'Request a public IP quota increase if you need interactive access.'
    }

    # P4 and P5: Fabric. P4 (Phase 28 live finding, 2026-10-30): the Hub setting is read through the Fabric admin API,
    # which needs a Fabric administrator; for anyone else it's a reminder to confirm it, which never stops the run or
    # keeps it from DONE, and only a setting read as disabled does. P5 (Phase 26a, ADR 0021): the workspace and the
    # lakehouse by name, read-only; preflight never creates them.
    $results.Add((Test-DemoFabricHubSetting -Config $Config -CheckId 'PREFLIGHT.P4.HUBSETTING'))
    $fabricCheck = Test-DemoFabricResolution -Config $Config
    $results.Add($fabricCheck.Result)
    # P11 (optional, Phase 18): Power BI viewer licensing on the workspace's capacity; a Warning below F64.
    $results.Add((Test-DemoFabricViewerLicense -Config $fabricCheck.Config -CapacityResult $fabricCheck.CapacityResult))
    # P12 and P13 (2026-11-05): the tenant settings the Insights app needs, which is part of every deployment but never
    # blocks it; read through the Fabric admin API, and never more than a Warning.
    $results.Add((Test-DemoFabricAppTenantSetting -Config $Config))

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

    # Policy inventory: read-only; resolves networkMode auto and reports conflicts. Phase 28: with networkMode private it
    # resolves nothing the template needs, so -DeferPolicyInventory leaves it to deploy.ps1, which runs it alongside the
    # template; the what-if below still catches a policy that denies part of the deployment. Never with public (review
    # finding 7): a Modify policy that turns SQL public access off isn't a denial the what-if sees, and its conflict
    # (PREFLIGHT.POLICY.SQLPUBLIC Fail) must stop the run before anything is created.
    $configuredNetworkMode = if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }
    $network = $null
    if ($DeferPolicyInventory -and -not $SkipPolicyInventory -and $configuredNetworkMode -eq 'private') {
        $network = Resolve-DemoNetworkMode -ConfiguredMode $configuredNetworkMode -PolicyUnknown
        Add-Check 'PREFLIGHT.POLICY.INVENTORY' 'subscription' 'Not selected' ('Deferred: networkMode is {0}, so the policy inventory resolves nothing the template needs. deploy.ps1 runs it alongside the template and adds its results at the end; the what-if check below catches policy denials before anything is created.' -f $configuredNetworkMode) -Evidence @{ deferred = $true }
        Add-Check 'PREFLIGHT.POLICY.SQLPUBLIC' 'subscription' 'Not selected' ('networkMode is {0}, as configured; the deferred policy inventory reports any conflict at the end of the run.' -f $configuredNetworkMode) -Evidence @{ configuredNetworkMode = $configuredNetworkMode; effectiveNetworkMode = $configuredNetworkMode; assumed = $false; policies = @(); deferred = $true }
    }
    elseif ($SkipPolicyInventory) {
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
            # The same budget start date the deployment sends: the budget's own, which Azure never changes (Phase 28 live
            # finding, 2026-11-02).
            $whatIfParameters = @{ Config = $Config; NetworkMode = $effectiveNetworkMode; ExistingVmName = $existingVms; T1SecurityType = $t1Security.SecurityType; T3UseFreeLimit = $t3UseFreeLimit; T3AdminGroupDisplayName = $groupDisplayName }
            $budgetStart = Get-DemoBudgetStartDate -Config $Config
            if ($budgetStart) {
                $whatIfParameters['BudgetStartDate'] = $budgetStart
            }
            Get-DemoDeploymentParameter @whatIfParameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parametersPath -Encoding utf8NoBOM
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

    # Cost: live retail prices against the ceilings, with the subscription's Defender for Cloud plans. T4 is priced at the
    # size it gets (ADR 0019): an existing server's own size or the default it moves to (PREFLIGHT.T4.SIZE), the step the
    # fallback starts at, or none when the fallback leaves T4 out, so a fallback whose worst case is over a ceiling leaves
    # T4 out instead of stopping the run. The estimates share one price cache, so the fallback's own estimate reads only
    # the prices it adds. The
    # activity profile's T3 incidents count (business-day by default since 2026-11-03), and a configuration that doesn't
    # set activityProfile gets one notice (PREFLIGHT.ACTIVITYPROFILE).
    $notice = New-DemoActivityProfileNotice -ActivityProfile (Get-DemoActivityProfile -Config $Config) -CheckPrefix 'PREFLIGHT'
    if ($null -ne $notice) {
        $results.Add($notice)
    }
    $costConfig = $Config
    if ($t4On -and $t4Exists -and $t4ServerSku -and -not $t4Scale -and $t4ServerSku -cne (Get-DemoT4SkuName -Config $Config)) {
        $costConfig = Copy-DemoT4Config -Config $Config -Source server -SkuName $t4ServerSku
    }
    elseif ($t4On -and $t4Start -in 'Standard_D4ads_v5', 'Standard_D2ds_v5') {
        $costConfig = Copy-DemoT4Config -Config $Config -Source fallback -SkuName $t4Start
    }
    elseif ($t4On -and $t4Start -in 'None', 'Refused') {
        $costConfig = Copy-DemoT4Config -Config $Config -Source fallback -Off
    }
    $costParameters = @{ Config = $costConfig; NetworkMode = $effectiveNetworkMode; T3UseFreeLimit = $t3UseFreeLimit; PriceCache = @{} }
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
    # T4's 7-day automatic restart (2026-11-04, ADR 0016): about a day per restart in the worst case only where a safety stop
    # is fully in place (the nightly safety stop, ADR 0024: its schedule, its role, and a last run that didn't fail; or the
    # control's); otherwise the rest of the month, with a Warning that names what's missing (PREFLIGHT.COST.T4RESTART). On
    # a first deployment the nightly safety stop doesn't exist yet: this run sets it up after the template.
    if ($t4On) {
        $costParameters['T4RestartCoverage'] = Get-DemoT4RestartCoverage -Config $Config
    }
    $results.Add((New-DemoT4RestartCoverageResult -Config $Config -Coverage $(if ($t4On) { $costParameters['T4RestartCoverage'] } else { $null }) -CheckPrefix 'PREFLIGHT'))
    $estimate = $null
    try {
        $estimate = Get-DemoCostEstimate @costParameters
    }
    catch {
        Add-Check 'PREFLIGHT.COST.SESSION' 'subscription' 'Warning' ('The cost estimate could not be computed: {0}' -f $_.Exception.Message)
    }
    if ($null -ne $estimate) {
        $costResults = @($estimate.Results)
        if ($t4On) {
            # The 2-vCore fallback's cost check, and where the fallback starts (ADR 0019). Its failure never
            # drops the run's own cost checks, a monthly-ceiling Fail included (review of 20e855c).
            try {
                $fallback = Get-DemoT4FallbackPreflight -Config $Config -CostParameters $costParameters -Estimate $estimate -Start $t4Start -Explicit:$t4Explicit -Exists:$t4Exists -ServerSku $t4ServerSku
                if ($null -ne $fallback.CostResults) {
                    $costResults = @($fallback.CostResults)
                }
                $results.Add($fallback.Result)
            }
            catch {
                $problem = Protect-DemoText -Text $_.Exception.Message
                $results.Add((New-DemoResult -CheckId 'PREFLIGHT.T4.FALLBACK' -Area 'preflight' -Target 'T4' -Status 'Warning' -Message ('T4''s 2-vCore fallback couldn''t be priced in preflight: {0}. PREFLIGHT.COST.* are the run''s own estimate; deploy.ps1 prices the fallback again right before it would create anything.' -f $problem) -Evidence ([ordered]@{ startSku = $t4Start; skipReason = 'Price'; priceError = $problem }) -Remediation 'Nothing to do: run preflight again later to see the fallback''s price.' -DocUrl 'https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'))
            }
        }
        foreach ($result in $costResults) {
            $results.Add($result)
        }
    }

    return $results.ToArray()
}
