@description('Name of the peering connection')
param peeringName string

@description('Name of the local VNet')
param localVnetName string

@description('Resource ID of the remote VNet')
param remoteVnetId string

@description('Allow forwarded traffic')
param allowForwardedTraffic bool = true

@description('Allow gateway transit')
param allowGatewayTransit bool = false

@description('Use remote gateways')
param useRemoteGateways bool = false

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${localVnetName}/${peeringName}'
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}

output peeringId string = peering.id
