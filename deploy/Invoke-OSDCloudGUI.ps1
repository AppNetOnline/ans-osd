#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud Deployment Console — launcher
.DESCRIPTION
    Fetches the UI (XAML) and deployment logic from GitHub, then opens the
    WPF monitor and runs Start-OSDCloud in a background runspace.
    Edit $DeployConfig and $GithubRaw below; do not edit the other two files.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Requires: OSD module, .NET Framework 4.8+
    Companion files (host on GitHub):
        OSDCloudGUI.xaml          — window layout
        Invoke-OSDCloudDeploy.ps1 — runspace deployment logic
#>

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
#  DEPLOYMENT CONFIGURATION — edit these values before deploying
# ─────────────────────────────────────────────────────────────────────────────
$DeployConfig = @{
    Restart               = [bool]$False
    RecoveryPartition     = [bool]$True
    OEMActivation         = [bool]$True
    WindowsUpdate         = [bool]$False
    WindowsUpdateDrivers  = [bool]$False
    WindowsDefenderUpdate = [bool]$False
    SetTimeZone           = [bool]$False
    ClearDiskConfirm      = [bool]$False
    ShutdownSetupComplete = [bool]$False
    SyncMSUpCatDriverUSB  = [bool]$True
    CheckSHA1             = [bool]$True
    OSVersion             = 11       # 10 or 11
    OSEdition             = 'Pro'    # Home | Pro | Enterprise | Education
    OSLanguage            = 'en-us'
    OSArch                = 'x64'
    ZTI                   = $True    # Zero Touch — suppresses all OSDCloud prompts
    SkipAutoPilot         = $True
    DriverPack            = $False   # $True for HP/Dell/Lenovo auto driver packs
}

# ─────────────────────────────────────────────────────────────────────────────
#  GITHUB — base URL for companion files
# ─────────────────────────────────────────────────────────────────────────────
$GithubRaw = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/deploy'

