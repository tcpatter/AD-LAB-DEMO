<#
.SYNOPSIS
    3-phase deployment orchestrator for the AD Lab environment (infra + VMs + validation).
.DESCRIPTION
    Deploys the AD Lab in phases using Azure CLI:
      1. Infra     - RGs, VNets, NSGs, Bastion, Storage, upload scripts
      2. VMs       - All 7 VMs (no domain config, Bastion-only access)
      3. Validate  - Run whoami + hostname on each VM via az vm run-command
.PARAMETER Phase
    Which phase(s) to run: 1-3, 'all', or comma-separated (e.g., '1,2,3')
.PARAMETER AdminPassword
    Password for the VM local admin account (plain text — az cli does not use SecureString)
.PARAMETER SafeModePassword
    DSRM password for Active Directory
.EXAMPLE
    .\deploy.ps1 -Phase all -AdminPassword 'L@bAdmin2026!x' -SafeModePassword 'L@bAdmin2026!x'
#>

param(
    [Parameter(Mandatory)]
    [string]$Phase,

    [Parameter(Mandatory)]
    [string]$AdminPassword,

    [Parameter(Mandatory)]
    [string]$SafeModePassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration ───────────────────────────────────────────────────────────

$config = @{
    Location            = 'eastus2'
    BicepPath           = Join-Path $PSScriptRoot '..\bicep\main.bicep'
    AdminUsername        = 'labadmin'
    StorageAccountName  = 'stadlabscripts01'
    RgEast              = 'rg-ADLab-East'
    RgWest              = 'rg-ADLab-West'
    VnetEast            = 'vnet-adlab-east'
    VnetWest            = 'vnet-adlab-west'
    PrimaryDcIp         = '10.1.1.4'
    SecondaryDcIp       = '10.1.1.5'
    WestDcIp            = '10.3.1.4'
    DomainName          = 'managed-connections.net'
    DomainDN            = 'DC=managed-connections,DC=net'
    ScriptsPath         = Join-Path $PSScriptRoot '..\scripts\powershell'
    CsvPath             = Join-Path $PSScriptRoot '..\scripts\python\data\users.csv'
}

# ─── Helper Functions ────────────────────────────────────────────────────────

function Deploy-BicepPhase {
    param(
        [string]$PhaseName,
        [hashtable]$ExtraParams = @{}
    )

    $deployName = "adlab-$PhaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "`n═══ Deploying phase: $PhaseName ($deployName) ═══" -ForegroundColor Cyan

    $params = @(
        "deployPhase=$PhaseName"
        "adminUsername=$($config.AdminUsername)"
        "adminPassword=$AdminPassword"
        "safeModePassword=$SafeModePassword"
        "storageAccountName=$($config.StorageAccountName)"
    )

    foreach ($key in $ExtraParams.Keys) {
        $params += "$key=$($ExtraParams[$key])"
    }

    az deployment sub create `
        --name $deployName `
        --location $config.Location `
        --template-file $config.BicepPath `
        --parameters $params `
        --verbose

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment phase '$PhaseName' failed with exit code $LASTEXITCODE"
    }
}

function Wait-VMAgentReady {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [int]$TimeoutMinutes = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $status = az vm get-instance-view `
            --resource-group $ResourceGroupName `
            --name $VMName `
            --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].displayStatus" `
            -o tsv 2>$null

        if ($status -eq 'Ready') {
            Write-Host "  $VMName — agent ready" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 20
    }

    Write-Warning "$VMName did not report ready within $TimeoutMinutes minutes."
    return $false
}

