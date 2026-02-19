<#
.SYNOPSIS
    Validates and configures Microsoft Entra Cloud Sync prerequisites on a DC.
.DESCRIPTION
    Runs on the target server (DVDC01 or DVDC03) via az vm run-command.
    Checks and applies:
      - OS version       (2019/2022 supported; warns on 2016 extended support and 2025 known issue)
      - .NET Framework   (4.7.1+ required)
      - TLS 1.2          (enables via registry if not set; reboot required after)
      - Execution policy (sets to RemoteSigned if Undefined)
      - VaultSvc         (Windows Credential Manager must not be Disabled)
      - KDS Root Key     (creates one if absent — required for gMSA auto-creation)
      - AD schema        (msDS-ExternalDirectoryObjectId must be present)
      - Outbound HTTPS   (tests connectivity to key Entra endpoints on port 443)

    Exits with code 1 if any blocking check fails so the calling orchestrator
    can detect failure via stdout content.

    Log written to: C:\Logs\CloudSync-Prereqs.log
#>

$ErrorActionPreference = 'Stop'
New-Item -Path C:\Logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path C:\Logs\CloudSync-Prereqs.log -Append

$pass = $true

function Write-Check {
    param(
        [string]$Label,
        [bool]$Ok,
        [string]$Detail = ''
    )
    $tag    = if ($Ok) { '[PASS]' } else { '[FAIL]' }
    $suffix = if ($Detail) { " — $Detail" } else { '' }
    Write-Output "  $tag $Label$suffix"
}

Write-Output "`n=== Microsoft Entra Cloud Sync Prerequisites Check ==="
Write-Output "Server : $env:COMPUTERNAME"
Write-Output "Date   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ── 1. OS Version ─────────────────────────────────────────────────────────────
Write-Output "`n--- OS Version ---"
$os      = Get-CimInstance Win32_OperatingSystem
$build   = [int]$os.BuildNumber
$caption = $os.Caption

if ($build -ge 26100) {
    Write-Output "  [WARN] Windows Server 2025 detected (Build $build)."
    Write-Output "         Known Cloud Sync sync issue — ensure KB5070773 (Oct 2025) is installed."
    Write-Output "         Support for WS2025 is planned for a future Cloud Sync release."
} elseif ($build -ge 20348) {
    Write-Check "OS Version" $true "$caption (Build $build — Windows Server 2022)"
} elseif ($build -ge 17763) {
    Write-Check "OS Version" $true "$caption (Build $build — Windows Server 2019)"
} elseif ($build -ge 14393) {
    Write-Output "  [WARN] Windows Server 2016 detected (Build $build) — in extended support."
    Write-Output "         Consider upgrading to Windows Server 2019 or 2022."
} else {
    Write-Check "OS Version" $false "$caption (Build $build) — unsupported"
    $pass = $false
}

# ── 2. .NET Framework 4.7.1+ ──────────────────────────────────────────────────
Write-Output "`n--- .NET Framework ---"
$netKey  = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$release = (Get-ItemProperty -Path $netKey -ErrorAction SilentlyContinue).Release

if ($release -ge 461308) {
    $version = if     ($release -ge 533320) { '4.8.1' }
               elseif ($release -ge 528040) { '4.8'   }
               elseif ($release -ge 461808) { '4.7.2' }
               else                         { '4.7.1' }
    Write-Check ".NET Framework 4.7.1+" $true "Installed: $version (release key $release)"
} else {
    $found = if ($release) { "release key $release" } else { "key not found" }
    Write-Check ".NET Framework 4.7.1+" $false "Requirement not met ($found). Minimum release key: 461308"
    $pass = $false
}

# ── 3. TLS 1.2 ────────────────────────────────────────────────────────────────
Write-Output "`n--- TLS 1.2 ---"
$tlsClientPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
$tlsServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server'
$netFxPath     = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'

$needsTls = $false
foreach ($path in @($tlsClientPath, $tlsServerPath)) {
    $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($props.Enabled -ne 1 -or $props.DisabledByDefault -ne 0) { $needsTls = $true }
}
$netFxProps = Get-ItemProperty -Path $netFxPath -ErrorAction SilentlyContinue
if ($netFxProps.SchUseStrongCrypto -ne 1) { $needsTls = $true }

