param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$DomainDN
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$users = Import-Csv -Path $CsvPath
$created = 0
$skipped = 0

foreach ($user in $users) {
    $samAccountName = $user.SamAccountName
    $existingUser = Get-ADUser -Filter "SamAccountName -eq '$samAccountName'" -ErrorAction SilentlyContinue

    if ($existingUser) {
        Write-Output "SKIP: $samAccountName already exists"
        $skipped++
        continue
    }

    $securePassword = ConvertTo-SecureString $user.Password -AsPlainText -Force

    $params = @{
        Name              = $user.DisplayName
        GivenName         = $user.FirstName
        Surname           = $user.LastName
        DisplayName       = $user.DisplayName
        SamAccountName    = $samAccountName
        UserPrincipalName = $user.UPN
        Department        = $user.Department
        Title             = $user.Role
        Path              = $user.OUPath
        AccountPassword   = $securePassword
        Enabled           = [bool]::Parse($user.Enabled)
        ChangePasswordAtLogon = $false
    }

    New-ADUser @params
    Write-Output "CREATED: $samAccountName in $($user.OUPath)"
    $created++
}

Write-Output "`nSummary: Created=$created, Skipped=$skipped, Total=$($users.Count)"
