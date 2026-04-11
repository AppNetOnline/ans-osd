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

Function New-UnattendFromTemplate {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $TemplateContent,

        [Parameter(Mandatory = $True)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]
        $Secrets
    );

    $UnattendContent = $TemplateContent;

    $ReplacementMap = @{
        '{AdminUserName}' = [System.String] $Secrets['AdministratorUser'];
        '{Password}'      = [System.String] $Secrets['AdministratorPassword'];
    };

    ForEach ($Key in $ReplacementMap.Keys) {
        $Value = $ReplacementMap[$Key];

        If ([System.String]::IsNullOrWhiteSpace($Value)) {
            throw "Replacement value for $Key is empty.";
        };

        $UnattendContent = $UnattendContent.Replace($Key, $Value);
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
        [ValidateNotNull()]
        [System.Collections.IDictionary]
        $Secrets,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $OutputPath
    );

    $TemplateContent = Get-UnattendTemplate -TemplateUrl $TemplateUrl;

    $ConfiguredUnattend = New-UnattendFromTemplate `
        -TemplateContent $TemplateContent `
        -Secrets $Secrets;

    Save-UnattendFile `
        -Content $ConfiguredUnattend `
        -OutputPath $OutputPath;

    Return [PSCustomObject]@{
        TemplateUrl = $TemplateUrl;
        OutputPath  = $OutputPath;
        Success     = $True;
    };
};