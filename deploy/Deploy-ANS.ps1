# To run: boot OSDCloud USB, at PS prompt:
#   iex (irm 'https://raw.githubusercontent.com/your-org/ans-osd/main/Deploy-ANS.ps1')
#
# Baked into WinPE via Build-ANSWorkspace.ps1:
#   Edit-OSDCloudWinPE -StartURL 'https://raw.githubusercontent.com/your-org/ans-osd/main/Deploy-ANS.ps1'
#
# This script is PUBLIC — no credentials, no secrets.
# Secrets live only on the OSDCloud USB in \OSDCloud\Config\Scripts\SetupComplete\secrets.json

#region --- Helper Functions ---

function Write-DarkGrayDate {
    [CmdletBinding()]
    param([Parameter(Position = 0)][System.String]$Message)
    if ($Message) { Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) $Message" }
    else          { Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) " -NoNewline }
}
function Write-DarkGrayHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.String]$Message)
    Write-Host -ForegroundColor DarkGray $Message
}
function Write-DarkGrayLine {
    Write-Host -ForegroundColor DarkGray '========================================================================='
}
function Write-SectionHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.String]$Message)
    Write-DarkGrayLine
    Write-DarkGrayDate
    Write-Host -ForegroundColor Cyan $Message
}
function Write-SectionSuccess {
    [CmdletBinding()]
    param([System.String]$Message = 'Success!')
    Write-DarkGrayDate
    Write-Host -ForegroundColor Green $Message
}

#endregion

$ScriptName    = 'Deploy-ANS.ps1'
$ScriptVersion = '1.2.0'
Write-Host -ForegroundColor Green "$ScriptName $ScriptVersion"

#region --- OS Variables ---

$Product      = (Get-MyComputerProduct)
$Model        = (Get-MyComputerModel)
$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
$OSVersion    = 'Windows 11'
$OSReleaseID  = '25H2'
$OSName       = 'Windows 11 24H2 x64'
$OSEdition    = 'Pro'
$OSActivation = 'Volume'
$OSLanguage   = 'en-us'

#endregion

#region --- OSDCloud Global Variables ---
# $Global:MyOSDCloud is merged into $Global:OSDCloud at the start of Invoke-OSDCloud,
# overriding defaults. Set everything you want here before calling Start-OSDCloud.

$Global:MyOSDCloud = [ordered]@{
    Restart               = [bool]$False    # Do not auto-restart after OS apply; script controls flow
    RecoveryPartition     = [bool]$true     # Create WinRE recovery partition
    OEMActivation         = [bool]$True     # Use BIOS-embedded product key if present
    WindowsUpdate         = [bool]$true     # Install Windows Updates via SetupComplete
    WindowsUpdateDrivers  = [bool]$false    # Install driver updates via Windows Update
    WindowsDefenderUpdate = [bool]$true     # Update Defender definitions via SetupComplete
    SetTimeZone           = [bool]$true     # Auto-detect timezone from IP
    ClearDiskConfirm      = [bool]$False    # Do not prompt before wiping disk (ZTI)
    ShutdownSetupComplete = [bool]$false    # Restart (not shutdown) after SetupComplete
    SyncMSUpCatDriverUSB  = [bool]$false     # Sync MS Update Catalog drivers from USB if present
    CheckSHA1             = [bool]$true     # Verify OS image SHA1 hash before applying
};

#endregion

#region --- Driver Pack Detection ---

$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
if ($DriverPack) {
    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
}

#endregion

#region --- Vendor-Specific Pre-OS Actions ---

If (Test-HPIASupport) {
    Write-SectionHeader "Detected HP Device — Enabling HPIA, BIOS and TPM Updates"
    $Global:MyOSDCloud.HPTPMUpdate  = [bool]$True
    $Global:MyOSDCloud.HPBIOSUpdate = [bool]$true
    # Skip HPIA on known problematic models
    if ($Product -ne '83B2' -and $Model -notmatch 'zbook') {
        $Global:MyOSDCloud.HPIAALL = [bool]$true
    }
    Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-HPBiosSettings.ps1")
    Manage-HPBiosSettings -SetSettings
}

If ($Manufacturer -match 'Lenovo') {
    Write-SectionHeader "Detected Lenovo Device — Applying BIOS Settings"
    Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1")
    try { Manage-LenovoBIOSSettings -SetSettings } catch {}
};

#endregion

#region --- Print Variables and Launch OSDCloud ---

Write-SectionHeader "OSDCloud Variables"
Write-Output $Global:MyOSDCloud

Write-SectionHeader "Starting OSDCloud"
Write-Host "Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage"

Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

#endregion

#region --- Post-OSDCloud Actions ---
# Runs in WinPE after OS image is applied, while C:\ is the offline OS volume.
# OSDCloud has already:
#   - Applied the OS image
#   - Injected driver packs
#   - Written SetupComplete.cmd (for Windows Updates)
#   - Copied \OSDCloud\Config\Scripts\SetupComplete\ from USB to C:\OSDCloud\Scripts\SetupComplete\
#     (which includes our Bootstrap.ps1 and secrets.json)

Write-SectionHeader "OSDCloud Complete — Running Post-Deployment Actions"

# CMTrace — copy from WinPE to deployed OS for log viewing
if (Test-Path 'X:\Windows\System32\cmtrace.exe') {
    Copy-Item 'X:\Windows\System32\cmtrace.exe' 'C:\Windows\System\cmtrace.exe' -Force
    Write-DarkGrayHost "CMTrace copied to C:\Windows\System\"
}

# Lenovo — copy PS modules to offline OS so they're available at first boot
if ($Manufacturer -match 'Lenovo') {
    $PSModuleDest = 'C:\Program Files\WindowsPowerShell'
    Write-DarkGrayHost "Copying Lenovo PS modules to offline OS..."
    Copy-PSModuleToFolder -Name LSUClient               -Destination "$PSModuleDest\Modules"
    Copy-PSModuleToFolder -Name Lenovo.Client.Scripting -Destination "$PSModuleDest\Modules"
}

#endregion

PAUSE

Write-SectionHeader "Deploy-ANS.ps1 Complete"
Write-SectionSuccess "Machine will reboot → SetupComplete (Bootstrap → PostOS) → OOBE."
