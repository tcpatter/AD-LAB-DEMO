# AD Lab DR Runbook — East US 2 ↔ Central US

## Overview

This runbook covers an unplanned DR failover exercise for the AD Lab: simulating an East US 2
region failure, recovering full AD and app server function from Central US (DVDC03), and
performing a graceful failback once East is restored.

This follows Microsoft's guidance:
- **Unplanned outage** → **seize** FSMO roles on the surviving DC (DVDC03)
- **Planned failback** → **transfer** FSMO roles gracefully back to DVDC01 (do not seize)

> **Scope:** This is a lab exercise. DVDC01/DVDC02 are deallocated via az CLI to simulate
> the outage — they are not destroyed and can be restarted for failback.

---

## DR Topology

```
                    ┌─────────────────────────────────────────────────────┐
                    │                 AD Forest                           │
                    │         managed-connections.net                     │
                    └──────────────────┬──────────────────────────────────┘
                                       │
            ┌──────────────────────────┴──────────────────────────┐
            │  East US 2 (PRIMARY)                                │  Central US (DR)
            │  rg-ADLab-East                                      │  rg-ADLab-West
            │                                                     │
            │  DVDC01  10.1.1.4  ◄── forest root, FSMO holder    │  DVDC03  10.3.1.4
            │  DVDC02  10.1.1.5  ◄── replica DC                  │          replica DC
            │                                                     │
            │  DVAS01  10.1.2.4  app server                       │  DVAS03  10.3.2.4
            │  DVAS02  10.1.2.5  app server                       │  DVAS04  10.3.2.5
            │                                                     │
            └──────────────────── VNet Peering ───────────────────┘
              vnet-adlab-east                    vnet-adlab-west
              10.1.0.0/16                        10.3.0.0/16
```

**Normal state:** Both VNets DNS → 10.1.1.4 (DVDC01)
**Failover state:** Both VNets DNS → 10.3.1.4 (DVDC03)

---

## RTO / RPO

| Metric | Estimate | Notes |
|---|---|---|
| RTO (failover) | ~20 min | Deallocate → seize → DNS update → validate |
| RTO (failback) | ~25 min | Start VMs → sync → transfer → DNS restore → validate |
| RPO | Last AD replication cycle | Typically ≤ 5 min in healthy lab; check `repadmin /replsummary` |

---

## Prerequisites

Before running either script:

- [ ] Azure CLI authenticated: `az account show`
- [ ] PowerShell 7+ (pwsh)
- [ ] DVDC03 is running and healthy (check: `az vm get-instance-view -g rg-ADLab-West -n DVDC03`)
- [ ] VNet peering is active between East and West
- [ ] AD replication is healthy: `repadmin /replsummary` shows 0 failures
- [ ] Know current FSMO holders: `netdom query fsmo` (from Bastion → DVDC01)

---

## Pre-Failover Checklist

Run from Bastion → DVDC01 before starting the failover:

```powershell
# 1. Confirm replication health
repadmin /replsummary
repadmin /showrepl

# 2. Note current FSMO holders (should all be DVDC01)
netdom query fsmo

# 3. Note last replication timestamp
repadmin /showrepl | Select-String 'Last attempt'

# 4. Confirm DVDC03 is in sync
repadmin /showrepl DVDC03
```

Expected output from `netdom query fsmo`:

```
Schema owner          DVDC01.managed-connections.net
Domain role owner     DVDC01.managed-connections.net
PDC role              DVDC01.managed-connections.net
RID pool manager      DVDC01.managed-connections.net
Infrastructure owner  DVDC01.managed-connections.net
```

---

## Failover Procedure

### Quick Start

```powershell
.\deploy\Invoke-Failover.ps1 -AdminPassword 'L@bAdmin2026!x'
```

### What the Script Does (step by step)

#### Step 1 — Pre-flight (DVDC03)

Runs `repadmin /replsummary`, `repadmin /showrepl`, and `netdom query fsmo` on DVDC03 via
az vm run-command. Warns if last sync delta exceeds 15 minutes.

**Expected output:**
```
=== Replication Summary ===
Replication Summary Start Time: ...
Beginning data collection for replication summary, this may take a while:
Source DSA          largest delta    fails/total %%   error
 DVDC01             00:02:14             0 /  5    0
...
[REPL OK] Last sync delta: 2m (threshold: 15m)
```

