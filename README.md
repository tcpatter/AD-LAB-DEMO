# AD Lab Demo

Azure-based Active Directory lab spanning 2 regions with 7 Windows Server 2022 VMs, deployed entirely via Bicep and managed through Azure Bastion (no public IPs on VMs).

## Purpose

Build a multi-region AD environment for testing:

- Active Directory Domain Services (AD DS) with multi-site replication
- Microsoft Entra Connect / Cloud Sync
- Global Secure Access (GSA)
- Group Policy, DNS, and cross-region failover scenarios

## Architecture

```
                        ┌─────────────────────────────────────────────────────┐
                        │              Azure Subscription                     │
                        │            MC-non-production                        │
                        └──────────────────┬──────────────────────────────────┘
                                           │
                ┌──────────────────────────┴──────────────────────────┐
                │                                                     │
    ┌───────────┴───────────────┐                     ┌──────────────┴──────────────┐
    │   rg-ADLab-East           │                     │   rg-ADLab-West             │
    │   eastus2                 │                     │   centralus                 │
    ├───────────────────────────┤                     ├─────────────────────────────┤
    │                           │                     │                             │
    │  vnet-adlab-east          │                     │  vnet-adlab-west            │
    │  10.1.0.0/16              │                     │  10.3.0.0/16                │
    │                           │                     │                             │
    │  ┌─ snet-dc (10.1.1.0/24)│                     │  ┌─ snet-dc (10.3.1.0/24)  │
    │  │  DVDC01  10.1.1.4     │                     │  │  DVDC03  10.3.1.4        │
    │  │  DVDC02  10.1.1.5     │                     │  └─────────────────────────┤│
    │  └───────────────────────┤│                     │  ┌─ snet-app (10.3.2.0/24) │
    │  ┌─ snet-app (10.1.2.0/24)                     │  │  DVAS03  10.3.2.4        │
    │  │  DVAS01  10.1.2.4     │                     │  │  DVAS04  10.3.2.5        │
    │  │  DVAS02  10.1.2.5     │                     │  └─────────────────────────┤│
    │  └───────────────────────┤│                     │  ┌─ AzureBastionSubnet     │
    │  ┌─ AzureBastionSubnet   │                     │  │  10.3.3.0/24             │
    │  │  10.1.3.0/24          │                     │  │  bas-adlab-west           │
    │  │  bas-adlab-east       │                     │  └─────────────────────────┤│
    │  └───────────────────────┤│                     │                             │
    │                           │                     │  kv-adlab-west              │
    │  kv-adlab-east            │                     │  stadlabscripts01 (East)    │
    │  stadlabscripts01         │                     └─────────────────────────────┘
    └───────────────────────────┘
```

### VM Inventory

| VM | Role | Region | Subnet | Static IP | Data Disk | Timezone |
|---|---|---|---|---|---|---|
| DVDC01 | Domain Controller (Primary) | eastus2 | snet-dc | 10.1.1.4 | 20 GB | Eastern |
| DVDC02 | Domain Controller | eastus2 | snet-dc | 10.1.1.5 | 20 GB | Eastern |
| DVAS01 | App Server (IIS + File) | eastus2 | snet-app | 10.1.2.4 | -- | Eastern |
| DVAS02 | App Server (IIS + File) | eastus2 | snet-app | 10.1.2.5 | -- | Eastern |
| DVDC03 | Domain Controller | centralus | snet-dc | 10.3.1.4 | 20 GB | Central |
| DVAS03 | App Server (IIS + File) | centralus | snet-app | 10.3.2.4 | -- | Central |
| DVAS04 | App Server (IIS + File) | centralus | snet-app | 10.3.2.5 | -- | Central |

All VMs run **Windows Server 2022 Datacenter Azure Edition** on **Standard_B2s** SKUs.

### Networking

| Resource | Region | Address Space |
|---|---|---|
| vnet-adlab-east | eastus2 | 10.1.0.0/16 |
| vnet-adlab-west | centralus | 10.3.0.0/16 |

