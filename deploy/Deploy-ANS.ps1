#to Run, boot OSDCloudUSB, at the PS Prompt:
#   iex (irm 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/Deploy-ANS.ps1')
#
# Or via startnet.cmd (set by Build-ANSWorkspace.ps1):
#   start /wait PowerShell -NoL -C Set-ExecutionPolicy RemoteSigned -Force
#   start /wait PowerShell -NoL -C "iex (irm 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/Deploy-ANS.ps1')"

#region Initialization

function Write-DarkGrayDate {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [System.String]
        $Message
    )
    if ($Message) {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) $Message"
    }
    else {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) " -NoNewline
    }
}
function Write-DarkGrayHost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]
        $Message
    )
    Write-Host -ForegroundColor DarkGray $Message
}
function Write-DarkGrayLine {
    [CmdletBinding()]
    param ()
    Write-Host -ForegroundColor DarkGray '========================================================================='
}
function Write-SectionHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]
        $Message
    )
    Write-DarkGrayLine
    Write-DarkGrayDate
    Write-Host -ForegroundColor Cyan $Message
}
function Write-SectionSuccess {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [System.String]
        $Message = 'Success!'
    )
    Write-DarkGrayDate
    Write-Host -ForegroundColor Green $Message
}

#endregion

$ScriptName    = 'Deploy-ANS.ps1'
$ScriptVersion = '1.3.0'
Write-Host -ForegroundColor Green "$ScriptName $ScriptVersion"

#region Variables

$Product      = (Get-MyComputerProduct)
$Model        = (Get-MyComputerModel)
$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
$OSVersion    = 'Windows 11'   # Used to determine driver pack
$OSReleaseID  = '24H2'         # Used to determine driver pack
$OSName       = 'Windows 11 24H2 x64'
$OSEdition    = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage   = 'en-us'

#endregion

#region OSDCloud Global Variables

$Global:MyOSDCloud = [ordered]@{
    Restart               = [bool]$True
    RecoveryPartition     = [bool]$true
    OEMActivation         = [bool]$True
    WindowsUpdate         = [bool]$true
    WindowsUpdateDrivers  = [bool]$true
    WindowsDefenderUpdate = [bool]$true
    SetTimeZone           = [bool]$true
    ClearDiskConfirm      = [bool]$False
    ShutdownSetupComplete = [bool]$false
    SyncMSUpCatDriverUSB  = [bool]$true
    CheckSHA1             = [bool]$true
};

#endregion

#region Driver Pack

$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID

if ($DriverPack) {
    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
}

#endregion

#region Vendor-Specific

if (Test-HPIASupport) {
    Write-SectionHeader -Message "Detected HP Device, Enabling HPIA, HP BIOS and HP TPM Updates"
    $Global:MyOSDCloud.HPTPMUpdate  = [bool]$True
    $Global:MyOSDCloud.HPBIOSUpdate = [bool]$true
    if ($Product -ne '83B2' -and $Model -notmatch "zbook") {
        $Global:MyOSDCloud.HPIAALL = [bool]$true
    }
    iex (irm https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-HPBiosSettings.ps1)
    Manage-HPBiosSettings -SetSettings
}

if ($Manufacturer -match "Lenovo") {
    iex (irm https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1)
    try {
        Manage-LenovoBIOSSettings -SetSettings
    }
    catch {}
}

#endregion

#region Launch OSDCloud

Write-SectionHeader "OSDCloud Variables"
Write-Output $Global:MyOSDCloud

Write-SectionHeader -Message "Starting OSDCloud"
Write-Host "Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage"

Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

#endregion

#region Post-OSDCloud Actions

Write-SectionHeader -Message "OSDCloud Process Complete, Running Custom Actions From Script Before Reboot"

# CMTrace
if (Test-Path -Path "X:\Windows\System32\cmtrace.exe") {
    Copy-Item "X:\Windows\System32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe" -Verbose
}

# Lenovo module copy
if ($Manufacturer -match "Lenovo") {
    $PowerShellSavePath = 'C:\Program Files\WindowsPowerShell'
    Write-Host "Copy-PSModuleToFolder -Name LSUClient to $PowerShellSavePath\Modules"
    Copy-PSModuleToFolder -Name LSUClient -Destination "$PowerShellSavePath\Modules"
    Write-Host "Copy-PSModuleToFolder -Name Lenovo.Client.Scripting to $PowerShellSavePath\Modules"
    Copy-PSModuleToFolder -Name Lenovo.Client.Scripting -Destination "$PowerShellSavePath\Modules"
}

#endregion

#Restart
#Restart-Computer