function Upload-ScriptsToStorage {
    # Get storage account key
    $key = az storage account keys list `
        --resource-group $config.RgEast `
        --account-name $config.StorageAccountName `
        --query "[0].value" -o tsv

    if ($LASTEXITCODE -ne 0) { throw "Failed to get storage account keys" }

    # Ensure scripts container exists
    az storage container create `
        --name 'scripts' `
        --account-name $config.StorageAccountName `
        --account-key $key `
        --output none 2>$null

    # Upload PowerShell scripts
    $scripts = Get-ChildItem -Path $config.ScriptsPath -Filter '*.ps1' -ErrorAction SilentlyContinue
    foreach ($script in $scripts) {
        Write-Host "  Uploading $($script.Name)..." -ForegroundColor Gray
        az storage blob upload `
            --file $script.FullName `
            --container-name 'scripts' `
            --name $script.Name `
            --account-name $config.StorageAccountName `
            --account-key $key `
            --overwrite `
            --output none
    }

    # Upload CSV if it exists
    if (Test-Path $config.CsvPath) {
        Write-Host "  Uploading users.csv..." -ForegroundColor Gray
        az storage blob upload `
            --file $config.CsvPath `
            --container-name 'scripts' `
            --name 'users.csv' `
            --account-name $config.StorageAccountName `
            --account-key $key `
            --overwrite `
            --output none
    }

    # Generate SAS token valid for 4 hours
    $expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
    $sasToken = az storage container generate-sas `
        --name 'scripts' `
        --account-name $config.StorageAccountName `
        --account-key $key `
        --permissions r `
        --expiry $expiry `
        -o tsv

    return "?$sasToken"
}

# ─── Phase Execution ─────────────────────────────────────────────────────────

$phases = if ($Phase -eq 'all') {
    1..3
} else {
    $Phase -split ',' | ForEach-Object { [int]$_.Trim() }
}

$sasToken = ''

# All 7 VMs — used by Phases 2 and 3
$allVMs = @(
    @{ RG = $config.RgEast; Name = 'DVDC01' }
    @{ RG = $config.RgEast; Name = 'DVDC02' }
    @{ RG = $config.RgEast; Name = 'DVAS01' }
    @{ RG = $config.RgEast; Name = 'DVAS02' }
    @{ RG = $config.RgWest; Name = 'DVDC03' }
    @{ RG = $config.RgWest; Name = 'DVAS03' }
    @{ RG = $config.RgWest; Name = 'DVAS04' }
)

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
            Write-Host "║  PHASE 2: Virtual Machines (7 VMs)       ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            Deploy-BicepPhase -PhaseName 'vms'

            Write-Host "`nWaiting for all 7 VMs to report agent ready..." -ForegroundColor Yellow
            foreach ($vm in $allVMs) {
                Wait-VMAgentReady -ResourceGroupName $vm.RG -VMName $vm.Name
            }

            Write-Host "All VMs deployed." -ForegroundColor Green
        }

        3 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 3: Bastion Validation             ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            $passed = 0
            $failed = 0

            foreach ($vm in $allVMs) {
                Write-Host "  Testing $($vm.Name)..." -ForegroundColor Yellow -NoNewline
                try {
                    $scriptFile = Join-Path $env:TEMP "validate-vm.ps1"
                    Set-Content -Path $scriptFile -Value 'Write-Output "whoami: $env:USERNAME"; Write-Output "hostname: $env:COMPUTERNAME"'

                    $resultJson = az vm run-command invoke `
                        --resource-group $vm.RG `
                        --name $vm.Name `
                        --command-id RunPowerShellScript `
                        --scripts '@{0}' -f $scriptFile `
                        -o json 2>&1

                    if ($LASTEXITCODE -ne 0) {
                        # Retry with inline script (--scripts may need different quoting)
                        $resultJson = az vm run-command invoke `
                            --resource-group $vm.RG `
                            --name $vm.Name `
                            --command-id RunPowerShellScript `
                            --scripts "hostname" `
                            -o json 2>&1
                    }

                    if ($LASTEXITCODE -ne 0) {
                        Write-Host " FAIL — az vm run-command returned exit code $LASTEXITCODE" -ForegroundColor Red
                        $failed++
                        continue
                    }

                    $parsed = $resultJson | ConvertFrom-Json
                    $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message

                    if ($stdout -and $stdout.Trim().Length -gt 0) {
                        Write-Host " PASS — $($stdout.Trim())" -ForegroundColor Green
                        $passed++
                    } else {
                        Write-Host " FAIL — unexpected output" -ForegroundColor Red
                        $failed++
                    }
                }
                catch {
                    Write-Host " FAIL — $($_.Exception.Message)" -ForegroundColor Red
                    $failed++
                }
            }

            Write-Host "`nValidation complete: $passed passed, $failed failed out of $($allVMs.Count) VMs." -ForegroundColor Cyan
            if ($failed -gt 0) {
                Write-Warning "Some VMs failed validation. Check Bastion connectivity and VM agent status."
            }
        }
    }
}

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  Deployment Complete!                    ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host @"

Verification steps:
  1. az vm list -g rg-ADLab-East -o table    (4 VMs: DVDC01, DVDC02, DVAS01, DVAS02)
  2. az vm list -g rg-ADLab-West -o table     (3 VMs: DVDC03, DVAS03, DVAS04)
  3. az network bastion list -o table          (2 Bastions, Standard SKU)
  4. No public IPs on VMs
  5. Bastion tunnel -> RDP login to each VM with labadmin
"@
