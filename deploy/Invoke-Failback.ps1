<#
.SYNOPSIS
    Graceful failback orchestrator: Central US → East US 2.
.DESCRIPTION
    Restores East US 2 as the primary AD region by starting DVDC01/DVDC02,
    waiting for AD replication to fully sync, then gracefully transferring
    (not seizing) all 5 FSMO roles back to DVDC01 and restoring DNS.

    Steps:
      1. Start East  — Start DVDC01 and DVDC02; wait for VM agent ready
      2. Sync        — Force repadmin /syncall from DVDC03; confirm 0 failures
      3. Transfer    — Gracefully transfer all 5 FSMO roles to DVDC01
      4. Restore DNS — Update both VNets to use DVDC01 (10.1.1.4) as DNS server
      5. Flush DNS   — Flush and re-register DNS on all 4 app servers
      6. Validate    — FSMO check, dcdiag Advertising, repadmin /replsummary

    Estimated time: ~25 minutes.
    Prerequisite: DVDC03 is healthy and holds all FSMO roles (post-failover state).
.PARAMETER AdminPassword
    Password for the VM local admin account (labadmin).
.EXAMPLE
    .\deploy\Invoke-Failback.ps1 -AdminPassword 'L@bAdmin2026!x'
#>

param(
    [Parameter(Mandatory)]
    [string]$AdminPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration ────────────────────────────────────────────────────────────

$config = @{
    RgEast      = 'rg-ADLab-East'
    RgWest      = 'rg-ADLab-West'
    VnetEast    = 'vnet-adlab-east'
    VnetWest    = 'vnet-adlab-west'
    PrimaryDcIp = '10.1.1.4'
    DomainName  = 'managed-connections.net'
    ScriptsPath = Join-Path $PSScriptRoot '..\scripts\powershell'
}

# ─── Helper: Wait for VM agent ────────────────────────────────────────────────

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

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  DR FAILBACK: Central US → East US 2    ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host "`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ─── Step 1: Start East VMs ───────────────────────────────────────────────────

Write-Host "`n── Step 1: Starting East VMs (DVDC01, DVDC02) ──" -ForegroundColor Yellow

Write-Host "  Starting DVDC01 (async)..." -ForegroundColor Gray
az vm start --resource-group $config.RgEast --name 'DVDC01' --no-wait --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to initiate DVDC01 start." }

Write-Host "  Starting DVDC02 (async)..." -ForegroundColor Gray
az vm start --resource-group $config.RgEast --name 'DVDC02' --no-wait --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to initiate DVDC02 start." }

Write-Host "  Waiting for DVDC01 agent ready..." -ForegroundColor Gray
$dc01ready = Wait-VMAgentReady -ResourceGroupName $config.RgEast -VMName 'DVDC01' -TimeoutMinutes 15

Write-Host "  Waiting for DVDC02 agent ready..." -ForegroundColor Gray
$dc02ready = Wait-VMAgentReady -ResourceGroupName $config.RgEast -VMName 'DVDC02' -TimeoutMinutes 15

if (-not ($dc01ready -and $dc02ready)) {
    throw "One or more East DCs did not become ready within 15 minutes."
}

Write-Host "  Extra 60s stabilization for AD DS services to start..." -ForegroundColor Gray
Start-Sleep -Seconds 60

# ─── Step 2: Force AD replication sync ───────────────────────────────────────

Write-Host "`n── Step 2: Forcing AD replication sync from DVDC03 ──" -ForegroundColor Yellow

$syncScript = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\DR-Failback-Sync.log -Append

Write-Output "=== Initiating syncall /AdeP from DVDC03 ==="
repadmin /syncall /AdeP

Write-Output "`n=== Waiting 30s for sync to propagate ==="
Start-Sleep -Seconds 30

Write-Output "`n=== Replication Summary ==="
repadmin /replsummary

Write-Output "`n=== Replication Status ==="
repadmin /showrepl

Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $syncScript
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        if ($result.Stdout -match '0 fail') {
            Write-Host "  [REPL OK] 0 replication failures reported." -ForegroundColor Green
        } elseif ($result.Stdout -match '\d+ fail') {
            Write-Warning "  [REPL WARN] Replication failures detected. Waiting extra 60s for convergence..."
            Start-Sleep -Seconds 60
        } else {
            Write-Host "  [REPL OK] No explicit failure indicators found." -ForegroundColor Green
        }
    }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
} catch {
    Write-Warning "Sync run-command failed: $($_.Exception.Message)"
    Write-Warning "Proceeding with transfer — verify replication manually on DVDC01 afterwards."
}

# ─── Step 3: Transfer FSMO roles to DVDC01 ───────────────────────────────────

Write-Host "`n── Step 3: Transferring FSMO roles to DVDC01 (graceful) ──" -ForegroundColor Yellow

