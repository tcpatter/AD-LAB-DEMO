targetScope = 'subscription'

// ─── Parameters ─────────────────────────────────────────────────────────────

@description('Deployment phase: infra, vms, primarydc, domainjoin, or groups')
@allowed(['infra', 'vms', 'primarydc', 'domainjoin', 'groups'])
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
var centralRegion = 'centralus'
var rgNameEast = 'rg-east'
var rgNameCentral = 'rg-central'

var eastVnetName = 'vnet-adlab-east'
var centralVnetName = 'vnet-adlab-central'

// Domain configuration
var domainName = 'managed-connections.net'
var netbiosName = 'MANAGED'
var domainDN = 'DC=${replace(domainName, '.', ',DC=')}'
var scriptBaseUrl = 'https://${storageAccountName}.blob.core.windows.net/scripts'

// ─── Resource Groups (pre-existing) ─────────────────────────────────────────

resource rgEast 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: rgNameEast
}

resource rgCentral 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: rgNameCentral
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

// Central NSGs
module nsgCentralDc 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'nsg-central-dc'
  params: {
    nsgName: 'nsg-adlab-central-dc'
    location: centralRegion
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

module nsgCentralApp 'modules/network/nsg.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'nsg-central-app'
  params: {
    nsgName: 'nsg-adlab-central-app'
    location: centralRegion
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

// Central VNet — no Bastion (uses East Bastion via VNet peering)
module vnetCentral 'modules/network/vnet.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'vnet-central'
  params: {
    vnetName: centralVnetName
    location: centralRegion
    addressPrefix: '10.3.0.0/16'
    tags: tags
    subnets: [
      {
        name: 'snet-dc'
        addressPrefix: '10.3.1.0/24'
        nsgId: nsgCentralDc.outputs.nsgId
      }
      {
        name: 'snet-app'
        addressPrefix: '10.3.2.0/24'
        nsgId: nsgCentralApp.outputs.nsgId
      }
    ]
  }
}

// East Bastion (Standard SKU — tunneling enabled; reaches Central VMs via peering)
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

// VNet peering — East ↔ Central (bidirectional, enables single Bastion to reach both regions)
module peeringEastToCentral 'modules/network/peering.bicep' = if (deployPhase == 'infra') {
  scope: rgEast
  name: 'peering-east-to-central'
  params: {
    peeringName: 'peer-east-to-central'
    localVnetName: eastVnetName
    remoteVnetId: vnetCentral.outputs.vnetId
  }
  dependsOn: [vnetEast, vnetCentral]
}

module peeringCentralToEast 'modules/network/peering.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'peering-central-to-east'
  params: {
    peeringName: 'peer-central-to-east'
    localVnetName: centralVnetName
    remoteVnetId: vnetEast.outputs.vnetId
  }
  dependsOn: [vnetEast, vnetCentral]
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

resource vnetEastExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEast
  name: eastVnetName
}

resource vnetCentralExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgCentral
  name: centralVnetName
}

resource nsgEastDcExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEast
  name: 'nsg-adlab-east-dc'
}

resource nsgEastAppExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgEast
  name: 'nsg-adlab-east-app'
}

resource nsgCentralDcExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgCentral
  name: 'nsg-adlab-central-dc'
}

resource nsgCentralAppExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgCentral
  name: 'nsg-adlab-central-app'
}

// ── East VMs ──

module vmDvdc01 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEast
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
    autoShutdownTime: '1900'
    tags: tags
  }
}

module vmDvdc02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEast
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
    autoShutdownTime: '1900'
    tags: tags
  }
}

module vmDvas01 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEast
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
    autoShutdownTime: '1900'
    tags: tags
  }
}

module vmDvas02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEast
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
    autoShutdownTime: '1900'
    tags: tags
  }
}

// ── Central VMs ──

module vmDvdc03 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgCentral
  name: 'vm-dvdc03'
  params: {
    vmName: 'DVDC03'
    location: centralRegion
    subnetId: '${vnetCentralExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.1.4'
    createPublicIp: false
    nsgId: nsgCentralDcExisting.id
    dataDiskSizeGB: 20
    autoShutdownTime: '1900'
    tags: tags
  }
}

