targetScope = 'subscription'

metadata name = 'Fabric Database Hub hybrid SQL demo'
metadata description = 'Subscription-scope entry point (ADR 0001, ADR 0002). Creates the demo resource group and deploys the demo into it.'

@description('Azure region for every resource. Defaults to the deployment location.')
param location string = deployment().location

@description('Short lowercase prefix for resource names.')
@minLength(3)
@maxLength(8)
param prefix string = 'dbhub'

@description('Environment name, for example demo.')
@minLength(2)
@maxLength(8)
param environment string = 'demo'

@description('Six lowercase characters that make globally unique names unique. Deterministic per subscription, prefix, and environment (ADR 0002).')
@minLength(6)
@maxLength(6)
param deploymentId string = take(uniqueString(subscription().id, prefix, environment), 6)

@description('public: T3 is reachable through a VNet rule. private: T3 uses a private endpoint (ADR 0007). Scripts resolve the configuration value auto to one of these from Azure Policy before they deploy.')
@allowed([
  'public'
  'private'
])
param networkMode string = 'public'

@description('Outbound internet path for the VM subnets (ADR 0017). NatGateway adds a NAT gateway and its public IP at extra cost.')
@allowed([
  'DefaultOutboundAccess'
  'NatGateway'
])
param outboundMode string = 'DefaultOutboundAccess'

@description('Value of the owner tag.')
@minLength(1)
@maxLength(64)
param owner string

@description('Recipient of budget alerts.')
@minLength(3)
param ownerEmail string

@description('Value of the costCenter tag.')
@maxLength(64)
param costCenter string = 'demo'

@description('Daily auto-shutdown time (HHmm, 24-hour) for T1 and the T2 host.')
@minLength(4)
@maxLength(4)
param autoShutdownTime string = '1900'

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string = 'Pacific Standard Time'

@description('Optional expiry date (yyyy-MM-dd) used by the expiry workflow. Empty for none.')
@maxLength(10)
param expiresOn string = ''

@description('Monthly budget amount in USD: the hard monthly ceiling (ADR 0016, C2).')
@minValue(1)
param monthlyCeilingUsd int = 250

@description('First day of the budget period (yyyy-MM-01). deploy.ps1 passes the existing value on re-runs.')
@minLength(10)
@maxLength(10)
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Tags already on the resource group. deploy.ps1 passes them so a re-run keeps them (ADR 0002).')
param existingResourceGroupTags object = {}

@description('Add a CanNotDelete lock to the resource group. Off by default; destroy refuses to run against a locked deployment.')
param enableLocks bool = false

@description('Cost and performance profile in config/profiles.json; sets the VM sizes, disks, guest sizing, and seed scale (ADR 0016).')
@allowed([
  'lowest-cost'
  'demo-day'
  'enhanced-performance'
])
param profile string = 'lowest-cost'

@description('Availability zone for T1 and the T2 host, or empty for regional VMs. With a zone and dataDiskSku Auto, demo-day and enhanced-performance data disks use Premium SSD v2 (ADR 0016, C10).')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param zone string = ''

@description('Data disk tier for T1 and the T2 host (ADR 0016). Auto: the profile decides (lowest-cost has no separate data disks; demo-day and enhanced-performance use Premium SSD v2 with a zone, otherwise their regional tier). None: no data disks; the OS disks hold SQL Server data on T1 and the guest VHDX and media on the T2 host. E10, P10, or PremiumV2 force that tier; P10 is an explicit opt-in that can exceed the monthly ceiling, and PremiumV2 needs a zone.')
@allowed([
  'Auto'
  'None'
  'E10'
  'P10'
  'PremiumV2'
])
param dataDiskSku string = 'Auto'

@description('Regular or Spot for T1. Spot evicts with Deallocate (ADR 0016, C5).')
@allowed([
  'Regular'
  'Spot'
])
param t1Priority string = 'Regular'

@description('Regular or Spot for the T2 host. Spot evicts with Deallocate (ADR 0016, C5).')
@allowed([
  'Regular'
  'Spot'
])
param hostPriority string = 'Regular'

