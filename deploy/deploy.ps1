#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute

<#
.SYNOPSIS
    3-phase deployment orchestrator for the AD Lab environment (infra + VMs + validation).
.DESCRIPTION
    Deploys the AD Lab in phases:
      1. Infra     - RGs, VNets, NSGs, Bastion, Storage, upload scripts
      2. VMs       - All 7 VMs (no domain config, Bastion-only access)
      3. Validate  - Bastion tunnel test to each VM via Invoke-AzVMRunCommand
.PARAMETER Phase
    Which phase(s) to run: 1-3, 'all', or comma-separated (e.g., '1,2,3')
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
    1..3
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
            Write-Host "║  PHASE 2: Virtual Machines (7 VMs)       ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            Deploy-BicepPhase -PhaseName 'vms'

            # Wait for all VMs to be provisioned and agent ready
            $allVMs = @(
                @{ RG = $config.RgEast; Name = 'DVDC01' }
                @{ RG = $config.RgEast; Name = 'DVDC02' }
                @{ RG = $config.RgEast; Name = 'DVAS01' }
                @{ RG = $config.RgEast; Name = 'DVAS02' }
                @{ RG = $config.RgWest; Name = 'DVDC03' }
                @{ RG = $config.RgWest; Name = 'DVAS03' }
                @{ RG = $config.RgWest; Name = 'DVAS04' }
            )

            Write-Host "`nWaiting for all 7 VMs to report agent ready..." -ForegroundColor Yellow
            foreach ($vm in $allVMs) {
                $deadline = (Get-Date).AddMinutes(15)
                $ready = $false
                while ((Get-Date) -lt $deadline) {
                    try {
                        $status = Get-AzVM -ResourceGroupName $vm.RG -Name $vm.Name -Status
                        $agentOk = $status.VMAgent.Statuses | Where-Object { $_.Code -eq 'ProvisioningState/succeeded' }
                        if ($agentOk) {
                            Write-Host "  $($vm.Name) — agent ready" -ForegroundColor Green
                            $ready = $true
                            break
                        }
                    } catch { }
                    Start-Sleep -Seconds 20
                }
                if (-not $ready) {
                    Write-Warning "$($vm.Name) did not report ready within 15 minutes."
                }
            }

            Write-Host "All VMs deployed." -ForegroundColor Green
        }

        3 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 3: Bastion Validation             ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            $allVMs = @(
                @{ RG = $config.RgEast; Name = 'DVDC01' }
                @{ RG = $config.RgEast; Name = 'DVDC02' }
                @{ RG = $config.RgEast; Name = 'DVAS01' }
                @{ RG = $config.RgEast; Name = 'DVAS02' }
                @{ RG = $config.RgWest; Name = 'DVDC03' }
                @{ RG = $config.RgWest; Name = 'DVAS03' }
                @{ RG = $config.RgWest; Name = 'DVAS04' }
            )

            $passed = 0
            $failed = 0

            foreach ($vm in $allVMs) {
                Write-Host "  Testing $($vm.Name)..." -ForegroundColor Yellow -NoNewline
                try {
                    $result = Invoke-AzVMRunCommand `
                        -ResourceGroupName $vm.RG `
                        -VMName $vm.Name `
                        -CommandId 'RunPowerShellScript' `
                        -ScriptString 'Write-Output "whoami: $(whoami)"; Write-Output "hostname: $(hostname)"'

                    $output = ($result.Value | Where-Object { $_.Code -eq 'ComponentStatus/StdOut/succeeded' }).Message
                    if ($output -match 'hostname:') {
                        Write-Host " PASS — $($output.Trim())" -ForegroundColor Green
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
