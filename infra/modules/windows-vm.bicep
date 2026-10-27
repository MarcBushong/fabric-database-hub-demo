metadata description = 'One Windows VM: NIC without a public IP, system-assigned identity (plus optional user-assigned identities), OS disk, an optional data disk at LUN 0, managed boot diagnostics, and a DevTest Labs auto-shutdown schedule (ADR 0003, ADR 0007, ADR 0016).'

@description('Azure region.')
param location string

@description('VM name, also used as the computer name.')
@minLength(1)
@maxLength(15)
param vmName string

@description('Tags for every resource.')
param tags object

@description('VM size.')
param vmSize string

@description('Resource ID of the subnet for the NIC.')
param subnetId string

@description('Marketplace image reference: publisher, offer, sku, and version.')
param imageReference object

@description('Availability zone, or empty for a regional VM. Premium SSD v2 data disks need a zone.')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param zone string

@description('Regular or Spot. Spot uses eviction policy Deallocate (ADR 0016, C5).')
@allowed([
  'Regular'
  'Spot'
])
param priority string

@description('Standard or TrustedLaunch (ADR 0003). Set explicitly because newer API versions default to Trusted Launch.')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param securityType string

@description('Storage account type of the OS disk.')
param osDiskSku string

@description('Size of the OS disk in GiB.')
param osDiskSizeGiB int

@description('Data disk at LUN 0: sku, sizeGiB, caching, and for Premium SSD v2 also iops and mbps. Sku None creates no data disk (ADR 0016).')
param dataDisk object

@description('Local administrator name.')
param adminUsername string

@description('Local administrator password, used only when the VM is created (ADR 0009).')
@secure()
param adminPassword string

@description('False when the VM already exists: osProfile cannot change after creation, so it is left out (ADR 0001, ADR 0009).')
param includeOsProfile bool

@description('Windows_Server applies Azure Hybrid Benefit (attested only); empty for none (ADR 0006, C6).')
@allowed([
  ''
  'Windows_Server'
])
param licenseType string

@description('Daily auto-shutdown time (HHmm, 24-hour).')
param autoShutdownTime string

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string

@description('Resource IDs of user-assigned identities to attach next to the system-assigned one; empty for none (ADR 0005).')
param userAssignedIdentityIds string[] = []

@description('Golden restore (ADR 0018): resource ID of a snapshot to create the OS disk from, attached to a new VM with no osProfile and no image. Empty builds from imageReference.')
param osDiskSourceResourceId string = ''

@description('Golden restore of a VM that already exists: attach its existing OS disk by ID and never declare the disk again, so a later capture that deletes the old snapshot can\'t break a redeployment (ADR 0018).')
param attachExistingOsDisk bool = false

@description('Current storage types of this VM\'s existing disks that drifted from the profile, keyed by disk name. The subscription\'s automation can switch a deallocated VM\'s disks to Standard HDD, and Azure doesn\'t change an OS disk\'s type through its VM, so the template keeps the current type (Phase 24).')
param diskSkuOverrides object = {}

var hasDataDisk = dataDisk.sku != 'None'
var osDiskName = '${vmName}-osdisk'
var dataDiskName = '${vmName}-data01'
var effectiveOsDiskSku = diskSkuOverrides[?osDiskName] ?? osDiskSku
var effectiveDataDiskSku = diskSkuOverrides[?dataDiskName] ?? dataDisk.sku
var isPremiumV2 = effectiveDataDiskSku == 'PremiumV2_LRS'
var osDiskFromSnapshot = !empty(osDiskSourceResourceId)
var attachOsDisk = osDiskFromSnapshot || attachExistingOsDisk

resource nic 'Microsoft.Network/networkInterfaces@2025-09-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

