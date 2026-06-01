<#
.SYNOPSIS
    Stages AADConnectProvisioningAgentSetup.exe and AzureADConnect.msi on DVAS01-DVAS04.
.DESCRIPTION
    Uploads both installers to stadlabscripts01 blob storage (installers container),
    generates 24-hour SAS URLs, then downloads both files to C:\Temp on each app server
    via az vm run-command invoke.

    Installation must be done interactively via Azure Bastion RDP after this script
    completes — this script only stages the files.

    Estimated time: ~8 minutes (upload + 4 VM deliveries).

.PARAMETER ProvisioningAgentPath
    Local path to AADConnectProvisioningAgentSetup.exe.
    Default: repo root (one level above the deploy folder)

.PARAMETER AzureADConnectPath
    Local path to AzureADConnect.msi.
    Default: repo root (one level above the deploy folder)

.EXAMPLE
    .\deploy\Deploy-Installers-AppServers.ps1

.EXAMPLE
    .\deploy\Deploy-Installers-AppServers.ps1 `
        -ProvisioningAgentPath 'D:\Downloads\AADConnectProvisioningAgentSetup.exe' `
        -AzureADConnectPath 'D:\Downloads\AzureADConnect.msi'
#>

param(
    [string]$ProvisioningAgentPath = (Join-Path $PSScriptRoot '..\AADConnectProvisioningAgentSetup.exe'),
    [string]$AzureADConnectPath    = (Join-Path $PSScriptRoot '..\AzureADConnect.msi')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Subscription -------------------------------------------------------

az account set --subscription '64d83543-8eda-43a0-b42f-a92876dfb11d'
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context." }

# --- Configuration -------------------------------------------------------

$config = @{
    RgEast         = 'rg-east'
    RgCentral      = 'rg-central'
    StorageAccount = 'stadlabscripts01'
    StorageRg      = 'rg-east'
    ContainerName  = 'installers'
    BlobAgent      = 'AADConnectProvisioningAgentSetup.exe'
    BlobConnect    = 'AzureADConnect.msi'
}

$appServers = @(
    @{ RG = $config.RgEast;    Name = 'DVAS01' }
    @{ RG = $config.RgEast;    Name = 'DVAS02' }
    @{ RG = $config.RgCentral; Name = 'DVAS03' }
    @{ RG = $config.RgCentral; Name = 'DVAS04' }
)

# --- Helper: Run remote PowerShell via az vm run-command -----------------

function Invoke-RunCommand {
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$ScriptContent
    )

    $tempScript = Join-Path $env:TEMP "rc-$(Get-Date -Format 'HHmmssff').ps1"
    Set-Content -Path $tempScript -Value $ScriptContent -Encoding UTF8

    $resultJson = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VMName `
        --command-id RunPowerShellScript `
        --scripts "@$tempScript" `
        -o json 2>&1

    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        throw "run-command failed on $VMName (exit code $LASTEXITCODE)"
    }

    $parsed = $resultJson | ConvertFrom-Json
    return @{
        Stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
        Stderr = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdErr/succeeded' }).message
    }
}

# --- Banner --------------------------------------------------------------

Write-Host "`n+======================================================+" -ForegroundColor Cyan
Write-Host "|  App Server Installer Staging                        |" -ForegroundColor Cyan
Write-Host "+======================================================+" -ForegroundColor Cyan
Write-Host "`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# --- Step 1: Validate local files ----------------------------------------

Write-Host "`n-- Step 1: Validating local installer files --" -ForegroundColor Yellow

foreach ($path in @($ProvisioningAgentPath, $AzureADConnectPath)) {
    if (-not (Test-Path $path)) {
        throw "Installer not found: $path"
    }
    $sizeMb = [math]::Round((Get-Item $path).Length / 1MB, 1)
    Write-Host "  Found: $(Split-Path $path -Leaf) ($sizeMb MB) at $path" -ForegroundColor Gray
}

$agentSizeMb   = [math]::Round((Get-Item $ProvisioningAgentPath).Length / 1MB, 1)
$connectSizeMb = [math]::Round((Get-Item $AzureADConnectPath).Length / 1MB, 1)

# --- Step 2: Get storage account key ------------------------------------

Write-Host "`n-- Step 2: Retrieving storage account key --" -ForegroundColor Yellow

$storageKey = az storage account keys list `
    --resource-group $config.StorageRg `
    --account-name $config.StorageAccount `
    --query "[0].value" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve storage account key." }
Write-Host "  Key retrieved for $($config.StorageAccount)." -ForegroundColor Gray

# --- Step 3: Create installers container --------------------------------

Write-Host "`n-- Step 3: Ensuring '$($config.ContainerName)' container exists --" -ForegroundColor Yellow

az storage container create `
    --name $config.ContainerName `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --output none 2>$null
Write-Host "  Container '$($config.ContainerName)' ready." -ForegroundColor Gray

# --- Step 4: Upload both installers ------------------------------------

Write-Host "`n-- Step 4: Uploading installers to blob storage --" -ForegroundColor Yellow

Write-Host "  Uploading $($config.BlobAgent) ($agentSizeMb MB)..." -ForegroundColor Gray
az storage blob upload `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobAgent `
    --file $ProvisioningAgentPath `
    --overwrite `
    --output none 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to upload $($config.BlobAgent)." }
Write-Host "  [OK] $($config.BlobAgent) uploaded." -ForegroundColor Green

Write-Host "  Uploading $($config.BlobConnect) ($connectSizeMb MB)..." -ForegroundColor Gray
az storage blob upload `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobConnect `
    --file $AzureADConnectPath `
    --overwrite `
    --output none 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to upload $($config.BlobConnect)." }
Write-Host "  [OK] $($config.BlobConnect) uploaded." -ForegroundColor Green

# --- Step 5: Generate 24-hour SAS URLs ----------------------------------

Write-Host "`n-- Step 5: Generating 24-hour SAS URLs --" -ForegroundColor Yellow

$expiry = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mmZ')

$agentSas = az storage blob generate-sas `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobAgent `
    --permissions r `
    --expiry $expiry `
    -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to generate SAS for $($config.BlobAgent)." }

$connectSas = az storage blob generate-sas `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobConnect `
    --permissions r `
    --expiry $expiry `
    -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to generate SAS for $($config.BlobConnect)." }

$agentUrl   = "https://$($config.StorageAccount).blob.core.windows.net/$($config.ContainerName)/$($config.BlobAgent)?$agentSas"
$connectUrl = "https://$($config.StorageAccount).blob.core.windows.net/$($config.ContainerName)/$($config.BlobConnect)?$connectSas"

Write-Host "  SAS URLs generated (valid until $expiry UTC)." -ForegroundColor Green

# --- Step 6: Deliver to each app server ---------------------------------

Write-Host "`n-- Step 6: Delivering installers to app servers --" -ForegroundColor Yellow

# Single-quoted here-string — no PowerShell expansion inside.
# PLACEHOLDER values are replaced via .Replace() (literal, not regex) after the string is built.
$downloadTemplate = @'
New-Item -Path C:\Temp -ItemType Directory -Force | Out-Null

Write-Output "Downloading AADConnectProvisioningAgentSetup.exe..."
Invoke-WebRequest -Uri 'PLACEHOLDER_AGENT_URL' -OutFile 'C:\Temp\AADConnectProvisioningAgentSetup.exe' -UseBasicParsing
$agentMb = [math]::Round((Get-Item 'C:\Temp\AADConnectProvisioningAgentSetup.exe').Length / 1MB, 1)
Write-Output "  Saved: AADConnectProvisioningAgentSetup.exe (${agentMb} MB)"

Write-Output "Downloading AzureADConnect.msi..."
Invoke-WebRequest -Uri 'PLACEHOLDER_CONNECT_URL' -OutFile 'C:\Temp\AzureADConnect.msi' -UseBasicParsing
$connectMb = [math]::Round((Get-Item 'C:\Temp\AzureADConnect.msi').Length / 1MB, 1)
Write-Output "  Saved: AzureADConnect.msi (${connectMb} MB)"

Write-Output "Download complete on $env:COMPUTERNAME"
'@

# Use literal .Replace() — avoids regex special-character issues in SAS token strings
$downloadScript = $downloadTemplate.Replace('PLACEHOLDER_AGENT_URL', $agentUrl).Replace('PLACEHOLDER_CONNECT_URL', $connectUrl)

$results = @{}

foreach ($vm in $appServers) {
    Write-Host "`n  Delivering to $($vm.Name) ($($vm.RG))..." -ForegroundColor Yellow
    try {
        $result = Invoke-RunCommand -ResourceGroup $vm.RG -VMName $vm.Name -ScriptContent $downloadScript
        if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
        if ($result.Stderr -and $result.Stderr.Trim()) {
            Write-Host "  StdErr: $($result.Stderr)" -ForegroundColor DarkYellow
        }

        if ($result.Stdout -match 'Download complete') {
            Write-Host "  [OK] $($vm.Name) -- both installers in C:\Temp" -ForegroundColor Green
            $results[$vm.Name] = 'OK'
        } else {
            Write-Warning "  Could not confirm delivery to $($vm.Name) -- check output above."
            $results[$vm.Name] = 'UNCONFIRMED'
        }
    } catch {
        Write-Warning "  Delivery to $($vm.Name) failed: $($_.Exception.Message)"
        $results[$vm.Name] = 'FAILED'
    }
}

# --- Summary -------------------------------------------------------------

Write-Host "`n+======================================================+" -ForegroundColor Green
Write-Host "|  Staging Complete                                    |" -ForegroundColor Green
Write-Host "+======================================================+" -ForegroundColor Green
Write-Host "`nCompleted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

Write-Host "`nDelivery results:" -ForegroundColor White
foreach ($vm in $appServers) {
    $status = $results[$vm.Name]
    $color  = switch ($status) {
        'OK'          { 'Green'  }
        'FAILED'      { 'Red'    }
        default       { 'Yellow' }
    }
    Write-Host ("  {0,-8} {1}" -f $vm.Name, $status) -ForegroundColor $color
}

Write-Host @"

Files staged on each app server:
  C:\Temp\AADConnectProvisioningAgentSetup.exe
  C:\Temp\AzureADConnect.msi

-------------------------------------------------------
 NEXT: Install via Azure Bastion RDP on each app server
-------------------------------------------------------

Connect via Bastion:
  Azure Portal -> rg-east -> bas-adlab-east -> Connect to VM
  DVAS03 and DVAS04 (rg-central) are reachable via the same Bastion (VNet peering).

To install Azure AD Connect Sync (AzureADConnect.msi):
  1. Open PowerShell as Administrator:
       msiexec /i C:\Temp\AzureADConnect.msi
     Or double-click the MSI in Explorer.
  2. Follow the Azure AD Connect setup wizard.
  3. Sign in with a Global Administrator account when prompted.

To install Cloud Sync Provisioning Agent (AADConnectProvisioningAgentSetup.exe):
  1. Open PowerShell as Administrator:
       C:\Temp\AADConnectProvisioningAgentSetup.exe
  2. Follow the wizard and sign in with a Hybrid Identity Administrator account.

Note: Azure AD Connect (full sync) and Cloud Sync agent are alternative approaches.
Install only the one appropriate for each server's role -- do not install both.
"@ -ForegroundColor White
