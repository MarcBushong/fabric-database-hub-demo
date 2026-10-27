targetScope = 'resourceGroup'

metadata description = 'Resource-group scope entry point for the demo: network, budget, and optional lock (Phase 5), the T1 and T2 host VMs with their bootstraps (Phase 6), and the optional Arc onboarding identity and the opt-in evaluation-only T2 VM (Phase 7).'

@description('Azure region for every resource.')
param location string

@description('Short lowercase prefix for resource names.')
@minLength(3)
@maxLength(8)
param prefix string

@description('Environment name.')
param environment string

@description('Six-character suffix of the deployment, recorded in the VM bootstrap settings.')
@minLength(6)
@maxLength(6)
param deploymentId string

@description('public or private (ADR 0007).')
param networkMode string

@description('DefaultOutboundAccess or NatGateway (ADR 0017).')
param outboundMode string

@description('Tags for every resource.')
param tags object

@description('Recipient of budget alerts.')
param ownerEmail string

@description('Monthly budget amount in USD.')
param monthlyCeilingUsd int

@description('First day of the budget period (yyyy-MM-01).')
param budgetStartDate string

@description('Add a CanNotDelete lock to the resource group.')
param enableLocks bool

@description('Daily auto-shutdown time (HHmm, 24-hour) for T1 and the T2 host.')
param autoShutdownTime string

@description('Windows time zone ID for the auto-shutdown schedules.')
param autoShutdownTimeZone string

@description('Cost and performance profile in config/profiles.json (ADR 0016).')
param profile string

@description('Availability zone for both VMs, or empty for regional VMs (ADR 0016, C10).')
param zone string

@description('Auto, None, E10, P10, or PremiumV2 (ADR 0016). Auto lets the profile and zone decide; None means no data disks.')
param dataDiskSku string

@description('Regular or Spot for T1.')
param t1Priority string

@description('Regular or Spot for the T2 host.')
param hostPriority string

@description('Standard or TrustedLaunch for T1.')
param t1SecurityType string

@description('Standard or TrustedLaunch for the T2 host.')
param hostSecurityType string

@description('T1 size override; empty uses the profile.')
param t1VmSize string

@description('T2 host size override; empty uses the profile.')
param hostVmSize string

@description('Apply Windows Server Azure Hybrid Benefit. Takes effect only with hybridBenefitAttested.')
param windowsHybridBenefit bool

@description('Apply SQL Server Azure Hybrid Benefit (AHUB) to T1. Takes effect only with hybridBenefitAttested.')
param sqlHybridBenefit bool

@description('The operator attests to the Hybrid Benefit entitlement (ADR 0006, C6).')
param hybridBenefitAttested bool

@description('PaygWizard, ProductKey, or Developer (ADR 0006).')
param t2SqlInstallMode string

@description('Nested (archost01 and its nested guest) or EvaluationOnlyAzureVm (the Azure VM arcsql01, evaluation only; ADR 0006).')
param t2Mode string = 'Nested'

@description('Create the optional Arc onboarding identity and its role assignment on the host (ADR 0005). Nested mode only.')
param assignArcOnboardingRole bool = false

@description('T2 golden restore (ADR 0018): the snapshot a new archost01\'s OS disk is copied from; empty builds the host from the image.')
param t2OsDiskSourceId string = ''

@description('T2 golden restore of an archost01 that already exists: attach its OS disk by ID (ADR 0018).')
param t2AttachExistingOsDisk bool = false

@description('Local administrator name for both VMs.')
param adminUsername string

@description('Local administrator password, used only for VMs that are created in this deployment (ADR 0009).')
@secure()
param adminPassword string

@description('VMs that already exist; their osProfile is left out (ADR 0001).')
param existingVmNames string[]

@description('SHA-256 of the bootstrap bundle zip. Empty skips the bootstrap Run Commands (ADR 0003).')
param bootstrapBundleSha256 string

