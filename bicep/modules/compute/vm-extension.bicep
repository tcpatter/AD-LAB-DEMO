@description('Name of the VM to attach the extension to')
param vmName string

@description('Location for the extension')
param location string

@description('URI of the script to execute')
param scriptUri string

@description('Command to execute')
param commandToExecute string

@description('Tags for the resource')
param tags object = {}

resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/CustomScriptExtension'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [scriptUri]
    }
    protectedSettings: {
      commandToExecute: commandToExecute
    }
  }
}

output extensionId string = vmExtension.id
