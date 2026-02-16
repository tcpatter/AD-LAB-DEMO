param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$DcIpAddress,

    [Parameter(Mandatory)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory)]
    [string]$DomainAdminPassword
)

$ErrorActionPreference = 'Stop'
New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "C:\Logs\Join-DomainAndConfigure.log" -Append

try {
    # Point DNS to local DC
    Write-Output "Setting DNS client to DC ($DcIpAddress)..."
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DcIpAddress

    # Build domain credential
    $domainCred = New-Object System.Management.Automation.PSCredential(
        "$DomainName\$DomainAdminUser",
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
    )

    # Join domain
    Write-Output "Joining domain $DomainName..."
    Add-Computer -DomainName $DomainName -Credential $domainCred -Force

    # Register a scheduled task to install IIS and File Server roles after reboot
    Write-Output "Registering post-reboot task to install IIS and File Server..."
    $taskScript = @'
Install-WindowsFeature -Name Web-Server, FS-FileServer -IncludeManagementTools
New-Item -Path "C:\Shares\Department" -ItemType Directory -Force
New-SmbShare -Name "Department" -Path "C:\Shares\Department" -FullAccess "Domain Admins" -ChangeAccess "Domain Users"
Unregister-ScheduledTask -TaskName "PostRebootConfig" -Confirm:$false
'@
    $taskScript | Out-File -FilePath "C:\Logs\PostRebootConfig.ps1" -Encoding UTF8

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Unrestricted -File C:\Logs\PostRebootConfig.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'PostRebootConfig' -Action $action -Trigger $trigger -Principal $principal -Force

    Write-Output "Restarting to complete domain join..."
    Restart-Computer -Force
}
catch {
    Write-Error "Failed to join domain and configure: $_"
    throw
}
finally {
    Stop-Transcript
}
