#Requires -Version 5.1

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';
Function Get-UnattendTemplate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $TemplateUrl
    )

    $Response = Invoke-RestMethod `
        -Uri $TemplateUrl `
        -Method Get `
        -ErrorAction Stop;

    If ([System.String]::IsNullOrWhiteSpace([System.String] $Response)) {
        throw 'The unattend template download returned empty content.';
    };

    Return [System.String] $Response;
};

Function Get-SecretsData {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SecretsPath
    )

    If (-Not (Test-Path -LiteralPath $SecretsPath)) {
        throw "Secrets file not found: $SecretsPath";
    };

    $Json = Get-Content `
        -LiteralPath $SecretsPath `
        -Raw `
        -ErrorAction Stop;

    If ([System.String]::IsNullOrWhiteSpace($Json)) {
        throw "Secrets file is empty: $SecretsPath";
    };

    $Secrets = $Json | ConvertFrom-Json -ErrorAction Stop;

    If ([System.String]::IsNullOrWhiteSpace($Secrets.AdministratorUser)) {
        throw 'Secrets file is missing AdministratorUser.';
    };

    If ([System.String]::IsNullOrWhiteSpace($Secrets.AdministratorPassword)) {
        throw 'Secrets file is missing AdministratorPassword.';
    };

    Return $Secrets;
};

Function New-UnattendFromTemplate {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $TemplateContent,

        [Parameter(Mandatory = $True)]
        [ValidateNotNull()]
        [System.Object]
        $Secrets
    )

    $UnattendContent = $TemplateContent;

    $ReplacementMap = @{
        '{AdminUserName}' = [System.String] $Secrets.AdministratorUser;
        '{Password}'      = [System.String] $Secrets.AdministratorPassword;
    };

    Foreach ($Placeholder in $ReplacementMap.Keys) {
        $Value = $ReplacementMap[$Placeholder];

        If ($UnattendContent -notmatch [regex]::Escape($Placeholder)) {
            Write-Warning "Placeholder not found in template: $Placeholder";
            continue;
        };

        $UnattendContent = $UnattendContent.Replace($Placeholder, $Value);
    };

    Return $UnattendContent;
};

Function Save-UnattendFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Content,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $OutputPath
    )

    $ParentPath = Split-Path -Path $OutputPath -Parent;

    If (-Not [System.String]::IsNullOrWhiteSpace($ParentPath) -and (-Not (Test-Path -LiteralPath $ParentPath))) {
        New-Item `
            -Path $ParentPath `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop | Out-Null;
    };

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($False);
    [System.IO.File]::WriteAllText($OutputPath, $Content, $Utf8NoBom);
};

Function New-ConfiguredUnattendFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $TemplateUrl,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SecretsPath,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $OutputPath
    )

    Write-Host "Downloading unattend template from: $TemplateUrl";
    $TemplateContent = Get-UnattendTemplate -TemplateUrl $TemplateUrl;

    Write-Host "Loading secrets from: $SecretsPath";
    $Secrets = Get-SecretsData -SecretsPath $SecretsPath;

    Write-Host 'Replacing unattend placeholders';
    $ConfiguredUnattend = New-UnattendFromTemplate `
        -TemplateContent $TemplateContent `
        -Secrets $Secrets;

    Write-Host "Saving unattend file to: $OutputPath";
    Save-UnattendFile `
        -Content $ConfiguredUnattend `
        -OutputPath $OutputPath;

    Return [PSCustomObject]@{
        TemplateUrl = $TemplateUrl;
        SecretsPath = $SecretsPath;
        OutputPath  = $OutputPath;
        Success     = $True;
    };
};