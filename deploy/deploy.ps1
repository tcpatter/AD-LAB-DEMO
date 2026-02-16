#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute

<#
.SYNOPSIS
    7-phase deployment orchestrator for the AD Lab environment.
.DESCRIPTION
    Deploys the AD Lab in phases to respect dependency ordering:
      1. Infra    - RGs, VNets, NSGs, Bastion, Storage, upload scripts
      2. VMs      - All 4 VMs (Azure default DNS, no domain config)
      3. PrimaryDC - CSE on DVDC01 → promote → wait for reboot + stabilize
      4. DNS+Peering - Update VNet DNS to DC IPs, create bidirectional peering
      5. SecondaryDC - CSE on DVDC02 → replicate → wait
      6. AppServers  - CSE on DVAS01/DVAS02 → domain join + install roles
      7. ADConfig    - OUs → Users via Invoke-AzVMRunCommand
.PARAMETER Phase
    Which phase(s) to run: 1-7, 'all', or comma-separated (e.g., '1,2,3')
.PARAMETER AdminPassword
    Password for the VM local admin account
.PARAMETER SafeModePassword
    DSRM password for Active Directory
.EXAMPLE
    .\deploy.ps1 -Phase all -AdminPassword (Read-Host -AsSecureString) -SafeModePassword (Read-Host -AsSecureString)
#>

param(
    [Parameter(Mandatory)]
    [string]$Phase,

    [Parameter(Mandatory)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory)]
    [SecureString]$SafeModePassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration ───────────────────────────────────────────────────────────

$config = @{
    SubscriptionId      = (Get-AzContext).Subscription.Id
    Location            = 'eastus2'
    BicepPath           = Join-Path $PSScriptRoot '..\bicep\main.bicep'
    DeploymentName      = "adlab-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    AdminUsername        = 'labadmin'
    StorageAccountName  = 'stadlabscripts01'
    RgEast              = 'rg-ADLab-East'
    RgCentral           = 'rg-ADLab-Central'
    VnetEast            = 'vnet-adlab-east'
    VnetCentral         = 'vnet-adlab-central'
    PrimaryDcIp         = '10.1.1.4'
    SecondaryDcIp       = '10.2.1.4'
    DomainName          = 'managed-connections.net'
    DomainDN            = 'DC=managed-connections,DC=net'
    ScriptsPath         = Join-Path $PSScriptRoot '..\scripts\powershell'
    CsvPath             = Join-Path $PSScriptRoot '..\scripts\python\data\users.csv'
}

# Convert secure strings to plain text for BICEP parameters
$adminPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
)
$safeModePwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SafeModePassword)
)

# ─── Helper Functions ────────────────────────────────────────────────────────

function Deploy-BicepPhase {
    param(
        [string]$PhaseName,
        [hashtable]$ExtraParams = @{}
    )

    $params = @{
        deployPhase        = $PhaseName
        adminUsername       = $config.AdminUsername
        adminPassword      = $adminPwd
        safeModePassword   = $safeModePwd
        storageAccountName = $config.StorageAccountName
    }

    foreach ($key in $ExtraParams.Keys) {
        $params[$key] = $ExtraParams[$key]
    }

    $deployName = "adlab-$PhaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "`n═══ Deploying phase: $PhaseName ($deployName) ═══" -ForegroundColor Cyan

    New-AzSubscriptionDeployment `
        -Name $deployName `
        -Location $config.Location `
        -TemplateFile $config.BicepPath `
        -TemplateParameterObject $params `
        -Verbose
}

function Wait-VMReboot {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [int]$TimeoutMinutes = 15
    )

    Write-Host "Waiting for $VMName to reboot and stabilize..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    # Wait for VM to go offline briefly
    Start-Sleep -Seconds 60

    # Poll until VM agent reports Ready
    while ((Get-Date) -lt $deadline) {
        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
            $agentStatus = $vm.VMAgent.Statuses | Where-Object { $_.Code -eq 'ProvisioningState/succeeded' }
            if ($agentStatus) {
                Write-Host "$VMName is back online and agent is ready." -ForegroundColor Green
                # Additional stabilization time for DC services
                Start-Sleep -Seconds 60
                return
            }
        }
        catch {
            # VM might be mid-reboot
        }
        Write-Host "  Still waiting for $VMName..." -ForegroundColor Gray
        Start-Sleep -Seconds 30
    }

    throw "Timeout waiting for $VMName to come back online after $TimeoutMinutes minutes."
}

