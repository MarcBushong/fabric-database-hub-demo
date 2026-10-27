metadata description = 'EVALUATION ONLY (t2Mode EvaluationOnlyAzureVm, ADR 0006): arcsql01 as an Azure VM from the plain Windows Server 2022 image, with no SQL IaaS Agent registration and no data disk, which the EvalArcVm bootstrap installs SQL Server on and prepares for Azure Arc with Microsoft\'s evaluation procedure. Deployed only when the operator opts in after the nested-virtualization preflight fails.'

@description('Azure region.')
param location string

@description('Tags for every resource. evaluationOnly: true is added.')
param tags object

@description('VM size: the profile\'s T2 host size, so quota, preflight, and the cost estimate stay the same.')
param vmSize string

@description('Resource ID of snet-archost, the T2 subnet.')
param subnetId string

@description('Marketplace image (config/versions.json vmImages.t2Host): Windows Server 2022 Datacenter Gen2, without SQL Server.')
param imageReference object

@description('Availability zone, or empty for a regional VM.')
param zone string

@description('Regular or Spot (ADR 0016, C5).')
param priority string

@description('Standard or TrustedLaunch (securityType.t2Host).')
param securityType string

@description('OS disk tier: sku and sizeGiB. SQL Server data stays on the OS disk.')
param osDisk object

@description('The None disk tier: no data disk.')
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

@description('Daily auto-shutdown time (HHmm).')
param autoShutdownTime string

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string

module vm 'windows-vm.bicep' = {
  name: 'arcsql01-eval-vm'
  params: {
    location: location
    vmName: 'arcsql01'
    tags: union(tags, {
      evaluationOnly: 'true'
    })
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
  }
}

@description('Resource ID of the evaluation-only VM arcsql01.')
output vmId string = vm.outputs.vmId

@description('Name of the evaluation-only VM.')
output vmName string = vm.outputs.vmName
