<#
.SYNOPSIS
    6-phase deployment orchestrator for the AD Lab environment.
.DESCRIPTION
    Deploys the AD Lab in phases using Azure CLI:
      1. Infra      - RGs, VNets, NSGs, Bastion, Storage, upload scripts
      2. VMs        - All 7 VMs (no domain config, Bastion-only access)
      3. Validate   - Run whoami + hostname on each VM via az vm run-command
      4. PrimaryDC  - Promote DVDC01 as forest root DC, configure DNS, update VNet DNS, validate AD
      5. DomainJoin - Join DVAS01, DVAS02, DVAS03, DVAS04 to managed-connections.net
      6. Groups     - Create 18 department security groups in ADLab/Groups and populate from OUs
.PARAMETER Phase
    Which phase(s) to run: 1-6, 'all', or comma-separated (e.g., '1,2,3,4,5,6')
.PARAMETER AdminPassword
    Password for the VM local admin account (plain text — az cli does not use SecureString)
.PARAMETER SafeModePassword
    DSRM password for Active Directory
.EXAMPLE
    .\deploy.ps1 -Phase all -AdminPassword 'L@bAdmin2026!x' -SafeModePassword 'L@bAdmin2026!x'
.EXAMPLE
    .\deploy.ps1 -Phase 6 -AdminPassword 'L@bAdmin2026!x' -SafeModePassword 'L@bAdmin2026!x'
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
    1..6
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
                        Write-Host " FAIL - az vm run-command returned exit code $LASTEXITCODE" -ForegroundColor Red
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

        4 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 4: Primary Domain Controller      ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            # ── Step 1a: Install AD DS features ──
            Write-Host "`n── Step 1: Promoting DVDC01 as forest root DC ──" -ForegroundColor Yellow
            Write-Host "  Installing AD DS, DNS, GPMC features..." -ForegroundColor Gray

            $installResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts 'Install-WindowsFeature -Name AD-Domain-Services, DNS, GPMC -IncludeManagementTools | Out-String' `
                -o json 2>&1

            if ($LASTEXITCODE -eq 0) {
                $parsed = ($installResult | ConvertFrom-Json)
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) { Write-Host "  $($stdout.Trim())" -ForegroundColor Gray }
            } else {
                throw "Failed to install AD DS features on DVDC01"
            }

            # ── Step 1b: Promote to forest root DC ──
            Write-Host "  Running Install-ADDSForest (this takes ~5-10 min, VM will reboot)..." -ForegroundColor Gray

            # Write script to temp file to avoid az cli quoting issues
            $tempScript = Join-Path $env:TEMP 'promote-dc-remote.ps1'
            @"
param([string]`$pw)
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\Promote-PrimaryDC.log -Append
`$secPw = ConvertTo-SecureString `$pw -AsPlainText -Force
Install-ADDSForest -DomainName '$($config.DomainName)' -DomainNetbiosName 'MANAGED' -SafeModeAdministratorPassword `$secPw -InstallDns:`$true -DatabasePath 'C:\Windows\NTDS' -LogPath 'C:\Windows\NTDS' -SysvolPath 'C:\Windows\SYSVOL' -NoRebootOnCompletion:`$false -Force:`$true
"@ | Set-Content -Path $tempScript -Encoding UTF8

            $result = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts "@$tempScript" `
                --parameters "pw=$SafeModePassword" `
                -o json 2>&1

            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

            # run-command may fail/timeout because the VM reboots mid-command — that's expected
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  run-command exited (expected — VM reboots after promotion)" -ForegroundColor Yellow
            } else {
                $parsed = $result | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) { Write-Host "  Output: $($stdout.Trim())" -ForegroundColor Gray }
            }

            # ── Step 2: Wait for DVDC01 reboot + stabilization ──
            Write-Host "`n── Step 2: Waiting for DVDC01 to reboot and stabilize ──" -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            $ready = Wait-VMAgentReady -ResourceGroupName $config.RgEast -VMName 'DVDC01' -TimeoutMinutes 15
            if (-not $ready) {
                throw "DVDC01 did not come back after promotion reboot."
            }
            Write-Host "  Extra 60s stabilization for AD DS services..." -ForegroundColor Gray
            Start-Sleep -Seconds 60

            # ── Step 3: Configure DNS forwarders ──
            Write-Host "`n── Step 3: Configuring DNS forwarders on DVDC01 ──" -ForegroundColor Yellow

            $dnsResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts 'Import-Module DnsServer; Set-DnsServerForwarder -IPAddress 168.63.129.16; Get-DnsServerForwarder | Out-String' `
                -o json 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "DNS forwarder configuration may have failed. Exit code: $LASTEXITCODE"
            } else {
                $parsed = $dnsResult | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) { Write-Host "  $($stdout.Trim())" -ForegroundColor Green }
            }

            # ── Step 4: Update VNet DNS on both VNets ──
            Write-Host "`n── Step 4: Updating VNet DNS to point to DVDC01 ($($config.PrimaryDcIp)) ──" -ForegroundColor Yellow

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

            Write-Host "  VNet DNS updated on both regions." -ForegroundColor Green

            # ── Step 5: Reset password + update Key Vault ──
            Write-Host "`n── Step 5: Resetting DVDC01 password and updating Key Vault ──" -ForegroundColor Yellow

            az vm user update `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --username $config.AdminUsername `
                --password $AdminPassword `
                --output none 2>$null

            # Update Key Vault secrets in both regions
            $kvEast = az keyvault list -g $config.RgEast --query "[0].name" -o tsv 2>$null
            $kvWest = az keyvault list -g $config.RgWest --query "[0].name" -o tsv 2>$null

            if ($kvEast) {
                az keyvault secret set --vault-name $kvEast --name 'vm-admin-password' --value $AdminPassword --output none
                Write-Host "  Updated secret in $kvEast" -ForegroundColor Green
            }
            if ($kvWest) {
                az keyvault secret set --vault-name $kvWest --name 'vm-admin-password' --value $AdminPassword --output none
                Write-Host "  Updated secret in $kvWest" -ForegroundColor Green
            }

            # ── Step 6: Validate AD ──
            Write-Host "`n── Step 6: Validating Active Directory on DVDC01 ──" -ForegroundColor Yellow

            # Write validation script to temp file to avoid az cli quoting issues
            $tempValidate = Join-Path $env:TEMP 'validate-ad-remote.ps1'
            @'
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $forest = Get-ADForest
    $domain = Get-ADDomain
    Write-Output "Forest: $($forest.Name)"
    Write-Output "Domain: $($domain.DNSRoot)"
    Write-Output "NetBIOS: $($domain.NetBIOSName)"
    Write-Output "ForestMode: $($forest.ForestMode)"
    Write-Output "DomainMode: $($domain.DomainMode)"
    Write-Output "---"
    Write-Output "Running dcdiag..."
    $dcdiag = dcdiag /s:DVDC01 2>&1
    $dcdiag | ForEach-Object { Write-Output $_ }
} catch {
    Write-Output "AD validation error: $_"
}
'@ | Set-Content -Path $tempValidate -Encoding UTF8

            $valResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts "@$tempValidate" `
                -o json 2>&1

            Remove-Item $tempValidate -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0) {
                $parsed = $valResult | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) {
                    Write-Host $stdout -ForegroundColor Cyan
                }
            } else {
                Write-Warning "AD validation run-command failed. You can re-run manually."
            }

            # ── DNS resolution test from DVAS01 ──
            Write-Host "`n  Testing DNS resolution from DVAS01..." -ForegroundColor Yellow

            $nslookupCmd = "nslookup $($config.DomainName) $($config.PrimaryDcIp)"
            $nslookupResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVAS01' `
                --command-id RunPowerShellScript `
                --scripts $nslookupCmd `
                -o json 2>&1

            if ($LASTEXITCODE -eq 0) {
                $parsed = $nslookupResult | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) { Write-Host "  $($stdout.Trim())" -ForegroundColor Cyan }
            } else {
                Write-Warning "DNS resolution test from DVAS01 failed."
            }

            Write-Host "`n  Phase 4 complete. Validate Bastion RDP with MANAGED\labadmin." -ForegroundColor Green
        }

        5 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 5: Domain Join Member Servers     ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            # Ensure scripts are uploaded and SAS token is available
            if (-not $sasToken) {
                Write-Host "`nUploading scripts to storage and generating SAS token..." -ForegroundColor Yellow
                $sasToken = Upload-ScriptsToStorage
            }

            # Deploy CSE to all 4 member servers
            Write-Host "`n── Deploying domain join CSE to DVAS01, DVAS02, DVAS03, DVAS04 ──" -ForegroundColor Yellow
            Deploy-BicepPhase -PhaseName 'domainjoin' -ExtraParams @{ scriptSasToken = $sasToken }

            # Wait for VMs to reboot and rejoin
            Write-Host "`n── Waiting for member servers to reboot after domain join ──" -ForegroundColor Yellow
            Write-Host "  (VMs restart automatically after joining the domain)" -ForegroundColor Gray
            Start-Sleep -Seconds 60

            $memberVMs = @(
                @{ RG = $config.RgEast; Name = 'DVAS01' }
                @{ RG = $config.RgEast; Name = 'DVAS02' }
                @{ RG = $config.RgWest; Name = 'DVAS03' }
                @{ RG = $config.RgWest; Name = 'DVAS04' }
            )

            foreach ($vm in $memberVMs) {
                Wait-VMAgentReady -ResourceGroupName $vm.RG -VMName $vm.Name -TimeoutMinutes 20
            }

            # Validate domain membership
            Write-Host "`n── Validating domain membership ──" -ForegroundColor Yellow
            foreach ($vm in $memberVMs) {
                Write-Host "  Checking $($vm.Name)..." -ForegroundColor Yellow -NoNewline
                try {
                    $result = az vm run-command invoke `
                        --resource-group $vm.RG `
                        --name $vm.Name `
                        --command-id RunPowerShellScript `
                        --scripts '(Get-WmiObject Win32_ComputerSystem).PartOfDomain; (Get-WmiObject Win32_ComputerSystem).Domain' `
                        -o json 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        $parsed = $result | ConvertFrom-Json
                        $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                        if ($stdout -and $stdout -match 'True') {
                            Write-Host " JOINED — $($stdout.Trim())" -ForegroundColor Green
                        } else {
                            Write-Host " NOT JOINED — $($stdout.Trim())" -ForegroundColor Red
                        }
                    } else {
                        Write-Host " FAIL — run-command error" -ForegroundColor Red
                    }
                }
                catch {
                    Write-Host " FAIL — $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            Write-Host "`n  Phase 5 complete. Member servers should be joined to $($config.DomainName)." -ForegroundColor Green
        }

        6 {
            Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║  PHASE 6: Department Security Groups     ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green

            # Wrap script content in a scriptblock call with DomainDN hardcoded
            # (avoids --parameters quoting issues with '=' and ',' in the DomainDN value)
            Write-Host "`n── Running Create-DepartmentGroups.ps1 on DVDC01 ──" -ForegroundColor Yellow
            $createGroupsScript = Join-Path $config.ScriptsPath 'Create-DepartmentGroups.ps1'
            $scriptContent = Get-Content $createGroupsScript -Raw

            $tempGroupsRunner = Join-Path $env:TEMP 'run-groups-remote.ps1'
            # Invoke as a scriptblock so the param() block receives the named argument
            "& {`n$scriptContent`n} -DomainDN '$($config.DomainDN)'" |
                Set-Content -Path $tempGroupsRunner -Encoding UTF8

            $groupResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts "@$tempGroupsRunner" `
                -o json 2>&1

            Remove-Item $tempGroupsRunner -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -ne 0) {
                throw "Create-DepartmentGroups.ps1 failed on DVDC01. Exit code: $LASTEXITCODE"
            } else {
                $parsed = $groupResult | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                $stderr = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdErr/succeeded' }).message
                if ($stdout) { Write-Host $stdout -ForegroundColor Cyan }
                if ($stderr) { Write-Host "StdErr: $stderr" -ForegroundColor Yellow }
            }

            # Validate: check that all 18 groups exist and have >= 1 member
            Write-Host "`n── Validating group count and membership on DVDC01 ──" -ForegroundColor Yellow

            $tempValidateGroups = Join-Path $env:TEMP 'validate-groups-remote.ps1'
            @'
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $groupsOU = "OU=Groups,OU=ADLab,DC=managed-connections,DC=net"
    $groups = Get-ADGroup -Filter * -SearchBase $groupsOU -SearchScope OneLevel
    $count = @($groups).Count
    Write-Output "Total groups in ADLab/Groups: $count (expected 18)"
    $emptyGroups = 0
    foreach ($g in $groups) {
        $members = @(Get-ADGroupMember -Identity $g.Name -ErrorAction SilentlyContinue).Count
        if ($members -eq 0) {
            Write-Output "[WARN] $($g.Name) — 0 members"
            $emptyGroups++
        } else {
            Write-Output "[PASS] $($g.Name) — $members member(s)"
        }
    }
    Write-Output "---"
    Write-Output "Groups with 0 members: $emptyGroups"
} catch {
    Write-Output "Validation error: $_"
}
'@ | Set-Content -Path $tempValidateGroups -Encoding UTF8

            $valResult = az vm run-command invoke `
                --resource-group $config.RgEast `
                --name 'DVDC01' `
                --command-id RunPowerShellScript `
                --scripts "@$tempValidateGroups" `
                -o json 2>&1

            Remove-Item $tempValidateGroups -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0) {
                $parsed = $valResult | ConvertFrom-Json
                $stdout = ($parsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' }).message
                if ($stdout) { Write-Host $stdout -ForegroundColor Cyan }
            } else {
                Write-Warning "Group validation run-command failed. Check C:\Logs\Create-DepartmentGroups.log on DVDC01."
            }

            Write-Host "`n  Phase 6 complete. AD replication will propagate groups to DVDC02/DVDC03." -ForegroundColor Green
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
  6. Bastion RDP to DVDC01 with MANAGED\labadmin (after Phase 4)
  7. Get-ADForest shows managed-connections.net  (after Phase 4)
"@