if ($needsTls) {
    Write-Output "  [INFO] TLS 1.2 not fully configured — applying registry keys..."
    foreach ($path in @($tlsClientPath, $tlsServerPath)) {
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name 'Enabled'          -Value 1 -Type DWord
        Set-ItemProperty -Path $path -Name 'DisabledByDefault' -Value 0 -Type DWord
    }
    New-Item -Path $netFxPath -Force | Out-Null
    Set-ItemProperty -Path $netFxPath -Name 'SchUseStrongCrypto' -Value 1 -Type DWord
    Write-Check "TLS 1.2" $true "Registry keys applied — server reboot required before installing agent"
    Write-Output "  [WARN] Reboot this server before running the Cloud Sync agent installer."
} else {
    Write-Check "TLS 1.2" $true "Already configured"
}

# ── 4. PowerShell Execution Policy ────────────────────────────────────────────
Write-Output "`n--- PowerShell Execution Policy ---"
$policy = Get-ExecutionPolicy -Scope LocalMachine
if ($policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Write-Check "Execution Policy" $true "$policy"
} elseif ($policy -eq 'Undefined') {
    Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Check "Execution Policy" $true "Set to RemoteSigned (was Undefined)"
} else {
    Write-Check "Execution Policy" $false "$policy — must be RemoteSigned or less restrictive"
    $pass = $false
}

# ── 5. Windows Credential Manager (VaultSvc) ──────────────────────────────────
Write-Output "`n--- Windows Credential Manager (VaultSvc) ---"
$vault = Get-Service -Name VaultSvc -ErrorAction SilentlyContinue
if ($null -eq $vault) {
    Write-Check "VaultSvc" $false "Service not found on this server"
    $pass = $false
} elseif ($vault.StartType -eq 'Disabled') {
    Write-Check "VaultSvc" $false "Service is Disabled — the Cloud Sync installer requires VaultSvc"
    $pass = $false
} else {
    Write-Check "VaultSvc" $true "StartType=$($vault.StartType), Status=$($vault.Status)"
}

# ── 6. KDS Root Key (required for gMSA auto-creation) ────────────────────────
Write-Output "`n--- KDS Root Key ---"
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $kdsKey = Get-KdsRootKey -ErrorAction SilentlyContinue
    if ($kdsKey) {
        Write-Check "KDS Root Key" $true "Key ID: $($kdsKey.KeyId)"
    } else {
        Write-Output "  [INFO] No KDS Root Key found — creating one (backdated for immediate lab use)..."
        Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
        Write-Check "KDS Root Key" $true "Created and effective immediately"
    }
} catch {
    Write-Check "KDS Root Key" $false $_.Exception.Message
    $pass = $false
}

# ── 7. AD Schema: msDS-ExternalDirectoryObjectId ─────────────────────────────
Write-Output "`n--- AD Schema Attribute (msDS-ExternalDirectoryObjectId) ---"
try {
    $schemaNc = (Get-ADRootDSE).schemaNamingContext
    $attrDn   = "CN=ms-DS-External-Directory-Object-Id,$schemaNc"
    $attr     = Get-ADObject -Identity $attrDn -ErrorAction SilentlyContinue
    if ($attr) {
        Write-Check "msDS-ExternalDirectoryObjectId" $true "Present in schema ($schemaNc)"
    } else {
        Write-Check "msDS-ExternalDirectoryObjectId" $false "Not found — schema may be pre-2016. Run adprep /forestprep."
        $pass = $false
    }
} catch {
    Write-Check "msDS-ExternalDirectoryObjectId" $false $_.Exception.Message
    $pass = $false
}

# ── 8. Outbound HTTPS connectivity to Entra endpoints ────────────────────────
Write-Output "`n--- Outbound Connectivity (port 443) ---"
$endpoints = @(
    'login.microsoftonline.com',
    'management.azure.com',
    'login.windows.net',
    'aadcdn.msftauthimages.net'
)
foreach ($endpoint in $endpoints) {
    try {
        $result = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
        Write-Check "HTTPS → $endpoint" $result.TcpTestSucceeded
        if (-not $result.TcpTestSucceeded) { $pass = $false }
    } catch {
        Write-Output "  [WARN] Could not test $endpoint — $($_.Exception.Message)"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Output "`n=== Summary ==="
if ($pass) {
    Write-Output "  ALL CHECKS PASSED — $env:COMPUTERNAME is ready for Cloud Sync agent installation."
} else {
    Write-Output "  ONE OR MORE CHECKS FAILED — resolve issues above before installing the Cloud Sync agent."
}

Stop-Transcript

if (-not $pass) { exit 1 }
