metadata description = 'Virtual network, subnets, and NSGs (ADR 0007), with the outbound mode from ADR 0017.'

@description('Azure region.')
param location string

@description('Short lowercase prefix for resource names.')
param prefix string

@description('Environment name.')
param environment string

@description('public or private (ADR 0007).')
@allowed([
  'public'
  'private'
])
param networkMode string

@description('DefaultOutboundAccess or NatGateway (ADR 0017).')
@allowed([
  'DefaultOutboundAccess'
  'NatGateway'
])
param outboundMode string

@description('Tags for every resource.')
param tags object

@description('Golden snapshot boot test only (ADR 0018, guardrail 8): deny every outbound flow from snet-archost before the restored host first boots. The main template never sets it.')
param quarantineHostOutbound bool = false

var addressSpace = '10.42.0.0/24'
var subnetPrefixes = {
  sqlvm: '10.42.0.0/27'
  archost: '10.42.0.32/27'
  privateEndpoints: '10.42.0.64/27'
  // T4 (Phase 24, ADR 0019): the smallest subnet Azure Database for PostgreSQL flexible server accepts for
  // virtual network integration is /28 (https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private).
  postgres: '10.42.0.96/28'
  bastion: '10.42.0.128/26'
}

// Azure KMS for Windows activation (documented addresses; ADR 0007).
var kmsAddresses = [
  '20.118.99.224/32'
  '40.83.235.53/32'
]

// Regional Sql service tags narrow T1-to-T3 traffic; unknown regions fall back to the global tag.
var sqlServiceTagRegions = {
  westus3: 'WestUS3'
  westus2: 'WestUS2'
  westus: 'WestUS'
  eastus: 'EastUS'
  eastus2: 'EastUS2'
  centralus: 'CentralUS'
  northeurope: 'NorthEurope'
  westeurope: 'WestEurope'
  uksouth: 'UKSouth'
}
var sqlServiceTag = contains(sqlServiceTagRegions, location) ? 'Sql.${sqlServiceTagRegions[location]}' : 'Sql'
// T4's write-ahead log archival goes to Azure Storage in the server's region; unknown regions use the global tag.
var storageServiceTag = contains(sqlServiceTagRegions, location) ? 'Storage.${sqlServiceTagRegions[location]}' : 'Storage'

