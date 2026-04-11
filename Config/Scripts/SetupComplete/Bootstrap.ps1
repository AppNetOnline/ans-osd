#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ANS OSDCloud SetupComplete Bootstrap
    Lives on the OSDCloud USB. Copied to C:\OSDCloud\Scripts\SetupComplete\ by OSDCloud.
    Downloads the latest PostOS script from GitHub and executes it.

.NOTES
    USB path : \OSDCloud\Config\Scripts\SetupComplete\Bootstrap.ps1
    Disk path: C:\OSDCloud\Scripts\SetupComplete\Bootstrap.ps1 (after OSDCloud copies it)

    To switch PostOS method: change $PostOSMethod below, update USB.
    To update PostOS logic : push changes to GitHub — no USB update needed.
#>

# =============================================================================
# --- EDIT THESE ---
# =============================================================================

# Your public GitHub raw base URL (no trailing slash)
$GitHubBaseURL = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/deploy'

# Which PostOS script to run: 'Chocolatey' or 'Direct'
$PostOSMethod = 'Chocolatey'

# =============================================================================

$MaxRetries = 3
$RetryDelaySec = 10

#region --- Logging ---

$LogDir = 'C:\OSDCloud\Logs'
$LogFile = "$LogDir\Bootstrap.log"
if (!(Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }

function Write-Log {
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
    $entry | Out-File $LogFile -Append -Encoding utf8
}

Write-Log '======================================================' 'INFO'
Write-Log "Bootstrap.ps1 started"
Write-Log "Method         : $PostOSMethod"
Write-Log "GitHub base URL: $GitHubBaseURL"
Write-Log "Script dir     : $PSScriptRoot"
Write-Log '======================================================' 'INFO'

#endregion

#region --- Verify secrets.json ---
# secrets.json is copied from the USB alongside this script by OSDCloud.
# If it's missing, the USB was not set up correctly.

$SecretsPath = Join-Path $PSScriptRoot 'secrets.json'

If (-not (Test-Path $SecretsPath)) {
    Write-Log "FATAL: secrets.json not found at $SecretsPath" 'ERROR'
    Write-Log "Ensure secrets.json is in C:\OSDCloud\Scripts\SetupComplete\ on the USB." 'ERROR'
    exit 1
};

Write-Log "secrets.json confirmed: $SecretsPath" 'SUCCESS'

#endregion

#region --- Download PostOS Script ---

$scriptName = if ($PostOSMethod -eq 'Direct') { 'PostOS-Direct.ps1' } else { 'PostOS-Choco.ps1' }
$scriptURL = "$GitHubBaseURL/$scriptName"
$scriptDest = Join-Path $PSScriptRoot $scriptName

Write-Log "Downloading $scriptName from GitHub..."

$downloaded = $false
$attempt = 0

while (-not $downloaded -and $attempt -lt $MaxRetries) {
    $attempt++
    Write-Log "Attempt $attempt/$MaxRetries : $scriptURL"
    try {
        Invoke-WebRequest -Uri $scriptURL -OutFile $scriptDest -UseBasicParsing -ErrorAction Stop
        if (Test-Path $scriptDest) {
            $kb = [math]::Round((Get-Item $scriptDest).Length / 1KB, 1)
            Write-Log "$scriptName downloaded ($kb KB)" 'SUCCESS'
            $downloaded = $true
        }
    }
    catch {
        Write-Log "Attempt $attempt failed: $($_.Exception.Message)" 'WARN'
        if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySec }
    }
};

If (-not $downloaded) {
    Write-Log "All download attempts failed for $scriptName. Cannot continue." 'ERROR'
    exit 1
};

#endregion

#region --- Download manifest.json (Direct method only) ---

If ($PostOSMethod -eq 'Direct') {
    $manifestURL = "$GitHubBaseURL/manifest.json"
    $manifestDest = Join-Path $PSScriptRoot 'manifest.json'
    Write-Log "Downloading manifest.json..."
    try {
        Invoke-WebRequest -Uri $manifestURL -OutFile $manifestDest -UseBasicParsing -ErrorAction Stop
        Write-Log "manifest.json downloaded." 'SUCCESS'
    }
    catch {
        Write-Log "manifest.json download failed (non-fatal): $($_.Exception.Message)" 'WARN'
    }
};

#endregion

#region --- Run PostOS Script ---

Write-Log "Launching $scriptName -SetupCompleteDir $PSScriptRoot"
try {
    & $scriptDest -SetupCompleteDir $PSScriptRoot
    Write-Log "$scriptName completed." 'SUCCESS'
}
catch {
    Write-Log "Exception from $($scriptName): $($_.Exception.Message)" 'ERROR'
    exit 1
}

#endregion

Write-Log '======================================================' 'INFO'
Write-Log 'Bootstrap.ps1 complete.' 'SUCCESS'
Write-Log '======================================================' 'INFO'