@description('Security type of T1. deploy.ps1 resolves securityType.t1 = Auto to TrustedLaunch when the image advertises it (ADR 0003).')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param t1SecurityType string = 'Standard'

@description('Security type of the T2 host. Standard by default: Trusted Launch is reported as incompatible with nested virtualization (ADR 0003).')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param hostSecurityType string = 'Standard'

@description('Override the profile\'s T1 size. Empty uses the profile.')
param t1VmSize string = ''

@description('Override the profile\'s T2 host size; it must be a nested-virtualization family. Empty uses the profile.')
param hostVmSize string = ''

@description('Apply Windows Server Azure Hybrid Benefit to T1 and the T2 host. Takes effect only with hybridBenefitAttested (ADR 0006, C6).')
param windowsHybridBenefit bool = false

@description('Apply SQL Server Azure Hybrid Benefit (AHUB) to T1. Takes effect only with hybridBenefitAttested (ADR 0006, C6).')
param sqlHybridBenefit bool = false

@description('I attest that I hold the licenses that Azure Hybrid Benefit requires (ADR 0006, C6).')
param hybridBenefitAttested bool = false

@description('How SQL Server is installed in the T2 guest (ADR 0006).')
@allowed([
  'PaygWizard'
  'ProductKey'
  'Developer'
])
param t2SqlInstallMode string = 'PaygWizard'

@description('Nested: T2 is the nested Hyper-V guest arcsql01 on archost01 (default). EvaluationOnlyAzureVm: the opt-in fallback when the nested preflight fails; arcsql01 is an Azure VM onboarded to Arc with Microsoft\'s evaluation procedure, labeled evaluation only everywhere (ADR 0006).')
@allowed([
  'Nested'
  'EvaluationOnlyAzureVm'
])
param t2Mode string = 'Nested'

@description('Create the optional least-privilege identity id-<prefix>-<env>-arc-onboard with Azure Connected Machine Onboarding on the resource group, attached to archost01 (ADR 0005). Needs Microsoft.Authorization/roleAssignments/write; deploy.ps1 sets it from assignRoles (ADR 0008). Nested mode only.')
param assignArcOnboardingRole bool = false

@description('T2 golden restore (ADR 0018): resource ID of the golden snapshot that a new archost01\'s OS disk is copied from, in rg-<prefix>-golden. deploy.ps1 sets it when t2Source resolves to golden; empty builds the host from the image.')
param t2OsDiskSourceId string = ''

@description('T2 golden restore of an archost01 that already exists: attach its OS disk by ID instead of declaring it again (ADR 0018). deploy.ps1 sets it for a host attached from a golden disk.')
param t2AttachExistingOsDisk bool = false

@description('Local administrator name for T1 and the T2 host.')
@minLength(1)
@maxLength(20)
param adminUsername string = 'dbhubadmin'

@description('Local administrator password, used only when a VM is created; required then. deploy.ps1 generates it and never stores it (ADR 0009).')
@secure()
param adminPassword string = ''

@description('VMs that already exist. Their osProfile is left out, because it cannot change after creation (ADR 0001).')
param existingVmNames string[] = []

@description('SHA-256 of the bootstrap bundle zip, passed by deploy.ps1 after Send-DemoBootstrapBundle has delivered the bundle to both VMs in Run Command chunks. Empty skips the bootstrap Run Commands, as on the Deploy to Azure button path (ADR 0003).')
@maxLength(64)
param bootstrapBundleSha256 string = ''

@description('Number of chunks Send-DemoBootstrapBundle delivered to each VM; required with bootstrapBundleSha256.')
@minValue(0)
@maxValue(999)
param bootstrapChunkCount int = 0

@description('SHA-256 of the workload runner zip, passed by deploy.ps1 after Send-DemoWorkloadRunner has delivered it to both VMs in Run Command chunks. It reaches the bootstraps in their settings, and their WorkloadRunner steps install it; empty leaves those steps Not selected (ADR 0010).')
@maxLength(64)
param workloadRunnerSha256 string = ''

@description('Number of chunks Send-DemoWorkloadRunner delivered to each VM; required with workloadRunnerSha256.')
@minValue(0)
@maxValue(999)
param workloadRunnerChunkCount int = 0

