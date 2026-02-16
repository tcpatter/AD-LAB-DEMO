targetScope = 'subscription'

// ─── Parameters ─────────────────────────────────────────────────────────────

@description('Deployment phase: infra or vms')
@allowed(['infra', 'vms'])
param deployPhase string

@description('Admin username for all VMs')
param adminUsername string

@description('Admin password for all VMs')
@secure()
param adminPassword string

@description('Safe Mode Administrator Password for AD DS')
@secure()
param safeModePassword string

@description('Storage account name (globally unique)')
param storageAccountName string

@description('SAS token for accessing scripts in blob storage')
@secure()
param scriptSasToken string = ''

@description('Source IP address allowed for direct RDP access (e.g. your public IP)')
param adminSourceIP string = ''

@description('Tags applied to all resources')
param tags object = {
  project: 'AD-Lab'
  environment: 'lab'
}

// ─── Variables ──────────────────────────────────────────────────────────────

var eastRegion = 'eastus2'
var westRegion = 'centralus'
var rgNameEast = 'rg-ADLab-East'
var rgNameWest = 'rg-ADLab-West'

var eastVnetName = 'vnet-adlab-east'
var westVnetName = 'vnet-adlab-west'

// ─── Resource Groups ────────────────────────────────────────────────────────

resource rgEast 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployPhase == 'infra') {
  name: rgNameEast
  location: eastRegion
  tags: tags
}

resource rgWest 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployPhase == 'infra') {
  name: rgNameWest
  location: westRegion
  tags: tags
}

// Use existing RGs for phases after infra
resource rgEastExisting 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (deployPhase != 'infra') {
  name: rgNameEast
}

resource rgWestExisting 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (deployPhase != 'infra') {
  name: rgNameWest
}

// ─── Phase: infra ───────────────────────────────────────────────────────────

// East NSGs
module nsgEastDc 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'nsg-east-dc'
  params: {
    nsgName: 'nsg-adlab-east-dc'
    location: eastRegion
    tags: tags
    securityRules: concat([
      {
        name: 'AllowRDP'
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '3389'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
      }
    ], adminSourceIP != '' ? [
      {
        name: 'AllowRDP-AdminIP'
        priority: 110
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '3389'
        sourceAddressPrefix: adminSourceIP
        destinationAddressPrefix: '*'
      }
    ] : [])
  }
}

module nsgEastApp 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'nsg-east-app'
  params: {
    nsgName: 'nsg-adlab-east-app'
    location: eastRegion
    tags: tags
    securityRules: [
      {
        name: 'AllowRDP'
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '3389'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
      }
      {
        name: 'AllowHTTPS'
        priority: 110
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '443'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
      {
        name: 'AllowHTTP'
        priority: 120
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '80'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    ]
  }
}

module nsgEastBastion 'modules/network/nsg-bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'nsg-east-bastion'
  params: {
    nsgName: 'nsg-adlab-east-bastion'
    location: eastRegion
    tags: tags
  }
}

// West NSGs
module nsgWestDc 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgWest
  name: 'nsg-west-dc'
  params: {
    nsgName: 'nsg-adlab-west-dc'
    location: westRegion
    tags: tags
    securityRules: [
      {
        name: 'AllowRDP'
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '3389'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
      }
    ]
  }
}

module nsgWestApp 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgWest
  name: 'nsg-west-app'
  params: {
    nsgName: 'nsg-adlab-west-app'
    location: westRegion
    tags: tags
    securityRules: [
      {
        name: 'AllowRDP'
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '3389'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
      }
      {
        name: 'AllowHTTPS'
        priority: 110
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '443'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
      {
        name: 'AllowHTTP'
        priority: 120
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        destinationPortRange: '80'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    ]
  }
}

module nsgWestBastion 'modules/network/nsg-bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgWest
  name: 'nsg-west-bastion'
  params: {
    nsgName: 'nsg-adlab-west-bastion'
    location: westRegion
    tags: tags
  }
}

// East VNet
module vnetEast 'modules/network/vnet.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'vnet-east'
  params: {
    vnetName: eastVnetName
    location: eastRegion
    addressPrefix: '10.1.0.0/16'
    tags: tags
    subnets: [
      {
        name: 'snet-dc'
        addressPrefix: '10.1.1.0/24'
        nsgId: nsgEastDc.outputs.nsgId
      }
      {
        name: 'snet-app'
        addressPrefix: '10.1.2.0/24'
        nsgId: nsgEastApp.outputs.nsgId
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.1.3.0/24'
        nsgId: nsgEastBastion.outputs.nsgId
      }
    ]
  }
}

