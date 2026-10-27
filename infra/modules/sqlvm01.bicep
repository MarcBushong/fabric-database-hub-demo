metadata description = 'T1 sqlvm01: SQL Server 2022 Standard on an Azure VM, registered with the SQL IaaS Agent extension, never Arc-enabled (ADR 0006, ADR 0007).'

@description('Azure region.')
param location string

@description('Tags for every resource.')
param tags object

@description('VM size from the profile (ADR 0016).')
param vmSize string

@description('Resource ID of snet-sqlvm.')
param subnetId string

@description('Marketplace image (config/versions.json vmImages.t1).')
param imageReference object

@description('Availability zone, or empty for a regional VM.')
param zone string

@description('Regular or Spot (ADR 0016, C5).')
param priority string

@description('Standard or TrustedLaunch; deploy.ps1 resolves Auto from the image features (ADR 0003).')
param securityType string

@description('OS disk tier: sku and sizeGiB.')
param osDisk object

@description('Data disk tier: sku, sizeGiB, caching, and for Premium SSD v2 iops and mbps.')
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

@description('PAYG, or AHUB for attested SQL Server Azure Hybrid Benefit (ADR 0006).')
@allowed([
  'PAYG'
  'AHUB'
])
param sqlLicenseType string

@description('Daily auto-shutdown time (HHmm).')
param autoShutdownTime string

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string

var vmName = 'sqlvm01'

module vm 'windows-vm.bicep' = {
  name: '${vmName}-vm'
  params: {
    location: location
    vmName: vmName
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
  }
}

// SQL IaaS Agent extension registration. Connectivity is LOCAL: the runner and DBA tools run on T1 itself
// (ADR 0007). Automated storage configuration isn't used: it's documented for Premium SSD only, and the
// T1 bootstrap formats the data disk the same way for every profile (ADR 0003, Phase 6 notes).
resource sqlVirtualMachine 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    virtualMachineResourceId: vm.outputs.vmId
    sqlServerLicenseType: sqlLicenseType
    enableAutomaticUpgrade: true
    serverConfigurationsManagementSettings: {
      sqlConnectivityUpdateSettings: {
        connectivityType: 'LOCAL'
        port: 1433
      }
    }
  }
}

@description('Resource ID of the T1 VM.')
output vmId string = vm.outputs.vmId

@description('Name of the T1 VM.')
output vmName string = vm.outputs.vmName

@description('Object ID of the T1 system-assigned identity (added to the P6 group in Phase 8).')
output principalId string = vm.outputs.principalId

@description('Resource ID of the SQL virtual machine resource.')
output sqlVirtualMachineId string = sqlVirtualMachine.id
