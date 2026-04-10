#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OSDCloud PostOS Script - Chocolatey Method
    Hosted on GitHub. Downloaded and executed by Bootstrap.ps1 at first boot.

.PARAMETER SetupCompleteDir
    Path to the SetupComplete folder where secrets.json lives.
    Passed by Bootstrap.ps1. Defaults to $PSScriptRoot if not provided.

.NOTES
    GitHub  : https://raw.githubusercontent.com/your-org/ans-osd/main/PostOS-Choco.ps1
    Context : SetupComplete phase (SYSTEM), runs before OOBE
    Secrets : Read from secrets.json in $SetupCompleteDir (copied from USB by OSDCloud)
#>

param(
    [string]$SetupCompleteDir = $PSScriptRoot
)

#region --- Logging ---

$Script:LogDir = 'C:\OSDCloud\Logs'
$Script:LogFile = "$($Script:LogDir)\PostOS-Choco.log"
$Script:TmpDir = 'C:\OSDCloud\Installers'

foreach ($dir in @($Script:LogDir, $Script:TmpDir)) {
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'INFO' { 'Cyan' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SUCCESS' { 'Green' }
    }
    $entry = "[$ts][$Level] $Message"
    Write-Host $entry -ForegroundColor $color
    $entry | Out-File $Script:LogFile -Append -Encoding utf8
}

Write-Log '=====================================================' 'INFO'
Write-Log "PostOS-Choco.ps1 started"
Write-Log "SetupCompleteDir : $SetupCompleteDir"
Write-Log '=====================================================' 'INFO'

#endregion

#region --- Chocolatey Package List ---

$ChocoPackages = @(
    '7zip',
    'googlechrome',
    'adobereader',
    'notepadplusplus',
    'vcredist140',
    'microsoft-teams'
)

$TimeZone = 'Central Standard Time'

#endregion

#region --- Load secrets.json ---

$SecretsPath = Join-Path $SetupCompleteDir 'secrets.json'
Write-Log "Loading secrets from: $SecretsPath"

if (-not (Test-Path $SecretsPath)) {
    Write-Log "secrets.json not found at $SecretsPath" 'ERROR'
    exit 1
}
try {
    $Secrets = Get-Content $SecretsPath -Raw -ErrorAction Stop | ConvertFrom-Json
    Write-Log 'Secrets loaded.' 'SUCCESS'
}
catch {
    Write-Log "Failed to parse secrets.json: $($_.Exception.Message)" 'ERROR'
    exit 1
}

#endregion

#region --- PowerShell SecretStore Setup ---

