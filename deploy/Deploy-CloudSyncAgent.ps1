<#
.SYNOPSIS
    Prepares DVDC01 and DVDC03 for Microsoft Entra Cloud Sync agent installation.
.DESCRIPTION
    Automates all pre-installation steps for both DCs:
      1. Create OU  — OU=CloudSync in AD on DVDC01 (dedicated Cloud Sync scope)
      2. Prereqs    — Verify/configure TLS 1.2, .NET, KDS key, schema, connectivity on DVDC01
      3. Prereqs    — Same checks on DVDC03
      4. Upload     — AADConnectProvisioningAgentSetup.exe → stadlabscripts01 blob storage
      5. Deliver    — Download installer to C:\Temp on DVDC01 via 24-hour SAS URL
      6. Deliver    — Download installer to C:\Temp on DVDC03

    After this script completes, the agent must be installed interactively via
    Azure Bastion RDP on each DC. The installer opens a browser for Entra ID
    authentication and cannot be automated.

    Estimated time: ~10 minutes.

    Prerequisite: Phase 0 must be complete (managed-connections.net verified as a
    custom domain in Entra, cloud-only Hybrid Identity Administrator account created).

.PARAMETER InstallerPath
    Local path to AADConnectProvisioningAgentSetup.exe.
    Default: C:\Users\TerryPatterson\Downloads\AADConnectProvisioningAgentSetup.exe

.EXAMPLE
    .\deploy\Deploy-CloudSyncAgent.ps1

.EXAMPLE
    .\deploy\Deploy-CloudSyncAgent.ps1 -InstallerPath 'D:\Downloads\AADConnectProvisioningAgentSetup.exe'
#>

param(
    [string]$InstallerPath = 'C:\Users\TerryPatterson\Downloads\AADConnectProvisioningAgentSetup.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration ────────────────────────────────────────────────────────────

$config = @{
    RgEast         = 'rg-ADLab-East'
    RgWest         = 'rg-ADLab-West'
    StorageAccount = 'stadlabscripts01'
    StorageRg      = 'rg-ADLab-East'
    ContainerName  = 'scripts'
    BlobName       = 'AADConnectProvisioningAgentSetup.exe'
    ScriptsPath    = Join-Path $PSScriptRoot '..\scripts\powershell'
}

# ─── Helper: Run remote PowerShell via az vm run-command ─────────────────────

function Invoke-RunCommand {
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$ScriptContent
    )

    # Write to temp file to avoid az CLI quoting issues with special characters
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

# ─── Banner ───────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Microsoft Entra Cloud Sync — Agent Deployment      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ─── Validate local prerequisites ────────────────────────────────────────────

if (-not (Test-Path $InstallerPath)) {
    throw "Installer not found: $InstallerPath"
}
$installerSizeMb = [math]::Round((Get-Item $InstallerPath).Length / 1MB, 1)
Write-Host "  Installer : $InstallerPath ($installerSizeMb MB)" -ForegroundColor Gray

$ouScriptPath     = Join-Path $config.ScriptsPath 'New-CloudSyncOU.ps1'
$prereqScriptPath = Join-Path $config.ScriptsPath 'Set-CloudSyncPrereqs.ps1'

foreach ($path in @($ouScriptPath, $prereqScriptPath)) {
    if (-not (Test-Path $path)) { throw "Script not found: $path" }
}

# ─── Step 1: Create CloudSync OU on DVDC01 ───────────────────────────────────

Write-Host "`n── Step 1: Creating CloudSync OU on DVDC01 ──" -ForegroundColor Yellow

$ouScript = Get-Content -Raw -Path $ouScriptPath

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName 'DVDC01' -ScriptContent $ouScript
    if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
    Write-Host "  [OK] CloudSync OU structure ready." -ForegroundColor Green
} catch {
    throw "CloudSync OU creation failed: $($_.Exception.Message)"
}

