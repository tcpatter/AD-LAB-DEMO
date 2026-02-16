@description('Name of the Virtual Network')
param vnetName string

@description('Location for the VNet')
param location string

@description('Address prefix for the VNet')
param addressPrefix string

@description('Array of subnet configurations')
param subnets array

@description('Custom DNS servers (empty = Azure default)')
param dnsServers array = []

@description('Tags for the resource')
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    dhcpOptions: empty(dnsServers) ? {} : {
      dnsServers: dnsServers
    }
    subnets: [
      for subnet in subnets: {
        name: subnet.name
        properties: {
          addressPrefix: subnet.addressPrefix
          networkSecurityGroup: contains(subnet, 'nsgId') && !empty(subnet.nsgId) ? {
            id: subnet.nsgId
          } : null
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetIds array = [for (subnet, i) in subnets: vnet.properties.subnets[i].id]