#### Step 2 — Simulate Outage (East VMs deallocated)

Deallocates DVDC01 and DVDC02 asynchronously, then polls until both reach
`PowerState/deallocated`.

**Expected output:**
```
  Deallocating DVDC01 (async)...
  Deallocating DVDC02 (async)...
  DVDC01 — deallocated
  DVDC02 — deallocated
  East region simulated as offline.
```

#### Step 3 — Seize FSMO Roles (on DVDC03)

Runs `Seize-FSMORoles.ps1` on DVDC03 via run-command. Uses `Move-ADDirectoryServerOperationMasterRole -Force` to seize all 5 roles.

**Expected output:**
```
=== Seizing all FSMO roles onto DVDC03 ===
...
Schema owner          DVDC03.managed-connections.net
Domain role owner     DVDC03.managed-connections.net
PDC role              DVDC03.managed-connections.net
RID pool manager      DVDC03.managed-connections.net
Infrastructure owner  DVDC03.managed-connections.net
[FSMO OK] DVDC03 confirmed in FSMO output.
```

#### Step 4 — Redirect DNS

Updates `vnet-adlab-east` and `vnet-adlab-west` DNS servers to `10.3.1.4` (DVDC03).

#### Step 5 — Flush DNS (DVAS03, DVAS04)

Runs `ipconfig /flushdns && ipconfig /registerdns` on both West app servers.

#### Step 6 — Validate (DVDC03)

```
[PASS] dcdiag Advertising
[PASS] dcdiag FsmoCheck
[PASS] SYSVOL share
[PASS] NETLOGON share
```

---

## Post-Failover Validation

Connect via Bastion to DVDC03 and run:

```powershell
# All 5 roles should show DVDC03
netdom query fsmo

# Both tests should pass
dcdiag /test:advertising /test:fsmocheck

# SYSVOL and NETLOGON must be present
NET SHARE

# Should return \\DVDC03
nltest /dsgetdc:managed-connections.net

# No failures
repadmin /replsummary
```

From DVAS03 or DVAS04:

```powershell
# Should resolve to 10.3.1.4
nslookup managed-connections.net

# Should return DVDC03
nltest /dsgetdc:managed-connections.net
```

---

## Failback Procedure

Run this after East is ready to resume operations.

### Quick Start

```powershell
.\deploy\Invoke-Failback.ps1 -AdminPassword 'L@bAdmin2026!x'
```

### What the Script Does (step by step)

#### Step 1 — Start East VMs

Starts DVDC01 and DVDC02 asynchronously, then waits for each VM agent to report Ready.
Adds 60 seconds of stabilization for AD DS services.

**Expected output:**
```
  Starting DVDC01 (async)...
  Starting DVDC02 (async)...
  DVDC01 — agent ready
  DVDC02 — agent ready
  Extra 60s stabilization for AD DS services to start...
```

#### Step 2 — Force Replication Sync

Runs `repadmin /syncall /AdeP` on DVDC03 to push all changes to DVDC01, then waits 30 seconds
and checks `repadmin /replsummary` for 0 failures.

**Expected output:**
```
=== Initiating syncall /AdeP from DVDC03 ===
SyncAll terminated with no errors.
...
[REPL OK] 0 replication failures reported.
```

If failures are detected, the script waits an extra 60 seconds before continuing.

#### Step 3 — Transfer FSMO Roles (on DVDC01)

Runs `Transfer-FSMORoles.ps1` on DVDC01 via run-command. Uses
`Move-ADDirectoryServerOperationMasterRole` **without** `-Force` for a graceful transfer.

**Expected output:**
```
Schema owner          DVDC01.managed-connections.net
Domain role owner     DVDC01.managed-connections.net
PDC role              DVDC01.managed-connections.net
RID pool manager      DVDC01.managed-connections.net
Infrastructure owner  DVDC01.managed-connections.net
[FSMO OK] DVDC01 confirmed in FSMO output.
```

#### Step 4 — Restore DNS

Updates both VNets DNS back to `10.1.1.4` (DVDC01).

#### Step 5 — Flush DNS (all 4 app servers)

Runs `ipconfig /flushdns && ipconfig /registerdns` on DVAS01, DVAS02, DVAS03, and DVAS04.

#### Step 6 — Validate (DVDC01)

