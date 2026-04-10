#Requires -Version 5.1
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';

<#
.SYNOPSIS
    OSDCloud post-OS deployment script using Chocolatey.

.DESCRIPTION
    Hosted on GitHub and downloaded/executed by Bootstrap.ps1 during first boot.
    Runs during SetupComplete in SYSTEM context before OOBE.

    This script performs the following actions:
      1. Loads deployment secrets from secrets.json
      2. Configures Microsoft.PowerShell.SecretStore
      3. Creates or updates the ANSAdmin local administrator account
      4. Configures single-use auto-logon
      5. Writes C:\Windows\Panther\Unattend.xml
      6. Installs Chocolatey
      7. Installs standard applications
      8. Performs cleanup and removes sensitive data from disk

.ParamETER SetupCompleteDir
    Path to the SetupComplete working directory where secrets.json resides.
    This is passed by Bootstrap.ps1. If not provided, defaults to $PSScriptRoot.

.NOTES
    Author    : Jarod Roberts
    Company   : Appalachian Network Services
    GitHub    : https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/deploy/PostOS-Choco.ps1
    Context   : SetupComplete phase (SYSTEM), runs before OOBE
    Secrets   : Reads secrets.json from the SetupComplete directory
#>

Param(
    [Parameter(Mandatory = $False)]
    [string]$SetupCompleteDir = $PSScriptRoot
)

#region --- Variables ---

$Script:LogDir = 'C:\OSDCloud\Logs';
$Script:LogFile = Join-Path -Path $Script:LogDir -ChildPath 'PostOS-Choco.log';
$Script:TmpDir = 'C:\OSDCloud\Installers';
$Script:VaultName = 'ANSDeployVault';
$Script:SecretsPath = Join-Path -Path $SetupCompleteDir -ChildPath 'secrets.json';
$Script:UnattendPath = 'C:\Windows\Panther\Unattend.xml';

$ChocoPackages = @(
    '7zip',
    'notepadplusplus'
);

$TimeZone = 'Central Standard Time';

#endregion

#region --- Functions ---

Function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [string]$Message,

        [Parameter(Mandatory = $False)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $TimeStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss';

    $Color = switch ($Level) {
        'INFO' { 'Cyan' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SUCCESS' { 'Green' }
    };

    $Entry = "[{0}][{1}] {2}" -f $TimeStamp, $Level, $Message;

    Write-Host $Entry -ForegroundColor $Color;
    $Entry | Out-File -FilePath $Script:LogFile -Append -Encoding utf8;
};

Function Initialize-PostOSWorkspace {
    [CmdletBinding()]
    Param()

    ForEach ($Path in @($Script:LogDir, $Script:TmpDir)) {
        If (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null;
        };
    };
};

Function Get-DeploySecrets {
    [CmdletBinding()]
    Param()

    Write-Log -Message "Loading secrets from: $($Script:SecretsPath)";

    If (-not (Test-Path -Path $Script:SecretsPath)) {
        throw "secrets.json not found at $($Script:SecretsPath)";
    };

    Return (Get-Content -Path $Script:SecretsPath -Raw -ErrorAction Stop | ConvertFrom-Json);
};

Function Initialize-SecretStoreVault {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [psobject]$Secrets
    )

    Write-Log -Message 'Configuring SecretStore vault...';

    $NuGetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue;
    If (-not $NuGetProvider -or $NuGetProvider.Version -lt [version]'2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -Scope AllUsers | Out-Null;
    };

    ForEach ($ModuleName in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
        If (-not (Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue)) {
            Install-Module -Name $ModuleName -Force -SkipPublisherCheck -Scope AllUsers -ErrorAction Stop;
        };

        Import-Module -Name $ModuleName -Force -ErrorAction Stop;
    };

    Set-SecretStoreConfiguration -Authentication None -PasswordTimeout -1 -Interaction None -Confirm:$False -ErrorAction Stop;

    If (-not (Get-SecretVault -Name $Script:VaultName -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name $Script:VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault -ErrorAction Stop;
    };

    $SecretMap = @{
        ANSAdminPassword        = $Secrets.ANSAdminPassword
        SentinelOneToken        = $Secrets.SentinelOneToken
        SentinelOneInstallerURL = $Secrets.SentinelOneInstallerURL
        CWAServerURL            = $Secrets.CWAServerURL
        CWAInstallerKey         = $Secrets.CWAInstallerKey
        CWALocationID           = $Secrets.CWALocationID
    };

    ForEach ($Key in $SecretMap.Keys) {
        If ([string]::IsNullOrWhiteSpace([string]$SecretMap[$Key])) {
            Write-Log -Message "Secret '$Key' is empty in secrets.json" -Level 'WARN';
            continue;
        };

        Set-Secret -Name $Key -Secret $SecretMap[$Key] -Vault $Script:VaultName -ErrorAction Stop;
    };

    Write-Log -Message 'SecretStore vault populated.' -Level 'SUCCESS';
};

Function Get-DeploySecret {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $True
        )]
        [string]
        $Name
    )

    try {
        Return (Get-Secret -Name $Name -Vault $Script:VaultName -AsPlainText -ErrorAction Stop);
    }
    catch {
        Write-Log -Message "Could not read secret '$Name': $($_.Exception.Message)" -Level 'ERROR';
        Return $Null;
    }
};