@description('Number of chunks Send-DemoBootstrapBundle delivered to each VM; required with bootstrapBundleSha256.')
param bootstrapChunkCount int

@description('SHA-256 of the workload runner zip; empty leaves the WorkloadRunner steps Not selected (ADR 0010).')
param workloadRunnerSha256 string

@description('Number of chunks Send-DemoWorkloadRunner delivered to each VM; required with workloadRunnerSha256.')
param workloadRunnerChunkCount int

@description('Activity profile that deploy.ps1 and start-demo.ps1 set (ADR 0010).')
param activityProfile string

@description('Whether the VMs also set activityProfile at every boot (ADR 0016, R183).')
param activityProfileOnBoot bool

@description('Object ID of the P6 Entra group, the T3 administrator (ADR 0008).')
param t3AdminGroupObjectId string

@description('Display name recorded as the T3 administrator login.')
param t3AdminGroupDisplayName string

@description('T3 auto-pause delay in minutes, -1 for none, or 0 for the profile\'s value (ADR 0016, C7).')
param t3AutoPauseMinutes int

@description('T3 uses the Azure SQL Database free offer (ADR 0016, C7).')
param t3UseFreeLimit bool

@description('Deploy T4, the Azure Database for PostgreSQL flexible server pgflex01-<deploymentId> (Phase 24, ADR 0019). Its administrator is the same P6 group as T3.')
param t4Enabled bool = true

@description('T4\'s compute size: Standard_B1ms (default), Standard_B2s (the documented fallback), or Standard_D2ds_v5 (the documented General Purpose option); the tier follows the size (Phase 24, ADR 0019).')
@allowed([
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_D2ds_v5'
])
param t4SkuName string = 'Standard_B1ms'

@description('T4\'s availability zone at creation: empty for no preference, or 1, 2, or 3.')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param t4AvailabilityZone string = ''

@description('Current storage types of existing disks that drifted from the profile, keyed by disk name; the VMs keep them (Phase 24).')
param diskSkuOverrides object = {}

// Single sources: profile sizing and disk tiers (config/profiles.json) and images (config/versions.json).
var catalogProfile = loadJsonContent('../../config/profiles.json', '$.profiles')[profile]
var diskTiers = loadJsonContent('../../config/profiles.json', '$.diskTiers')
var vmImages = loadJsonContent('../../config/versions.json', '$.vmImages')
var postgres = loadJsonContent('../../config/versions.json', '$.postgresql')

// Data disk tiers (ADR 0016). Keep in step with Resolve-DemoDataDiskTier in the DbHubDemo module, which the
// cost estimate and preflight use. An explicit dataDiskSku wins (P10 is only ever an explicit opt-in, and
// None removes the data disk); otherwise Premium SSD v2 applies only with a zone, because it needs a zonal
// VM (C10). The lowest-cost profile's regional tier is None: the VMs get no data disk (2026-10-20).
var t1DataDiskTier = dataDiskSku != 'Auto'
  ? dataDiskSku
  : (!empty(zone) && contains(catalogProfile.t1, 'zonalDataDisk') ? catalogProfile.t1.zonalDataDisk : catalogProfile.t1.dataDisk)
var hostDataDiskTier = dataDiskSku != 'Auto'
  ? dataDiskSku
  : (!empty(zone) && contains(catalogProfile.t2Host, 'zonalDataDisk') ? catalogProfile.t2Host.zonalDataDisk : catalogProfile.t2Host.dataDisk)

// Hybrid Benefit applies only with the entitlement attestation (ADR 0006); deploy.ps1 fails closed earlier.
var windowsLicenseType = windowsHybridBenefit && hybridBenefitAttested ? 'Windows_Server' : ''
var sqlLicenseType = sqlHybridBenefit && hybridBenefitAttested ? 'AHUB' : 'PAYG'

// The nested T2 (default) or the opt-in evaluation-only Azure VM (ADR 0006).
var isNestedT2 = t2Mode != 'EvaluationOnlyAzureVm'

