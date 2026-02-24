<#
.SYNOPSIS
    Cloud Sync agent health check and force-refresh for DVDC01 and DVDC03.
.DESCRIPTION
    Reports a pre-restart baseline for both Cloud Sync agents, force-restarts the
    AADConnectProvisioningAgent service on each VM (triggering an immediate Entra
    re-handshake and fresh event log entries), then reports post-restart health to
    confirm the service recovered cleanly.

    Steps:
      1. Pre-restart baseline  — Health check on DVDC01 (East US 2) and DVDC03 (Central US)
      2. Force restart         — Stop/Start AADConnectProvisioningAgent on DVDC01, then DVDC03
      3. Post-restart health   — Re-run health check on both VMs
      4. Summary               — Before/after comparison table

    Estimated time: ~4 minutes.

    Note: REG_PATH_MISSING is expected when agents have been installed but not yet
    registered to an Entra tenant. Complete the registration wizard via Bastion to
    resolve it.
.PARAMETER AdminPassword
    Password for the VM local admin account (labadmin). Consistent with all other
    deploy scripts; not used directly for run-command auth.
.EXAMPLE
    $pass = az keyvault secret show --vault-name kv-adlab-east --name vm-admin-password --query value -o tsv
    .\deploy\Invoke-CloudSyncHealthCheck.ps1 -AdminPassword $pass
#>

param(
    [Parameter(Mandatory)]
    [string]$AdminPassword
)

# Continue — health check must always run to completion and print results even if
# one VM is unhealthy.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# ─── Configuration ────────────────────────────────────────────────────────────

$config = @{
    RgEast = 'rg-ADLab-East'
    RgWest = 'rg-ADLab-West'
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

# ─── Helper: Test Cloud Sync agent health ────────────────────────────────────
# Returns @{ Ok = [bool]; Summary = [string] } for use in the before/after table.

function Test-CloudSyncAgentHealth {
    param(
        [string]$ResourceGroup,
        [string]$VMName
    )

    Write-Host "  Checking Cloud Sync agent on $VMName..." -ForegroundColor Gray

    $healthScript = @'
# 1. Service state
$svc = Get-Service -Name 'AADConnectProvisioningAgent' -ErrorAction SilentlyContinue
Write-Output "CLOUDSYNC_SERVICE: $(if ($svc) { $svc.Status } else { 'NOT_FOUND' })"

# 2. Registry registration (TenantId key = agent registered)
$regPath = 'HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent'
if (Test-Path $regPath) {
    $tenantId = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).TenantId
    Write-Output "CLOUDSYNC_REGISTERED: $(if ($tenantId) { 'YES' } else { 'NO_TENANT_ID' })"
} else {
    Write-Output "CLOUDSYNC_REGISTERED: REG_PATH_MISSING"
}

# 3. Event log — last 2 hours
$logName = 'Microsoft-AAD-Connect-ProvisioningAgent/Admin'
try {
    $events = Get-WinEvent -LogName $logName -MaxEvents 50 -ErrorAction Stop |
              Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) }
    $errCnt  = ($events | Where-Object { $_.Level -le 2 }).Count
    $last    = $events | Select-Object -First 1
    Write-Output "CLOUDSYNC_LAST_EVENT: $(if ($last) { $last.TimeCreated.ToString('HH:mm:ss') + ' ID=' + $last.Id } else { 'NONE_IN_2H' })"
    Write-Output "CLOUDSYNC_ERRORS_2H: $errCnt"
} catch {
    Write-Output "CLOUDSYNC_EVENTLOG: CANNOT_READ"
}

# 4. Outbound HTTPS connectivity
foreach ($ep in @('login.microsoftonline.com','management.azure.com',
                   'login.windows.net','aadcdn.msftauthimages.net')) {
    $ok = (Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
    Write-Output "CLOUDSYNC_CONN_${ep}: $ok"
}
'@

    try {
        $result = Invoke-RunCommand -ResourceGroup $ResourceGroup -VMName $VMName -ScriptContent $healthScript
        $out = if ($result.Stdout) { $result.Stdout } else { '' }
        $allOk = $true
        $svcSummary = 'UNKNOWN'
        $regSummary = 'UNKNOWN'

        # Service state
        if ($out -match 'CLOUDSYNC_SERVICE:\s*(\S+)') {
            $svcState = $Matches[1]
            $svcSummary = $svcState
            if ($svcState -eq 'Running') {
                Write-Host "    Service:     Running" -ForegroundColor Green
            } else {
                Write-Host "    Service:     $svcState" -ForegroundColor Red
                $allOk = $false
            }
        }

        # Registration
        if ($out -match 'CLOUDSYNC_REGISTERED:\s*(\S+)') {
            $reg = $Matches[1]
            $regSummary = $reg
            if ($reg -eq 'YES') {
                Write-Host "    Registered:  YES" -ForegroundColor Green
            } else {
                Write-Host "    Registered:  $reg" -ForegroundColor Yellow
                $allOk = $false
            }
        }

        # Event log
        if ($out -match 'CLOUDSYNC_EVENTLOG:\s*CANNOT_READ') {
            Write-Host "    Event log:   CANNOT_READ (log name may differ - run Get-WinEvent -ListLog *Provisioning* via Bastion)" -ForegroundColor Yellow
        } else {
            if ($out -match 'CLOUDSYNC_LAST_EVENT:\s*(.+)') {
                Write-Host "    Last event:  $($Matches[1].Trim())" -ForegroundColor Gray
            }
            if ($out -match 'CLOUDSYNC_ERRORS_2H:\s*(\d+)') {
                $errCnt2h = [int]$Matches[1]
                if ($errCnt2h -eq 0) {
                    Write-Host "    Errors (2h): 0" -ForegroundColor Green
                } else {
                    Write-Host "    Errors (2h): $errCnt2h" -ForegroundColor Yellow
                    $allOk = $false
                }
            }
        }

        # Connectivity
        $connEndpoints = @('login.microsoftonline.com','management.azure.com','login.windows.net','aadcdn.msftauthimages.net')
        foreach ($ep in $connEndpoints) {
            $escapedEp = [regex]::Escape($ep)
            if ($out -match "CLOUDSYNC_CONN_${escapedEp}:\s*(\S+)") {
                $connOk = $Matches[1]
                if ($connOk -eq 'True') {
                    Write-Host "    Conn ${ep}: OK" -ForegroundColor Green
                } else {
                    Write-Host "    Conn ${ep}: FAILED" -ForegroundColor Red
                    $allOk = $false
                }
            }
        }

        return @{
            Ok      = $allOk
            Summary = "Service: $svcSummary / $regSummary"
        }
    } catch {
        Write-Warning "  Cloud Sync health check failed on ${VMName}: $($_.Exception.Message)"
        return @{
            Ok      = $false
            Summary = 'CHECK FAILED'
        }
    }
}

