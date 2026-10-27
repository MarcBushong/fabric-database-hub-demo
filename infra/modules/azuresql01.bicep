metadata description = 'T3 azuresql01: the Azure SQL logical server and the ContosoCare database (General Purpose serverless), Entra-only with the P6 group as administrator, in public or private network mode (ADR 0007, ADR 0008, ADR 0016).'

@description('Azure region.')
param location string

@description('Tags for every resource.')
param tags object

@description('Logical server name: azuresql01-<deploymentId>. It stays the same when T3 is removed and recreated (ADR 0016).')
@minLength(1)
@maxLength(63)
param serverName string

@description('Database name.')
@minLength(1)
@maxLength(128)
param databaseName string

@description('public: a VNet rule for snet-sqlvm only. private: public network access off, a private endpoint in snet-pe, and the privatelink DNS zone linked to the VNet (ADR 0007).')
@allowed([
  'public'
  'private'
])
param networkMode string

@description('Object ID of the P6 Entra security group, the T3 administrator (ADR 0008).')
@minLength(36)
@maxLength(36)
param adminGroupObjectId string

@description('Name recorded as the administrator login: the P6 group\'s display name.')
@minLength(1)
@maxLength(128)
param adminGroupDisplayName string

@description('Serverless sizing from config/profiles.json: minVcores, maxVcores, and maxSizeGB (ADR 0016).')
param sizing object

@description('Auto-pause delay in minutes, or -1 to keep the database online (ADR 0016, C7).')
param autoPauseMinutes int

@description('Use the Azure SQL Database free offer with "continue using database for additional charges" (ADR 0016, C7).')
param useFreeLimit bool

@description('Resource ID of snet-sqlvm, the only subnet the public-mode VNet rule allows.')
param sqlvmSubnetId string

@description('Resource ID of snet-pe, which holds the private endpoint in private mode.')
param privateEndpointSubnetId string

@description('Resource ID of the virtual network that the private DNS zone is linked to in private mode.')
param virtualNetworkId string

@description('Name of the private endpoint in private mode.')
param privateEndpointName string

var isPrivate = networkMode == 'private'

// privatelink.database.windows.net in Azure public cloud, from the cloud's SQL host suffix.
var privateDnsZoneName = 'privatelink${az.environment().suffixes.sqlServerHostname}'

// Entra-only from creation (ADR 0009): no SQL authentication is ever set, and a tenant Deny policy rejects
// servers without administrators.azureADOnlyAuthentication. ARM applies azureADOnlyAuthentication only at
// creation; later updates keep it.
resource server 'Microsoft.Sql/servers@2025-01-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: adminGroupDisplayName
      sid: adminGroupObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

// General Purpose serverless, regional, with locally redundant backups (the cheapest options). The free-offer
// properties are sent only when the offer is used, because an existing database can't be converted.
resource database 'Microsoft.Sql/servers/databases@2025-01-01' = {
  parent: server
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: sizing.maxVcores
  }
  properties: union(
    {
      autoPauseDelay: autoPauseMinutes
      minCapacity: sizing.minVcores
      maxSizeBytes: sizing.maxSizeGB * 1073741824
      zoneRedundant: false
      requestedBackupStorageRedundancy: 'Local'
    },
    useFreeLimit
      ? {
          useFreeLimit: true
          freeLimitExhaustionBehavior: 'BillOverUsage'
        }
      : {}
  )
}

// Public mode: only T1's subnet, through its Microsoft.Sql service endpoint. There are no IP firewall rules and
// no "Allow Azure services" rule (ADR 0007).
resource virtualNetworkRule 'Microsoft.Sql/servers/virtualNetworkRules@2025-01-01' = if (!isPrivate) {
  parent: server
  name: 'snet-sqlvm'
  properties: {
    virtualNetworkSubnetId: sqlvmSubnetId
    ignoreMissingVnetServiceEndpoint: false
  }
}

// Private mode. Remove-DemoT3 deletes the server and the private endpoint but keeps the zone and its link, so
// a recreated T3 resolves again as soon as its new endpoint registers.
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (isPrivate) {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (isPrivate) {
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2025-09-01' = if (isPrivate) {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    customNetworkInterfaceName: '${privateEndpointName}-nic'
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: server.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-09-01' = if (isPrivate) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(privateDnsZoneName, '.', '-')
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

@description('Name of the T3 logical server.')
output serverName string = server.name

@description('Fully qualified domain name of the T3 logical server. Inside the VNet it resolves to the private endpoint in private mode.')
output serverFqdn string = server.properties.fullyQualifiedDomainName

@description('Name of the T3 database.')
output databaseName string = database.name

@description('Resource ID of the T3 logical server.')
output serverId string = server.id

@description('Resource ID of the T3 database.')
output databaseId string = database.id

@description('Resource ID of the T3 private endpoint, or empty in public mode.')
output privateEndpointId string = isPrivate ? privateEndpoint.id : ''

@description('Resource ID of the private DNS zone, or empty in public mode.')
output privateDnsZoneId string = isPrivate ? privateDnsZone.id : ''
