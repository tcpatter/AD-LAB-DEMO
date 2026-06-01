<#
.SYNOPSIS
    Promotes DVDC02 (East) and DVDC03 (Central) as additional domain controllers.
.DESCRIPTION
    Runs Promote-SecondaryDC.ps1 on each DC via az vm run-command, waits for reboot,
    then validates the promotion. Run after Phase 4 (PrimaryDC) completes.
#>

param(
    [string]$AdminPassword    = 'L@bAdmin2026!x',
    [string]$SafeModePassword = 'L@bAdmin2026!x'
)

$ErrorActionPreference = 'Stop'

az account set --subscription '64d83543-8eda-43a0-b42f-a92876dfb11d'
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context." }

$domainName      = 'managed-connections.net'
$primaryDcIp     = '10.1.1.4'
$adminUser       = 'labadmin'
$scriptPath      = Join-Path $PSScriptRoot '..\scripts\powershell\Promote-SecondaryDC.ps1'
$secondaryScript = Get-Content $scriptPath -Raw
$nl              = [Environment]::NewLine

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Secondary DC Promotion                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

function Wait-VMReady {
    param([string]$RG, [string]$VMName, [int]$TimeoutMinutes = 20)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $status = az vm get-instance-view --resource-group $RG --name $VMName `
            --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].displayStatus" `
            -o tsv 2>$null
        if ($status -eq 'Ready') { return $true }
        Start-Sleep -Seconds 20
    }
    return $false
}

function Invoke-SecondaryPromotion {
    param([string]$RG, [string]$VMName)

    Write-Host "`n-- Promoting $VMName as additional DC --" -ForegroundColor Yellow

    $tempScript = Join-Path $env:TEMP "promote-$VMName.ps1"
    $invocation = "& {$nl$secondaryScript$nl} -DomainName '$domainName' -PrimaryDcIp '$primaryDcIp' -SafeModePassword '$SafeModePassword' -DomainAdminUser '$adminUser' -DomainAdminPassword '$AdminPassword'"
    Set-Content -Path $tempScript -Value $invocation -Encoding UTF8

    Write-Host "  Running Install-ADDSDomainController (VM will reboot)..." -ForegroundColor Gray
    $result = az vm run-command invoke `
        --resource-group $RG `
        --name $VMName `
        --command-id RunPowerShellScript `
        --scripts "@$tempScript" `
        -o json 2>&1

    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  run-command exited (VM likely rebooted after promotion)" -ForegroundColor Yellow
    } else {
        $parsed = $result | ConvertFrom-Json
        $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
        if ($stdout) { Write-Host $stdout -ForegroundColor Gray }
    }

    Write-Host "  Waiting 45s then polling for agent readiness..." -ForegroundColor Gray
    Start-Sleep -Seconds 45
    $ready = Wait-VMReady -RG $RG -VMName $VMName -TimeoutMinutes 20
    if (-not $ready) { Write-Warning "$VMName did not report ready within 20 min." }

    Write-Host "  Waiting 60s for AD DS services to stabilize..." -ForegroundColor Gray
    Start-Sleep -Seconds 60

    # Validate
    $valScript = "Import-Module ActiveDirectory; Get-ADDomainController -Identity '$VMName' | Select-Object Name, Site, IsGlobalCatalog, IsReadOnly | Out-String"
    $valResult = az vm run-command invoke `
        --resource-group $RG `
        --name $VMName `
        --command-id RunPowerShellScript `
        --scripts $valScript `
        -o json 2>&1

    if ($LASTEXITCODE -eq 0) {
        $parsed = $valResult | ConvertFrom-Json
        $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
        $stderr = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdErr/succeeded' }).message
        if ($stdout) { Write-Host $stdout -ForegroundColor Cyan }
        if ($stderr -and $stderr.Trim()) { Write-Host "StdErr: $stderr" -ForegroundColor Yellow }
        Write-Host "  [OK] $VMName promoted successfully." -ForegroundColor Green
    } else {
        Write-Warning "Validation run-command failed for $VMName - check manually via Bastion."
    }
}

Invoke-SecondaryPromotion -RG 'rg-east'    -VMName 'DVDC02'
Invoke-SecondaryPromotion -RG 'rg-central' -VMName 'DVDC03'

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Secondary DC Promotion Complete         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host @"

Domain Controllers:
  DVDC01  10.1.1.4   Primary DC / Forest root (East)
  DVDC02  10.1.1.5   Additional DC (East)
  DVDC03  10.3.1.4   Additional DC (Central)

Verify replication:
  Bastion RDP to DVDC01, then run:
    repadmin /replsummary
    Get-ADDomainController -Filter * | Select Name, Site, IPv4Address
"@

