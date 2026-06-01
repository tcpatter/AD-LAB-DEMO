Apply all available Windows updates (including optional and driver updates) to all 7 AD Lab VMs using the PSWindowsUpdate module. Runs two passes with reboots between passes to fully patch each VM.

## Lab Context
- Subscription: `64d83543-8eda-43a0-b42f-a92876dfb11d`
- East VMs → `rg-east`: DVDC01, DVDC02, DVAS01, DVAS02
- Central VMs → `rg-central`: DVDC03, DVAS03, DVAS04
- All update execution via `az vm run-command invoke` — no RDP required
- Admin: `MANAGED\labadmin` (not needed for run-command; used for manual Bastion verification only)

## Execution

Spawn **7 parallel sub-agents**, one per VM. Each agent owns its VM end-to-end: start → wait → update (pass 1) → reboot if needed → update (pass 2) → report.

Use this prompt template for each sub-agent, substituting VM_NAME and RESOURCE_GROUP:

```
You are patching a single Azure VM in the AD Lab.

VM: <VM_NAME>
Resource group: <RESOURCE_GROUP>
Subscription: 64d83543-8eda-43a0-b42f-a92876dfb11d

Steps to execute:

1. Set subscription:
   az account set --subscription 64d83543-8eda-43a0-b42f-a92876dfb11d

2. Start the VM:
   az vm start --resource-group <RESOURCE_GROUP> --name <VM_NAME>

3. Wait for agent ready (poll every 20s, timeout 15 min):
   Loop: az vm get-instance-view -g <RESOURCE_GROUP> -n <VM_NAME>
         --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].displayStatus" -o tsv
   Continue when output equals "Ready".

4. Write the update script to C:/Windows/Temp/wu-<VM_NAME>.ps1 using the Write tool.
   Script content: (see ## Update Script below)

5. Run Pass 1:
   az vm run-command invoke --resource-group <RESOURCE_GROUP> --name <VM_NAME>
     --command-id RunPowerShellScript
     --scripts "@C:\Windows\Temp\wu-<VM_NAME>.ps1"
     -o json
   Parse stdout for REBOOT_NEEDED= and INSTALLED_COUNT=

6. If REBOOT_NEEDED=True:
   az vm restart --resource-group <RESOURCE_GROUP> --name <VM_NAME>
   Wait for agent ready again (step 3 pattern).
   Run Pass 2 (same script, same command as step 5).

7. Report: VM name, Pass 1 count, Pass 2 count (if ran), final reboot status.
```

## Update Script

Write this content to `C:/Windows/Temp/wu-<VM_NAME>.ps1` before each run-command invocation:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
$log = "C:\Logs\WU-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
Start-Transcript -Path $log -Append -Force
try {
    Write-Output "=== Windows Update: $env:COMPUTERNAME $(Get-Date) ==="
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Output "Installing PSWindowsUpdate..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Scope AllUsers
    }
    Import-Module PSWindowsUpdate -Force
    $available = @(Get-WindowsUpdate -MicrosoftUpdate)
    Write-Output "AVAILABLE_COUNT=$($available.Count)"
    if ($available.Count -gt 0) {
        $installed = @(Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot)
        Write-Output "INSTALLED_COUNT=$($installed.Count)"
    } else {
        Write-Output "INSTALLED_COUNT=0"
    }
    $reboot = Get-WURebootStatus -Silent
    Write-Output "REBOOT_NEEDED=$reboot"
    Write-Output "LOG=$log"
} catch {
    Write-Output "ERROR: $_"
    Write-Output "REBOOT_NEEDED=False"
} finally {
    Stop-Transcript
}
```

## Check Update Logs Later

Read the most recent update log from any VM:

```powershell
az vm run-command invoke `
    --resource-group <rg> `
    --name <vm> `
    --command-id RunPowerShellScript `
    --scripts 'Get-Content (Get-ChildItem C:\Logs\WU-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName | Select-Object -Last 60 | Out-String' `
    -o json
```

## Required Permissions

The following must be present in `.claude/settings.local.json` before running — sub-agents will stall without them:

```json
"PowerShell(*)",
"Write(*)",
"Bash(sleep *)",
"Bash(while *)",
"Bash(for *)"
```

These are already set in the project settings after the first run.

## Notes

- PSWindowsUpdate uses `-MicrosoftUpdate` to include all update categories (security, optional, drivers)
- `-IgnoreReboot` lets the run-command complete cleanly; reboots are issued separately via `az vm restart`
- Two passes handle the common "updates unlocked after first reboot" scenario
- Logs persist on each VM at `C:\Logs\WU-<timestamp>.log`
- VMs auto-shutdown at 19:00 Eastern — no need to deallocate after patching
- Re-run `/windows-update` any time to apply new patches; already-installed updates are skipped
