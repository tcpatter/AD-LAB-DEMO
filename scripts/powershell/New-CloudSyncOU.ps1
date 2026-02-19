<#
.SYNOPSIS
    Creates the dedicated CloudSync OU structure in Active Directory.
.DESCRIPTION
    Creates OU=CloudSync at the domain root with Users and Groups sub-OUs.
    This OU is the exclusive scope for Microsoft Entra Cloud Sync, keeping its
    objects fully separated from those managed by the existing Entra Connect agent.

    Structure created:
      OU=CloudSync,DC=managed-connections,DC=net
        OU=Users
        OU=Groups

    All OUs are protected from accidental deletion.
    Safe to re-run — skips any OU that already exists.
#>

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

$domainDn     = (Get-ADDomain).DistinguishedName
$cloudSyncDn  = "OU=CloudSync,$domainDn"

Write-Output "`n=== CloudSync OU Creation ==="
Write-Output "Domain : $domainDn"
Write-Output "Date   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output ""

# ── Top-level OU ──────────────────────────────────────────────────────────────
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$cloudSyncDn'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name 'CloudSync' -Path $domainDn -ProtectedFromAccidentalDeletion $true
    Write-Output "  Created : $cloudSyncDn"
} else {
    Write-Output "  Exists  : $cloudSyncDn"
}

# ── Sub-OUs ───────────────────────────────────────────────────────────────────
foreach ($sub in @('Users', 'Groups')) {
    $subDn = "OU=$sub,$cloudSyncDn"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$subDn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $sub -Path $cloudSyncDn -ProtectedFromAccidentalDeletion $true
        Write-Output "  Created : $subDn"
    } else {
        Write-Output "  Exists  : $subDn"
    }
}

# ── Confirm structure ─────────────────────────────────────────────────────────
Write-Output "`nCurrent CloudSync OU structure:"
Get-ADOrganizationalUnit -Filter "DistinguishedName -like '*OU=CloudSync*'" |
    Select-Object -ExpandProperty DistinguishedName |
    Sort-Object |
    ForEach-Object { Write-Output "  $_" }

Write-Output "`nDone. Set this as the Cloud Sync scope in the Entra admin center:"
Write-Output "  OU=CloudSync,$domainDn"
