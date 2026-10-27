metadata description = 'T2 host archost01: Windows Server 2022 Datacenter Gen2 Hyper-V host for the nested guest arcsql01. No Arc agent and no SQL IaaS extension on the host (ADR 0003).'

@description('Azure region.')
param location string

@description('Tags for every resource.')
param tags object

@description('VM size from the profile; must be a nested-virtualization family (ADR 0003).')
param vmSize string

@description('Resource ID of snet-archost.')
param subnetId string

@description('Marketplace image (config/versions.json vmImages.t2Host).')
param imageReference object

@description('Availability zone, or empty for a regional VM.')
param zone string

@description('Regular or Spot (ADR 0016, C5).')
param priority string

@description('Standard by default: Trusted Launch is reported as incompatible with nested virtualization (ADR 0003).')
param securityType string

@description('OS disk tier: sku and sizeGiB.')
param osDisk object

@description('Data disk tier for the media and the guest VHDX: sku, sizeGiB, caching, and for Premium SSD v2 iops and mbps.')
param dataDisk object

@description('Current storage types of existing disks that drifted from the profile, keyed by disk name; the VM keeps them (Phase 24).')
param diskSkuOverrides object = {}

@description('Local administrator name.')
param adminUsername string

@description('Local administrator password, used only when the VM is created (ADR 0009).')
@secure()
param adminPassword string

@description('False when the VM already exists (ADR 0001).')
param includeOsProfile bool

@description('Windows_Server for attested Azure Hybrid Benefit; empty for none (ADR 0006).')
param licenseType string

@description('Daily auto-shutdown time (HHmm). The guest shuts down cleanly through its automatic stop action.')
param autoShutdownTime string

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string

@description('Create the optional least-privilege Arc onboarding identity, give it Azure Connected Machine Onboarding on the resource group, and attach it to the host (ADR 0005). Needs Microsoft.Authorization/roleAssignments/write (ADR 0008).')
param assignArcOnboardingRole bool = false

@description('Name of the optional onboarding identity, id-<prefix>-<env>-arc-onboard.')
param arcOnboardIdentityName string = ''

@description('Golden restore (ADR 0018): the snapshot the new host\'s OS disk is copied from. Empty builds the host from the image.')
param osDiskSourceResourceId string = ''

@description('Golden restore of a host that already exists: attach its OS disk by ID (ADR 0018).')
param attachExistingOsDisk bool = false

// Azure Connected Machine Onboarding: read and write Arc machines and add extensions; it can't delete
// machines or manage extensions (https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/management-and-governance#azure-connected-machine-onboarding).
var connectedMachineOnboardingRoleId = 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'

// The host requests a token for this identity from IMDS with its client ID (configure-arc.ps1
// -UseHostIdentity), so no token leaves the operator's machine. The guest can't reach IMDS (ADR 0004).
resource arcOnboardIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (assignArcOnboardingRole) {
  name: arcOnboardIdentityName
  location: location
  tags: tags
}

resource arcOnboardRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignArcOnboardingRole) {
  name: guid(resourceGroup().id, arcOnboardIdentityName, connectedMachineOnboardingRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', connectedMachineOnboardingRoleId)
    principalId: arcOnboardIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Arc onboarding of arcsql01 from archost01 (ADR 0005).'
  }
}

module vm 'windows-vm.bicep' = {
  name: 'archost01-vm'
  params: {
    location: location
    vmName: 'archost01'
    tags: tags
    vmSize: vmSize
    subnetId: subnetId
    imageReference: imageReference
    zone: zone
    priority: priority
    securityType: securityType
    osDiskSku: osDisk.sku
    osDiskSizeGiB: osDisk.sizeGiB
    dataDisk: dataDisk
    diskSkuOverrides: diskSkuOverrides
    adminUsername: adminUsername
    adminPassword: adminPassword
    includeOsProfile: includeOsProfile
    licenseType: licenseType
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    userAssignedIdentityIds: assignArcOnboardingRole ? [arcOnboardIdentity.id] : []
    osDiskSourceResourceId: osDiskSourceResourceId
    attachExistingOsDisk: attachExistingOsDisk
  }
}

@description('Resource ID of the T2 host VM.')
output vmId string = vm.outputs.vmId

@description('Name of the T2 host VM.')
output vmName string = vm.outputs.vmName

@description('Object ID of the host system-assigned identity. It is never reachable from the guest (ADR 0004).')
output principalId string = vm.outputs.principalId

@description('Client ID of the optional onboarding identity; empty when assignArcOnboardingRole is false.')
output arcOnboardClientId string = assignArcOnboardingRole ? arcOnboardIdentity!.properties.clientId : ''
