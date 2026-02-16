param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$NetBIOSName,

    [Parameter(Mandatory)]
    [string]$SafeModePassword
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "C:\Logs\Promote-PrimaryDC.log" -Append
New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null

try {
    Write-Output "Installing AD DS, DNS, and GPMC features..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS, GPMC -IncludeManagementTools

    Write-Output "Promoting server to Primary Domain Controller for $DomainName..."
    $securePassword = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force

    $params = @{
        DomainName                    = $DomainName
        DomainNetbiosName             = $NetBIOSName
        SafeModeAdministratorPassword = $securePassword
        InstallDns                    = $true
        DatabasePath                  = 'C:\Windows\NTDS'
        LogPath                       = 'C:\Windows\NTDS'
        SysvolPath                    = 'C:\Windows\SYSVOL'
        NoRebootOnCompletion          = $false
        Force                         = $true
    }

    Install-ADDSForest @params
}
catch {
    Write-Error "Failed to promote Primary DC: $_"
    throw
}
finally {
    Stop-Transcript
}