**Subnets per VNet:**
- `snet-dc` — Domain controllers (.1.0/24)
- `snet-app` — Application servers (.2.0/24)
- `AzureBastionSubnet` — Azure Bastion (.3.0/24)

## Security

### Zero Public IP Design

No VMs have public IP addresses. All management access is through Azure Bastion (Standard SKU) with tunneling and IP Connect enabled.

### Bastion Configuration

- **SKU:** Standard (required for tunneling and native client support)
- **Features:** Tunneling, IP Connect
- **Authentication:** Password from Azure Key Vault (avoids credential exposure in browser forms)
- **Instances:** 1 per region (bas-adlab-east, bas-adlab-west)

### Network Security Groups

Each subnet has a dedicated NSG with least-privilege rules:

**DC Subnets (nsg-adlab-east-dc, nsg-adlab-west-dc):**
- Allow RDP (3389) from VirtualNetwork only

**App Subnets (nsg-adlab-east-app, nsg-adlab-west-app):**
- Allow RDP (3389) from VirtualNetwork
- Allow HTTPS (443) inbound
- Allow HTTP (80) inbound

**Bastion Subnets (nsg-adlab-east-bastion, nsg-adlab-west-bastion):**
- Standard Azure Bastion NSG rules per [Microsoft requirements](https://learn.microsoft.com/en-us/azure/bastion/bastion-nsg):
  - Inbound: HTTPS from Internet, GatewayManager, AzureLoadBalancer, BastionHostCommunication
  - Outbound: SSH/RDP to VirtualNetwork, HTTPS to AzureCloud, BastionHostCommunication, HTTP to Internet

### Key Vaults

Credentials are stored in Azure Key Vault (one per region) rather than passed as plain text:

| Key Vault | Resource Group | Secret |
|---|---|---|
| kv-adlab-east | rg-ADLab-East | vm-admin-password |
| kv-adlab-west | rg-ADLab-West | vm-admin-password |

Bastion connects using "Password from Azure Key Vault" authentication, pulling credentials directly from the vault at connection time.

### Credential Management

- VM local admin: `labadmin`
- Passwords set via `az vm user update` (VMAccessAgent) to avoid shell-escaping issues with special characters
- No credentials stored in code or deployment parameters

## Disaster Recovery

The lab includes a full unplanned DR failover exercise: East US 2 → Central US, with graceful failback.

### DR Topology

```
East US 2 (PRIMARY)          Central US (DR)
DVDC01  10.1.1.4  ←FSMO      DVDC03  10.3.1.4  ← DR target
DVDC02  10.1.1.5              (bidirectional VNet peering)
```

DVDC03 is a fully promoted replica DC. In a simulated East outage, all 5 FSMO roles are **seized** onto
DVDC03. During failback, roles are **transferred** (not seized) back to DVDC01 once replication is healthy.

See [docs/DR-Runbook.md](docs/DR-Runbook.md) for the full runbook including pre-flight checklist,
expected output, post-validation steps, and troubleshooting.

### Quick Start

```powershell
# Failover: East → West (~20 min) — simulates East US 2 outage
.\deploy\Invoke-Failover.ps1 -AdminPassword 'L@bAdmin2026!x'

# Failback: West → East (~25 min) — restores East as primary
.\deploy\Invoke-Failback.ps1 -AdminPassword 'L@bAdmin2026!x'
```

## Project Structure

```
AD-Lab/
├── bicep/
│   ├── main.bicep              # Orchestrator — phased deployment (infra, vms, primarydc)
│   ├── main.bicepparam         # Parameter file
│   ├── main.json               # Compiled ARM template
│   └── modules/
│       ├── compute/
│       │   ├── vm.bicep         # Windows Server VM (configurable IP, disk, public IP)
│       │   └── vm-extension.bicep  # Custom Script Extension runner
│       ├── network/
│       │   ├── bastion.bicep    # Bastion host (Standard SKU + tunneling)
│       │   ├── nsg.bicep        # Generic NSG with configurable rules
│       │   ├── nsg-bastion.bicep # Bastion-specific NSG (Azure required rules)
│       │   ├── peering.bicep    # VNet peering (bidirectional East ↔ West)
│       │   └── vnet.bicep       # VNet with subnets
│       └── storage/
│           └── storageaccount.bicep  # Storage for deployment scripts
├── deploy/
│   ├── deploy.ps1              # 6-phase PowerShell orchestrator (az cli)
│   ├── Invoke-Failover.ps1     # DR failover: East US 2 → Central US
│   └── Invoke-Failback.ps1     # DR failback: Central US → East US 2
├── docs/
│   └── DR-Runbook.md           # Full DR runbook with troubleshooting guide
└── scripts/
    ├── powershell/              # DC promotion, domain join, DNS, OU, DR scripts
    │   ├── Promote-PrimaryDC.ps1
    │   ├── Promote-SecondaryDC.ps1
    │   ├── Join-DomainAndConfigure.ps1
    │   ├── Configure-DNS-Forwarders.ps1
    │   ├── Configure-OUs.ps1
    │   ├── Create-ADUsers.ps1
    │   ├── Create-DepartmentGroups.ps1
    │   ├── Seize-FSMORoles.ps1  # FSMO seizure for unplanned failover (runs on DVDC03)
    │   └── Transfer-FSMORoles.ps1  # FSMO transfer for graceful failback (runs on DVDC01)
    └── python/                  # User generation (Faker-based CSV)
        └── data/users.csv
```

## Deployment

### Prerequisites

- Azure CLI (`az`) authenticated with a subscription
- PowerShell 7+ (pwsh)
- Bicep CLI (bundled with Azure CLI)

### Deploy

```powershell
# All three phases sequentially
.\deploy\deploy.ps1 -Phase all -AdminPassword '<password>' -SafeModePassword '<password>'

# Or individual phases
.\deploy\deploy.ps1 -Phase 1 ...   # Infrastructure (RGs, VNets, NSGs, Bastion, Storage)
.\deploy\deploy.ps1 -Phase 2 ...   # Virtual Machines (7 VMs, waits for agent ready)
.\deploy\deploy.ps1 -Phase 3 ...   # Validation (run-command on each VM)
```

### Post-Deploy: Set Timezones

```bash
# East VMs → Eastern Standard Time
for vm in DVDC01 DVDC02 DVAS01 DVAS02; do
  az vm run-command invoke --resource-group rg-ADLab-East --name $vm \
    --command-id RunPowerShellScript --scripts "Set-TimeZone -Id 'Eastern Standard Time'"
done

# West VMs → Central Standard Time
for vm in DVDC03 DVAS03 DVAS04; do
  az vm run-command invoke --resource-group rg-ADLab-West --name $vm \
    --command-id RunPowerShellScript --scripts "Set-TimeZone -Id 'Central Standard Time'"
done
```

### Post-Deploy: Reset VM Passwords

```bash
az vm user update --resource-group rg-ADLab-East --name DVDC01 \
  --username labadmin --password '<password>'
```

### Verify

```bash
az vm list -g rg-ADLab-East -o table    # 4 VMs
az vm list -g rg-ADLab-West -o table    # 3 VMs
az network bastion list -o table         # 2 Bastions (Standard SKU)
```

## Future Phases

The following phases are planned for future work:

1. **Entra Sync** — Microsoft Entra Connect / Cloud Sync to Entra ID
2. **Global Secure Access** — GSA agent deployment and policy testing

**Completed phases** (Phases 1–6 of `deploy.ps1` plus DR exercise):
- Infrastructure (RGs, VNets, NSGs, Bastion, Storage)
- Virtual Machines (7 VMs, Standard_B2s, Windows Server 2022)
- Primary DC Promotion (DVDC01 as forest root `managed-connections.net`)
- DNS + VNet Peering (bidirectional East ↔ West, Azure DNS forwarder)
- Secondary DC Promotions (DVDC02 East, DVDC03 West as replica DCs)
- App Server Domain Join (DVAS01–04 joined, IIS + File Server roles)
- AD Configuration (OU structure, 100 test users, 18 department security groups)
- DR Failover / Failback exercise (FSMO seize/transfer, VNet DNS redirect)
