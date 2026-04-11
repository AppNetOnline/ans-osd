#Requires -Version 5.1

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';

$TranscriptPath = 'C:\ans-osd-transcript.log';

Try {
    Start-Transcript `
        -Path $TranscriptPath `
        -Force `
        -ErrorAction Stop;

    $TemplateUrl = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/deploy/Unattend.xml';
    $FunctionsUri = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/deploy/ans-osd-functions.ps1';
    $OutputPath = 'C:\Windows\Panther\Unattend.xml';

    # --- Hardcoded secrets ---
    $Secrets = @{
        AdministratorUser       = 'ANSAdmin';
        AdministratorPassword   = 'Password';
        SentinelOneToken        = 'REPLACE';
        SentinelOneInstallerURL = 'REPLACE';
        CWAServerURL            = 'REPLACE';
        CWAInstallerKey         = 'REPLACE';
        CWALocationID           = 'REPLACE';
    };

    If ([System.String]::IsNullOrWhiteSpace([System.String] $Secrets['AdministratorUser'])) {
        throw 'Missing AdministratorUser.';
    }

    If ([System.String]::IsNullOrWhiteSpace([System.String] $Secrets['AdministratorPassword'])) {
        throw 'Missing AdministratorPassword.';
    }

    # --- Save secrets.json ---
    $SecretsJsonPath = 'C:\OSDCloud\Scripts\SetupComplete\secrets.json';
    $SecretsDir = Split-Path -Path $SecretsJsonPath -Parent;

    If (-Not (Test-Path -LiteralPath $SecretsDir)) {
        New-Item `
            -Path $SecretsDir `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop | Out-Null;
    };

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($False);

    [System.IO.File]::WriteAllText(
        $SecretsJsonPath,
        ($Secrets | ConvertTo-Json -Depth 3),
        $Utf8NoBom
    );

    Write-Host "Secrets written to $SecretsJsonPath";

    # --- Load functions ---
    $FunctionsText = Invoke-RestMethod `
        -Uri $FunctionsUri `
        -ErrorAction Stop;

    Import-Module `
        -ModuleInfo (New-Module `
            -Name 'AnsOsdFunctions' `
            -ScriptBlock ([ScriptBlock]::Create($FunctionsText))) `
        -Force;

    # --- Create unattend ---
    $Result = New-ConfiguredUnattendFile `
        -TemplateUrl $TemplateUrl `
        -Secrets $Secrets `
        -OutputPath $OutputPath;

    Return $Result;
}
Catch {
    Write-Error $_;
}
Finally {
    Try {
        Stop-Transcript | Out-Null;
    }
    Catch {
        Write-Warning 'Transcript was not started or already stopped.';
    }
}