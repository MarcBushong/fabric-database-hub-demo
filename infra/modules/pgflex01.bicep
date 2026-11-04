metadata description = 'T4 pgflex01 (Phase 24, ADR 0019): an Azure Database for PostgreSQL flexible server, at the smallest Burstable size by default or the General Purpose size deploy.ps1 falls back to, with the contosocare database, Microsoft Entra-only authentication with the P6 group as administrator, virtual network integration with no public endpoint, the free enhanced metrics turned on, and max_connections at 50 on every size.'

@description('Azure region.')
param location string

@description('Tags for every resource.')
param tags object

@description('Server name: pgflex01-<deploymentId>. It stays the same across deployments, so the runner and Database Hub keep finding it.')
@minLength(3)
@maxLength(63)
param serverName string

@description('The only database the workload runner uses.')
@minLength(1)
@maxLength(63)
param databaseName string = 'contosocare'

@description('PostgreSQL major version, pinned in config/versions.json (postgresql.majorVersion).')
param postgresVersion string

@description('Compute, storage, and backup sizing from config/profiles.json (profiles.<profile>.t4), with skuName from the t4SkuName setting and the tier that follows it; the storage, backup, and high availability settings are valid on both tiers.')
param sizing object

@description('Availability zone when the server is created: empty for no preference, or 1, 2, or 3. Sent only when set (Phase 24).')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param availabilityZone string = ''

@description('Resource ID of snet-pg, the subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers.')
param delegatedSubnetId string

@description('Resource ID of the virtual network the private DNS zone is linked to.')
param virtualNetworkId string

@description('Private DNS zone for virtual network integration. It must end with .postgres.database.azure.com and differ from any server name.')
param privateDnsZoneName string

@description('Object ID of the P6 Entra security group, the T4 administrator (the same group as T3, ADR 0008).')
@minLength(36)
@maxLength(36)
param adminGroupObjectId string

@description('The P6 group\'s display name: the PostgreSQL role name its members sign in with.')
@minLength(1)
@maxLength(128)
param adminGroupDisplayName string

@description('Server-wide idle_in_transaction_session_timeout in milliseconds: the backstop that ends any session left idle in a transaction (ADR 0010). The runner sets a shorter value on its own sessions.')
@minValue(60000)
@maxValue(3600000)
param idleInTransactionTimeoutMs int = 900000

@description('max_connections on every size, from config/versions.json (postgresql.maxConnections): Standard_B1ms\'s own default of 50, so connection-surge reaches the limit, and Database Hub\'s Failed connections fill, on the larger sizes too (ADR 0019, 2026-11-03). A static parameter: the value takes effect at the next restart, which deploy.ps1 does when one is pending.')
@minValue(25)
@maxValue(5000)
param maxConnections int = 50

@description('Autonomous tuning (2026-11-04, ADR 0019): Query Store and index tuning in REPORT mode, only on a size that runs them (4 vCores or more, not Burstable); deploy.ps1 decides (Get-DemoT4Tuning). When false, these parameters are left as they are, except that Query Store is turned off on a Burstable size.')
param autonomousTuning bool = false

@description('The autonomous tuning values from config/versions.json (postgresql.autonomousTuning): queryCaptureMode, parametersCaptureMode, analysisIntervalMinutes, and mode.')
param tuning object = {
  queryCaptureMode: 'top'
  parametersCaptureMode: 'capture_first_sample'
  analysisIntervalMinutes: 60
  mode: 'report'
}

// The private DNS zone that virtual network integration needs, linked to the demo VNet so T1 resolves the
// server's name to its private address (https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private).
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-${last(split(virtualNetworkId, '/'))}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

// Entra-only from creation: password authentication is off, so no administrator login or password exists
// (ADR 0009). Virtual network integration can't be changed after creation; the server never has a public
// endpoint. Storage auto-grow is off, so a runaway scenario can't grow the bill (ADR 0010, ADR 0016).
resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: sizing.skuName
    tier: sizing.tier
  }
  properties: union({
    version: postgresVersion
    storage: {
      storageSizeGB: sizing.storageSizeGB
      tier: sizing.storageTier
      autoGrow: 'Disabled'
      type: 'Premium_LRS'
    }
    backup: {
      backupRetentionDays: sizing.backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZone.id
      publicNetworkAccess: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: subscription().tenantId
    }
  }, empty(availabilityZone) ? {} : {
    availabilityZone: availabilityZone
  })
  dependsOn: [
    privateDnsZoneLink
  ]
}