function Upload-ScriptsToStorage {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $config.RgEast -Name $config.StorageAccountName
    $ctx = $storageAccount.Context

    $scripts = Get-ChildItem -Path $config.ScriptsPath -Filter '*.ps1'
    foreach ($script in $scripts) {
        Write-Host "  Uploading $($script.Name)..." -ForegroundColor Gray
        Set-AzStorageBlobContent `
            -File $script.FullName `
            -Container 'scripts' `
            -Blob $script.Name `
            -Context $ctx `
            -Force | Out-Null
    }

    # Upload CSV if it exists
    if (Test-Path $config.CsvPath) {
        Write-Host "  Uploading users.csv..." -ForegroundColor Gray
        Set-AzStorageBlobContent `
            -File $config.CsvPath `
            -Container 'scripts' `
            -Blob 'users.csv' `
            -Context $ctx `
            -Force | Out-Null
    }

    # Generate SAS token valid for 4 hours
    $sasToken = New-AzStorageContainerSASToken `
        -Name 'scripts' `
        -Context $ctx `
        -Permission 'r' `
        -ExpiryTime (Get-Date).AddHours(4)

    return $sasToken
}

# ─── Phase Execution ─────────────────────────────────────────────────────────

# Determine which phases to run
$phases = if ($Phase -eq 'all') {
    1..7
} else {
    $Phase -split ',' | ForEach-Object { [int]$_.Trim() }
}

$sasToken = ''

foreach ($p in $phases) {
    switch ($p) {
        1 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 1: Infrastructure                 ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            Deploy-BicepPhase -PhaseName 'infra'

            Write-Host "`nUploading scripts to storage..." -ForegroundColor Yellow
            $sasToken = Upload-ScriptsToStorage
            Write-Host "Scripts uploaded. SAS token generated." -ForegroundColor Green
        }

        2 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 2: Virtual Machines               ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            Deploy-BicepPhase -PhaseName 'vms'
        }

        3 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 3: Primary Domain Controller      ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            if (-not $sasToken) {
                Write-Host "Generating SAS token..." -ForegroundColor Yellow
                $sasToken = Upload-ScriptsToStorage
            }

            Deploy-BicepPhase -PhaseName 'primarydc' -ExtraParams @{ scriptSasToken = $sasToken }
            Wait-VMReboot -ResourceGroupName $config.RgEast -VMName 'DVDC01' -TimeoutMinutes 20

            # Configure DNS forwarders on primary DC
            Write-Host "Configuring DNS forwarders on DVDC01..." -ForegroundColor Yellow
            Invoke-AzVMRunCommand -ResourceGroupName $config.RgEast -VMName 'DVDC01' `
                -CommandId 'RunPowerShellScript' `
                -ScriptPath (Join-Path $config.ScriptsPath 'Configure-DNS-Forwarders.ps1')
        }

        4 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 4: DNS Update + VNet Peering      ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            # Update East VNet DNS to Primary DC
            Write-Host "Updating East VNet DNS to $($config.PrimaryDcIp)..." -ForegroundColor Yellow
            $vnetEast = Get-AzVirtualNetwork -ResourceGroupName $config.RgEast -Name $config.VnetEast
            $vnetEast.DhcpOptions.DnsServers = @($config.PrimaryDcIp)
            $vnetEast | Set-AzVirtualNetwork | Out-Null

            # Update Central VNet DNS to Primary DC (secondary will be added later)
            Write-Host "Updating Central VNet DNS to $($config.PrimaryDcIp)..." -ForegroundColor Yellow
            $vnetCentral = Get-AzVirtualNetwork -ResourceGroupName $config.RgCentral -Name $config.VnetCentral
            $vnetCentral.DhcpOptions.DnsServers = @($config.PrimaryDcIp)
            $vnetCentral | Set-AzVirtualNetwork | Out-Null

            # Deploy peering
            Deploy-BicepPhase -PhaseName 'dns-peering'

            Write-Host "DNS updated and VNet peering established." -ForegroundColor Green
        }

        5 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 5: Secondary Domain Controller    ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            if (-not $sasToken) {
                Write-Host "Generating SAS token..." -ForegroundColor Yellow
                $sasToken = Upload-ScriptsToStorage
            }

            Deploy-BicepPhase -PhaseName 'secondarydc' -ExtraParams @{ scriptSasToken = $sasToken }
            Wait-VMReboot -ResourceGroupName $config.RgCentral -VMName 'DVDC02' -TimeoutMinutes 20

            # Configure DNS forwarders on secondary DC
            Write-Host "Configuring DNS forwarders on DVDC02..." -ForegroundColor Yellow
            Invoke-AzVMRunCommand -ResourceGroupName $config.RgCentral -VMName 'DVDC02' `
                -CommandId 'RunPowerShellScript' `
                -ScriptPath (Join-Path $config.ScriptsPath 'Configure-DNS-Forwarders.ps1')

            # Update both VNets to use both DCs for DNS
            Write-Host "Updating VNet DNS to both DCs..." -ForegroundColor Yellow
            $bothDns = @($config.PrimaryDcIp, $config.SecondaryDcIp)

            $vnetEast = Get-AzVirtualNetwork -ResourceGroupName $config.RgEast -Name $config.VnetEast
            $vnetEast.DhcpOptions.DnsServers = $bothDns
            $vnetEast | Set-AzVirtualNetwork | Out-Null

            $vnetCentral = Get-AzVirtualNetwork -ResourceGroupName $config.RgCentral -Name $config.VnetCentral
            $vnetCentral.DhcpOptions.DnsServers = $bothDns
            $vnetCentral | Set-AzVirtualNetwork | Out-Null

            Write-Host "Secondary DC promoted and DNS updated." -ForegroundColor Green
        }

        6 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 6: App Servers (Domain Join)      ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            if (-not $sasToken) {
                Write-Host "Generating SAS token..." -ForegroundColor Yellow
                $sasToken = Upload-ScriptsToStorage
            }

            Deploy-BicepPhase -PhaseName 'appservers' -ExtraParams @{ scriptSasToken = $sasToken }

            # Wait for both app servers to reboot after domain join
            Wait-VMReboot -ResourceGroupName $config.RgEast -VMName 'DVAS01' -TimeoutMinutes 15
            Wait-VMReboot -ResourceGroupName $config.RgCentral -VMName 'DVAS02' -TimeoutMinutes 15

            Write-Host "App servers joined to domain and configured." -ForegroundColor Green
        }

        7 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 7: AD Configuration (OUs + Users) ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            # Create OU structure
            Write-Host "Creating OU structure on DVDC01..." -ForegroundColor Yellow
            Invoke-AzVMRunCommand -ResourceGroupName $config.RgEast -VMName 'DVDC01' `
                -CommandId 'RunPowerShellScript' `
                -ScriptString "& '$($config.ScriptsPath)\Configure-OUs.ps1' -DomainDN '$($config.DomainDN)'" `
                -ErrorAction Stop

            # Upload and import users
            Write-Host "Importing AD users on DVDC01..." -ForegroundColor Yellow

            # First, download CSV to DC
            $csvContent = Get-Content -Path $config.CsvPath -Raw
            $downloadScript = @"
`$csvContent = @'
$csvContent
'@
`$csvContent | Out-File -FilePath 'C:\Temp\users.csv' -Encoding UTF8
New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
"@
            Invoke-AzVMRunCommand -ResourceGroupName $config.RgEast -VMName 'DVDC01' `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $downloadScript

            # Then create users from CSV
            $createUsersScript = @"
