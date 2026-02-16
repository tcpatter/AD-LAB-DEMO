using './main.bicep'

param deployPhase = 'infra'

param adminUsername = 'labadmin'

param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD')

param safeModePassword = readEnvironmentVariable('SAFE_MODE_PASSWORD')

param storageAccountName = 'stadlabscripts01'

param scriptSasToken = readEnvironmentVariable('SCRIPT_SAS_TOKEN', '')

param tags = {
  project: 'AD-Lab'
  environment: 'lab'
}
