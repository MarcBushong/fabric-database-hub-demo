metadata description = 'On-demand Azure Bastion Basic and its Standard public IP in the existing AzureBastionSubnet, for the T2 setup-wizard step (start-demo.ps1 -Interactive). Deployed at resource group scope on its own; stop-demo.ps1 and the bastion-cleanup workflow delete it (plan section 9.4, C8).'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the demo virtual network, which has the AzureBastionSubnet (network.bicep).')
param vnetName string

@description('Name of the Bastion host, bas-<prefix>-<env>.')
param bastionName string

@description('Name of the Bastion public IP, pip-<prefix>-<env>-bastion.')
param publicIpName string

@description('UTC time after which the bastion-cleanup workflow deletes Bastion (bastionMaxHours).')
param expiresUtc string

@description('Tags from the resource group; the expiry tag is added.')
param tags object = {}

var bastionTags = union(tags, {
  DbHubBastionExpiresUtc: expiresUtc
})

// Basic SKU: browser RDP from the Azure portal, which is all the wizard step needs.
// https://learn.microsoft.com/azure/bastion/configuration-settings
resource publicIp 'Microsoft.Network/publicIPAddresses@2025-09-01' = {
  name: publicIpName
  location: location
  tags: bastionTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-09-01' = {
  name: bastionName
  location: location
  tags: bastionTags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'AzureBastionSubnet')
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

@description('Name of the Bastion host.')
output bastionName string = bastion.name

@description('Resource ID of the Bastion host.')
output bastionId string = bastion.id

@description('Resource ID of the Bastion public IP.')
output publicIpId string = publicIp.id
