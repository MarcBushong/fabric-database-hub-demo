targetScope = 'resourceGroup'

metadata description = 'Golden snapshot boot test (ADR 0018, guardrail 8): a disposable network whose host subnet denies all outbound traffic before first boot, and a T2 host restored from a golden snapshot. scripts/test-t2-golden.ps1 deploys it into rg-<prefix>-gtest and deletes the group afterward. It reuses the network and host modules of the main template.'

@description('Azure region; it must be the snapshot\'s region.')
param location string = resourceGroup().location

@description('Short lowercase prefix for resource names.')
@minLength(3)
@maxLength(8)
param prefix string

@description('The test environment\'s name.')
@minLength(2)
@maxLength(8)
param environment string = 'gtest'

@description('Tags for every resource.')
param tags object

@description('Resource ID of the golden snapshot to restore.')
param osDiskSourceResourceId string

@description('Cost and performance profile in config/profiles.json; sets the host size and the OS disk tier.')
@allowed([
  'lowest-cost'
  'demo-day'
  'enhanced-performance'
])
param profile string = 'lowest-cost'

@description('Host size override; empty uses the profile.')
param hostVmSize string = ''

@description('Deny all outbound traffic from the host subnet. Always true for the boot test; the test script deletes the rule before it onboards the copy.')
param quarantineHostOutbound bool = true

@description('Create the least-privilege Arc onboarding identity id-<prefix>-<env>-arc-onboard with Azure Connected Machine Onboarding on the test group and attach it to the copy, so -Onboard uses it instead of the operator\'s token (ADR 0005, ADR 0009). Needs Microsoft.Authorization/roleAssignments/write; test-t2-golden.ps1 sets it from assignRoles with -Onboard. The group\'s deletion removes both.')
param assignArcOnboardingRole bool = false

@description('Daily auto-shutdown time (HHmm), a backstop if the test is interrupted.')
param autoShutdownTime string = '1900'

@description('Windows time zone ID for the auto-shutdown schedule.')
param autoShutdownTimeZone string = 'UTC'

var catalogProfile = loadJsonContent('../config/profiles.json', '$.profiles')[profile]
var diskTiers = loadJsonContent('../config/profiles.json', '$.diskTiers')
var vmImages = loadJsonContent('../config/versions.json', '$.vmImages')

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    prefix: prefix
    environment: environment
    networkMode: 'public'
    outboundMode: 'DefaultOutboundAccess'
    tags: tags
    quarantineHostOutbound: quarantineHostOutbound
  }
}

// The restored host attaches its copied OS disk: no osProfile, no image, so no administrator password.
module archost01 'modules/archost01.bicep' = {
  name: 'archost01'
  params: {
    location: location
    tags: tags
    vmSize: empty(hostVmSize) ? catalogProfile.t2Host.size : hostVmSize
    subnetId: network.outputs.subnetIds[1]
    imageReference: vmImages.t2Host
    zone: ''
    priority: 'Regular'
    securityType: 'Standard'
    osDisk: diskTiers[catalogProfile.t2Host.osDisk]
    dataDisk: diskTiers.None
    adminUsername: 'unused'
    adminPassword: ''
    includeOsProfile: false
    licenseType: ''
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    // Created only with assignArcOnboardingRole, but ARM evaluates the identity's resource ID either way, so it needs a valid name.
    assignArcOnboardingRole: assignArcOnboardingRole
    arcOnboardIdentityName: 'id-${prefix}-${environment}-arc-onboard'
    osDiskSourceResourceId: osDiskSourceResourceId
  }
}

@description('Resource ID of the restored host.')
output hostVmId string = archost01.outputs.vmId

@description('Name of the host subnet\'s network security group.')
output hostNsgName string = 'nsg-${prefix}-${environment}-archost'
