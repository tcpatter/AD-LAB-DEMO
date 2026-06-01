param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$PrimaryDcIp,

    [Parameter(Mandatory)]
    [string]$SafeModePassword,

    [Parameter(Mandatory)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory)]
    [string]$DomainAdminPassword
)

$ErrorActionPreference = 'Stop'
New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\Logs\Promote-SecondaryDC.log" -Append

try {
    # DNS is provided by VNet DHCP (set to PrimaryDcIp in Phase 4) — no manual override needed.
    # Set-DnsClientServerAddress is unreliable on Azure VMs (DHCP-managed adapters).
    Write-Output "DNS server: $((Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Select-Object -First 1).ServerAddresses -join ', ')"

    Write-Output "Installing AD DS and DNS features..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

    Write-Output "Promoting server as additional Domain Controller for $DomainName..."
    $securePassword = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force
    $domainCred = New-Object System.Management.Automation.PSCredential(
        "MANAGED\$DomainAdminUser",
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
    )

    $params = @{
        DomainName                    = $DomainName
        Credential                    = $domainCred
        SafeModeAdministratorPassword = $securePassword
        InstallDns                    = $true
        DatabasePath                  = 'C:\Windows\NTDS'
        LogPath                       = 'C:\Windows\NTDS'
        SysvolPath                    = 'C:\Windows\SYSVOL'
        NoRebootOnCompletion          = $false
        Force                         = $true
    }

    Install-ADDSDomainController @params
}
catch {
    Write-Error "Failed to promote Secondary DC: $_"
    throw
}
finally {
    Stop-Transcript
}