# ─── Step 2: Prerequisites check — DVDC01 ────────────────────────────────────

Write-Host "`n── Step 2: Cloud Sync prerequisites — DVDC01 ──" -ForegroundColor Yellow

$prereqScript = Get-Content -Raw -Path $prereqScriptPath

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName 'DVDC01' -ScriptContent $prereqScript
    if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }

    if ($result.Stdout -match 'ALL CHECKS PASSED') {
        Write-Host "  [PREREQ OK] DVDC01 is ready for Cloud Sync agent installation." -ForegroundColor Green
    } elseif ($result.Stdout -match 'ONE OR MORE CHECKS FAILED') {
        throw "DVDC01 prerequisite check failed — resolve issues above before proceeding."
    } else {
        Write-Warning "  Could not confirm prereq result for DVDC01 — review output above."
    }
} catch {
    throw "Prerequisites check failed on DVDC01: $($_.Exception.Message)"
}

# ─── Step 3: Prerequisites check — DVDC03 ────────────────────────────────────

Write-Host "`n── Step 3: Cloud Sync prerequisites — DVDC03 ──" -ForegroundColor Yellow

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $prereqScript
    if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }

    if ($result.Stdout -match 'ALL CHECKS PASSED') {
        Write-Host "  [PREREQ OK] DVDC03 is ready for Cloud Sync agent installation." -ForegroundColor Green
    } elseif ($result.Stdout -match 'ONE OR MORE CHECKS FAILED') {
        throw "DVDC03 prerequisite check failed — resolve issues above before proceeding."
    } else {
        Write-Warning "  Could not confirm prereq result for DVDC03 — review output above."
    }
} catch {
    throw "Prerequisites check failed on DVDC03: $($_.Exception.Message)"
}

# ─── Step 4: Upload installer to Azure Blob Storage ──────────────────────────

Write-Host "`n── Step 4: Uploading installer to Azure Blob Storage ──" -ForegroundColor Yellow

Write-Host "  Getting storage account key..." -ForegroundColor Gray
$storageKey = az storage account keys list `
    --resource-group $config.StorageRg `
    --account-name $config.StorageAccount `
    --query "[0].value" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve storage account key." }

Write-Host "  Uploading to $($config.StorageAccount)/$($config.ContainerName)/$($config.BlobName)..." -ForegroundColor Gray
az storage blob upload `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobName `
    --file $InstallerPath `
    --overwrite `
    --output none 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to upload installer to blob storage." }
Write-Host "  Upload complete ($installerSizeMb MB)." -ForegroundColor Green

Write-Host "  Generating 24-hour SAS URL..." -ForegroundColor Gray
$expiry   = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mmZ')
$sasToken = az storage blob generate-sas `
    --account-name $config.StorageAccount `
    --account-key $storageKey `
    --container-name $config.ContainerName `
    --name $config.BlobName `
    --permissions r `
    --expiry $expiry `
    -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "Failed to generate SAS token." }

$sasUrl = "https://$($config.StorageAccount).blob.core.windows.net/$($config.ContainerName)/$($config.BlobName)?$sasToken"
Write-Host "  SAS URL generated (valid until $expiry UTC)." -ForegroundColor Green

# ─── Step 5: Deliver installer to DVDC01 ─────────────────────────────────────

Write-Host "`n── Step 5: Delivering installer to DVDC01 ──" -ForegroundColor Yellow

