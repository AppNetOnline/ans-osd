#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ANS OSDCloud Workspace Builder
    Run this ONCE on your admin workstation to build the template, workspace,
    configure WinPE, and stage SetupComplete files. Re-run when you need to
    rebuild USB media or update the WinPE configuration.

.DESCRIPTION
    Step 1 - Prerequisites     : ADK + WinPE Addon, OSD module
    Step 2 - Template          : New-OSDCloudTemplate (WinPE base, ~10-15 min)
    Step 3 - Workspace         : New-OSDCloudWorkspace (copy of template to customize)
    Step 4 - WinPE             : Edit-OSDCloudWinPE (bake -StartURL, drivers, wallpaper)
    Step 5 - SetupComplete     : Copy Bootstrap.ps1 + SetupComplete.cmd to workspace
    Step 6 - USB               : New-OSDCloudUSB (partition, format, copy media)
    Step 7 - USB Secrets       : Remind tech to place secrets.json on USB manually

.NOTES
    Prerequisites (install before running):
        Windows ADK       : https://go.microsoft.com/fwlink/?linkid=2243390
        WinPE Addon       : https://go.microsoft.com/fwlink/?linkid=2243391
        OSD Module        : Install-Module OSD -Force

    Re-running:
        - Edit-OSDCloudWinPE must be called with ALL params every run (resets startnet.cmd)
        - Use -SkipTemplate and -SkipWorkspace switches to skip already-built steps
        - Use -UpdateUSB to only update an existing USB without rebuilding ISO

    Template vs Workspace:
        Template  : Base WinPE image stored in C:\ProgramData\OSDCloud\Templates\
                    Created once, never modified directly
        Workspace : Your customizable copy at $WorkspacePath
                    Where drivers, scripts, wallpaper, and StartURL config live
                    Multiple workspaces can share one template
#>

[CmdletBinding()]
param(
    # Skip New-OSDCloudTemplate if already built (saves 10-15 min)
    [switch]$SkipTemplate,

    # Skip New-OSDCloudWorkspace if already exists
    [switch]$SkipWorkspace,

    # Only update USB from existing workspace (skip template + workspace build)
    [switch]$UpdateUSBOnly,

    # Workspace path
    [string]$WorkspacePath = 'C:\OSDCloud\ANS'
)

#region --- Config ---

# Template name — used to identify your build in Get-OSDCloudTemplateNames
$TemplateName  = 'ANS-WinPE'

# Your public GitHub raw base URL for Deploy-ANS.ps1
$DeployScriptURL = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/Deploy-ANS.ps1'

# WinPE cloud drivers to inject (comma-separated or wildcard *)
# Options: Dell, HP, IntelNet, LenovoDock, Nutanix, Surface, USB, VMware, WiFi
$CloudDrivers = @('Dell', 'HP', 'IntelNet', 'Surface', 'USB', 'WiFi')

# Optional: path to a JPG wallpaper for WinPE branding
# Leave empty to use OSDCloud default
$WallpaperPath = ''  # e.g. 'C:\ANS\Branding\winpe-bg.jpg'

#endregion

#region --- Logging ---

$LogFile = 'C:\OSDCloud\Logs\Build-ANSWorkspace.log'
if (!(Test-Path (Split-Path $LogFile))) { New-Item (Split-Path $LogFile) -ItemType Directory -Force | Out-Null }

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    $entry = "`n$(Get-Date -Format 'HH:mm:ss') === $Message ==="
    Write-Host $entry -ForegroundColor $Color
    $entry | Out-File $LogFile -Append -Encoding utf8
}
function Write-Info  { param([string]$m) Write-Host "  $m" -ForegroundColor Gray;   "  $m" | Out-File $LogFile -Append -Encoding utf8 }
function Write-OK    { param([string]$m) Write-Host "  $m" -ForegroundColor Green;  "  OK: $m" | Out-File $LogFile -Append -Encoding utf8 }
function Write-Warn  { param([string]$m) Write-Host "  $m" -ForegroundColor Yellow; "  WARN: $m" | Out-File $LogFile -Append -Encoding utf8 }
function Write-Fail  { param([string]$m) Write-Host "  $m" -ForegroundColor Red;    "  FAIL: $m" | Out-File $LogFile -Append -Encoding utf8 }

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "  ANS OSDCloud Workspace Builder" -ForegroundColor Cyan
Write-Host "  $(Get-Date)" -ForegroundColor DarkGray
Write-Host "=================================================`n" -ForegroundColor Cyan