// T4's names are computed rather than read from its module, so T1's settings (and its bootstrap) never wait for
// the PostgreSQL server to be created. Inside the VNet the public name resolves through the linked private zone.
var t4ServerName = '${postgres.serverNamePrefix}-${deploymentId}'
var t4ServerFqdn = '${t4ServerName}.postgres.database.azure.com'

// The workload runner (ADR 0010, Phase 13): a new runner SHA-256 changes the settings, which re-runs the loader,
// and the WorkloadRunner steps install it. The auto-shutdown schedule bounds the activity profiles (--not-after).
var workloadSettings = {
  runnerSha256: toLower(workloadRunnerSha256)
  runnerChunkCount: workloadRunnerChunkCount
  activityProfile: activityProfile
  profileOnBoot: activityProfileOnBoot
  autoShutdownTime: autoShutdownTime
  autoShutdownTimeZone: autoShutdownTimeZone
}

var commonSettings = {
  schemaVersion: 1
  prefix: prefix
  environment: environment
  deploymentId: deploymentId
  location: location
  resourceGroup: resourceGroup().name
  profile: profile
  seedScale: catalogProfile.database.seedScale
  workload: workloadSettings
}

module network 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    prefix: prefix
    environment: environment
    networkMode: networkMode
    outboundMode: outboundMode
    tags: tags
  }
}

module budget 'budget.bicep' = {
  name: 'budget'
  params: {
    name: 'budget-${prefix}-${environment}'
    amount: monthlyCeilingUsd
    startDate: budgetStartDate
    contactEmails: [
      ownerEmail
    ]
  }
}

module sqlvm01 'sqlvm01.bicep' = {
  name: 'sqlvm01'
  params: {
    location: location
    tags: tags
    vmSize: empty(t1VmSize) ? catalogProfile.t1.size : t1VmSize
    subnetId: network.outputs.subnetIds[0]
    imageReference: vmImages.t1
    zone: zone
    priority: t1Priority
    securityType: t1SecurityType
    osDisk: diskTiers[catalogProfile.t1.osDisk]
    dataDisk: diskTiers[t1DataDiskTier]
    diskSkuOverrides: diskSkuOverrides
    adminUsername: adminUsername
    adminPassword: adminPassword
    includeOsProfile: !contains(existingVmNames, 'sqlvm01')
    licenseType: windowsLicenseType
    sqlLicenseType: sqlLicenseType
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
  }
}

module archost01 'archost01.bicep' = if (isNestedT2) {
  name: 'archost01'
  params: {
    location: location
    tags: tags
    vmSize: empty(hostVmSize) ? catalogProfile.t2Host.size : hostVmSize
    subnetId: network.outputs.subnetIds[1]
    imageReference: vmImages.t2Host
    zone: zone
    priority: hostPriority
    securityType: hostSecurityType
    osDisk: diskTiers[catalogProfile.t2Host.osDisk]
    dataDisk: diskTiers[hostDataDiskTier]
    diskSkuOverrides: diskSkuOverrides
    adminUsername: adminUsername
    adminPassword: adminPassword
    includeOsProfile: !contains(existingVmNames, 'archost01')
    licenseType: windowsLicenseType
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    assignArcOnboardingRole: assignArcOnboardingRole
    arcOnboardIdentityName: 'id-${prefix}-${environment}-arc-onboard'
    osDiskSourceResourceId: t2OsDiskSourceId
    attachExistingOsDisk: t2AttachExistingOsDisk
  }
}

module arcsql01Eval 'arcsql01-eval.bicep' = if (!isNestedT2) {
  name: 'arcsql01-eval'
  params: {
    location: location
    tags: tags
    vmSize: empty(hostVmSize) ? catalogProfile.t2Host.size : hostVmSize
    subnetId: network.outputs.subnetIds[1]
    imageReference: vmImages.t2Host
    zone: zone
    priority: hostPriority
    securityType: hostSecurityType
    osDisk: diskTiers[catalogProfile.t2Host.osDisk]
    dataDisk: diskTiers.None
    diskSkuOverrides: diskSkuOverrides
    adminUsername: adminUsername
    adminPassword: adminPassword
    includeOsProfile: !contains(existingVmNames, 'arcsql01')
    licenseType: windowsLicenseType
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
  }
}