# SAS URL is injected via string replacement into the single-quoted here-string
# to avoid PowerShell escaping issues with special characters in the URL.
$downloadScript = @'
New-Item -Path C:\Temp -ItemType Directory -Force | Out-Null
$url = 'PLACEHOLDER_SAS_URL'
Write-Output "Downloading Cloud Sync agent installer..."
Invoke-WebRequest -Uri $url -OutFile 'C:\Temp\AADConnectProvisioningAgentSetup.exe' -UseBasicParsing
$sizeMb = [math]::Round((Get-Item 'C:\Temp\AADConnectProvisioningAgentSetup.exe').Length / 1MB, 1)
Write-Output "Download complete — ${sizeMb} MB saved to C:\Temp\AADConnectProvisioningAgentSetup.exe"
'@ -replace 'PLACEHOLDER_SAS_URL', $sasUrl

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName 'DVDC01' -ScriptContent $downloadScript
    if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
    if ($result.Stdout -match 'Download complete') {
        Write-Host "  [OK] Installer ready on DVDC01 at C:\Temp\AADConnectProvisioningAgentSetup.exe" -ForegroundColor Green
    }
} catch {
    throw "Installer delivery to DVDC01 failed: $($_.Exception.Message)"
}

# ─── Step 6: Deliver installer to DVDC03 ─────────────────────────────────────

Write-Host "`n── Step 6: Delivering installer to DVDC03 ──" -ForegroundColor Yellow

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $downloadScript
    if ($result.Stdout) { Write-Host $result.Stdout -ForegroundColor Cyan }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
    if ($result.Stdout -match 'Download complete') {
        Write-Host "  [OK] Installer ready on DVDC03 at C:\Temp\AADConnectProvisioningAgentSetup.exe" -ForegroundColor Green
    }
} catch {
    throw "Installer delivery to DVDC03 failed: $($_.Exception.Message)"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Pre-Installation Complete!                          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host @"

Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

What was automated:
  - OU=CloudSync,DC=managed-connections,DC=net created (with Users, Groups sub-OUs)
  - Prerequisites verified and configured on DVDC01 and DVDC03
  - Installer uploaded to $($config.StorageAccount)/$($config.ContainerName)
  - Installer delivered to C:\Temp on DVDC01 and DVDC03

─────────────────────────────────────────────────────────
 NEXT: Interactive installation via Azure Bastion RDP
─────────────────────────────────────────────────────────

STEP A — Install on DVDC01 (primary — do first):
  1. Azure Portal → rg-ADLab-East → DVDC01 → Connect → Bastion
  2. Open PowerShell as Administrator and run:
       C:\Temp\AADConnectProvisioningAgentSetup.exe
  3. Accept license terms
  4. When prompted to sign in to Entra ID:
       Use the cloud-only Hybrid Identity Administrator account
       (e.g. cloudsync-admin@<tenant>.onmicrosoft.com)
  5. When prompted for Active Directory credentials:
       Enter MANAGED\labadmin (Domain Admin)
       The installer auto-creates MANAGED\provAgentgMSA$
  6. Complete the wizard — agent registers with Entra tenant

STEP B — Install on DVDC03 (failover DC — do after DVDC01):
  1. Azure Portal → rg-ADLab-West → DVDC03 → Connect → Bastion
  2. Open PowerShell as Administrator and run:
       C:\Temp\AADConnectProvisioningAgentSetup.exe
  3. Sign in with the same HIA account used in Step A
  4. Provide MANAGED\labadmin credentials — gMSA is reused (already exists)
  5. Complete the wizard — second agent registers for high availability

STEP C — Configure Cloud Sync scope in Entra admin center:
  1. https://entra.microsoft.com
     → Identity → Hybrid management → Microsoft Entra Connect → Cloud sync
  2. Click New configuration → select managed-connections.net
  3. Under Scope → Selected organizational units:
       OU=CloudSync,DC=managed-connections,DC=net
  4. Configure attribute mappings (defaults are fine for the lab)
  5. Enable Password Hash Sync if desired
  6. Save and click Enable sync

STEP D — Validate:
  1. Cloud sync → Your configuration → Agent status
     Both DVDC01 and DVDC03 agents should show Healthy
  2. Cloud sync → Provisioning logs — confirm objects sync without errors
  3. Move a test user into OU=CloudSync\Users and verify they appear in Entra ID
"@ -ForegroundColor White