// A separate disk resource so Premium SSD v2 can set its provisioned IOPS and throughput, and so every
// SKU lands in the VM's zone. Export and public network access are turned off. Tier None creates none.
resource dataDisk01 'Microsoft.Compute/disks@2025-01-02' = if (hasDataDisk) {
  name: dataDiskName
  location: location
  tags: tags
  zones: empty(zone) ? null : [
    zone
  ]
  sku: {
    name: effectiveDataDiskSku
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: dataDisk.sizeGiB
    diskIOPSReadWrite: isPremiumV2 ? dataDisk.iops : null
    diskMBpsReadWrite: isPremiumV2 ? dataDisk.mbps : null
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}

// Golden restore (ADR 0018): the OS disk is a copy of the golden snapshot, with export denied. Declared only
// when the VM is created; afterwards the VM attaches it by ID (attachExistingOsDisk).
resource goldenOsDisk 'Microsoft.Compute/disks@2025-01-02' = if (osDiskFromSnapshot) {
  name: osDiskName
  location: location
  tags: tags
  zones: empty(zone) ? null : [
    zone
  ]
  sku: {
    name: effectiveOsDiskSku
  }
  properties: {
    osType: 'Windows'
    hyperVGeneration: 'V2'
    creationData: {
      createOption: 'Copy'
      sourceResourceId: osDiskSourceResourceId
    }
    diskSizeGB: osDiskSizeGiB
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-11-01' = {
  name: vmName
  location: location
  tags: tags
  zones: empty(zone) ? null : [
    zone
  ]
  identity: empty(userAssignedIdentityIds)
    ? {
        type: 'SystemAssigned'
      }
    : {
        type: 'SystemAssigned, UserAssigned'
        userAssignedIdentities: toObject(userAssignedIdentityIds, id => id, id => {})
      }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    priority: priority
    evictionPolicy: priority == 'Spot' ? 'Deallocate' : null
    billingProfile: priority == 'Spot'
      ? {
          maxPrice: -1
        }
      : null
    licenseType: empty(licenseType) ? null : licenseType
    securityProfile: securityType == 'TrustedLaunch'
      ? {
          securityType: 'TrustedLaunch'
          uefiSettings: {
            secureBootEnabled: true
            vTpmEnabled: true
          }
        }
      : {
          securityType: 'Standard'
        }
    osProfile: includeOsProfile && !attachOsDisk
      ? {
          computerName: vmName
          adminUsername: adminUsername
          adminPassword: adminPassword
          windowsConfiguration: {
            provisionVMAgent: true
            enableAutomaticUpdates: true
            patchSettings: {
              patchMode: 'AutomaticByOS'
            }
          }
        }
      : null
    storageProfile: {
      imageReference: attachOsDisk ? null : imageReference
      osDisk: attachOsDisk
        ? {
            name: osDiskName
            createOption: 'Attach'
            osType: 'Windows'
            caching: 'ReadWrite'
            deleteOption: 'Delete'
            managedDisk: {
              id: osDiskFromSnapshot ? goldenOsDisk.id : resourceId('Microsoft.Compute/disks', osDiskName)
            }
          }
        : {
            name: osDiskName
            createOption: 'FromImage'
            caching: 'ReadWrite'
            diskSizeGB: osDiskSizeGiB
            deleteOption: 'Delete'
            managedDisk: {
              storageAccountType: effectiveOsDiskSku
            }
          }
      dataDisks: hasDataDisk
        ? [
            {
              lun: 0
              createOption: 'Attach'
              caching: dataDisk.caching
              deleteOption: 'Detach'
              managedDisk: {
                id: dataDisk01.id
              }
            }
          ]
        : []
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      // Managed boot diagnostics storage isn't billed.
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// The DevTest Labs name format is required for the VM's auto-shutdown blade to find it.
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
  }
}

@description('Resource ID of the VM.')
output vmId string = vm.id

@description('Name of the VM.')
output vmName string = vm.name

@description('Object ID of the VM system-assigned identity.')
output principalId string = vm.identity.principalId

@description('Private IP address of the NIC.')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