Function Set-ANSAdminAccount {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Creating ANSAdmin local administrator...';

    $AdminPassword = Get-DeploySecret -Name 'ANSAdminPassword';
    If ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        throw 'ANSAdminPassword secret is missing or empty.';
    };

    $SecurePassword = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force;

    $ExistingUser = Get-LocalUser -Name 'ANSAdmin' -ErrorAction SilentlyContinue;
    If ($Null -ne $ExistingUser) {
        Write-Log -Message 'ANSAdmin exists, updating password.' -Level 'WARN';
        $ExistingUser | Set-LocalUser -Password $SecurePassword;
        Enable-LocalUser -Name 'ANSAdmin';
    }
    Else {
        New-LocalUser `
            -Name 'ANSAdmin' `
            -Password $SecurePassword `
            -FullName 'ANS Administrator' `
            -Description 'Managed local admin - ANS' `
            -PasswordNeverExpires `
            -AccountNeverExpires `
            -ErrorAction Stop | Out-Null;

        Write-Log -Message 'ANSAdmin created.' -Level 'SUCCESS';
    }

    $Members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue;
    If ($Members.Name -notcontains "$($env:COMPUTERNAME)\ANSAdmin") {
        Add-LocalGroupMember -Group 'Administrators' -Member 'ANSAdmin' -ErrorAction Stop;
        Write-Log -Message 'ANSAdmin added to Administrators.' -Level 'SUCCESS';
    };
};

Function Set-SingleUseAutoLogon {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Configuring single-use auto-logon...';

    $AdminPassword = Get-DeploySecret -Name 'ANSAdminPassword';
    If ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        Write-Log 'ANSAdminPassword secret is missing or empty.';
        $AdminPassword = "ChangeMe"
    };

    $RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon';

    Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon'    -Value '1'                 -Type String;
    Set-ItemProperty -Path $RegPath -Name 'DefaultUserName'   -Value 'ANSAdmin'          -Type String;
    Set-ItemProperty -Path $RegPath -Name 'DefaultPassword'   -Value $AdminPassword      -Type String;
    Set-ItemProperty -Path $RegPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME   -Type String;
    Set-ItemProperty -Path $RegPath -Name 'AutoLogonCount'    -Value 1                   -Type DWord;

    Write-Log -Message 'Auto-logon configured for one use.' -Level 'SUCCESS';
};

Function Set-UnattendFile {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Writing unattend.xml...';

    $PantherDir = Split-Path -Path $Script:UnattendPath -Parent;
    If (-not (Test-Path -Path $PantherDir)) {
        New-Item -Path $PantherDir -ItemType Directory -Force | Out-Null;
    };

    $UnattendXml = @"
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
"@;

    $UnattendXml | Out-File -FilePath $Script:UnattendPath -Encoding utf8 -Width 2000 -Force;
    Write-Log -Message 'Unattend.xml written.' -Level 'SUCCESS';
};

Function Install-Chocolatey {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Installing Chocolatey...';

    If (-not (Get-Command -Name 'choco' -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force;
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'));

        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [System.Environment]::GetEnvironmentVariable('Path', 'User');
    };

    Write-Log -Message 'Chocolatey ready.' -Level 'SUCCESS';
};

Function Install-ChocoPackages {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Installing standard applications...';

    ForEach ($Package in $ChocoPackages) {
        Write-Log -Message "Installing package: $Package";

        try {
            $Output = choco install $Package -y --no-progress --limit-output 2>&1;

            If ($LASTEXITCODE -in @(0, 3010)) {
                Write-Log -Message "$Package installed." -Level 'SUCCESS';
            }
            Else {
                Write-Log -Message "$Package Returned exit code $LASTEXITCODE : $($Output -join ' ')" -Level 'WARN';
            }
        }
        catch {
            Write-Log -Message "$Package threw an exception: $($_.Exception.Message)" -Level 'WARN';
        }
    };
};

Function Invoke-Cleanup {
    [CmdletBinding()]
    Param()

    Write-Log -Message 'Cleaning up...';

    try {
        Get-ChildItem -Path $Script:TmpDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue;

        If (Test-Path -Path $Script:SecretsPath) {
            Remove-Item -Path $Script:SecretsPath -Force;
            Write-Log -Message 'secrets.json deleted from disk.' -Level 'SUCCESS';
        };

        Get-SecretInfo -Vault $Script:VaultName -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Secret -Name $_.Name -Vault $Script:VaultName -ErrorAction SilentlyContinue;
        };

        Unregister-SecretVault -Name $Script:VaultName -ErrorAction SilentlyContinue;
        Write-Log -Message 'Vault purged.' -Level 'SUCCESS';
    }
    catch {
        Write-Log -Message "Cleanup error (non-fatal): $($_.Exception.Message)" -Level 'WARN';
    }
};

#endregion

#region --- Main ---

Initialize-PostOSWorkspace;

Write-Log -Message '=====================================================';
Write-Log -Message 'PostOS-Choco.ps1 started';
Write-Log -Message "SetupCompleteDir : $SetupCompleteDir";
Write-Log -Message '=====================================================';

try {
    $Secrets = Get-DeploySecrets;
    Write-Log -Message 'Secrets loaded.' -Level 'SUCCESS';

    Initialize-SecretStoreVault -Secrets $Secrets;
    Set-ANSAdminAccount;
    Set-SingleUseAutoLogon;
    Set-UnattendFile;
    Install-Chocolatey;
    Install-ChocoPackages;
}
catch {
    Write-Log -Message "Fatal error: $($_.Exception.Message)" -Level 'ERROR';
    exit 1;
}
finally {
    Invoke-Cleanup;
}

Write-Log -Message '=====================================================';
Write-Log -Message 'PostOS-Choco.ps1 complete.' -Level 'SUCCESS';
Write-Log -Message '=====================================================';

#endregion