#endregion

#region --- Step 1: Prerequisites ---

Write-Step "Step 1: Checking Prerequisites"

# OSD Module
if (-not (Get-Module -ListAvailable -Name OSD -ErrorAction SilentlyContinue)) {
    Write-Info "OSD module not found — installing..."
    Install-Module OSD -Force -SkipPublisherCheck -ErrorAction Stop
    Write-OK "OSD module installed."
}
else {
    $osdVer = (Get-Module -ListAvailable OSD | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-OK "OSD module present: v$osdVer"
    # Update to latest
    Write-Info "Updating OSD module to latest..."
    Update-Module OSD -Force -ErrorAction SilentlyContinue
}
Import-Module OSD -Force

# ADK check — look for oscdimg.exe which is part of the ADK Deployment Tools
$oscdimg = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\' `
           -Filter oscdimg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $oscdimg) {
    Write-Fail "Windows ADK not found."
    Write-Fail "Download ADK: https://go.microsoft.com/fwlink/?linkid=2243390"
    Write-Fail "Download WinPE Addon: https://go.microsoft.com/fwlink/?linkid=2243391"
    Write-Fail "Install both, then re-run this script."
    exit 1
}
Write-OK "Windows ADK found: $($oscdimg.FullName)"

# WinPE Addon check
$winpeAdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\' `
            -ErrorAction SilentlyContinue
if (-not $winpeAdk) {
    Write-Fail "WinPE Addon for ADK not found."
    Write-Fail "Download: https://go.microsoft.com/fwlink/?linkid=2243391"
    exit 1
}
Write-OK "WinPE Addon found."

if ($UpdateUSBOnly) {
    Write-Info "-UpdateUSBOnly specified — skipping template and workspace build."
    $SkipTemplate = $true
    $SkipWorkspace = $true
}

#endregion

#region --- Step 2: OSDCloud Template ---
# The Template is the base WinPE image. Build it once; reuse across workspaces.
# New-OSDCloudTemplate mounts the ADK WinPE WIM, injects packages (PowerShell,
# .NET, curl, Gallery support, etc.), and saves to C:\ProgramData\OSDCloud\Templates\

Write-Step "Step 2: OSDCloud Template"

if ($SkipTemplate) {
    $currentTemplate = Get-OSDCloudTemplate -ErrorAction SilentlyContinue
    Write-Info "Skipping template build. Current template: $currentTemplate"
}
else {
    $existingTemplates = Get-OSDCloudTemplateNames -ErrorAction SilentlyContinue
    if ($existingTemplates -contains $TemplateName) {
        Write-Warn "Template '$TemplateName' already exists."
        Write-Info "To rebuild it, delete C:\ProgramData\OSDCloud\Templates\$TemplateName and re-run."
        Set-OSDCloudTemplate -Name $TemplateName | Out-Null
    }
    else {
        Write-Info "Building template '$TemplateName' — this takes 10-15 minutes..."
        Write-Info "Adding 7-Zip support to template..."

        # -Add7Zip injects 7za.exe for HP Softpaq extraction in WinPE
        New-OSDCloudTemplate -Name $TemplateName -Add7Zip -Verbose

        Write-OK "Template '$TemplateName' created."
        Set-OSDCloudTemplate -Name $TemplateName | Out-Null
    }
}

$activeTemplate = Get-OSDCloudTemplate
Write-OK "Active template: $activeTemplate"

#endregion

#region --- Step 3: OSDCloud Workspace ---
# Workspace is a copy of the template you customize per-deployment scenario.
# Drivers, wallpaper, SetupComplete scripts, and WinPE startup config live here.
# Multiple workspaces can share one template — keep one for dev, one for prod.

Write-Step "Step 3: OSDCloud Workspace"

