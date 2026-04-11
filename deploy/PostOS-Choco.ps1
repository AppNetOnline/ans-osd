#Requires -Version 5.1
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';

[string]$SetupCompleteDir = $PSScriptRoot

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
    Install-Chocolatey;
    Install-ChocoPackages;
}
catch {
    Write-Log -Message "Fatal error: $($_.Exception.Message)" -Level 'ERROR';
    #exit 1;
}
finally {
    Invoke-Cleanup;
}

Write-Log -Message '=====================================================';
Write-Log -Message 'PostOS-Choco.ps1 complete.' -Level 'SUCCESS';
Write-Log -Message '=====================================================';

#endregion