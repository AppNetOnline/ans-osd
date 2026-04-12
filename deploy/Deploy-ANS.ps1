#to Run, boot OSDCloudUSB, at the PS Prompt:
#   iex (irm 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/Deploy-ANS.ps1')
#
# Or via startnet.cmd (set by Build-ANSWorkspace.ps1):
#   start /wait PowerShell -NoL -C Set-ExecutionPolicy RemoteSigned -Force
#   start /wait PowerShell -NoL -C "iex (irm 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/deploy/Deploy-ANS.ps1')"

#region Initialization

Set-ExecutionPolicy RemoteSigned -Force
Import-Module OSD -Force

Function Write-DarkGrayDate {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [System.String]
        $Message
    )
    If ($Message) {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) $Message"
    }
    Else {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) " -NoNewline
    }
};
Function Write-DarkGrayHost {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True, Position = 0)]
        [System.String]
        $Message
    )
    Write-Host -ForegroundColor DarkGray $Message
};
Function Write-DarkGrayLine {
    [CmdletBinding()]
    Param ()
    Write-Host -ForegroundColor DarkGray '========================================================================='
};
Function Write-SectionHeader {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True, Position = 0)]
        [System.String]
        $Message
    )
    Write-DarkGrayLine
    Write-DarkGrayDate
    Write-Host -ForegroundColor Cyan $Message
};
Function Write-SectionSuccess {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [System.String]
        $Message = 'Success!'
    )
    Write-DarkGrayDate
    Write-Host -ForegroundColor Green $Message
};

#endregion

$ScriptName    = 'Deploy-ANS.ps1'
$ScriptVersion = '1.4.0'
Write-Host -ForegroundColor Green "$ScriptName $ScriptVersion"

#region Variables

$Product      = (Get-MyComputerProduct)
$Model        = (Get-MyComputerModel)
$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
$OSVersion    = 'Windows 11'   # Used to determine driver pack
$OSReleaseID  = '25H2'         # Used to determine driver pack
$OSName       = 'Windows 11 24H2 x64'
$OSEdition    = 'Pro'
$OSActivation = 'Volume'
$OSLanguage   = 'en-us'

#endregion

#region OSDCloud Global Variables

$Global:MyOSDCloud = [ordered]@{
    Restart               = [bool]$False
    RecoveryPartition     = [bool]$True
    OEMActivation         = [bool]$True
    WindowsUpdate         = [bool]$False
    WindowsUpdateDrivers  = [bool]$False
    WindowsDefenderUpdate = [bool]$False
    SetTimeZone           = [bool]$False
    ClearDiskConfirm      = [bool]$False
    ShutdownSetupComplete = [bool]$false
    SyncMSUpCatDriverUSB  = [bool]$True
    CheckSHA1             = [bool]$True
};

#endregion

#region Driver Pack

$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID

If ($DriverPack) {
    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
};

#endregion

#region Vendor-Specific

If (Test-HPIASupport) {
    Write-SectionHeader -Message "Detected HP Device, Enabling HPIA, HP BIOS and HP TPM Updates"
    $Global:MyOSDCloud.HPTPMUpdate  = [bool]$True
    $Global:MyOSDCloud.HPBIOSUpdate = [bool]$True
    If ($Product -ne '83B2' -and $Model -notmatch "zbook") {
        $Global:MyOSDCloud.HPIAALL = [bool]$True
    };
    Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-HPBiosSettings.ps1")
    Manage-HPBiosSettings -SetSettings
};

If ($Manufacturer -match "Lenovo") {
    Invoke-Expression (Invoke-RestMethod "https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1")
    try {
        Manage-LenovoBIOSSettings -SetSettings
    }
    catch {}
};

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

# Lenovo module copy
If ($Manufacturer -match "Lenovo") {
    $PowerShellSavePath = 'C:\Program Files\WindowsPowerShell'
    Write-Host "Copy-PSModuleToFolder -Name LSUClient to $PowerShellSavePath\Modules"
    Copy-PSModuleToFolder -Name LSUClient -Destination "$PowerShellSavePath\Modules"
    Write-Host "Copy-PSModuleToFolder -Name Lenovo.Client.Scripting to $PowerShellSavePath\Modules"
    Copy-PSModuleToFolder -Name Lenovo.Client.Scripting -Destination "$PowerShellSavePath\Modules"
};

#endregion

#Restart
#Restart-Computer -Force