// The server accepts one change at a time, so the administrator, the database, and the parameters are chained.
resource administrator 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = {
  parent: server
  name: adminGroupObjectId
  properties: {
    principalType: 'Group'
    principalName: adminGroupDisplayName
    tenantId: subscription().tenantId
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    administrator
  ]
}

// Enhanced metrics (sessions by state and by wait event type, the oldest transaction, deadlocks, and more) are
// off by default; this dynamic parameter turns them on at no extra charge
// (https://learn.microsoft.com/azure/postgresql/monitor/concepts-monitoring#enhanced-metrics).
resource enhancedMetrics 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: server
  name: 'metrics.collector_database_activity'
  properties: {
    value: 'on'
    source: 'user-override'
  }
  dependsOn: [
    database
  ]
}

resource idleInTransactionTimeout 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: server
  name: 'idle_in_transaction_session_timeout'
  properties: {
    value: string(idleInTransactionTimeoutMs)
    source: 'user-override'
  }
  dependsOn: [
    enhancedMetrics
  ]
}

// A static parameter (allowed values 25-5000): the new value waits for a restart (isConfigPendingRestart), which
// deploy.ps1 does before T1 sets T4 up. 50 is Standard_B1ms's default; Standard_B2s and Standard_D2ds_v5 default to 429
// and 859, above connection-surge's cap, so lowering it makes them refuse the surge's overshoot too. 15 slots stay
// reserved (reserved_connections 5, superuser_reserved_connections 10), which leaves 35 for the runner.
// (https://learn.microsoft.com/azure/postgresql/server-parameters/param-connections-authentication-connection-settings,
// https://learn.microsoft.com/azure/postgresql/configure-maintain/concepts-limits)
resource maxConnectionsSetting 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: server
  name: 'max_connections'
  properties: {
    value: string(maxConnections)
    source: 'user-override'
  }
  dependsOn: [
    idleInTransactionTimeout
  ]
}

// Autonomous tuning (2026-11-04, user-directed; ADR 0019), on T4's 4-vCore default: it "is supported on any currently
// supported compute SKU with at least 4 vCores", and needs Query Store capturing queries (top or all); the runner's
// queries are parameterized, so parameters_capture_mode is capture_first_sample. index_tuning.analysis_interval goes
// before index_tuning.mode: the first session is scheduled from the interval in effect when tuning is turned on, and 60
// minutes is its minimum, because T4 runs only during demos. All four are dynamic (no restart). Without autonomous
// tuning they're left as they are, except on Burstable: "Don't enable query store on the Burstable pricing tier as it
// causes performance problems", so a server moved to a Burstable size (t4SkuName, to keep the month cheap) gets Query
// Store off, where the 4-vCore default had turned it on.
// (https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning,
// https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store,
// https://learn.microsoft.com/azure/postgresql/parameters/parameters-query-store,
// https://learn.microsoft.com/azure/postgresql/parameters/parameters-autonomous-tuning)
resource queryCaptureMode 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = if (autonomousTuning || sizing.tier == 'Burstable') {
  parent: server
  name: 'pg_qs.query_capture_mode'
  properties: {
    value: autonomousTuning ? string(tuning.queryCaptureMode) : 'none'
    source: 'user-override'
  }
  dependsOn: [
    maxConnectionsSetting
  ]
}

resource parametersCaptureMode 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = if (autonomousTuning) {
  parent: server
  name: 'pg_qs.parameters_capture_mode'
  properties: {
    value: string(tuning.parametersCaptureMode)
    source: 'user-override'
  }
  dependsOn: [
    queryCaptureMode
  ]
}

resource tuningInterval 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = if (autonomousTuning) {
  parent: server
  name: 'index_tuning.analysis_interval'
  properties: {
    value: string(tuning.analysisIntervalMinutes)
    source: 'user-override'
  }
  dependsOn: [
    parametersCaptureMode
  ]
}

resource tuningMode 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = if (autonomousTuning) {
  parent: server
  name: 'index_tuning.mode'
  properties: {
    value: string(tuning.mode)
    source: 'user-override'
  }
  dependsOn: [
    tuningInterval
  ]
}

@description('Name of the T4 server.')
output serverName string = server.name

@description('Fully qualified domain name of the T4 server; inside the VNet it resolves to the server\'s private address.')
output serverFqdn string = server.properties.fullyQualifiedDomainName

@description('Resource ID of the T4 server.')
output serverId string = server.id

@description('Name of the T4 database.')
output databaseName string = database.name

@description('Resource ID of the T4 private DNS zone.')
output privateDnsZoneId string = privateDnsZone.id