// The loader Run Commands are deployed only after Send-DemoBootstrapBundle has delivered the bundle in Run
// Command chunks: deploy.ps1 deploys the VMs, sends the chunks, then deploys again with the bundle's SHA-256
// and chunk count. The Deploy to Azure button leaves the SHA-256 empty and provisions infrastructure only.
// deploy.ps1's parallel tracks run the same loaders themselves from the loaderSettings output (ADR 0018).
module bootstrap 'bootstrap.bicep' = if (!empty(bootstrapBundleSha256)) {
  name: 'bootstrap'
  params: {
    location: location
    tags: tags
    bundleSha256: bootstrapBundleSha256
    chunkCount: bootstrapChunkCount
    // Module outputs make the bootstraps wait for both VM modules, including T1's SQL IaaS Agent registration.
    sqlVmName: sqlvm01.outputs.vmName
    hostVmName: isNestedT2 ? archost01!.outputs.vmName : arcsql01Eval!.outputs.vmName
    hostRole: isNestedT2 ? 'ArcHost' : 'EvalArcVm'
    sqlVmSettings: sqlVmLoaderSettings
    hostSettings: hostLoaderSettings
  }
}

// The loaders' settings; nothing here is secret. T1 drives T3 and T4 with its managed identity, so it gets their
// names (stable across stop-demo.ps1 -RemoveT3 and across T4 stops). T4's runner role is the PostgreSQL role
// mapped to T1's identity that Enable-DemoT4Workload creates (ADR 0019).
var sqlVmLoaderSettings = union(commonSettings, {
  role: 'SqlVm'
  dataDiskTier: t1DataDiskTier
  t3: {
    serverName: azuresql01.outputs.serverName
    serverFqdn: azuresql01.outputs.serverFqdn
    databaseName: azuresql01.outputs.databaseName
  }
}, t4Enabled ? {
  t4: {
    serverName: t4ServerName
    serverFqdn: t4ServerFqdn
    databaseName: postgres.databaseName
    runnerRole: postgres.runnerRole
  }
} : {})
var hostLoaderSettings = union(commonSettings, {
  role: isNestedT2 ? 'ArcHost' : 'EvalArcVm'
  dataDiskTier: isNestedT2 ? hostDataDiskTier : 'None'
  t2Mode: t2Mode
  t2SqlInstallMode: t2SqlInstallMode
  guest: {
    name: 'arcsql01'
    vcpus: catalogProfile.t2Guest.vcpus
    memoryGiB: catalogProfile.t2Guest.memoryGiB
    vhdxGB: catalogProfile.t2Guest.vhdxGB
  }
})

// T3 (Phase 8): stable names, so a T3 removed with stop-demo.ps1 -RemoveT3 comes back under the same names.
module azuresql01 'azuresql01.bicep' = {
  name: 'azuresql01'
  params: {
    location: location
    tags: tags
    serverName: 'azuresql01-${deploymentId}'
    databaseName: 'ContosoCare'
    networkMode: networkMode
    adminGroupObjectId: t3AdminGroupObjectId
    adminGroupDisplayName: t3AdminGroupDisplayName
    sizing: catalogProfile.t3
    autoPauseMinutes: t3AutoPauseMinutes == 0 ? catalogProfile.t3.autoPauseMinutes : t3AutoPauseMinutes
    useFreeLimit: t3UseFreeLimit
    sqlvmSubnetId: network.outputs.subnetIds[0]
    privateEndpointSubnetId: network.outputs.subnetIds[2]
    virtualNetworkId: network.outputs.virtualNetworkId
    privateEndpointName: 'pe-${prefix}-${environment}-azuresql01'
  }
}

