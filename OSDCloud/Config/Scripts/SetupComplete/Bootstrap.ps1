#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ANS OSDCloud SetupComplete Bootstrap
    Downloads the latest PostOS script from GitHub and runs it.
    Reads secrets.json from the same directory (copied from USB by OSDCloud).
#>

param([string]$SetupCompleteDir = $PSScriptRoot)

# ============================================================
# EDIT THIS: Your public GitHub raw base URL
# ============================================================
$GitHubBaseURL = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main'

# 'Chocolatey' or 'Direct'
$PostOSMethod = 'Chocolatey'

$MaxRetries    = 3
$RetryDelaySec = 10

#region --- Logging ---
$LogFile = 'C:\OSDCloud\Logs\Bootstrap.log'
if (!(Test-Path (Split-Path $LogFile))) { New-Item (Split-Path $LogFile) -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'INFO' {'Cyan'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'SUCCESS' {'Green'} }
    $entry = "[$ts][$Level] $Message"
    Write-Host $entry -ForegroundColor $color
    $entry | Out-File $LogFile -Append -Encoding utf8
}

Write-Log '======================================================' 'INFO'
Write-Log "Bootstrap.ps1 started | Method: $PostOSMethod | Dir: $SetupCompleteDir"
Write-Log '======================================================' 'INFO'
#endregion

#region --- Verify secrets.json ---
$SecretsPath = Join-Path $SetupCompleteDir 'secrets.json'
if (-not (Test-Path $SecretsPath)) {
    Write-Log "FATAL: secrets.json not found at $SecretsPath" 'ERROR'
    Write-Log "Place secrets.json in \OSDCloud\Config\Scripts\SetupComplete\ on the USB." 'ERROR'
    exit 1
}
Write-Log "secrets.json confirmed: $SecretsPath" 'SUCCESS'
#endregion

#region --- Download PostOS script ---
$scriptName = if ($PostOSMethod -eq 'Direct') { 'PostOS-Direct.ps1' } else { 'PostOS-Choco.ps1' }
$scriptURL  = "$GitHubBaseURL/$scriptName"
$scriptDest = Join-Path $SetupCompleteDir $scriptName

$downloaded = $false
$attempt    = 0
while (-not $downloaded -and $attempt -lt $MaxRetries) {
    $attempt++
    Write-Log "Downloading $scriptName (attempt $attempt/$MaxRetries)..."
    try {
        Invoke-WebRequest -Uri $scriptURL -OutFile $scriptDest -UseBasicParsing -ErrorAction Stop
        if (Test-Path $scriptDest) { $downloaded = $true; Write-Log "$scriptName downloaded." 'SUCCESS' }
    }
    catch {
        Write-Log "Attempt $attempt failed: $($_.Exception.Message)" 'WARN'
        if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySec }
    }
}
if (-not $downloaded) { Write-Log "All download attempts failed." 'ERROR'; exit 1 }
#endregion

#region --- Download manifest.json (Direct method only) ---
if ($PostOSMethod -eq 'Direct') {
    $manifestDest = Join-Path $SetupCompleteDir 'manifest.json'
    try {
        Invoke-WebRequest -Uri "$GitHubBaseURL/manifest.json" -OutFile $manifestDest -UseBasicParsing -ErrorAction Stop
        Write-Log "manifest.json downloaded." 'SUCCESS'
    }
    catch { Write-Log "manifest.json download failed (non-fatal): $($_.Exception.Message)" 'WARN' }
}
#endregion

#region --- Run PostOS script ---
Write-Log "Launching $scriptName..."
try {
    & $scriptDest -SetupCompleteDir $SetupCompleteDir
    Write-Log "$scriptName completed." 'SUCCESS'
}
catch {
    Write-Log "Exception from $scriptName : $($_.Exception.Message)" 'ERROR'
    exit 1
}
#endregion

Write-Log 'Bootstrap.ps1 complete.' 'SUCCESS'
