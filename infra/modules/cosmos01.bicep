metadata description = 'T5 cosmos01: an Azure Cosmos DB for NoSQL account with local (key) authentication off, the contosocare database, and the patient-events container at 400 RU/s, reached through a private endpoint in snet-pe in both network modes (ADR 0027).'

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
// (https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control). Public network access is off
// in both network modes: the private endpoint below is the only way in, so Database Hub's Security page lists no
// public-access issue for it. One region, no zone redundancy, and no automatic failover keep it at the minimum price.
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
    publicNetworkAccess: 'Disabled'
    isVirtualNetworkFilterEnabled: false
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2025-09-01' = {
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

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-09-01' = {
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

@description('The T5 account\'s document endpoint (https://<account>.documents.azure.com:443/). Inside the VNet it resolves to the private endpoint.')
output documentEndpoint string = account.properties.documentEndpoint

@description('Resource ID of the T5 account.')
output accountId string = account.id

@description('Name of the T5 database.')
output databaseName string = database.name

@description('Name of the T5 container.')
output containerName string = container.name

@description('Resource ID of the T5 private endpoint.')
output privateEndpointId string = privateEndpoint.id
