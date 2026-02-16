param(
    [Parameter(Mandatory)]
    [string]$DomainDN
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# Top-level OU
$topOU = "OU=ADLab,$DomainDN"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$topOU'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name 'ADLab' -Path $DomainDN -ProtectedFromAccidentalDeletion $true
    Write-Output "Created OU: ADLab"
}

# Functional OUs under ADLab
$functionalOUs = @('Users', 'Groups', 'Servers', 'ServiceAccounts')
foreach ($ou in $functionalOUs) {
    $ouDN = "OU=$ou,$topOU"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou -Path $topOU -ProtectedFromAccidentalDeletion $true
        Write-Output "Created OU: $ou"
    }
}

# Department OUs under Users
$departments = @('HR', 'IT', 'Legal', 'Finance', 'Marketing', 'Operations')
$usersOU = "OU=Users,$topOU"

foreach ($dept in $departments) {
    $deptDN = "OU=$dept,$usersOU"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$deptDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $dept -Path $usersOU -ProtectedFromAccidentalDeletion $true
        Write-Output "Created OU: $dept"
    }

    # Role OUs under each department
    $roles = @('Managers', 'Employees', 'Contractors')
    foreach ($role in $roles) {
        $roleDN = "OU=$role,$deptDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$roleDN'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $role -Path $deptDN -ProtectedFromAccidentalDeletion $true
            Write-Output "Created OU: $dept\$role"
        }
    }
}

Write-Output "OU structure creation complete."
