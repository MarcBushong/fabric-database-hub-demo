function Get-DemoDeploymentParameter {
    <#
    .SYNOPSIS
    Builds the ARM deployment parameters for infra/main.bicep from the demo configuration.

    .DESCRIPTION
    Returns a deployment-parameters document (schema, contentVersion, parameters). It never contains
    secrets: the VM password is passed separately, only when a VM is created (ADR 0009). Azure Hybrid
    Benefit fails closed: requesting it without the entitlement attestation throws (ADR 0006, C6).
    t2Mode comes from the configuration (default Nested), and assignArcOnboardingRole from assignRoles: the
    optional Arc onboarding identity exists only in the nested mode (ADR 0005, ADR 0008).

    .PARAMETER ExistingResourceGroupTags
    Tags already on the resource group, so a re-run keeps them (ADR 0002).

    .PARAMETER BudgetStartDate
    The existing budget's start date (yyyy-MM-01). Omit it for a new budget.

    .PARAMETER NetworkMode
    The effective network mode, public or private, from Resolve-DemoNetworkMode (preflight resolves it
    from Azure Policy). Required when the configuration's networkMode is auto, because the template
    accepts only public or private (ADR 0007).

    .PARAMETER ExistingVmName
    VMs that already exist; the template leaves out their osProfile (ADR 0001). arcsql01 is a VM only in the
    evaluation-only mode (t2Mode EvaluationOnlyAzureVm, ADR 0006).

    .PARAMETER T1SecurityType
    securityType.t1 resolved by Resolve-DemoT1SecurityType. When the configuration says Auto and this is
    empty, Standard is used: the documented fallback.

    .PARAMETER BootstrapBundleSha256
    SHA-256 of the bootstrap bundle, passed only after Send-DemoBootstrapBundle has delivered it to both VMs.
    The template then adds the loader Run Command DbHubDemo-Bootstrap. Omitted, the template deploys no
    bootstrap (ADR 0003).

    .PARAMETER BootstrapChunkCount
    The chunk count Send-DemoBootstrapBundle returned; required with -BootstrapBundleSha256.

    .PARAMETER T3UseFreeLimit
    Whether T3 uses the Azure SQL Database free offer: the useFreeLimit evidence of preflight's
    PREFLIGHT.T3.FREEOFFER (Get-DemoT3FreeOfferStatus), or false when deploy.ps1 falls back after Azure
    rejects the offer (Resolve-DemoT3FreeOfferError). Required when the configuration's t3FreeOffer is
    auto; with off it defaults to false and can't be true (ADR 0016, C7).

    .PARAMETER WorkloadRunnerSha256
    SHA-256 of the workload runner zip from Publish-DemoWorkloadRunner, passed only after Send-DemoWorkloadRunner
    has delivered it to both VMs. It reaches the bootstraps in their settings, and their WorkloadRunner steps
    install it; a new value re-runs the loader. Omitted, those steps are Not selected (ADR 0010). Needs
    -BootstrapBundleSha256, because the settings travel with the loader.

    .PARAMETER WorkloadRunnerChunkCount
    The chunk count Send-DemoWorkloadRunner returned; required with -WorkloadRunnerSha256.

    .PARAMETER T3AdminGroupDisplayName
    The P6 group's display name (preflight's PREFLIGHT.P6.GROUP evidence), recorded as T3's administrator
    login and cut to 128 characters. Omitted, the template's placeholder name is used; the administrator is
    identified by t3AdminGroupObjectId either way.

    .PARAMETER T2OsDiskSourceId
    Resource ID of a golden snapshot that a new archost01's OS disk is copied from (ADR 0018,
    Resolve-DemoT2Source). Only for a host that doesn't exist yet.

    .PARAMETER T2AttachExistingOsDisk
    archost01 exists and runs from a golden disk (no osProfile): the template attaches its existing OS disk
    instead of declaring an image.

    .PARAMETER DiskSkuOverride
    Disk name (<vm>-osdisk or <vm>-data01) -> current storage type, for existing disks whose type drifted from
    the profile (Get-DemoVmDiskDrift). The template keeps those types (diskSkuOverrides), because the
    subscription's automation can switch a deallocated VM's disks to Standard HDD and Azure doesn't change an
    OS disk's type through its VM (Phase 24).

    .PARAMETER T4Exists
    T4's server exists: its availability zone isn't sent, because a server keeps the zone it was created in.
    t4SkuName (Get-DemoT4SkuName) is always sent (Phase 24, ADR 0019).

    .EXAMPLE
    Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true | ConvertTo-Json -Depth 10

    .EXAMPLE
    Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -ExistingVmName sqlvm01, archost01 -BootstrapBundleSha256 $bundle.Sha256 -BootstrapChunkCount $sent.ChunkCount

    .EXAMPLE
    Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $false -ExistingVmName sqlvm01, archost01 -BootstrapBundleSha256 $bundle.Sha256 -BootstrapChunkCount 1 -WorkloadRunnerSha256 $runner.Sha256 -WorkloadRunnerChunkCount 7
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [System.Collections.IDictionary] $ExistingResourceGroupTags = @{},

        [ValidatePattern('^$|^[0-9]{4}-[0-9]{2}-01$')]
        [string] $BudgetStartDate = '',

        [ValidateSet('public', 'private')]
        [string] $NetworkMode,

        [ValidateSet('sqlvm01', 'archost01', 'arcsql01')]
        [string[]] $ExistingVmName = @(),

        [ValidateSet('', 'Standard', 'TrustedLaunch')]
        [string] $T1SecurityType = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
        [string] $BootstrapBundleSha256 = '',

        [ValidateRange(0, 999)]
        [int] $BootstrapChunkCount = 0,

        [bool] $T3UseFreeLimit,

        [ValidateLength(0, 256)]
        [string] $T3AdminGroupDisplayName = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
        [string] $WorkloadRunnerSha256 = '',

        [ValidateRange(0, 999)]
        [int] $WorkloadRunnerChunkCount = 0,

        [ValidatePattern('^$|^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]{1,90}/providers/Microsoft\.Compute/snapshots/[A-Za-z0-9._-]{1,80}$')]
        [string] $T2OsDiskSourceId = '',

        [switch] $T2AttachExistingOsDisk,

        [System.Collections.IDictionary] $DiskSkuOverride = @{},

        [switch] $T4Exists
    )

    if ($T2OsDiskSourceId -and $T2AttachExistingOsDisk) {
        throw 'Pass -T2OsDiskSourceId for a new golden host or -T2AttachExistingOsDisk for an existing one, not both.'
    }
    foreach ($diskName in @($DiskSkuOverride.Keys)) {
        if ([string]$diskName -notmatch '^(sqlvm01|archost01|arcsql01)-(osdisk|data01)$' -or [string]$DiskSkuOverride[$diskName] -notmatch '^(Standard_LRS|StandardSSD_LRS|Premium_LRS|PremiumV2_LRS|StandardSSD_ZRS|Premium_ZRS|UltraSSD_LRS)$') {
            throw ('-DiskSkuOverride takes demo disk names (<vm>-osdisk or <vm>-data01) and managed disk types; got {0} = {1}.' -f $diskName, $DiskSkuOverride[$diskName])
        }
    }
    if ($BootstrapBundleSha256 -and $BootstrapChunkCount -lt 1) {
        throw '-BootstrapChunkCount is required with -BootstrapBundleSha256: pass the ChunkCount that Send-DemoBootstrapBundle returned.'
    }
    if (-not $BootstrapBundleSha256 -and $BootstrapChunkCount -gt 0) {
        throw '-BootstrapChunkCount needs -BootstrapBundleSha256.'
    }
    if ($WorkloadRunnerSha256 -and $WorkloadRunnerChunkCount -lt 1) {
        throw '-WorkloadRunnerChunkCount is required with -WorkloadRunnerSha256: pass the ChunkCount that Send-DemoWorkloadRunner returned.'
    }
    if (-not $WorkloadRunnerSha256 -and $WorkloadRunnerChunkCount -gt 0) {
        throw '-WorkloadRunnerChunkCount needs -WorkloadRunnerSha256.'
    }
    if ($WorkloadRunnerSha256 -and -not $BootstrapBundleSha256) {
        throw '-WorkloadRunnerSha256 needs -BootstrapBundleSha256: the runner''s settings reach the VMs with the bootstrap loader.'
    }

    $effectiveNetworkMode = if ($NetworkMode) {
        $NetworkMode
    }
    elseif ($Config['networkMode'] -in 'public', 'private') {
        [string]$Config['networkMode']
    }
    else {
        throw "networkMode is '$($Config['networkMode'])' in the configuration, so it must be resolved before the deployment parameters are built. Preflight resolves it from Azure Policy (Resolve-DemoNetworkMode); pass the result with -NetworkMode public or private."
    }

    $hybrid = $Config['hybridBenefit']
    $windowsBenefit = [bool]$hybrid['windows']
    $sqlBenefit = [bool]$hybrid['sql']
    $attested = [bool]$hybrid['entitlementAttested']
    if (($windowsBenefit -or $sqlBenefit) -and -not $attested) {
        throw 'Azure Hybrid Benefit is requested, but hybridBenefit.entitlementAttested is false. Attest the entitlement or turn the benefit off (ADR 0006, C6). Nothing was deployed.'
    }

    # The T3 free offer, like networkMode auto, is resolved by preflight (ADR 0016, C7).
    $t3FreeOffer = if ($Config['t3FreeOffer']) { [string]$Config['t3FreeOffer'] } else { 'auto' }
    if ($PSBoundParameters.ContainsKey('T3UseFreeLimit')) {
        if ($T3UseFreeLimit -and $t3FreeOffer -eq 'off') {
            throw "t3FreeOffer is off in the configuration, so -T3UseFreeLimit can't be true."
        }
        $t3UseFreeLimitValue = $T3UseFreeLimit
    }
    elseif ($t3FreeOffer -eq 'off') {
        $t3UseFreeLimitValue = $false
    }
    else {
        throw "t3FreeOffer is '$t3FreeOffer' in the configuration, so whether T3 uses the Azure SQL Database free offer must be resolved before the deployment parameters are built. Preflight checks it (Get-DemoT3FreeOfferStatus); pass the result with -T3UseFreeLimit `$true or `$false."
    }

    $t1Security = [string]$Config['securityType']['t1']
    if ($T1SecurityType) {
        $t1Security = $T1SecurityType
    }
    elseif ($t1Security -eq 'Auto') {
        $t1Security = 'Standard'
    }
    $zone = ''
    if ($Config.Contains('zone') -and $Config['zone']) {
        $zone = [string]$Config['zone']
    }

    $values = [ordered]@{
        location                  = $Config['location']
        prefix                    = $Config['prefix']
        environment               = $Config['environment']
        networkMode               = $effectiveNetworkMode
        outboundMode              = $Config['outboundMode']
        owner                     = $Config['owner']
        ownerEmail                = $Config['ownerEmail']
        costCenter                = $Config['costCenter']
        autoShutdownTime          = $Config['autoShutdownTime']
        autoShutdownTimeZone      = $Config['autoShutdownTimeZone']
        expiresOn                 = if ($Config['expiresOn']) { [string]$Config['expiresOn'] } else { '' }
        monthlyCeilingUsd         = [int][System.Math]::Ceiling([double]$Config['monthlyCeilingUsd'])
        existingResourceGroupTags = $ExistingResourceGroupTags
        profile                   = $Config['profile']
        zone                      = $zone
        dataDiskSku               = (Get-DemoDataDiskOverride -Config $Config)
        t1Priority                = $Config['t1Priority']
        hostPriority              = $Config['hostPriority']
        t1SecurityType            = $t1Security
        hostSecurityType          = [string]$Config['securityType']['t2Host']
        windowsHybridBenefit      = $windowsBenefit
        sqlHybridBenefit          = $sqlBenefit
        hybridBenefitAttested     = $attested
        t2SqlInstallMode          = $Config['t2SqlInstallMode']
        existingVmNames           = @($ExistingVmName)
        t3AdminGroupObjectId      = [string]$Config['t3AdminGroupObjectId']
        t3AutoPauseMinutes        = [int]$Config['t3AutoPauseMinutes']
        t3UseFreeLimit            = $t3UseFreeLimitValue
        activityProfile           = if ($Config['activityProfile']) { [string]$Config['activityProfile'] } else { 'baseline' }
        activityProfileOnBoot     = ($Config.Contains('activityProfileOnBoot') -and [bool]$Config['activityProfileOnBoot'])
        t4Enabled                 = (Test-DemoT4Enabled -Config $Config)
        t4SkuName                 = (Get-DemoT4SkuName -Config $Config)
        # A server keeps the zone it was created in, so the zone goes only to a T4 that doesn't exist yet.
        t4AvailabilityZone        = $(if ($T4Exists) { '' } else { Get-DemoT4AvailabilityZone -Config $Config })
    }
    if ($DiskSkuOverride.Count -gt 0) {
        $overrides = [ordered]@{}
        foreach ($diskName in @($DiskSkuOverride.Keys | Sort-Object)) {
            $overrides[[string]$diskName] = [string]$DiskSkuOverride[$diskName]
        }
        $values['diskSkuOverrides'] = $overrides
    }
    if ($T3AdminGroupDisplayName) {
        # Group display names can be up to 256 characters; a SQL login name is at most 128.
        $values['t3AdminGroupDisplayName'] = if ($T3AdminGroupDisplayName.Length -gt 128) { $T3AdminGroupDisplayName.Substring(0, 128) } else { $T3AdminGroupDisplayName }
    }
    $t2Mode = if ($Config.Contains('t2Mode') -and $Config['t2Mode']) { [string]$Config['t2Mode'] } else { 'Nested' }
    $values['t2Mode'] = $t2Mode
    $values['assignArcOnboardingRole'] = [bool]$Config['assignRoles'] -and $t2Mode -eq 'Nested'
    if ($BudgetStartDate) {
        $values['budgetStartDate'] = $BudgetStartDate
    }
    if ($BootstrapBundleSha256) {
        $values['bootstrapBundleSha256'] = $BootstrapBundleSha256.ToLowerInvariant()
        $values['bootstrapChunkCount'] = $BootstrapChunkCount
    }
    if ($WorkloadRunnerSha256) {
        $values['workloadRunnerSha256'] = $WorkloadRunnerSha256.ToLowerInvariant()
        $values['workloadRunnerChunkCount'] = $WorkloadRunnerChunkCount
    }
    if ($T2OsDiskSourceId) {
        $values['t2OsDiskSourceId'] = $T2OsDiskSourceId
    }
    if ($T2AttachExistingOsDisk) {
        $values['t2AttachExistingOsDisk'] = $true
    }

    $parameters = [ordered]@{}
    foreach ($key in $values.Keys) {
        $parameters[$key] = @{ value = $values[$key] }
    }

    return [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }
}
