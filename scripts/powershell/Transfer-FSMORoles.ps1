<#
.SYNOPSIS
    Gracefully transfers all 5 FSMO roles to the target DC.
.DESCRIPTION
    Used during planned failback when both DCs are healthy and replication is
    current. Runs on DVDC01 via az vm run-command invoke.

    Prefer Transfer over Seize whenever the source DC is reachable — graceful
    transfer preserves AD consistency and avoids USN rollback risk.
.PARAMETER TargetDC
    The NetBIOS name of the DC to receive all FSMO roles (e.g. DVDC01).
.EXAMPLE
    # Called by Invoke-Failback.ps1 via run-command — not run directly by operators.
    .\Transfer-FSMORoles.ps1 -TargetDC DVDC01
#>
param(
    [Parameter(Mandatory)]
    [string]$TargetDC
)

New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\Transfer-FSMORoles.log -Append

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — Transferring all FSMO roles to $TargetDC"
Write-Output "Running on: $env:COMPUTERNAME"

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    Move-ADDirectoryServerOperationMasterRole `
        -Identity $TargetDC `
        -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
        -Confirm:$false

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — Transfer complete. Verifying current FSMO holders:"
    netdom query fsmo

} catch {
    Write-Output "ERROR during FSMO transfer: $_"
    Stop-Transcript
    exit 1
}

Stop-Transcript
