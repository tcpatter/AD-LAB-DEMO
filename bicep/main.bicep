targetScope = 'subscription'

// ─── Parameters ─────────────────────────────────────────────────────────────

@description('Deployment phase: infra, vms, primarydc, dns-peering, secondarydc, appservers, adconfig')
@allowed(['infra', 'vms', 'primarydc', 'dns-peering', 'secondarydc', 'appservers', 'adconfig'])
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
var centralRegion = 'northcentralus'
var rgNameEast = 'rg-ADLab-East'
var rgNameCentral = 'rg-ADLab-Central'

var eastVnetName = 'vnet-adlab-east'
var centralVnetName = 'vnet-adlab-central'

var domainName = 'managed-connections.net'
var netbiosName = 'MANAGEDCONN'

var primaryDcIp = '10.1.1.4'
var secondaryDcIp = '10.2.1.4'

var scriptBaseUrl = 'https://${storageAccountName}.blob.${environment().suffixes.storage}/scripts/'

// ─── Resource Groups ────────────────────────────────────────────────────────

resource rgEast 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployPhase == 'infra') {
  name: rgNameEast
  location: eastRegion
  tags: tags
}

resource rgCentral 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployPhase == 'infra') {
  name: rgNameCentral
  location: centralRegion
  tags: tags
}

// Use existing RGs for phases after infra
resource rgEastExisting 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (deployPhase != 'infra') {
  name: rgNameEast
}

resource rgCentralExisting 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (deployPhase != 'infra') {
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

module nsgCentralBastion 'modules/network/nsg-bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'nsg-central-bastion'
  params: {
    nsgName: 'nsg-adlab-central-bastion'
    location: centralRegion
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

// Central VNet
module vnetCentral 'modules/network/vnet.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'vnet-central'
  params: {
    vnetName: centralVnetName
    location: centralRegion
    addressPrefix: '10.2.0.0/16'
    tags: tags
    subnets: [
      {
        name: 'snet-dc'
        addressPrefix: '10.2.1.0/24'
        nsgId: nsgCentralDc.outputs.nsgId
      }
      {
        name: 'snet-app'
        addressPrefix: '10.2.2.0/24'
        nsgId: nsgCentralApp.outputs.nsgId
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.2.3.0/24'
        nsgId: nsgCentralBastion.outputs.nsgId
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

module bastionCentral 'modules/network/bastion.bicep' = if (deployPhase == 'infra') {
  scope: rgCentral
  name: 'bastion-central'
  params: {
    bastionName: 'bas-adlab-central'
    location: centralRegion
    subnetId: vnetCentral.outputs.subnetIds[2]
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

// Need to reference existing VNets for VM deployment and peering
resource vnetEastExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms' || deployPhase == 'dns-peering') {
  scope: rgEastExisting
  name: eastVnetName
}

resource vnetCentralExisting 'Microsoft.Network/virtualNetworks@2024-01-01' existing = if (deployPhase == 'vms' || deployPhase == 'dns-peering') {
  scope: rgCentralExisting
  name: centralVnetName
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

resource nsgCentralDcExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgCentralExisting
  name: 'nsg-adlab-central-dc'
}

resource nsgCentralAppExisting 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = if (deployPhase == 'vms') {
  scope: rgCentralExisting
  name: 'nsg-adlab-central-app'
}

module vmDvdc01 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgEastExisting
  name: 'vm-dvdc01'
  params: {
    vmName: 'DVDC01'
    location: eastRegion
    subnetId: '${vnetEastExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: primaryDcIp
    createPublicIp: true
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
    createPublicIp: true
    nsgId: nsgEastAppExisting.id
    tags: tags
  }
}

module vmDvdc02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgCentralExisting
  name: 'vm-dvdc02'
  params: {
    vmName: 'DVDC02'
    location: centralRegion
    subnetId: '${vnetCentralExisting.id}/subnets/snet-dc'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: secondaryDcIp
    createPublicIp: true
    nsgId: nsgCentralDcExisting.id
    dataDiskSizeGB: 20
    tags: tags
  }
}

module vmDvas02 'modules/compute/vm.bicep' = if (deployPhase == 'vms') {
  scope: rgCentralExisting
  name: 'vm-dvas02'
  params: {
    vmName: 'DVAS02'
    location: centralRegion
    subnetId: '${vnetCentralExisting.id}/subnets/snet-app'
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIpAddress: '10.2.2.4'
    createPublicIp: true
    nsgId: nsgCentralAppExisting.id
    tags: tags
  }
}

// ─── Phase: primarydc ───────────────────────────────────────────────────────

module cseDvdc01 'modules/compute/vm-extension.bicep' = if (deployPhase == 'primarydc') {
  scope: rgEastExisting
  name: 'cse-dvdc01'
  params: {
    vmName: 'DVDC01'
    location: eastRegion
    scriptUri: '${scriptBaseUrl}Promote-PrimaryDC.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Promote-PrimaryDC.ps1 -DomainName ${domainName} -NetBIOSName ${netbiosName} -SafeModePassword "${safeModePassword}"'
    tags: tags
  }
}

// ─── Phase: dns-peering ─────────────────────────────────────────────────────

// VNet DNS update is handled by deploy.ps1 via Azure CLI/PowerShell
// Peering is deployed here

module peeringEastToCentral 'modules/network/peering.bicep' = if (deployPhase == 'dns-peering') {
  scope: rgEastExisting
  name: 'peering-east-to-central'
  params: {
    peeringName: 'peer-east-to-central'
    localVnetName: eastVnetName
    remoteVnetId: vnetCentralExisting.id
  }
}

module peeringCentralToEast 'modules/network/peering.bicep' = if (deployPhase == 'dns-peering') {
  scope: rgCentralExisting
  name: 'peering-central-to-east'
  params: {
    peeringName: 'peer-central-to-east'
    localVnetName: centralVnetName
    remoteVnetId: vnetEastExisting.id
  }
}

// ─── Phase: secondarydc ─────────────────────────────────────────────────────

module cseDvdc02 'modules/compute/vm-extension.bicep' = if (deployPhase == 'secondarydc') {
  scope: rgCentralExisting
  name: 'cse-dvdc02'
  params: {
    vmName: 'DVDC02'
    location: centralRegion
    scriptUri: '${scriptBaseUrl}Promote-SecondaryDC.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Promote-SecondaryDC.ps1 -DomainName ${domainName} -PrimaryDcIp ${primaryDcIp} -SafeModePassword "${safeModePassword}" -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

// ─── Phase: appservers ──────────────────────────────────────────────────────

module cseDvas01 'modules/compute/vm-extension.bicep' = if (deployPhase == 'appservers') {
  scope: rgEastExisting
  name: 'cse-dvas01'
  params: {
    vmName: 'DVAS01'
    location: eastRegion
    scriptUri: '${scriptBaseUrl}Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Join-DomainAndConfigure.ps1 -DomainName ${domainName} -DcIpAddress ${primaryDcIp} -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}

module cseDvas02 'modules/compute/vm-extension.bicep' = if (deployPhase == 'appservers') {
  scope: rgCentralExisting
  name: 'cse-dvas02'
  params: {
    vmName: 'DVAS02'
    location: centralRegion
    scriptUri: '${scriptBaseUrl}Join-DomainAndConfigure.ps1${scriptSasToken}'
    commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Join-DomainAndConfigure.ps1 -DomainName ${domainName} -DcIpAddress ${secondaryDcIp} -DomainAdminUser "${adminUsername}" -DomainAdminPassword "${adminPassword}"'
    tags: tags
  }
}
