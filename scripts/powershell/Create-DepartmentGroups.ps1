param(
    [Parameter(Mandatory)]
    [string]$DomainDN
)

$ErrorActionPreference = 'Stop'
New-Item -Path 'C:\Logs' -ItemType Directory -Force | Out-Null
Start-Transcript -Path 'C:\Logs\Create-DepartmentGroups.log' -Append

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    $departments = @('Finance', 'HR', 'IT', 'Legal', 'Marketing', 'Operations')
    $types       = @('Contractors', 'Employees', 'Managers')
    $groupsOU    = "OU=Groups,OU=ADLab,$DomainDN"
    $usersBase   = "OU=Users,OU=ADLab,$DomainDN"

    $createErrors = 0

    foreach ($dept in $departments) {
        foreach ($type in $types) {
            $groupName = "$dept-$type"
            $sourceOU  = "OU=$type,OU=$dept,$usersBase"

            try {
                # Idempotent group creation
                if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
                    New-ADGroup -Name $groupName `
                                -GroupScope Global `
                                -GroupCategory Security `
                                -Path $groupsOU `
                                -Description "$dept $type security group"
                    Write-Output "[CREATED] $groupName"
                } else {
                    Write-Output "[EXISTS]  $groupName"
                }

                # Additive membership — add users from source OU (never removes existing members)
                $users = Get-ADUser -Filter * -SearchBase $sourceOU -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($users) {
                    Add-ADGroupMember -Identity $groupName -Members $users -ErrorAction SilentlyContinue
                    Write-Output "  -> Added/verified $(@($users).Count) user(s) from $sourceOU"
                } else {
                    Write-Output "  -> No users found in $sourceOU"
                }
            }
            catch {
                Write-Output "[ERROR] $groupName - $_"
                $createErrors++
            }
        }
    }

    # Validation: all 18 groups must have >= 1 member
    Write-Output "`n=== Validation ==="
    $validationFails = 0
    foreach ($dept in $departments) {
        foreach ($type in $types) {
            $groupName = "$dept-$type"
            try {
                $count = @(Get-ADGroupMember -Identity $groupName -ErrorAction Stop).Count
                if ($count -ge 1) {
                    Write-Output "[PASS] $groupName ($count member(s))"
                } else {
                    Write-Output "[WARN] $groupName — 0 members"
                    $validationFails++
                }
            }
            catch {
                Write-Output "[FAIL] $groupName — $_"
                $validationFails++
            }
        }
    }

    Write-Output "`nSummary: $createErrors creation error(s), $validationFails validation failure(s)"

    if ($createErrors -gt 0) {
        throw "Script completed with $createErrors creation error(s). Check C:\Logs\Create-DepartmentGroups.log for details."
    }
}
catch {
    Write-Output "FATAL: $_"
    Stop-Transcript
    exit 1
}

Stop-Transcript