@description('Activity profile that deploy.ps1 and start-demo.ps1 set until the next auto-shutdown: off, baseline, business-day, or incident:<scenario> (ADR 0010). While T3 has an active profile, the runner keeps its serverless database awake (ADR 0016).')
@minLength(3)
@maxLength(57)
param activityProfile string = 'baseline'

@description('Whether the VMs also set activityProfile at every boot. False (default): a VM that starts serves only the profile someone set, so T3 can auto-pause (ADR 0016, R183).')
param activityProfileOnBoot bool = false

@description('Object ID of the Entra security group that administers T3 (prerequisite P6). It becomes the Entra-only administrator of the logical server (ADR 0008).')
@minLength(36)
@maxLength(36)
param t3AdminGroupObjectId string

@description('Name recorded as the T3 administrator login. deploy.ps1 passes the P6 group\'s display name.')
@minLength(1)
@maxLength(128)
param t3AdminGroupDisplayName string = 'T3 SQL administrators (P6)'

@description('T3 serverless auto-pause delay in minutes (15 to 10080), or -1 to keep the database online. 0 uses the profile\'s value. deploy.ps1 passes t3AutoPauseMinutes from the configuration (ADR 0016, C7).')
@minValue(-1)
@maxValue(10080)
param t3AutoPauseMinutes int = 0

@description('T3 uses the Azure SQL Database free offer with "continue using database for additional charges" (ADR 0016, C7). Preflight decides; deploy.ps1 redeploys T3 without it if Azure rejects the offer.')
param t3UseFreeLimit bool = true

@description('Deploy T4, the Azure Database for PostgreSQL flexible server pgflex01-<deploymentId>: Burstable Standard_B1ms, Entra-only with the P6 group as administrator, virtual network integration in snet-pg (Phase 24, ADR 0019).')
param t4Enabled bool = true

@description('T4\'s compute size: Standard_B1ms, the smallest Burstable size (default); Standard_B2s, the documented fallback when Azure answers SkuNotAvailable for B1ms in the region; or Standard_D2ds_v5, the documented General Purpose option (2 vCores, 8 GiB) the owner chose on 2026-10-26 after both were refused. The tier follows the size (Phase 24, ADR 0019). deploy.ps1 never changes it on its own.')
@allowed([
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_D2ds_v5'
])
param t4SkuName string = 'Standard_B1ms'

@description('T4\'s availability zone when it is created: empty for no preference, or 1, 2, or 3. A server keeps its zone, so deploy.ps1 passes it only while T4 doesn\'t exist (Phase 24, ADR 0019).')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param t4AvailabilityZone string = ''

@description('Current storage types of existing disks that differ from the profile, keyed by disk name (for example sqlvm01-osdisk). The subscription\'s automation can switch a deallocated VM\'s disks to Standard HDD, and Azure doesn\'t change an OS disk\'s type through its VM, so deploy.ps1 passes each drifted disk\'s current type and the template keeps it (Phase 24).')
param diskSkuOverrides object = {}

var resourceGroupName = 'rg-${prefix}-${environment}'

var commonTags = {
  solution: 'fabric-database-hub-demo'
  environment: environment
  owner: owner
  purpose: 'customer-demo'
  costCenter: costCenter
  autoShutdown: '${autoShutdownTime} ${autoShutdownTimeZone}'
  deploymentId: deploymentId
}

var expiryTag = empty(expiresOn) ? {} : { expiresOn: expiresOn }

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: union(existingResourceGroupTags, commonTags, expiryTag, { ArcSQLServerExtensionDeployment: 'PAYG' })
}