if ($SkipWorkspace) {
    Write-Info "Skipping workspace build."
    Set-OSDCloudWorkspace -WorkspacePath $WorkspacePath | Out-Null
}
else {
    if (Test-Path $WorkspacePath) {
        Write-Warn "Workspace path already exists: $WorkspacePath"
        Write-Info "Setting as active workspace. Use -SkipWorkspace to suppress this warning."
    }
    else {
        Write-Info "Creating workspace at $WorkspacePath..."
        New-OSDCloudWorkspace -WorkspacePath $WorkspacePath

        Write-OK "Workspace created at $WorkspacePath"
    }

    Set-OSDCloudWorkspace -WorkspacePath $WorkspacePath | Out-Null

    # Trim unnecessary language folders to reduce ISO/USB size
    Write-Info "Trimming non-English language files..."
    $keepDirs = @('boot','efi','en-us','sources','fonts','resources')
    $mediaDirs = @(
        "$WorkspacePath\Media",
        "$WorkspacePath\Media\Boot",
        "$WorkspacePath\Media\EFI\Microsoft\Boot"
    )
    foreach ($dir in $mediaDirs) {
        if (Test-Path $dir) {
            Get-ChildItem $dir | Where-Object { $_.PSIsContainer -and $_.Name -notin $keepDirs } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-OK "Language trim complete."
}

$activeWorkspace = Get-OSDCloudWorkspace
Write-OK "Active workspace: $activeWorkspace"

#endregion

#region --- Step 4: Edit WinPE ---
# Edit-OSDCloudWinPE mounts boot.wim, makes changes, unmounts.
# IMPORTANT: Every call RESETS startnet.cmd — always pass ALL params in one call.
# -StartURL bakes the Deploy-ANS.ps1 URL into startnet.cmd so it runs on boot.

Write-Step "Step 4: Configuring WinPE"
Write-Info "This mounts, modifies, and unmounts boot.wim — takes several minutes..."
Write-Warn "Edit-OSDCloudWinPE resets startnet.cmd on every run. All params must be in one call."

$editParams = @{
    StartURL       = $DeployScriptURL
    CloudDriver    = $CloudDrivers
    WorkspacePath  = $activeWorkspace
}

# Add wallpaper if specified and exists
if ($WallpaperPath -and (Test-Path $WallpaperPath)) {
    $editParams.Wallpaper = Get-Item $WallpaperPath
    Write-Info "Wallpaper: $WallpaperPath"
}
else {
    $editParams.UseDefaultWallpaper = $true
    if ($WallpaperPath) { Write-Warn "Wallpaper not found at '$WallpaperPath' — using default." }
}

Write-Info "Parameters being applied:"
Write-Info "  -StartURL      : $DeployScriptURL"
Write-Info "  -CloudDriver   : $($CloudDrivers -join ', ')"
Write-Info "  -WorkspacePath : $activeWorkspace"

Edit-OSDCloudWinPE @editParams

Write-OK "WinPE configuration complete."

#endregion

#region --- Step 5: Stage SetupComplete Files in Workspace ---
# Files placed here are automatically copied to the USB \OSDCloud\Config\Scripts\SetupComplete\
# when you run New-OSDCloudUSB or Update-OSDCloudUSB.
# OSDCloud then automatically copies them to C:\OSDCloud\Scripts\SetupComplete\
# on the target machine and wires SetupComplete.cmd.

Write-Step "Step 5: Staging SetupComplete Files in Workspace"

# Correct workspace path for SetupComplete content that ends up on the USB NTFS partition
$setupCompleteDest = "$activeWorkspace\OSDCloud\Config\Scripts\SetupComplete"

if (!(Test-Path $setupCompleteDest)) {
    New-Item $setupCompleteDest -ItemType Directory -Force | Out-Null
    Write-OK "Created: $setupCompleteDest"
}

# --- SetupComplete.cmd ---
$setupCompleteCmd = @'
@ECHO OFF
:: OSDCloud entry point — calls Bootstrap.ps1 which downloads the latest
:: PostOS script from GitHub and runs it with secrets.json from this folder.
powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Bootstrap.ps1"
'@
$setupCompleteCmd | Out-File "$setupCompleteDest\SetupComplete.cmd" -Encoding ascii -Force
Write-OK "SetupComplete.cmd staged."

# --- Bootstrap.ps1 ---
# NOTE: Replace the GitHubBaseURL value before building production USB
$bootstrapPs1 = @'
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
$GitHubBaseURL = 'https://raw.githubusercontent.com/your-org/ans-osd/main'

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
'@
$bootstrapPs1 | Out-File "$setupCompleteDest\Bootstrap.ps1" -Encoding utf8 -Force
Write-OK "Bootstrap.ps1 staged."

# --- secrets.json placeholder ---
# The REAL secrets.json must be manually placed on the USB after creation.
# This placeholder reminds the tech what's needed.
$secretsPlaceholder = @'
{
    "_IMPORTANT": "REPLACE THIS FILE with your real secrets.json before deploying.",
    "_DO_NOT_DEPLOY": "This placeholder must be replaced. Deploying with it will cause PostOS to fail.",

    "ANSAdminPassword":        "REPLACE_ME",
    "SentinelOneToken":        "REPLACE_ME",
    "SentinelOneInstallerURL": "REPLACE_ME",
    "CWAServerURL":            "REPLACE_ME",
    "CWAInstallerKey":         "REPLACE_ME",
    "CWALocationID":           "REPLACE_ME"
}
'@
$secretsPlaceholder | Out-File "$setupCompleteDest\secrets.json" -Encoding utf8 -Force
Write-Warn "secrets.json PLACEHOLDER staged — replace with real values on the USB after creation!"

Write-OK "SetupComplete staging complete: $setupCompleteDest"
Write-Info "Contents:"
Get-ChildItem $setupCompleteDest | ForEach-Object { Write-Info "  $($_.Name)" }

#endregion

#region --- Step 6: Create OSDCloud ISO and USB ---

Write-Step "Step 6: Building ISO and USB"

# Build ISO from workspace
Write-Info "Building OSDCloud ISO..."
New-OSDCloudISO -WorkspacePath $activeWorkspace
Write-OK "ISO created in $activeWorkspace"

# List available ISOs
$isoFiles = Get-ChildItem $activeWorkspace -Filter '*.iso' -ErrorAction SilentlyContinue
if ($isoFiles) {
    Write-Info "ISOs available:"
    $isoFiles | ForEach-Object { Write-Info "  $($_.Name) ($([math]::Round($_.Length/1MB,0)) MB)" }
    Write-Info "  OSDCloud_NoPrompt.iso boots directly into WinPE without a keypress."
}

# USB creation
Write-Host "`n  Connect your OSDCloud USB drive now." -ForegroundColor Yellow
Write-Host "  WARNING: The selected drive will be completely wiped." -ForegroundColor Red
$createUSB = Read-Host "`n  Create USB now? [Y/N]"

if ($createUSB -eq 'Y') {
    Write-Info "Launching New-OSDCloudUSB — select your USB disk number when prompted..."
    New-OSDCloudUSB -WorkspacePath $activeWorkspace
    Write-OK "USB creation complete."
}
else {
    Write-Info "USB creation skipped. To create USB later:"
    Write-Info "  Set-OSDCloudWorkspace -WorkspacePath '$WorkspacePath'"
    Write-Info "  New-OSDCloudUSB"
}

#endregion

#region --- Step 7: Post-Build Instructions ---

Write-Step "Step 7: Next Steps" 'Green'

Write-Host @"

  REQUIRED BEFORE DEPLOYING:
  ─────────────────────────────────────────────────────────────
  1. Replace secrets.json on the USB:
       USB path: \OSDCloud\Config\Scripts\SetupComplete\secrets.json
       Fill in real values for all fields (password, S1 token, CWA key, etc.)

  2. Push your GitHub scripts to: $DeployScriptURL
       - Deploy-ANS.ps1
       - PostOS-Choco.ps1 (or PostOS-Direct.ps1)
       - manifest.json

  3. Update Bootstrap.ps1 on the USB with your real GitHub URL
       Current placeholder: 'https://raw.githubusercontent.com/your-org/ans-osd/main'

  TO UPDATE SCRIPTS (no USB rebuild needed):
  ─────────────────────────────────────────────────────────────
  Push changes to GitHub. Next boot gets the latest automatically.

  TO UPDATE USB AFTER WORKSPACE CHANGES:
  ─────────────────────────────────────────────────────────────
  Set-OSDCloudWorkspace -WorkspacePath '$WorkspacePath'
  Update-OSDCloudUSB

  TO REBUILD WINPE (e.g. add drivers):
  ─────────────────────────────────────────────────────────────
  Re-run this script with -SkipTemplate -SkipWorkspace
  (Edit-OSDCloudWinPE always runs with all params in one call)

  LOG FILE: $LogFile

"@ -ForegroundColor Cyan

Write-Host "  Build complete." -ForegroundColor Green
Write-Host "  Workspace: $activeWorkspace`n" -ForegroundColor DarkGray

#endregion