module vmDvas03 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgCentral
  name: 'vm-dvas03'
  params: {
    vmName: 'DVAS03'
    location: centralRegion
    subnetId: '${vnetCentralExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.2.4'
    createPublicIp: false
    nsgId: nsgCentralAppExisting.id
    autoShutdownTime: '1900'
    tags: tags
  }
}

module vmDvas04 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgCentral
  name: 'vm-dvas04'
  params: {
    vmName: 'DVAS04'
    location: centralRegion
    subnetId: '${vnetCentralExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.3.2.5'
    createPublicIp: false
    nsgId: nsgCentralAppExisting.id
    autoShutdownTime: '1900'
    tags: tags
  }
}

// ─── Phase: primarydc ──────────────────────────────────────────────────────

resource vmDvdc01Existing 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'primarydc') {
  scope: rgEast
  name: 'DVDC01'
}

module cseDvdc01Promote 'modules/compute/vm-extension.bicep' = if (deployPhase == 'primarydc') {
  scope: rgEast
  name: 'cse-dvdc01-promote'
  params: {
    vmName: vmDvdc01Existing.name
    location: eastRegion
    scriptUri: '${scriptBaseUrl}/Promote-PrimaryDC.ps1?${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Promote-PrimaryDC.ps1 -DomainName "${domainName}" -NetBIOSName "${netbiosName}" -SafeModePassword "${safeModePassword}"'
    tags: tags
  }
}

// ─── Phase: domainjoin ───────────────────────────────────────────────────────

// ── East member servers ──

resource vmDvas01Existing 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'domainjoin') {
  scope: rgEast
  name: 'DVAS01'
}

resource vmDvas02Existing 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'domainjoin') {
  scope: rgEast
  name: 'DVAS02'
}

module cseDvas01Join 'modules/compute/vm-extension.bicep' = if (deployPhase == 'domainjoin') {
  scope: rgEast
  name: 'cse-dvas01-join'
  params: {
    vmName: vmDvas01Existing.name
    location: eastRegion
    scriptUri: '${scriptBaseUrl}/Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Join-DomainAndConfigure.ps1 -DomainName "${domainName}" -DcIpAddress "10.1.1.4" -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

module cseDvas02Join 'modules/compute/vm-extension.bicep' = if (deployPhase == 'domainjoin') {
  scope: rgEast
  name: 'cse-dvas02-join'
  params: {
    vmName: vmDvas02Existing.name
    location: eastRegion
    scriptUri: '${scriptBaseUrl}/Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Join-DomainAndConfigure.ps1 -DomainName "${domainName}" -DcIpAddress "10.1.1.4" -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

// ── Central member servers ──

resource vmDvas03Existing 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'domainjoin') {
  scope: rgCentral
  name: 'DVAS03'
}

resource vmDvas04Existing 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'domainjoin') {
  scope: rgCentral
  name: 'DVAS04'
}

module cseDvas03Join 'modules/compute/vm-extension.bicep' = if (deployPhase == 'domainjoin') {
  scope: rgCentral
  name: 'cse-dvas03-join'
  params: {
    vmName: vmDvas03Existing.name
    location: centralRegion
    scriptUri: '${scriptBaseUrl}/Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Join-DomainAndConfigure.ps1 -DomainName "${domainName}" -DcIpAddress "10.1.1.4" -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

module cseDvas04Join 'modules/compute/vm-extension.bicep' = if (deployPhase == 'domainjoin') {
  scope: rgCentral
  name: 'cse-dvas04-join'
  params: {
    vmName: vmDvas04Existing.name
    location: centralRegion
    scriptUri: '${scriptBaseUrl}/Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Join-DomainAndConfigure.ps1 -DomainName "${domainName}" -DcIpAddress "10.1.1.4" -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

// ─── Phase: groups ───────────────────────────────────────────────────────────

resource vmDvdc01Groups 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (deployPhase == 'groups') {
  scope: rgEast
  name: 'DVDC01'
}

module cseDvdc01Groups 'modules/compute/vm-extension.bicep' = if (deployPhase == 'groups') {
  scope: rgEast
  name: 'cse-dvdc01-groups'
  params: {
    vmName: vmDvdc01Groups.name
    location: eastRegion
    scriptUri: '${scriptBaseUrl}/Create-DepartmentGroups.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Bypass -File Create-DepartmentGroups.ps1 -DomainDN "${domainDN}"'
    tags: tags
  }
}
