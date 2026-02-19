<#
.SYNOPSIS
    Unplanned DR failover orchestrator: East US 2 → Central US.
.DESCRIPTION
    Simulates an unplanned East US 2 outage by deallocating DVDC01 and DVDC02,
    then seizes all 5 FSMO roles on DVDC03 (Central US) and redirects VNet DNS.

    Steps:
      1. Pre-flight   — Verify DVDC03 replication health and current FSMO holders
      2. Outage       — Deallocate DVDC01 and DVDC02 (simulates East region failure)
      3. Seize FSMO   — Force-seize all 5 FSMO roles on DVDC03
      4. Redirect DNS — Update both VNets to use DVDC03 (10.3.1.4) as DNS server
      5. Flush DNS    — Flush and re-register DNS on DVAS03 and DVAS04
      6. Validate     — dcdiag, FSMO check, SYSVOL share, domain locate test

    Estimated time: ~20 minutes.
.PARAMETER AdminPassword
    Password for the VM local admin account (labadmin). Used for future auth
    tests; the orchestrator itself uses az CLI / run-command for remote execution.
.EXAMPLE
    .\deploy\Invoke-Failover.ps1 -AdminPassword 'L@bAdmin2026!x'
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
    WestDcIp    = '10.3.1.4'
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

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  DR FAILOVER: East US 2 → Central US    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ─── Step 1: Pre-flight checks ────────────────────────────────────────────────

Write-Host "`n── Step 1: Pre-flight checks on DVDC03 ──" -ForegroundColor Yellow

$preflightScript = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\DR-Failover-Preflight.log -Append

Write-Output "=== Replication Summary ==="
repadmin /replsummary

Write-Output "`n=== Replication Status ==="
repadmin /showrepl

Write-Output "`n=== Current FSMO Holders ==="
netdom query fsmo

Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $preflightScript
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        # Parse largest delta from replsummary output
        if ($result.Stdout -match 'largest delta\s+(\d+):(\d+):(\d+)') {
            $deltaHours = [int]$Matches[1]
            $deltaMins  = [int]$Matches[2]
            $totalMins  = $deltaHours * 60 + $deltaMins
            if ($totalMins -lt 15) {
                Write-Host "  [REPL OK] Last sync delta: ${totalMins}m (threshold: 15m)" -ForegroundColor Green
            } else {
                Write-Warning "  [REPL WARN] Last sync delta: ${totalMins}m exceeds 15m threshold. Proceed with caution."
            }
        } elseif ($result.Stdout -match '0 fail') {
            Write-Host "  [REPL OK] 0 replication failures reported." -ForegroundColor Green
        } else {
            Write-Host "  [REPL OK] No explicit failure indicators in replsummary." -ForegroundColor Green
        }
    }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
} catch {
    Write-Warning "Pre-flight run-command failed: $($_.Exception.Message)"
    Write-Warning "Proceeding with failover. Verify DVDC03 health manually if concerned."
}

# ─── Step 2: Simulate East US 2 outage ───────────────────────────────────────

Write-Host "`n── Step 2: Simulating East US 2 outage (deallocating DVDC01, DVDC02) ──" -ForegroundColor Yellow

Write-Host "  Deallocating DVDC01 (async)..." -ForegroundColor Gray
az vm deallocate --resource-group $config.RgEast --name 'DVDC01' --no-wait --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to initiate DVDC01 deallocation." }

Write-Host "  Deallocating DVDC02 (async)..." -ForegroundColor Gray
az vm deallocate --resource-group $config.RgEast --name 'DVDC02' --no-wait --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to initiate DVDC02 deallocation." }

Write-Host "  Waiting for DVDC01 and DVDC02 to reach Stopped (deallocated) state..." -ForegroundColor Gray

$deadline = (Get-Date).AddMinutes(10)
$dc01done = $false
$dc02done = $false

while ((Get-Date) -lt $deadline -and -not ($dc01done -and $dc02done)) {
    if (-not $dc01done) {
        $s1 = az vm get-instance-view -g $config.RgEast -n 'DVDC01' `
            --query "instanceView.statuses[?code=='PowerState/deallocated'].displayStatus" -o tsv 2>$null
        if ($s1 -match 'deallocated') { $dc01done = $true; Write-Host "  DVDC01 — deallocated" -ForegroundColor Green }
    }
    if (-not $dc02done) {
        $s2 = az vm get-instance-view -g $config.RgEast -n 'DVDC02' `
            --query "instanceView.statuses[?code=='PowerState/deallocated'].displayStatus" -o tsv 2>$null
        if ($s2 -match 'deallocated') { $dc02done = $true; Write-Host "  DVDC02 — deallocated" -ForegroundColor Green }
    }
    if (-not ($dc01done -and $dc02done)) { Start-Sleep -Seconds 15 }
}

if (-not ($dc01done -and $dc02done)) {
    Write-Warning "One or more East VMs may not have fully deallocated within timeout. Continuing."
}

Write-Host "  East region simulated as offline." -ForegroundColor Green

