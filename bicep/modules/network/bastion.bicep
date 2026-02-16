@description('Name of the Bastion host')
param bastionName string

@description('Location for the Bastion')
param location string

@description('Subnet ID for AzureBastionSubnet')
param subnetId string

@description('Tags for the resource')
param tags object = {}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${bastionName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