var vmRules = [
  {
    name: 'Allow-RDP-From-Bastion'
    properties: {
      description: 'RDP only from the on-demand Bastion subnet.'
      access: 'Allow'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: subnetPrefixes.bastion
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
    }
  }
  {
    name: 'Deny-VNet-Inbound'
    properties: {
      description: 'Overrides the default AllowVnetInBound rule; nothing else in the VNet needs to reach the VMs.'
      access: 'Deny'
      direction: 'Inbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Allow-HTTPS-Outbound'
    properties: {
      description: 'Arc, telemetry, extensions, downloads, and updates over HTTPS. NSGs cannot restrict by FQDN (ADR 0007).'
      access: 'Allow'
      direction: 'Outbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '443'
    }
  }
  // No DNS rule: Azure-provided DNS (168.63.129.16) is platform traffic that NSGs allow by default, and the
  // AzurePlatformDNS service tag is valid only in Deny rules (ADR 0007, Phase 5 live finding).
  {
    name: 'Allow-KMS-Outbound'
    properties: {
      description: 'Windows activation (Azure KMS). Platform-allowed already; kept in case a 0.0.0.0/0 route disables the platform rule.'
      access: 'Allow'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefixes: kmsAddresses
      destinationPortRange: '1688'
    }
  }
  {
    name: 'Deny-Lateral-Management-Outbound'
    properties: {
      description: 'Blocks RDP and SSH from this subnet to the rest of the VNet (lateral movement).'
      access: 'Deny'
      direction: 'Outbound'
      priority: 200
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'Deny-Internet-Outbound'
    properties: {
      description: 'Everything else to the internet is denied.'
      access: 'Deny'
      direction: 'Outbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
]

var sqlOutboundRule = {
  name: 'Allow-AzureSql-Outbound'
  properties: {
    description: 'T1 to T3 in public mode, including the redirect connection policy ports.'
    access: 'Allow'
    direction: 'Outbound'
    priority: 130
    protocol: 'Tcp'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: sqlServiceTag
    destinationPortRanges: [
      '1433'
      '11000-11999'
    ]
  }
}

var privateEndpointRules = [
  {
    name: 'Allow-Sql-From-T1'
    properties: {
      description: 'Only T1 reaches the T3 private endpoint.'
      access: 'Allow'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: subnetPrefixes.sqlvm
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '1433'
    }
  }
  {
    name: 'Deny-VNet-Inbound'
    properties: {
      description: 'Overrides the default AllowVnetInBound rule.'
      access: 'Deny'
      direction: 'Inbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Deny-Lateral-Management-Outbound'
    properties: {
      description: 'Blocks RDP and SSH from this subnet to the rest of the VNet (lateral movement).'
      access: 'Deny'
      direction: 'Outbound'
      priority: 200
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
]

// T4 (Phase 24, ADR 0019): the delegated subnet of the PostgreSQL flexible server. Only T1 reaches port 5432.
// Learn requires port 5432 within the subnet, Azure Storage for write-ahead log archival, and Microsoft Entra ID
// for Entra sign-ins (https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private). There's no
// deny-internet rule: the service's other outbound dependencies aren't documented, so the default rules stay.
var postgresRules = [
  {
    name: 'Allow-Postgres-From-T1'
    properties: {
      description: 'Only T1 (the workload runner) reaches T4 on port 5432.'
      access: 'Allow'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: subnetPrefixes.sqlvm
      sourcePortRange: '*'
      destinationAddressPrefix: subnetPrefixes.postgres
      destinationPortRange: '5432'
    }
  }
  {
    name: 'Allow-Postgres-Within-Subnet'
    properties: {
      description: 'Port 5432 within the delegated subnet, which the service requires.'
      access: 'Allow'
      direction: 'Inbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: subnetPrefixes.postgres
      sourcePortRange: '*'
      destinationAddressPrefix: subnetPrefixes.postgres
      destinationPortRange: '5432'
    }
  }
  {
    name: 'Deny-VNet-Inbound'
    properties: {
      description: 'Overrides the default AllowVnetInBound rule; nothing else in the VNet reaches T4.'
      access: 'Deny'
      direction: 'Inbound'
      priority: 4000
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Allow-Postgres-Within-Subnet-Outbound'
    properties: {
      description: 'Port 5432 within the delegated subnet, which the service requires.'
      access: 'Allow'
      direction: 'Outbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: subnetPrefixes.postgres
      sourcePortRange: '*'
      destinationAddressPrefix: subnetPrefixes.postgres
      destinationPortRange: '5432'
    }
  }
  {
    name: 'Allow-Storage-Outbound'
    properties: {
      description: 'Write-ahead log archival to Azure Storage in the region.'
      access: 'Allow'
      direction: 'Outbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: storageServiceTag
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-EntraId-Outbound'
    properties: {
      description: 'Microsoft Entra ID, for Entra-only sign-ins.'
      access: 'Allow'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Deny-Lateral-Management-Outbound'
    properties: {
      description: 'Blocks RDP and SSH from this subnet to the rest of the VNet (lateral movement).'
      access: 'Deny'
      direction: 'Outbound'
      priority: 200
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
]

// The rules Azure Bastion requires on AzureBastionSubnet.
var bastionRules = [
  {
    name: 'AllowHttpsInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowGatewayManagerInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 130
      protocol: 'Tcp'
      sourceAddressPrefix: 'GatewayManager'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 140
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionHostCommunication'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 150
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
    }
  }
  {
    name: 'AllowSshRdpOutbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 100
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'AllowAzureCloudOutbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 110
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureCloud'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionCommunication'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 120
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
    }
  }
  {
    name: 'AllowHttpOutbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 130
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '80'
    }
  }
]

module nsgSqlvm 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-sqlvm'
  params: {
    name: 'nsg-${prefix}-${environment}-sqlvm'
    location: location
    tags: tags
    securityRules: concat(vmRules, [
      sqlOutboundRule
    ])
    enableTelemetry: false
  }
}

// The boot test's quarantine (ADR 0018): ahead of every allow rule, nothing leaves the host's subnet. Priority
// 100 is the lowest number a rule can have, which Allow-HTTPS-Outbound also uses, so in quarantine that one rule
// moves to 101; deleting the deny rule then restores the standard outbound rules. The VM agent's WireServer
// traffic (168.63.129.16, ports 80 and 32526) and Azure DNS aren't subject to network security groups, so Run
// Command keeps working (https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16;
// priorities 100 to 4096: https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview).
var quarantineRule = {
  name: 'Deny-Quarantine-Outbound'
  properties: {
    description: 'Golden snapshot boot test: every outbound flow is denied until the restored guest\'s Arc identity is reset (ADR 0018).'
    access: 'Deny'
    direction: 'Outbound'
    priority: 100
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}
var quarantinedHostRules = concat(
  [
    quarantineRule
  ],
  map(
    vmRules,
    rule =>
      rule.properties.direction == 'Outbound' && rule.properties.priority == 100
        ? union(rule, { properties: union(rule.properties, { priority: 101 }) })
        : rule
  )
)

module nsgArchost 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-archost'
  params: {
    name: 'nsg-${prefix}-${environment}-archost'
    location: location
    tags: tags
    securityRules: quarantineHostOutbound ? quarantinedHostRules : vmRules
    enableTelemetry: false
  }
}

module nsgPrivateEndpoints 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-pe'
  params: {
    name: 'nsg-${prefix}-${environment}-pe'
    location: location
    tags: tags
    securityRules: privateEndpointRules
    enableTelemetry: false
  }
}

module nsgPostgres 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-pg'
  params: {
    name: 'nsg-${prefix}-${environment}-pg'
    location: location
    tags: tags
    securityRules: postgresRules
    enableTelemetry: false
  }
}

module nsgBastion 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-bastion'
  params: {
    name: 'nsg-${prefix}-${environment}-bastion'
    location: location
    tags: tags
    securityRules: bastionRules
    enableTelemetry: false
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2025-09-01' = if (outboundMode == 'NatGateway') {
  name: 'pip-${prefix}-${environment}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2025-09-01' = if (outboundMode == 'NatGateway') {
  name: 'ng-${prefix}-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

var useDefaultOutbound = outboundMode == 'DefaultOutboundAccess'
var natGatewayId = outboundMode == 'NatGateway' ? natGateway.id : null

// privateEndpointNetworkPolicies is set on every subnet, because what-if reports a change from the live value
// (Disabled) to Enabled when it's omitted. snet-pe keeps NetworkSecurityGroupEnabled so nsg-pe filters traffic
// to the T3 private endpoint.
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet'
  params: {
    name: 'vnet-${prefix}-${environment}'
    location: location
    tags: tags
    addressPrefixes: [
      addressSpace
    ]
    subnets: [
      {
        name: 'snet-sqlvm'
        addressPrefix: subnetPrefixes.sqlvm
        networkSecurityGroupResourceId: nsgSqlvm.outputs.resourceId
        serviceEndpoints: networkMode == 'public' ? [
          'Microsoft.Sql'
        ] : []
        privateEndpointNetworkPolicies: 'Disabled'
        defaultOutboundAccess: useDefaultOutbound
        natGatewayResourceId: natGatewayId
      }
      {
        name: 'snet-archost'
        addressPrefix: subnetPrefixes.archost
        networkSecurityGroupResourceId: nsgArchost.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        defaultOutboundAccess: useDefaultOutbound
        natGatewayResourceId: natGatewayId
      }
      {
        name: 'snet-pe'
        addressPrefix: subnetPrefixes.privateEndpoints
        networkSecurityGroupResourceId: nsgPrivateEndpoints.outputs.resourceId
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
        defaultOutboundAccess: false
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: subnetPrefixes.bastion
        networkSecurityGroupResourceId: nsgBastion.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
      }
      // T4 (Phase 24, ADR 0019), last so the other subnets keep their index. Delegated to the PostgreSQL flexible
      // server; the service adds the Microsoft.Storage service endpoint when the first server is created, and
      // removing it can disrupt connectivity, so it's declared here and a re-deploy never removes it.
      {
        name: 'snet-pg'
        addressPrefix: subnetPrefixes.postgres
        networkSecurityGroupResourceId: nsgPostgres.outputs.resourceId
        delegation: 'Microsoft.DBforPostgreSQL/flexibleServers'
        serviceEndpoints: [
          'Microsoft.Storage'
        ]
        privateEndpointNetworkPolicies: 'Disabled'
        defaultOutboundAccess: useDefaultOutbound
        natGatewayResourceId: natGatewayId
      }
    ]
    enableTelemetry: false
  }
}

@description('Resource ID of the virtual network.')
output virtualNetworkId string = virtualNetwork.outputs.resourceId

@description('Subnet resource IDs, in declaration order: snet-sqlvm, snet-archost, snet-pe, AzureBastionSubnet, snet-pg.')
output subnetIds string[] = virtualNetwork.outputs.subnetResourceIds

@description('Resource ID of snet-pg, the subnet delegated to T4 (Phase 24).')
output postgresSubnetId string = virtualNetwork.outputs.subnetResourceIds[4]
