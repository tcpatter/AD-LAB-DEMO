<#
.SYNOPSIS
    Force-seizes all 5 FSMO roles on the target DC.
.DESCRIPTION
    Used during unplanned DR failover when the original FSMO holder is unreachable.
    Runs on the target DC (DVDC03) via az vm run-command invoke.

    WARNING: Only seize FSMO roles when the original holder cannot be gracefully
    reached. Seizing creates a USN rollback risk if the original holder comes back
    online without being demoted first. After a seizure, do not bring the old FSMO
    holder back online — demote it cleanly before rejoining.
.PARAMETER TargetDC
    The NetBIOS name of the DC to receive all FSMO roles (e.g. DVDC03).
.EXAMPLE
    # Called by Invoke-Failover.ps1 via run-command — not run directly by operators.
    .\Seize-FSMORoles.ps1 -TargetDC DVDC03
#>
param(
    [Parameter(Mandatory)]
    [string]$TargetDC
)

New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\Seize-FSMORoles.log -Append

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — Seizing all FSMO roles onto $TargetDC"
Write-Output "Running on: $env:COMPUTERNAME"

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    Move-ADDirectoryServerOperationMasterRole `
        -Identity $TargetDC `
        -OperationMasterRole SchemaMaster,DomainNamingMaster,PDCEmulator,RIDMaster,InfrastructureMaster `
        -Force `
        -Confirm:$false

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — Seizure complete. Verifying current FSMO holders:"
    netdom query fsmo

} catch {
    Write-Output "ERROR during FSMO seizure: $_"
    Stop-Transcript
    exit 1
}

Stop-Transcript