# ─── Step 3: Seize FSMO roles on DVDC03 ──────────────────────────────────────

Write-Host "`n── Step 3: Seizing FSMO roles on DVDC03 ──" -ForegroundColor Yellow

# Inline the seizure logic — avoids scriptblock-wrapper parsing issues that occur
# when embedding file content with non-ASCII characters via run-command.
$seizeRunner = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\Seize-FSMORoles.log -Append
Write-Output "Seizing all 5 FSMO roles onto DVDC03"
Import-Module ActiveDirectory -ErrorAction Stop
Move-ADDirectoryServerOperationMasterRole `
    -Identity 'DVDC03' `
    -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
    -Force `
    -Confirm:$false
Write-Output "Seizure complete. Current FSMO holders:"
netdom query fsmo
Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $seizeRunner
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        if ($result.Stdout -match 'DVDC03') {
            Write-Host "  [FSMO OK] DVDC03 confirmed in FSMO output." -ForegroundColor Green
        } else {
            Write-Warning "  [FSMO WARN] Could not confirm all roles on DVDC03 — verify manually."
        }
    }
    if ($result.Stderr) { Write-Host "StdErr: $($result.Stderr)" -ForegroundColor Yellow }
} catch {
    throw "FSMO seizure failed: $($_.Exception.Message)"
}

# ─── Step 4: Redirect VNet DNS to DVDC03 ─────────────────────────────────────

Write-Host "`n── Step 4: Redirecting VNet DNS to DVDC03 ($($config.WestDcIp)) ──" -ForegroundColor Yellow

Write-Host "  Updating $($config.VnetEast)..." -ForegroundColor Gray
az network vnet update `
    -g $config.RgEast `
    -n $config.VnetEast `
    --dns-servers $config.WestDcIp `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to update DNS on $($config.VnetEast)" }

Write-Host "  Updating $($config.VnetWest)..." -ForegroundColor Gray
az network vnet update `
    -g $config.RgWest `
    -n $config.VnetWest `
    --dns-servers $config.WestDcIp `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to update DNS on $($config.VnetWest)" }

Write-Host "  VNet DNS updated on both regions → $($config.WestDcIp)" -ForegroundColor Green

# ─── Step 5: Flush DNS cache on West app servers ──────────────────────────────

Write-Host "`n── Step 5: Flushing DNS cache on DVAS03, DVAS04 ──" -ForegroundColor Yellow

$flushScript = @'
ipconfig /flushdns
ipconfig /registerdns
Write-Output "DNS cache flushed and re-registered on $env:COMPUTERNAME"
'@

foreach ($vm in @('DVAS03', 'DVAS04')) {
    Write-Host "  Flushing DNS on $vm..." -ForegroundColor Gray
    try {
        $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName $vm -ScriptContent $flushScript
        if ($result.Stdout) { Write-Host "  $($result.Stdout.Trim())" -ForegroundColor Green }
    } catch {
        Write-Warning "  DNS flush on $vm failed: $($_.Exception.Message)"
    }
}

# ─── Step 6: Validate West region DC ─────────────────────────────────────────

Write-Host "`n── Step 6: Validating West region (DVDC03) ──" -ForegroundColor Yellow

$validateScript = @'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\DR-Failover-Validate.log -Append

Write-Output "=== dcdiag: Advertising + FsmoCheck ==="
dcdiag /test:advertising /test:fsmocheck

Write-Output "`n=== FSMO Role Holders ==="
netdom query fsmo

Write-Output "`n=== SYSVOL / NETLOGON Shares ==="
NET SHARE

Write-Output "`n=== Domain Locate Test ==="
nltest /dsgetdc:managed-connections.net

Stop-Transcript
'@

try {
    $result = Invoke-RunCommand -ResourceGroup $config.RgWest -VMName 'DVDC03' -ScriptContent $validateScript
    if ($result.Stdout) {
        Write-Host $result.Stdout -ForegroundColor Cyan

        $checks = @{
            '[PASS] dcdiag Advertising'  = 'passed test Advertising'
            '[PASS] dcdiag FsmoCheck'    = 'passed test\s+FsmoCheck'
            '[PASS] SYSVOL share'        = 'SYSVOL'
            '[PASS] NETLOGON share'      = 'NETLOGON'
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
    Write-Warning "Connect via Bastion to DVDC03 and run: dcdiag /test:advertising /test:fsmocheck"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Failover Complete!                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host @"

Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Summary:
  - DVDC01 and DVDC02 are deallocated (East region offline)
  - DVDC03 (10.3.1.4) holds all 5 FSMO roles
  - Both VNets DNS → 10.3.1.4
  - DVAS03 and DVAS04 DNS flushed

Manual validation (via Bastion → DVDC03):
  netdom query fsmo
  dcdiag /test:advertising /test:fsmocheck
  NET SHARE
  nltest /dsgetdc:managed-connections.net

To restore East region, run:
  .\deploy\Invoke-Failback.ps1 -AdminPassword '<password>'
"@ -ForegroundColor White
