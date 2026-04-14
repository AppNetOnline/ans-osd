#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud — WinPE OOBE shutdown script
.DESCRIPTION
    Runs after OSDCloud finishes imaging, before the machine reboots into Windows.
    - Reads secrets from secrets.json on the USB drive
    - Fetches shared functions from GitHub
    - Creates Unattend.xml on the imaged drive to suppress OOBE and configure auto-login
.NOTES
    Fetched at runtime by Config\Scripts\Shutdown\oobe.ps1 (baked into WinPE).
    Hosted at: winpe/Invoke-OOBE.ps1
    Update this file on GitHub to change OOBE behaviour without rebuilding the ISO.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$GithubBase  = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main'
$TemplateUrl = "$GithubBase/postos/Unattend.xml"
$FunctionsUrl = "$GithubBase/shared/ans-osd-functions.ps1"
$OutputPath  = 'C:\Windows\Panther\Unattend.xml'
$TranscriptPath = "$env:TEMP\ans-oobe.log"

# ─────────────────────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────────────────────
try { Start-Transcript -Path $TranscriptPath -Force | Out-Null } catch {}

Function Write-Step {
    Param([string]$Msg, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host "[$ts][$Level]  $Msg" -ForegroundColor $color
}

Write-Step '=================================================='
Write-Step 'ANS OSDCloud — Invoke-OOBE.ps1 started'
Write-Step '=================================================='

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD SECRETS from USB
# ─────────────────────────────────────────────────────────────────────────────
$secretsFile = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.Root 'OSDCloud\Config\Scripts\SetupComplete\secrets.json' } |
    Where-Object   { Test-Path $_ -ErrorAction SilentlyContinue } |
    Select-Object  -First 1

If (-not $secretsFile) {
    Write-Step 'secrets.json not found on any drive — cannot continue.' 'ERROR'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

Write-Step "Loading secrets from: $secretsFile" 'OK'
$Secrets = Get-Content $secretsFile -Raw | ConvertFrom-Json

If ([string]::IsNullOrWhiteSpace($Secrets.ANSAdminPassword)) {
    Write-Step 'ANSAdminPassword is empty in secrets.json — cannot continue.' 'ERROR'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD SHARED FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Fetching shared functions from $FunctionsUrl"
$functionsText = Invoke-RestMethod -Uri $FunctionsUrl -UseBasicParsing -ErrorAction Stop
Import-Module -ModuleInfo (New-Module -Name 'AnsOsdFunctions' -ScriptBlock ([ScriptBlock]::Create($functionsText))) -Force
Write-Step 'Shared functions loaded.' 'OK'

# ─────────────────────────────────────────────────────────────────────────────
#  BUILD UNATTEND.XML
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Creating Unattend.xml at $OutputPath"

$secretsHashtable = @{
    AdministratorUser     = 'ANSAdmin'
    AdministratorPassword = $Secrets.ANSAdminPassword
};

$Result = New-ConfiguredUnattendFile `
    -TemplateUrl $TemplateUrl `
    -Secrets     $secretsHashtable `
    -OutputPath  $OutputPath

Write-Step "Unattend.xml written successfully." 'OK'
Write-Step '=================================================='
Write-Step 'Invoke-OOBE.ps1 complete.'
Write-Step '=================================================='

try { Stop-Transcript | Out-Null } catch {}
