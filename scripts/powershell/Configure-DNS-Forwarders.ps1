param(
    [string[]]$Forwarders = @('168.63.129.16')
)

$ErrorActionPreference = 'Stop'
Import-Module DnsServer

Write-Output "Configuring DNS forwarders: $($Forwarders -join ', ')"

# Clear existing forwarders and set new ones
Set-DnsServerForwarder -IPAddress $Forwarders

# Verify
$configured = Get-DnsServerForwarder
Write-Output "DNS Forwarders configured: $($configured.IPAddress -join ', ')"
