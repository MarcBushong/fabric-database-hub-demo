metadata description = 'T5 cosmos01: an Azure Cosmos DB for NoSQL account with local (key) authentication off, the contosocare database, and the patient-events container at 400 RU/s, reached from T1\'s subnet only: through a private endpoint in snet-pe when something needs it, otherwise through T1\'s subnet\'s service endpoint (ADR 0027).'

@description('Azure region.')
param location string

@description('Tags for every resource.')
param tags object

@description('Account name: cosmos01-<deploymentId>, globally unique, 3 to 44 lowercase letters, digits, and hyphens.')
@minLength(3)
@maxLength(44)
param accountName string

@description('Database name.')
@minLength(1)
@maxLength(255)
param databaseName string

@description('Container name.')
@minLength(1)
@maxLength(255)
param containerName string

@description('The container\'s partition key path.')
param partitionKeyPath string

@description('The container\'s partition key version: 2, hash partitioning with keys up to 2 KB (config/versions.json).')
@allowed([
  1
  2
])
param partitionKeyVersion int = 2

@description('The container\'s indexing policy (config/versions.json, which the scripts and the session control\'s runbooks create the container with too).')
param indexingPolicy object

@description('The container\'s manual throughput in RU/s; 400 is the minimum for a container.')
@minValue(400)
param throughput int

@description('Use the subscription\'s one free-tier account (1,000 RU/s and 25 GB free). Azure sets it only when the account is created, so deploy.ps1 passes an existing account\'s own value (ADR 0027).')
param enableFreeTier bool

@description('Keep T5 behind its private endpoint, with public network access off (true, the default): in private mode, under a policy that turns Azure Cosmos DB public network access off or denies it, when the policies couldn\'t all be read, and for an account that already has its endpoint; deploy.ps1 decides (DEPLOY.T5.NETWORK). False: public network access on, limited to T1\'s subnet by a virtual network rule, with no private endpoint or DNS zone, as T3 in public mode (ADR 0027, 2026-11-21).')
param privateAccess bool = true

@description('Resource ID of snet-sqlvm, T1\'s subnet: the one subnet the account\'s virtual network rule allows when privateAccess is false. Its Microsoft.AzureCosmosDB service endpoint is network.bicep\'s.')
param allowedSubnetId string

@description('Resource ID of snet-pe, which holds the private endpoint.')
param privateEndpointSubnetId string

@description('Resource ID of the virtual network that the private DNS zone is linked to.')
param virtualNetworkId string

@description('Name of the private endpoint.')
param privateEndpointName string

@description('The private DNS zone of the NoSQL API\'s private endpoint: privatelink.documents.azure.com in Azure public cloud.')
param privateDnsZoneName string

@description('The private endpoint\'s group (subresource) ID for the NoSQL API.')
param privateEndpointGroupId string

// Microsoft Entra only (ADR 0027): disableLocalAuth turns the account keys off for the data plane, so T1's managed
// identity signs in with its data-plane role, and nothing has a key to keep
// (https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control). Only T1's subnet reaches it,
// either way: with privateAccess, public network access is off and the private endpoint below is the only way in, so
// Database Hub's Security page lists no public-access issue for it; without it, public network access is on with no IP
// rule, and a virtual network rule lets in T1's subnet alone through its service endpoint
// (https://learn.microsoft.com/azure/cosmos-db/how-to-configure-vnet-service-endpoint), as T3 in public mode, and the
// Security page lists T5's public access as it does T3's. One region, no zone redundancy, and no automatic failover keep
// it at the minimum price.
resource account 'Microsoft.DocumentDB/databaseAccounts@2025-10-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    enableFreeTier: enableFreeTier
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    publicNetworkAccess: privateAccess ? 'Disabled' : 'Enabled'
    isVirtualNetworkFilterEnabled: !privateAccess
    virtualNetworkRules: privateAccess
      ? []
      : [
          {
            id: allowedSubnetId
            ignoreMissingVNetServiceEndpoint: false
          }
        ]
    ipRules: []
    minimalTlsVersion: 'Tls12'
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2025-10-15' = {
  parent: account
  name: databaseName
  tags: tags
  properties: {
    resource: {
      id: databaseName
    }
  }
}

// The throughput is the container's own (dedicated), so the whole 400 RU/s serves the one container, and ru-storm's hot
// partition can use all of it. Every path is indexed except the documents' payload filler, which the runner never queries.
// The container exists only during a session once the session control's role can create it (2026-11-19, ADR 0027): a
// container's throughput can't be taken away, only deleted with it, so stop-demo.ps1, the session's end, and the nightly
// safety stop delete it, and start-demo.ps1, Run all, and this template create it again from config/versions.json.
resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2025-10-15' = {
  parent: database
  name: containerName
  tags: tags
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          partitionKeyPath
        ]
        kind: 'Hash'
        version: partitionKeyVersion
      }
      indexingPolicy: indexingPolicy
    }
    options: {
      throughput: throughput
    }
  }
}

// The private endpoint, its DNS zone, the zone's link, and its zone group exist only with privateAccess. Without it the
// template leaves out these four, and since a deployment adds and updates but never deletes, an account that has its
// endpoint keeps it; deploy.ps1 keeps privateAccess for such an account, so an update changes nothing in T5's network.
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (privateAccess) {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (privateAccess) {
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2025-09-01' = if (privateAccess) {
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
          privateLinkServiceId: account.id
          groupIds: [
            privateEndpointGroupId
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-09-01' = if (privateAccess) {
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

@description('Name of the T5 account.')
output accountName string = account.name

@description('The T5 account\'s document endpoint (https://<account>.documents.azure.com:443/). With privateAccess it resolves to the private endpoint inside the VNet.')
output documentEndpoint string = account.properties.documentEndpoint

@description('Resource ID of the T5 account.')
output accountId string = account.id

@description('Name of the T5 database.')
output databaseName string = database.name

@description('Name of the T5 container.')
output containerName string = container.name

@description('Resource ID of the T5 private endpoint, or empty without privateAccess.')
output privateEndpointId string = privateAccess ? privateEndpoint.id : ''