# ─── Helper: Format summary entry ─────────────────────────────────────────────

function Format-SummaryEntry {
    param([string]$Summary)
    if ($Summary -match 'REG_PATH_MISSING') {
        return "$Summary [EXPECTED - agent not tenant-registered]"
    }
    return $Summary
}

# ─── Banner ───────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  CLOUD SYNC HEALTH CHECK + FORCE REFRESH ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ─── Step 1: Pre-restart baseline ─────────────────────────────────────────────

Write-Host "`n── Step 1: Pre-restart baseline ──" -ForegroundColor Yellow

Write-Host "  DVDC01 (East US 2):" -ForegroundColor Gray
$pre01 = Test-CloudSyncAgentHealth -ResourceGroup $config.RgEast -VMName 'DVDC01'

Write-Host "  DVDC03 (Central US):" -ForegroundColor Gray
$pre03 = Test-CloudSyncAgentHealth -ResourceGroup $config.RgWest -VMName 'DVDC03'

# ─── Step 2: Force service restart ────────────────────────────────────────────

Write-Host "`n── Step 2: Force-restarting AADConnectProvisioningAgent ──" -ForegroundColor Yellow

$restartScript = @'
Stop-Service AADConnectProvisioningAgent -Force -ErrorAction SilentlyContinue
(Get-Service AADConnectProvisioningAgent).WaitForStatus('Stopped', '00:00:30')
Start-Service AADConnectProvisioningAgent
(Get-Service AADConnectProvisioningAgent).WaitForStatus('Running', '00:01:00')
Write-Output "RESTART_STATUS: $((Get-Service AADConnectProvisioningAgent).Status)"
'@

$vmsToRestart = @(
    @{ Name = 'DVDC01'; Rg = $config.RgEast },
    @{ Name = 'DVDC03'; Rg = $config.RgWest }
)

foreach ($vm in $vmsToRestart) {
    Write-Host "  Restarting AADConnectProvisioningAgent on $($vm.Name)..." -ForegroundColor Gray
    try {
        $result = Invoke-RunCommand -ResourceGroup $vm.Rg -VMName $vm.Name -ScriptContent $restartScript
        if ($result.Stdout -match 'RESTART_STATUS:\s*(\S+)') {
            $svcStatus = $Matches[1]
            if ($svcStatus -eq 'Running') {
                Write-Host "    $($vm.Name): RESTART_STATUS: $svcStatus" -ForegroundColor Green
            } else {
                Write-Host "    $($vm.Name): RESTART_STATUS: $svcStatus" -ForegroundColor Red
            }
        }
        if ($result.Stderr) { Write-Host "    StdErr: $($result.Stderr)" -ForegroundColor Yellow }
    } catch {
        Write-Warning "  Service restart on $($vm.Name) failed: $($_.Exception.Message)"
    }

    Write-Host "  Waiting 30s for $($vm.Name) agent to re-establish Entra connection..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

# ─── Step 3: Post-restart health check ────────────────────────────────────────

Write-Host "`n── Step 3: Post-restart health check ──" -ForegroundColor Yellow

Write-Host "  DVDC01 (East US 2):" -ForegroundColor Gray
$post01 = Test-CloudSyncAgentHealth -ResourceGroup $config.RgEast -VMName 'DVDC01'

Write-Host "  DVDC03 (Central US):" -ForegroundColor Gray
$post03 = Test-CloudSyncAgentHealth -ResourceGroup $config.RgWest -VMName 'DVDC03'

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Health Check Complete                   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""
Write-Host "Before / After:" -ForegroundColor White
Write-Host "  DVDC01: $(Format-SummaryEntry $pre01.Summary)  ->  $(Format-SummaryEntry $post01.Summary)" -ForegroundColor White
Write-Host "  DVDC03: $(Format-SummaryEntry $pre03.Summary)  ->  $(Format-SummaryEntry $post03.Summary)" -ForegroundColor White
Write-Host ""
Write-Host "Note: REG_PATH_MISSING persists until the agent registration wizard is completed" -ForegroundColor White
Write-Host "with an Entra Global Administrator account. To register:" -ForegroundColor White
Write-Host "  Bastion -> DVDC01 (or DVDC03) -> Run the Microsoft Entra Connect Provisioning" -ForegroundColor White
Write-Host "  Agent configuration wizard and sign in interactively." -ForegroundColor White
Write-Host ""
Write-Host "To verify sync status in Entra:" -ForegroundColor White
Write-Host "  entra.microsoft.com -> Identity -> Hybrid management -> Microsoft Entra Connect -> Cloud sync" -ForegroundColor White

