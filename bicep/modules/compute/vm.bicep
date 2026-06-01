@description('Name of the Virtual Machine')
param vmName string

@description('Location for the VM')
param location string

@description('Subnet ID for the NIC')
param subnetId string

@description('VM size')
param vmSize string = 'Standard_D2als_v7'

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('Static private IP address (empty = dynamic)')
param privateIpAddress string = ''

@description('Whether to create a public IP')
param createPublicIp bool = false

@description('NSG ID to associate with the NIC')
param nsgId string = ''

@description('Size of optional data disk in GB (0 = no data disk)')
param dataDiskSizeGB int = 0

@description('Daily auto-shutdown time in 24h HHmm format (empty = disabled)')
param autoShutdownTime string = ''

@description('Tags for the resource')
param tags object = {}

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (createPublicIp) {
  name: '${vmName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: empty(privateIpAddress) ? 'Dynamic' : 'Static'
          privateIPAddress: empty(privateIpAddress) ? null : privateIpAddress
          subnet: {
            id: subnetId
          }
          publicIPAddress: createPublicIp ? {
            id: pip.id
          } : null
        }
      }
    ]
    networkSecurityGroup: !empty(nsgId) ? {
      id: nsgId
    } : null
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: dataDiskSizeGB > 0 ? [
        {
          name: '${vmName}-datadisk'
          diskSizeGB: dataDiskSizeGB
          lun: 0
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ] : []
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(autoShutdownTime)) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'Eastern Standard Time'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = createPublicIp ? pip.properties.ipAddress : ''
