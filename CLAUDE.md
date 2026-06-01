# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Azure-based Active Directory lab: 2 regions (East US 2, Central US), 7 Windows Server 2025 Azure Edition VMs, no public IPs. All management access via Azure Bastion (deleted when idle — recreate with deploy Phase 1). Deployed via Bicep + PowerShell orchestrator.

- **Subscription:** `64d83543-8eda-43a0-b42f-a92876dfb11d`
- **Domain:** `managed-connections.net` (NetBIOS: `MANAGED`)
- **Admin user:** `labadmin`
- **Resource groups:** `rg-east` (eastus2) and `rg-central` (centralus) — pre-existing, not created by Bicep

## Deploy Commands

```powershell
# Full deployment (all 6 phases)
.\deploy\deploy.ps1 -Phase all -AdminPassword '<pw>' -SafeModePassword '<pw>'

# Single phase
.\deploy\deploy.ps1 -Phase 4 -AdminPassword '<pw>' -SafeModePassword '<pw>'

# Promote secondary DCs (DVDC02 + DVDC03) — run after Phase 4 completes
.\deploy\Promote-SecondaryDCs.ps1 -AdminPassword '<pw>' -SafeModePassword '<pw>'

# DR failover: East → Central (~20 min)
.\deploy\Invoke-Failover.ps1 -AdminPassword '<pw>'

# DR failback: Central → East (~25 min)
.\deploy\Invoke-Failback.ps1 -AdminPassword '<pw>'

# Cloud Sync health check (safe to run anytime)
$pass = az keyvault secret show --vault-name kv-mc-ad-east --name vm-admin-password --query value -o tsv
.\deploy\Invoke-CloudSyncHealthCheck.ps1 -AdminPassword $pass
```

## Python User Generation

The `scripts/python/generate_users.py` script regenerates `scripts/python/data/users.csv` (100 AD users across 6 departments). The venv uses only `faker`.

```powershell
# Activate venv (PowerShell)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
& ".\scripts\python\.venv\Scripts\Activate.ps1"

# Install deps (first time)
pip install -r scripts/python/requirements.txt

# Regenerate users.csv + users.json
python scripts/python/generate_users.py
```

The script is seeded (`Faker.seed(42)`) so output is deterministic. The generated CSV is consumed by Phase 6 of `deploy.ps1` — upload to blob storage happens automatically during that phase. Only regenerate if you need different user data; commit the new `users.csv` before redeploying Phase 6.

## Verify Infrastructure

```bash
az vm list -g rg-east -o table       # DVDC001, DVDC002, DVAS01, DVAS02
az vm list -g rg-central -o table    # DVDC003, DVAS03, DVAS04
az network bastion list -o table     # Bastion deleted — recreate via deploy Phase 1
az account show                      # confirm subscription context
```

## Architecture

### Deployment Flow

`deploy.ps1` is the 6-phase orchestrator. **Only phases 1 and 2 call Bicep** (`Deploy-BicepPhase` → `az deployment sub create`). Phases 3–6 use `az vm run-command invoke` directly — no Bicep involvement. The Bicep file does contain `primarydc`, `domainjoin`, and `groups` phases but the orchestrator no longer routes through them.

```
Phase 1 (infra)      → Bicep: NSGs, VNets, Bastion (East only), VNet peering, Storage
Phase 2 (vms)        → Bicep: 7 VMs with static private IPs, no public IPs
Phase 3 (validate)   → run-command: hostname check on all 7 VMs
Phase 4 (primarydc)  → run-command: AD DS install → Install-ADDSForest → DNS forwarder → VNet DNS update → Key Vault secret
Phase 5 (domainjoin) → run-command: Join-DomainAndConfigure.ps1 on DVAS01-04
Phase 6 (groups)     → run-command: Configure-OUs → Create-ADUsers (from CSV) → Create-DepartmentGroups
```

### Bicep Structure

`bicep/main.bicep` is subscription-scoped. A single `deployPhase` parameter gates all modules via `if (deployPhase == '<phase>')`. Resource groups are `existing` references — they are never created by Bicep.

The `vm.bicep` module handles static IP assignment, optional data disk, optional public IP, and auto-shutdown schedule. Scripts run via `vm-extension.bicep` (Custom Script Extension) using SAS-token URLs from `stadlabscripts01`.

### VM Inventory (WS2025 Azure Edition)

| VM | IP | Role | Region |
|---|---|---|---|
| DVDC001 | 10.1.1.6 | PDC / All FSMO / GC | East US 2 |
| DVDC002 | 10.1.1.7 | Replica DC / GC | East US 2 |
| DVDC003 | 10.3.1.5 | Replica DC / GC | Central US |
| DVAS01 | 10.1.2.4 | App server | East US 2 |
| DVAS02 | 10.1.2.5 | App server | East US 2 |
| DVAS03 | 10.3.2.4 | App server | Central US |
| DVAS04 | 10.3.2.5 | App server | Central US |

AD functional level: **Windows2025Forest / Windows2025Domain** (schema version 91)

### Networking Key Facts