# ─────────────────────────────────────────────────────────────────────────────
#  ASSEMBLIES
# ─────────────────────────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ─────────────────────────────────────────────────────────────────────────────
#  BOOTSTRAP — fetch XAML and runspace script from GitHub before showing UI
# ─────────────────────────────────────────────────────────────────────────────
try {
    [xml]$XAML                      = Invoke-RestMethod "$GithubRaw/OSDCloudGUI.xaml"          -UseBasicParsing
    $script:DeployScriptContent     = Invoke-RestMethod "$GithubRaw/Invoke-OSDCloudDeploy.ps1" -UseBasicParsing
}
catch {
    Write-Host "Bootstrap failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Verify network connectivity and that $GithubRaw is reachable." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD WINDOW
# ─────────────────────────────────────────────────────────────────────────────
try {
    $reader = [System.Xml.XmlNodeReader]::new($XAML)
    $Window = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    Write-Host "XAML Error : $($_.Exception.Message)"               -ForegroundColor Red
    Write-Host "Line       : $($_.Exception.LineNumber)"            -ForegroundColor Yellow
    Write-Host "Inner      : $($_.Exception.InnerException.Message)" -ForegroundColor Magenta
    exit 1
}

Function Get-Control { Param($Name) $Window.FindName($Name) }

$RtbLog         = Get-Control 'RtbLog'
$LogScroller    = Get-Control 'LogScroller'
$StatusDot      = Get-Control 'StatusDot'
$TxtStatusLabel = Get-Control 'TxtStatusLabel'
$TxtProgress    = Get-Control 'TxtProgress'
$TxtPercent     = Get-Control 'TxtPercent'
$ProgressFill   = Get-Control 'ProgressFill'
$TxtClock       = Get-Control 'TxtClock'

# Fix RichTextBox PageWidth — prevents single-character-per-line rendering in .NET Framework
$RtbLog.Document.PageWidth        = 2000
$RtbLog.Document.LineHeight       = [Double]::NaN
$RtbLog.HorizontalContentAlignment = 'Stretch'
$Window.Add_SizeChanged({
    $RtbLog.Document.PageWidth = [Math]::Max($LogScroller.ActualWidth - 48, 400)
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHARED STATE
# ─────────────────────────────────────────────────────────────────────────────
$script:MessageQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:IsDeploying  = $False

$script:ProgressMap = [ordered]@{
    'initializing'          = @(2,   'Initializing OSDCloud...')
    'starting osdcloud'     = @(5,   'Starting OSDCloud engine...')
    'windows image'         = @(8,   'Locating Windows image...')
    'downloading'           = @(15,  'Downloading OS image...')
    'esd'                   = @(22,  'Processing ESD file...')
    'formatting'            = @(30,  'Formatting target disk...')
    'applying image'        = @(45,  'Applying Windows image...')
    'expand-windowsimage'   = @(50,  'Expanding Windows image...')
    'windows image applied' = @(60,  'Image applied successfully.')
    'installing drivers'    = @(65,  'Installing drivers...')
    'driver'                = @(68,  'Processing drivers...')
    'setting up windows'    = @(72,  'Configuring Windows...')
    'oobe'                  = @(76,  'Setting up OOBE...')
    'autopilot'             = @(79,  'Registering Autopilot...')
    'bitlocker'             = @(82,  'Configuring BitLocker...')
    'winre'                 = @(85,  'Rebuilding WinRE...')
    'finishing'             = @(90,  'Finishing deployment...')
    'complete'              = @(100, 'Deployment complete!')
    'restart'               = @(100, 'Complete — system restarting...')
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────
Function Write-LogLine {
    Param([string]$Text, [string]$Color = '#C8C8C8', [bool]$Bold = $False)
    $para = [System.Windows.Documents.Paragraph]::new()
    $para.Margin = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $run = [System.Windows.Documents.Run]::new($Text)
    $run.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    If ($Bold) { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $para.Inlines.Add($run)
    $RtbLog.Document.Blocks.Add($para)
    $LogScroller.ScrollToBottom()
}

Function Write-LogDivider {
    Param([string]$Label = '', [string]$Color = '#E50019')
    Write-LogLine ''
    If ($Label) { Write-LogLine "  $Label" $Color $True }
    Write-LogLine ('  ' + ([string][char]0x2500 * 56)) '#2A2A2A'
    Write-LogLine ''
}

Function Set-Status {
    Param([string]$Label, [string]$DotColor, [string]$TextColor)
    $StatusDot.Fill          = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($DotColor)
    $TxtStatusLabel.Text       = $Label
    $TxtStatusLabel.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($TextColor)
}

Function Update-Progress {
    Param([int]$Pct, [string]$Label)
    $TxtProgress.Text = $Label
    $TxtPercent.Text  = "$Pct%"
    $parent = $ProgressFill.Parent
    If ($parent -and $parent.ActualWidth -gt 0) {
        $ProgressFill.Width = [Math]::Round($parent.ActualWidth * ($Pct / 100), 1)
    }
    $color = If ($Pct -lt 50) { '#E50019' } ElseIf ($Pct -lt 90) { '#C8820A' } Else { '#3A9B50' }
    $ProgressFill.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($color)
}

Function Get-LineStyle {
    Param([string]$Line)
    $l = $Line.ToLower()
    If ($l -match 'error|fail|exception|critical') { Return @{ Color = '#E50019'; Bold = $False } }
    If ($l -match 'warning|warn')                  { Return @{ Color = '#C8820A'; Bold = $False } }
    If ($l -match 'success|complete|done|finished') { Return @{ Color = '#3A9B50'; Bold = $True  } }
    If ($l -match '^\s*\[')                         { Return @{ Color = '#AEB0B3'; Bold = $False } }
    If ($l -match 'verbose|debug')                  { Return @{ Color = '#383838'; Bold = $False } }
    Return @{ Color = '#C8C8C8'; Bold = $False }
}

Function Get-ProgressHint {
    Param([string]$Line)
    $l = $Line.ToLower()

    # Extract real download percentage from lines like "Downloading [####] 34%  234 MB/s"
    If ($l -match 'download' -and $Line -match '(\d{1,3})\s*%') {
        $dlPct   = [int]$Matches[1]
        $overall = 15 + [int]($dlPct * 0.14)   # maps 0-100% download → 15-29% overall
        Return @($overall, "Downloading OS image... ($dlPct%)")
    }

    ForEach ($key in $script:ProgressMap.Keys) {
        If ($l -match [regex]::Escape($key)) {
            Return $script:ProgressMap[$key]
        }
    }
    Return $Null
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISPATCHER TIMER — drains message queue onto UI thread every 80 ms
# ─────────────────────────────────────────────────────────────────────────────
$DispatchTimer          = [System.Windows.Threading.DispatcherTimer]::new()
$DispatchTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$DispatchTimer.Add_Tick({
    $TxtClock.Text = (Get-Date).ToString('HH:mm:ss')
    $msg = [hashtable]$Null
    $n   = 0
    while ($script:MessageQueue.TryDequeue([ref]$msg) -and $n -lt 30) {
        $n++
        $ts = (Get-Date).ToString('HH:mm:ss')
        switch ($msg.Type) {
            'line' {
                $style = Get-LineStyle $msg.Text
                Write-LogLine "[$ts]  $($msg.Text)" $style.Color $style.Bold
                $hint = Get-ProgressHint $msg.Text
                If ($hint) { Update-Progress $hint[0] $hint[1] }
            }
            'error' {
                Write-LogLine "[$ts]  ERROR: $($msg.Text)" '#E50019' $True
                Set-Status 'Error' '#E50019' '#E50019'
                $script:IsDeploying = $False
            }
            'complete' {
                Write-LogDivider 'Deployment Completed Successfully' '#3A9B50'
                Update-Progress 100 'Deployment complete!'
                Set-Status 'Complete' '#3A9B50' '#3A9B50'
                $script:IsDeploying = $False
            }
        }
    }
})
$DispatchTimer.Start()

# ─────────────────────────────────────────────────────────────────────────────
#  RUNSPACE — OSDCloud runs here; never blocks the UI thread
# ─────────────────────────────────────────────────────────────────────────────
Function Start-DeploymentRunspace {
    Param([hashtable]$Config)

    $script:IsDeploying = $True

    $rs                  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState   = 'STA'
    $rs.ThreadOptions    = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Config',       $Config)
    $rs.SessionStateProxy.SetVariable('MessageQueue', $script:MessageQueue)

    $ps          = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null        = $ps.AddScript($script:DeployScriptContent)

    $script:DeployRunspace = $rs
    $script:DeployPipeline = $ps
    $null = $ps.BeginInvoke()
}

# ─────────────────────────────────────────────────────────────────────────────
#  WINDOW EVENTS
# ─────────────────────────────────────────────────────────────────────────────
$Window.Add_MouseLeftButtonDown({ $Window.DragMove() })

$Window.Add_Loaded({
    Set-Status 'Deploying' '#E50019' '#E50019'
    Write-LogDivider "ANS OSDCloud  //  $(Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')" '#E50019'

    If (Get-Module -ListAvailable -Name OSD -ErrorAction SilentlyContinue) {
        $v = (Get-Module -ListAvailable -Name OSD | Select-Object -First 1).Version
        Write-LogLine "  OSD Module v$v detected." '#3A9B50'
    }
    Else {
        Write-LogLine '  WARNING: OSD Module not found. Install with: Install-Module OSD' '#C8820A'
    }
    Write-LogLine ''

    Start-DeploymentRunspace -Config $DeployConfig
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHOW
# ─────────────────────────────────────────────────────────────────────────────
[void]$Window.ShowDialog()

$DispatchTimer.Stop()
If ($script:DeployPipeline) {
    try { $script:DeployPipeline.Stop() } catch {}
    try { $script:DeployRunspace.Close() } catch {}
}