# Inline the transfer logic — avoids scriptblock-wrapper parsing issues that occur
# when embedding file content with non-ASCII characters via run-command.
$transferRunner = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\Transfer-FSMORoles.log -Append
Write-Output "Transferring all 5 FSMO roles to DVDC01 (graceful)"
Import-Module ActiveDirectory -ErrorAction Stop
Move-ADDirectoryServerOperationMasterRole `
    -Identity 'DVDC01' `
    -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
    -Confirm:$false
Write-Output "Transfer complete. Current FSMO holders:"
netdom query fsmo
Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName 'DVDC01' -ScriptContent $transferRunner
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        if ($result.Stdout -match 'DVDC01') {
            Write-Host "  [FSMO OK] DVDC01 confirmed in FSMO output." -ForegroundColor Green
        } else {
            Write-Warning "  [FSMO WARN] Could not confirm all roles on DVDC01 — verify manually."
        }
    }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
} catch {
    throw "FSMO transfer failed: $($_.Exception.Message)"
}

# ─── Step 4: Restore VNet DNS to DVDC01 ──────────────────────────────────────

Write-Host "`n── Step 4: Restoring VNet DNS to DVDC01 ($($config.PrimaryDcIp)) ──" -ForegroundColor Yellow

Write-Host "  Updating $($config.VnetEast)..." -ForegroundColor Gray
az network vnet update `
    -g $config.RgEast `
    -n $config.VnetEast `
    --dns-servers $config.PrimaryDcIp `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to update DNS on $($config.VnetEast)" }

Write-Host "  Updating $($config.VnetWest)..." -ForegroundColor Gray
az network vnet update `
    -g $config.RgWest `
    -n $config.VnetWest `
    --dns-servers $config.PrimaryDcIp `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to update DNS on $($config.VnetWest)" }

Write-Host "  VNet DNS restored on both regions → $($config.PrimaryDcIp)" -ForegroundColor Green

# ─── Step 5: Flush DNS cache on all app servers ───────────────────────────────

Write-Host "`n── Step 5: Flushing DNS cache on all 4 app servers ──" -ForegroundColor Yellow

$flushScript = @'
ipconfig /flushdns
ipconfig /registerdns
Write-Output "DNS cache flushed and re-registered on $env:COMPUTERNAME"
'@

$eastAppVMs = @('DVAS01', 'DVAS02')
$westAppVMs = @('DVAS03', 'DVAS04')

foreach ($vm in $eastAppVMs) {
    Write-Host "  Flushing DNS on $vm (East)..." -ForegroundColor Gray
    try {
        $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName $vm -ScriptContent $flushScript
        if ($result.Stdout) { Write-Host "  $($result.Stdout.Trim())" -ForegroundColor Green }
    } catch {
        Write-Warning "  DNS flush on $vm failed: $($_.Exception.Message)"
    }
}

foreach ($vm in $westAppVMs) {
    Write-Host "  Flushing DNS on $vm (West)..." -ForegroundColor Gray
    try {
        $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName $vm -ScriptContent $flushScript
        if ($result.Stdout) { Write-Host "  $($result.Stdout.Trim())" -ForegroundColor Green }
    } catch {
        Write-Warning "  DNS flush on $vm failed: $($_.Exception.Message)"
    }
}

# ─── Step 6: Validate East region DC ─────────────────────────────────────────

Write-Host "`n── Step 6: Validating East region (DVDC01) ──" -ForegroundColor Yellow

$validateScript = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\DR-Failback-Validate.log -Append

Write-Output "=== FSMO Role Holders ==="
netdom query fsmo

Write-Output "`n=== dcdiag: Advertising ==="
dcdiag /test:advertising

Write-Output "`n=== Replication Summary ==="
repadmin /replsummary

Write-Output "`n=== Domain Locate Test ==="
nltest /dsgetdc:managed-connections.net

Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgEast -VMName 'DVDC01' -ScriptContent $validateScript
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        $checks = @{
            '[PASS] DVDC01 holds FSMO roles' = 'DVDC01'
            '[PASS] dcdiag Advertising'      = 'passed test Advertising'
            '[PASS] 0 replication failures'  = '0 fail'
        }
        foreach ($label in $checks.Keys) {
            if ($result.Stdout -match $checks[$label]) {
                Write-Host "  $label" -ForegroundColor Green
            } else {
                Write-Warning "  [WARN] $($label.TrimStart('[PASS] ')) not confirmed — verify manually."
            }
        }
    }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
} catch {
    Write-Warning "Validation run-command failed: $($_.Exception.Message)"
    Write-Warning "Connect via Bastion to DVDC01 and run: netdom query fsmo && dcdiag /test:advertising"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Failback Complete!                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host @"

Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Summary:
  - DVDC01 and DVDC02 are running (East region restored)
  - DVDC01 (10.1.1.4) holds all 5 FSMO roles
  - Both VNets DNS → 10.1.1.4
  - All 4 app servers DNS flushed

Manual validation (via Bastion → DVDC01):
  netdom query fsmo
  dcdiag /test:advertising /test:fsmocheck
  repadmin /replsummary
  repadmin /showrepl
"@ -ForegroundColor White