- Bastion (`bas-adlab-east`) is **deleted when idle** — recreate: `az network bastion create -g rg-east -n bas-adlab-east --location eastus2 --vnet-name vnet-adlab-east --public-ip-address <pip> --sku Standard`
- VNet peering is bidirectional (`peer-east-to-central` + `peer-central-to-east`)
- East: `10.1.0.0/16` | Central: `10.3.0.0/16`
- DC subnet `.1.0/24`, App subnet `.2.0/24`, Bastion subnet `.3.0/24`
- Both VNets DNS → `10.1.1.6` (DVDC001)

### DR Topology

Normal state: both VNets DNS → `10.1.1.6` (DVDC001)
Failover state: update both VNets DNS → `10.3.1.5` (DVDC003), seize FSMO on DVDC003

FSMO roles are **seized** (forced) during unplanned failover, **transferred** (graceful) during failback. Do not confuse these — seizing during failback will cause USN rollback issues.

## Shell & Scripting Conventions

**az vm run-command and quoting:** The az CLI on Windows (especially Git Bash) mangles argument quoting. The pattern used throughout this repo is to write scripts to a `$env:TEMP` file and pass `--scripts "@$tempScript"`. Never use inline `--scripts` for multi-line PowerShell or scripts with special characters.

```powershell
# Pattern used in deploy.ps1 — write to temp file, invoke, then delete
$tempScript = Join-Path $env:TEMP 'my-remote-script.ps1'
@'
# PowerShell content here — single-quoted heredoc avoids expansion
'@ | Set-Content -Path $tempScript -Encoding UTF8
az vm run-command invoke --resource-group $rg --name $vm `
    --command-id RunPowerShellScript --scripts "@$tempScript" -o json
Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
```

**Heredoc encoding:** Avoid em dashes (`—`), box-drawing characters, and other non-ASCII in heredocs or script files that are pushed through `az vm run-command`. They cause encoding errors that are difficult to diagnose. Use ASCII alternatives.

**PowerShell file encoding:** The `Write` tool creates UTF-8 without BOM. PowerShell 5.1 needs BOM for non-ASCII characters. After writing a `.ps1` with non-ASCII content:
```powershell
powershell -Command "$p='<path>'; Set-Content $p (Get-Content $p -Raw -Encoding UTF8) -Encoding UTF8"
```

**No interactive prompts:** All scripts must be non-interactive. Do not use `Read-Host` or `pause` — the Bash tool is non-interactive. Use parameters or environment variables.

**Process lifecycle:** Use `Start-Process` (PowerShell) rather than bash `&` when launching long-running `dotnet` or server processes. Bash subshells terminate child processes when the shell exits.

**Git Bash path mangling:** When parsing ARM resource IDs in Git Bash, use `MSYS_NO_PATHCONV=1` to prevent path mangling on strings like `/subscriptions/...`.

## Azure Deployment Conventions

**Key Vault roles:** Before running any script that writes Key Vault secrets, confirm the CLI user has the **Key Vault Secrets Officer** role on both `kv-mc-ad-east` and `kv-mc-central`.

**Scripts in blob storage:** All PowerShell scripts in `scripts/powershell/` are uploaded to the `scripts` container in `stadlabscripts01`. The SAS token is generated fresh at the start of each deployment run (4-hour expiry). Do not hardcode SAS tokens.

**VM passwords:** Use `az keyvault secret show` to retrieve passwords rather than hardcoding. `az vm user update` is not supported on Domain Controllers — skip it for DVDC001/DVDC002/DVDC003.

**run-command timeouts:** `Install-ADDSForest` causes a VM reboot mid-command — the run-command will return a non-zero exit code or timeout. This is expected. The pattern is: detect the expected failure, then `Wait-VMAgentReady` until the VM comes back online.

**VNet DNS update timing:** After `az network vnet update --dns-servers`, VMs need `ipconfig /flushdns && ipconfig /registerdns` before they resolve to the new DC. The scripts do this explicitly on app servers; allow 30–60 seconds after the VNet update before testing resolution.

## Cloud Sync

Cloud Sync agents were on the old DVDC01/DVDC03 (now deleted). They have **not yet been reinstalled** on DVDC001/DVDC003. To reinstall, run `deploy/Deploy-CloudSyncAgent.ps1` targeting DVDC001 and DVDC003, then complete interactive tenant registration via the Entra portal (requires Global Admin sign-in).

The health check script (`deploy/Invoke-CloudSyncHealthCheck.ps1`) checks service state, registry registration, event logs, and outbound HTTPS to 4 Entra endpoints. Run it anytime to confirm agent state.

## Destructive Operations

Always use **plan mode** before running destructive Azure operations (subscription cleanup, resource deletion, FSMO seizure). Confirm the exact `az` commands before executing. In particular:

- FSMO seizure (`Move-ADDirectoryServerOperationMasterRole -Force`) is irreversible in the sense that the old holder's metadata is invalidated
- `az vm deallocate` during DR simulation stops billing but the VM must be explicitly restarted for failback
- Key Vault purge protection means deleted vaults cannot be immediately recreated — check `az keyvault list-deleted` before creating vaults with the same name