Write-Log 'Configuring SecretStore vault...'
$VaultName = 'ANSDeployVault'
try {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt '2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }
    foreach ($mod in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
        if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
            Install-Module $mod -Force -SkipPublisherCheck -Scope AllUsers -ErrorAction Stop
        }
        Import-Module $mod -Force -ErrorAction Stop
    }

    # No-prompt required for SYSTEM context during SetupComplete
    Set-SecretStoreConfiguration -Authentication None -PasswordTimeout -1 -Interaction None -Confirm:$false -ErrorAction Stop

    if (-not (Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name $VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
    }

    $secretMap = @{
        ANSAdminPassword        = $Secrets.ANSAdminPassword
        SentinelOneToken        = $Secrets.SentinelOneToken
        SentinelOneInstallerURL = $Secrets.SentinelOneInstallerURL
        CWAServerURL            = $Secrets.CWAServerURL
        CWAInstallerKey         = $Secrets.CWAInstallerKey
        CWALocationID           = $Secrets.CWALocationID
    }
    foreach ($key in $secretMap.Keys) {
        if ($secretMap[$key]) { Set-Secret -Name $key -Secret $secretMap[$key] -Vault $VaultName -ErrorAction Stop }
        else { Write-Log "Secret '$key' is empty in secrets.json" 'WARN' }
    }
    Write-Log 'SecretStore vault populated.' 'SUCCESS'
}
catch {
    Write-Log "SecretStore setup failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

#endregion

#region --- Helper ---

function Get-DeploySecret {
    param([Parameter(Mandatory)][string]$Name)
    try { return (Get-Secret -Name $Name -Vault $VaultName -AsPlainText -ErrorAction Stop) }
    catch { Write-Log "Could not read secret '$Name': $($_.Exception.Message)" 'ERROR'; return $null }
}

#endregion

#region --- Create ANSAdmin ---

Write-Log 'Creating ANSAdmin local administrator...'
try {
    $adminPass = Get-DeploySecret 'ANSAdminPassword'
    Write-Host "SECRET TEST $($adminPass)"
    $securePass = ConvertTo-SecureString $adminPass -AsPlainText -Force

    if (Get-LocalUser -Name 'ANSAdmin' -ErrorAction SilentlyContinue) {
        Write-Log 'ANSAdmin exists — updating password.' 'WARN'
        Set-LocalUser -Name 'ANSAdmin' -Password $securePass -PasswordNeverExpires $true
        Enable-LocalUser -Name 'ANSAdmin'
    }
    else {
        New-LocalUser -Name 'ANSAdmin' -Password $securePass -FullName 'ANS Administrator' `
            -Description 'Managed local admin - ANS' -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop
        Write-Log 'ANSAdmin created.' 'SUCCESS'
    }

    $members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
    if ($members.Name -notcontains "$($env:COMPUTERNAME)\ANSAdmin") {
        Add-LocalGroupMember -Group 'Administrators' -Member 'ANSAdmin' -ErrorAction Stop
        Write-Log 'ANSAdmin added to Administrators.' 'SUCCESS'
    }
}
catch {
    Write-Log "ANSAdmin setup failed: $($_.Exception.Message)" 'ERROR'
}

#endregion

#region --- Auto-Logon (single use) ---

Write-Log 'Configuring single-use auto-logon...'
try {
    $adminPass = Get-DeploySecret 'ANSAdminPassword'
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $regPath -Name AutoAdminLogon    -Value '1'              -Type String
    Set-ItemProperty $regPath -Name DefaultUserName   -Value 'ANSAdmin'       -Type String
    Set-ItemProperty $regPath -Name DefaultPassword   -Value $adminPass        -Type String
    Set-ItemProperty $regPath -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
    Set-ItemProperty $regPath -Name AutoLogonCount    -Value 1                -Type DWord
    Write-Log 'Auto-logon configured (1 use).' 'SUCCESS'
}
catch {
    Write-Log "Auto-logon failed: $($_.Exception.Message)" 'ERROR'
}

#endregion

#region --- Unattend.xml ---

Write-Log 'Writing unattend.xml...'
try {
    $adminPass = Get-DeploySecret 'ANSAdminPassword'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
      xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>*</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
      <RegisteredOrganization>ANS</RegisteredOrganization>
      <RegisteredOwner>ANSAdmin</RegisteredOwner>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
      xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
      xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>$TimeZone</TimeZone>
    </component>
  </settings>
</unattend>
"@
    if (!(Test-Path 'C:\Windows\Panther')) { New-Item 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null }
    $xml | Out-File 'C:\Windows\Panther\Unattend.xml' -Encoding utf8 -Width 2000 -Force
    Write-Log 'Unattend.xml written.' 'SUCCESS'
}
catch {
    Write-Log "Unattend.xml failed: $($_.Exception.Message)" 'ERROR'
}

#endregion

#region --- Install Chocolatey ---

Write-Log 'Installing Chocolatey...'
try {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [System.Environment]::GetEnvironmentVariable('Path', 'User')
    }
    Write-Log 'Chocolatey ready.' 'SUCCESS'
}
catch {
    Write-Log "Chocolatey install failed: $($_.Exception.Message)" 'ERROR'
}

#endregion

#region --- Install Apps via Chocolatey ---

Write-Log 'Installing standard applications...'
foreach ($pkg in $ChocoPackages) {
    Write-Log "Installing: $pkg"
    try {
        $output = choco install $pkg -y --no-progress --limit-output 2>&1
        if ($LASTEXITCODE -in @(0, 3010)) { Write-Log "$pkg installed." 'SUCCESS' }
        else { Write-Log "$pkg exit code $LASTEXITCODE : $($output -join ' ')" 'WARN' }
    }
    catch { Write-Log "$pkg exception: $($_.Exception.Message)" 'WARN' }
}

#endregion

#region --- Install SentinelOne ---
<#
Write-Log '--- Installing SentinelOne ---'
try {
    $s1Token = Get-DeploySecret 'SentinelOneToken'
    $s1Url   = Get-DeploySecret 'SentinelOneInstallerURL'
    if (-not $s1Token -or -not $s1Url) { throw 'Missing SentinelOne secrets.' }

    $s1Msi = Join-Path $Script:TmpDir 'SentinelOne.msi'
    Write-Log "Downloading SentinelOne installer..."
    (New-Object System.Net.WebClient).DownloadFile($s1Url, $s1Msi)

    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$s1Msi`" /qn SITE_TOKEN=`"$s1Token`" /l*v `"$Script:LogDir\SentinelOne.log`"" -Wait -PassThru
    if ($proc.ExitCode -in @(0,3010)) { Write-Log 'SentinelOne installed.' 'SUCCESS' }
    else { Write-Log "SentinelOne exit code: $($proc.ExitCode)" 'WARN' }
}
catch { Write-Log "SentinelOne failed: $($_.Exception.Message)" 'ERROR' }
#>

#endregion

#region --- Install ConnectWise Automate ---
<#
Write-Log '--- Installing ConnectWise Automate ---'
try {
    $cwaServer = Get-DeploySecret 'CWAServerURL'
    $cwaKey = Get-DeploySecret 'CWAInstallerKey'
    $cwaLocId = Get-DeploySecret 'CWALocationID'
    if (-not $cwaServer -or -not $cwaKey -or -not $cwaLocId) { throw 'Missing CWA secrets.' }

    $cwaUrl = "$cwaServer/Labtech/Deployment.aspx?InstallerType=msi&ID=$cwaKey&LocationID=$cwaLocId"
    $cwaMsi = Join-Path $Script:TmpDir 'CWAInstaller.msi'
    Write-Log "Downloading CWA installer..."
    (New-Object System.Net.WebClient).DownloadFile($cwaUrl, $cwaMsi)

    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$cwaMsi`" /qn /l*v `"$Script:LogDir\CWA.log`"" -Wait -PassThru
    if ($proc.ExitCode -in @(0, 3010)) { Write-Log 'CWA installed.' 'SUCCESS' }
    else { Write-Log "CWA exit code: $($proc.ExitCode)" 'WARN' }
}
catch { Write-Log "CWA failed: $($_.Exception.Message)" 'ERROR' }
#>


#endregion

#region --- Cleanup ---

Write-Log 'Cleaning up...'
try {
    Get-ChildItem $Script:TmpDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

    # Delete secrets.json — no longer needed after vault is loaded
    $localSecrets = Join-Path $SetupCompleteDir 'secrets.json'
    if (Test-Path $localSecrets) {
        Remove-Item $localSecrets -Force
        Write-Log 'secrets.json deleted from disk.' 'SUCCESS'
    }

    # Purge vault
    Get-SecretInfo -Vault $VaultName -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Secret -Name $_.Name -Vault $VaultName -ErrorAction SilentlyContinue }
    Unregister-SecretVault -Name $VaultName -ErrorAction SilentlyContinue
    Write-Log 'Vault purged.' 'SUCCESS'
}
catch { Write-Log "Cleanup error (non-fatal): $($_.Exception.Message)" 'WARN' }

#endregion

Write-Log '=====================================================' 'INFO'
Write-Log 'PostOS-Choco.ps1 complete.' 'SUCCESS'
Write-Log '=====================================================' 'INFO'
