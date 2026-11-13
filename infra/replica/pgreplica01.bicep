metadata description = 'T4\'s read replica (2026-11-13, ADR 0025): a same-region read replica of T4, pgreplica01-<deploymentId>, created for each session in T4\'s delegated subnet and private DNS zone, at T4\'s actual size or a larger documented General Purpose size. deploy.ps1 and start-demo.ps1 deploy this template (resource group deployment dbhub-t4-replica) only while the replica doesn\'t exist: a second deployment fails (ReadReplicaAlreadyExistWithGivenName). Authentication, roles, and most parameters come from T4.'

@description('Azure region: T4\'s, for a same-region replica.')
param location string

@description('Tags for the replica.')
param tags object

@description('Replica name: pgreplica01-<deploymentId>. It stays the same across sessions, so the runner, Database Hub, and the safety stop find each session\'s replica under it.')
@minLength(3)
@maxLength(63)
param serverName string

@description('Resource ID of T4, the source server. It must be Ready: Azure refuses a replica of a stopped server (ReadReplicaServerInUnexpectedState).')
param sourceServerId string

@description('The replica\'s compute size: T4\'s actual size, or a larger documented General Purpose size when Azure refuses it (never fewer vCores than T4\'s).')
@allowed([
  'Standard_D2ds_v5'
  'Standard_D4ds_v5'
  'Standard_D4ads_v5'
])
param skuName string

@description('Availability zone: empty for no preference, or 1, 2, or 3 (the size fallback\'s retry in another zone).')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param availabilityZone string = ''

@description('Storage, as T4\'s: Learn requires the same storage type, and the size at least the source\'s.')
param storageSizeGB int = 32

@description('Premium SSD performance tier, as T4\'s.')
param storageTier string = 'P4'

@description('Resource ID of snet-pg, T4\'s delegated subnet; its network security group already allows port 5432 within the subnet, which replication needs.')
param delegatedSubnetId string

@description('Resource ID of T4\'s private DNS zone, so T1 resolves the replica\'s name to its private address.')
param privateDnsZoneId string

@description('max_standby_streaming_delay in milliseconds, from config/versions.json (postgresql.replica.maxStandbyStreamingDelayMs): how long replaying T4\'s changes waits for a query on the replica before cancelling it. A dynamic parameter. The replica-lag scenario holds a report for less than this, so Read replica lag climbs while it runs.')
@minValue(-1)
@maxValue(2147483647)
param maxStandbyStreamingDelayMs int = 600000

// A read replica of T4 (createMode Replica): its compute is billed while it exists, so deploy.ps1 and start-demo.ps1 create
// it for a session and stop-demo.ps1 deletes it. Storage auto-grow stays off, as on T4 ("If storage autogrow is enabled on
// the primary server, it must also be enabled on the replicas"). Backups and high availability aren't available on a
// replica, and authentication comes from T4 (Microsoft Entra only).
// (https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas,
// https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica)
resource replica 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'GeneralPurpose'
  }
  properties: union({
    createMode: 'Replica'
    sourceServerResourceId: sourceServerId
    storage: {
      storageSizeGB: storageSizeGB
      tier: storageTier
      autoGrow: 'Disabled'
      type: 'Premium_LRS'
    }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
  }, empty(availabilityZone) ? {} : {
    availabilityZone: availabilityZone
  })
}

// Replaying T4's changes waits up to this long for a conflicting query on the replica, then cancels it (dynamic, so no
// restart; settable on a replica, live 2026-11-13). https://www.postgresql.org/docs/current/hot-standby.html
resource standbyDelay 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: replica
  name: 'max_standby_streaming_delay'
  properties: {
    value: string(maxStandbyStreamingDelayMs)
    source: 'user-override'
  }
}

@description('Name of the replica.')
output serverName string = replica.name

@description('Fully qualified domain name of the replica; inside the VNet it resolves to its private address.')
output serverFqdn string = replica.properties.fullyQualifiedDomainName

@description('Resource ID of the replica.')
output serverId string = replica.id
