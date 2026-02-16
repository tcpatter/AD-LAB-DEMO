@description('Name of the Network Security Group')
param nsgName string

@description('Location for the NSG')
param location string

@description('Array of security rules')
param securityRules array = []

@description('Tags for the resource')
param tags object = {}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      for rule in securityRules: {
        name: rule.name
        properties: {
          priority: rule.priority
          direction: rule.direction
          access: rule.access
          protocol: rule.protocol
          sourcePortRange: contains(rule, 'sourcePortRange') ? rule.sourcePortRange : '*'
          destinationPortRange: contains(rule, 'destinationPortRange') ? rule.destinationPortRange : null
          destinationPortRanges: contains(rule, 'destinationPortRanges') ? rule.destinationPortRanges : []
          sourceAddressPrefix: contains(rule, 'sourceAddressPrefix') ? rule.sourceAddressPrefix : '*'
          destinationAddressPrefix: contains(rule, 'destinationAddressPrefix') ? rule.destinationAddressPrefix : '*'
        }
      }
    ]
  }
}

output nsgId string = nsg.id
output nsgName string = nsg.name