```
[PASS] DVDC01 holds FSMO roles
[PASS] dcdiag Advertising
[PASS] 0 replication failures
```

---

## Post-Failback Validation

Connect via Bastion to DVDC01 and run:

```powershell
# All 5 roles should show DVDC01
netdom query fsmo

# Both tests should pass
dcdiag /test:advertising /test:fsmocheck

# No failures, DVDC02 and DVDC03 all in sync
repadmin /replsummary
repadmin /showrepl

# Full dcdiag sweep
dcdiag /v
```

---

## Troubleshooting

### FSMO Seizure Fails

**Symptom:** `Move-ADDirectoryServerOperationMasterRole` throws an error about contacting the
current FSMO holder.

**Cause:** DVDC01 may still be partially reachable (e.g., VM is starting, not fully deallocated).

**Fix:**
1. Confirm DVDC01 and DVDC02 are fully deallocated:
   ```powershell
   az vm get-instance-view -g rg-ADLab-East -n DVDC01 --query "instanceView.statuses" -o table
   ```
2. Wait 2–3 minutes and retry the seizure step manually from Bastion → DVDC03:
   ```powershell
   Move-ADDirectoryServerOperationMasterRole -Identity DVDC03 `
       -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
       -Force -Confirm:$false
   ```

---

### SYSVOL Not Shared After Failover

**Symptom:** `NET SHARE` on DVDC03 does not show SYSVOL or NETLOGON.

**Cause:** DFS-R SYSVOL has not yet finished replicating, or DVDC03 is not authoritative.

**Fix:**
```powershell
# Check DFS-R backlog
dfsrdiag backlog /rgname:"Domain System Volume" /rfname:"SYSVOL Share" /sendingmember:DVDC01 /receivingmember:DVDC03

# Force DFSR poll
(Get-WmiObject -Namespace "root\MicrosoftDFS" -Class "DfsrMachineConfig").PollIntervalInMin = 0

# If SYSVOL still not shared, set authoritative restore flag
# (only if DVDC03 is the only remaining DC)
reg add "HKLM\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\SysVols\Seeding Sysvols\managed-connections.net" /v "Is Primary" /t REG_DWORD /d 1 /f
net stop dfsr && net start dfsr
```

---

### DNS Not Propagating After Redirect

**Symptom:** App servers still resolve to old DC IPs; domain join attempts fail.

**Cause:** VNet DNS update may take a few minutes to take effect; VMs need NIC restart.

**Fix:**
```powershell
# From Bastion, flush DNS on affected app server
ipconfig /flushdns
ipconfig /registerdns

# If still not resolving, restart the NIC (causes brief disconnect)
# via Bastion console: Device Manager → Network Adapters → Disable/Enable
```

---

### FSMO Transfer Fails During Failback

**Symptom:** `Move-ADDirectoryServerOperationMasterRole` fails without `-Force`.

**Cause:** Replication has not fully converged; DVDC03 does not yet see DVDC01 as a valid
transfer target.

**Fix:**
1. Check replication is complete:
   ```powershell
   repadmin /replsummary    # should show 0 failures
   repadmin /showrepl       # DVDC01 should appear with recent sync timestamp
   ```
2. If DVDC01 is not yet fully replicated, wait 5 minutes and retry.
3. If DVDC03 cannot contact DVDC01 at all, verify VNet peering is still active.

---

### Replication Fails After Failback

**Symptom:** `repadmin /replsummary` shows failures involving DVDC01.

**Cause:** USN rollback or lingering objects if DVDC01 was brought back after being out of sync
for a long time (unlikely in a lab exercise where deallocate/start is clean).

**Fix:**
```powershell
# Force full sync
repadmin /syncall /Ade

# Check for lingering objects
repadmin /removelingeringobjects DVDC01 DVDC03 "DC=managed-connections,DC=net"

# Full consistency check
dcdiag /test:replications
```

---

## References

- [Seize FSMO roles — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/seize-fsmo-roles-using-ntdsutil)
- [Transfer FSMO roles — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/fsmo-roles)
- [AD replication troubleshooting — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/troubleshoot/troubleshoot-ad-replication-error)
- [SYSVOL replication using DFS-R — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/storage/dfs-replication/dfsr-overview)
- [Move-ADDirectoryServerOperationMasterRole — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/activedirectory/move-addirectoryserveroperationmasterrole)