// T4 (Phase 24, ADR 0019): stable names, virtual network integration in snet-pg in both network modes (no public
// endpoint), and the P6 group as its Entra administrator.
module pgflex01 'pgflex01.bicep' = if (t4Enabled) {
  name: 'pgflex01'
  params: {
    location: location
    tags: tags
    serverName: t4ServerName
    databaseName: postgres.databaseName
    postgresVersion: postgres.majorVersion
    // The tier follows the size (Phase 24): Standard_B sizes are Burstable, the documented D2ds_v5 option is
    // General Purpose (https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-compute).
    sizing: union(catalogProfile.t4, {
      skuName: t4SkuName
      tier: startsWith(t4SkuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
    })
    availabilityZone: t4AvailabilityZone
    delegatedSubnetId: network.outputs.postgresSubnetId
    virtualNetworkId: network.outputs.virtualNetworkId
    privateDnsZoneName: '${prefix}-${environment}.private.postgres.database.azure.com'
    adminGroupObjectId: t3AdminGroupObjectId
    adminGroupDisplayName: t3AdminGroupDisplayName
  }
}

resource lock 'Microsoft.Authorization/locks@2020-05-01' = if (enableLocks) {
  name: 'lock-${prefix}-${environment}'
  properties: {
    level: 'CanNotDelete'
    notes: 'Optional demo lock. Remove it before destroy; Contributor cannot delete locks.'
  }
}

@description('Resource ID of the virtual network.')
output virtualNetworkId string = network.outputs.virtualNetworkId

@description('Resource ID of T1.')
output t1VmId string = sqlvm01.outputs.vmId

@description('Object ID of the T1 system-assigned identity.')
output t1PrincipalId string = sqlvm01.outputs.principalId

@description('Resource ID of the T2 host; empty in the evaluation-only mode.')
output hostVmId string = isNestedT2 ? archost01!.outputs.vmId : ''

@description('Resource ID of the evaluation-only VM arcsql01; empty in the default nested mode.')
output evaluationVmId string = isNestedT2 ? '' : arcsql01Eval!.outputs.vmId

@description('Data disk tier used by T1 and the T2 host (PremiumV2 only with a zone).')
output dataDiskTiers object = {
  t1: t1DataDiskTier
  t2Host: hostDataDiskTier
}

@description('Name of the T3 logical server.')
output t3ServerName string = azuresql01.outputs.serverName

@description('Fully qualified domain name of the T3 logical server.')
output t3ServerFqdn string = azuresql01.outputs.serverFqdn

@description('Name of the T3 database.')
output t3DatabaseName string = azuresql01.outputs.databaseName

@description('Resource ID of the T3 logical server.')
output t3ServerId string = azuresql01.outputs.serverId

@description('Resource ID of the T3 database.')
output t3DatabaseId string = azuresql01.outputs.databaseId

@description('Resource ID of the T3 private endpoint, or empty in public mode.')
output t3PrivateEndpointId string = azuresql01.outputs.privateEndpointId

@description('Name of the T4 server (pgflex01-<deploymentId>), or empty when T4 is off.')
output t4ServerName string = t4Enabled ? pgflex01!.outputs.serverName : ''

@description('Fully qualified domain name of the T4 server, or empty when T4 is off.')
output t4ServerFqdn string = t4Enabled ? pgflex01!.outputs.serverFqdn : ''

@description('Resource ID of the T4 server, or empty when T4 is off.')
output t4ServerId string = t4Enabled ? pgflex01!.outputs.serverId : ''

@description('Name of the T4 database, or empty when T4 is off.')
output t4DatabaseName string = t4Enabled ? pgflex01!.outputs.databaseName : ''

@description('The bootstrap loaders\' settings (nothing secret), for the loaders deploy.ps1 runs itself (ADR 0018); deploy.ps1 fills in the workload runner fields.')
output loaderSettings object = {
  sqlVm: sqlVmLoaderSettings
  host: hostLoaderSettings
}