// West VNet
module vnetWest 'modules/network/vnet.bicep' = if (deployPhase == 'infra') {
  scope: rgWest
  name: 'vnet-west'
  params: {
    vnetName: westVnetName
    location: westRegion
    addressPrefix: '10.3.0.0/16'
    tags: tags
    subnets: [
      {
        name: 'snet-dc'
        addressPrefix: '10.3.1.0/24'
        nsgId: nsgWestDc.outputs.nsgId
      }
      {
        name: 'snet-app'
        addressPrefix: '10.3.2.0/24'
        nsgId: nsgWestApp.outputs.nsgId
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.3.3.0/24'
        nsgId: nsgWestBastion.outputs.nsgId
      }
    ]
  }
}

// Bastion hosts
module bastionEast 'modules/network/bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'bastion-east'
  params: {
    bastionName: 'bas-adlab-east'
    location: eastRegion
    subnetId: vnetEast.outputs.subnetIds[2]
    tags: tags
  }
}

module bastionWest 'modules/network/bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgWest
  name: 'bastion-west'
  params: {
    bastionName: 'bas-adlab-west'
    location: westRegion
    subnetId: vnetWest.outputs.subnetIds[2]
    tags: tags
  }
}

// Storage account
module storage 'modules/storage/storageaccount.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'storage'
  params: {
    storageAccountName: storageAccountName
    location: eastRegion
    tags: tags
  }
}

// ─── Phase: vms ─────────────────────────────────────────────────────────────

// Need to reference existing VNets for VM deployment
resource vnetEastExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: eastVnetName
}

resource vnetWestExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: westVnetName
}

// Existing NSGs for VM NIC associations
resource nsgEastDcExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'nsg-adlab-east-dc'
}

resource nsgEastAppExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'nsg-adlab-east-app'
}

resource nsgWestDcExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: 'nsg-adlab-west-dc'
}

resource nsgWestAppExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: 'nsg-adlab-west-app'
}

// ── East VMs ──

module vmDvdc01 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'vm-dvdc01'
  params: {
    vmName: 'DVDC01'
    location: eastRegion
    subnetId: '${vnetEastExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.1.1.4'
    createPublicIp: false
    nsgId: nsgEastDcExisting.id
    dataDiskSizeGB: 20
    tags: tags
  }
}

module vmDvdc02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'vm-dvdc02'
  params: {
    vmName: 'DVDC02'
    location: eastRegion
    subnetId: '${vnetEastExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.1.1.5'
    createPublicIp: false
    nsgId: nsgEastDcExisting.id
    dataDiskSizeGB: 20
    tags: tags
  }
}

module vmDvas01 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'vm-dvas01'
  params: {
    vmName: 'DVAS01'
    location: eastRegion
    subnetId: '${vnetEastExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.1.2.4'
    createPublicIp: false
    nsgId: nsgEastAppExisting.id
    tags: tags
  }
}

module vmDvas02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'vm-dvas02'
  params: {
    vmName: 'DVAS02'
    location: eastRegion
    subnetId: '${vnetEastExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.1.2.5'
    createPublicIp: false
    nsgId: nsgEastAppExisting.id
    tags: tags
  }
}

// ── West VMs ──

module vmDvdc03 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: 'vm-dvdc03'
  params: {
    vmName: 'DVDC03'
    location: westRegion
    subnetId: '${vnetWestExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.1.4'
    createPublicIp: false
    nsgId: nsgWestDcExisting.id
    dataDiskSizeGB: 20
    tags: tags
  }
}

module vmDvas03 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: 'vm-dvas03'
  params: {
    vmName: 'DVAS03'
    location: westRegion
    subnetId: '${vnetWestExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.2.4'
    createPublicIp: false
    nsgId: nsgWestAppExisting.id
    tags: tags
  }
}

module vmDvas04 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgWestExisting
  name: 'vm-dvas04'
  params: {
    vmName: 'DVAS04'
    location: westRegion
    subnetId: '${vnetWestExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.2.5'
    createPublicIp: false
    nsgId: nsgWestAppExisting.id
    tags: tags
  }
}