module demo 'modules/demo.bicep' = {
  name: 'demo-${deploymentId}'
  scope: resourceGroup
  params: {
    location: location
    prefix: prefix
    environment: environment
    deploymentId: deploymentId
    networkMode: networkMode
    outboundMode: outboundMode
    tags: commonTags
    ownerEmail: ownerEmail
    monthlyCeilingUsd: monthlyCeilingUsd
    budgetStartDate: budgetStartDate
    enableLocks: enableLocks
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    profile: profile
    zone: zone
    dataDiskSku: dataDiskSku
    t1Priority: t1Priority
    hostPriority: hostPriority
    t1SecurityType: t1SecurityType
    hostSecurityType: hostSecurityType
    t1VmSize: t1VmSize
    hostVmSize: hostVmSize
    windowsHybridBenefit: windowsHybridBenefit
    sqlHybridBenefit: sqlHybridBenefit
    hybridBenefitAttested: hybridBenefitAttested
    t2SqlInstallMode: t2SqlInstallMode
    t2Mode: t2Mode
    assignArcOnboardingRole: assignArcOnboardingRole && t2Mode == 'Nested'
    t2OsDiskSourceId: t2Mode == 'Nested' ? t2OsDiskSourceId : ''
    t2AttachExistingOsDisk: t2Mode == 'Nested' && t2AttachExistingOsDisk
    adminUsername: adminUsername
    adminPassword: adminPassword
    existingVmNames: existingVmNames
    bootstrapBundleSha256: bootstrapBundleSha256
    bootstrapChunkCount: bootstrapChunkCount
    workloadRunnerSha256: workloadRunnerSha256
    workloadRunnerChunkCount: workloadRunnerChunkCount
    activityProfile: activityProfile
    activityProfileOnBoot: activityProfileOnBoot
    t3AdminGroupObjectId: t3AdminGroupObjectId
    t3AdminGroupDisplayName: t3AdminGroupDisplayName
    t3AutoPauseMinutes: t3AutoPauseMinutes
    t3UseFreeLimit: t3UseFreeLimit
    t4Enabled: t4Enabled
    t4SkuName: t4SkuName
    t4AvailabilityZone: t4AvailabilityZone
    diskSkuOverrides: diskSkuOverrides
  }
}

@description('Name of the demo resource group.')
output resourceGroupName string = resourceGroup.name

@description('Suffix used in globally unique names.')
output deploymentId string = deploymentId

@description('Resource ID of the virtual network.')
output virtualNetworkId string = demo.outputs.virtualNetworkId

@description('Resource ID of T1 (sqlvm01).')
output t1VmId string = demo.outputs.t1VmId

@description('Object ID of the T1 system-assigned identity.')
output t1PrincipalId string = demo.outputs.t1PrincipalId

@description('Resource ID of the T2 host (archost01); empty in the evaluation-only mode.')
output hostVmId string = demo.outputs.hostVmId

@description('Resource ID of the evaluation-only VM arcsql01; empty in the default nested mode (ADR 0006).')
output evaluationVmId string = demo.outputs.evaluationVmId

@description('Data disk tiers in use: PremiumV2 only when a zone is set.')
output dataDiskTiers object = demo.outputs.dataDiskTiers

@description('Name of the T3 logical server (azuresql01-<deploymentId>).')
output t3ServerName string = demo.outputs.t3ServerName

@description('Fully qualified domain name of the T3 logical server.')
output t3ServerFqdn string = demo.outputs.t3ServerFqdn

@description('Name of the T3 database.')
output t3DatabaseName string = demo.outputs.t3DatabaseName

@description('Resource ID of the T3 logical server.')
output t3ServerId string = demo.outputs.t3ServerId

@description('Resource ID of the T3 database.')
output t3DatabaseId string = demo.outputs.t3DatabaseId

@description('Resource ID of the T3 private endpoint, or empty in public mode.')
output t3PrivateEndpointId string = demo.outputs.t3PrivateEndpointId

@description('Name of the T4 server (pgflex01-<deploymentId>), or empty when T4 is off.')
output t4ServerName string = demo.outputs.t4ServerName

@description('Fully qualified domain name of the T4 server, or empty when T4 is off.')
output t4ServerFqdn string = demo.outputs.t4ServerFqdn

@description('Resource ID of the T4 server, or empty when T4 is off.')
output t4ServerId string = demo.outputs.t4ServerId

@description('Name of the T4 database, or empty when T4 is off.')
output t4DatabaseName string = demo.outputs.t4DatabaseName

@description('The bootstrap loaders\' settings (nothing secret), for the loaders deploy.ps1 runs itself (ADR 0018).')
output loaderSettings object = demo.outputs.loaderSettings