New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
# CSV was uploaded in previous step
Import-Module ActiveDirectory
`$users = Import-Csv -Path 'C:\Temp\users.csv'
`$created = 0
foreach (`$user in `$users) {
    `$existing = Get-ADUser -Filter "SamAccountName -eq '`$(`$user.SamAccountName)'" -ErrorAction SilentlyContinue
    if (`$existing) { continue }
    `$pwd = ConvertTo-SecureString `$user.Password -AsPlainText -Force
    New-ADUser -Name `$user.DisplayName -GivenName `$user.FirstName -Surname `$user.LastName ``
        -DisplayName `$user.DisplayName -SamAccountName `$user.SamAccountName ``
        -UserPrincipalName `$user.UPN -Department `$user.Department -Title `$user.Role ``
        -Path `$user.OUPath -AccountPassword `$pwd -Enabled `$true -ChangePasswordAtLogon `$false
    `$created++
}
Write-Output "Created `$created users out of `$(`$users.Count) total."
"@
            Invoke-AzVMRunCommand -ResourceGroupName $config.RgEast -VMName 'DVDC01' `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $createUsersScript

            Write-Host "AD configuration complete." -ForegroundColor Green
        }
    }
}

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  Deployment Complete!                    ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host @"

Verification steps:
  1. RDP to DVDC01 via Bastion: Get-ADForest
  2. Check replication: repadmin /replsummary
  3. List computers: Get-ADComputer -Filter *
  4. List users: Get-ADUser -Filter * -SearchBase "OU=ADLab,$($config.DomainDN)" | Measure-Object
  5. Test IIS: Browse to DVAS01/DVAS02 private IPs
  6. Test File Share: \\DVAS01\Department
"@
