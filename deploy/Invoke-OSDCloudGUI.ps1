#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud Deployment Console
.DESCRIPTION
    Zero-touch WPF deployment monitor for OSDCloud.
    Runs Start-OSDCloud in a background runspace and streams all output
    live into the log panel. No user interaction required.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Requires: OSD module, .NET Framework 4.8+
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
    ShutdownSetupComplete = [bool]$false
    SyncMSUpCatDriverUSB  = [bool]$True
    CheckSHA1             = [bool]$True
    OSVersion             = 11          # 10 or 11
    OSEdition             = 'Pro'       # Home | Pro | Enterprise | Education
    OSLanguage            = 'en-us'
    OSArch                = 'x64'
    ZTI                   = $True       # Zero Touch — suppresses all OSDCloud prompts
    SkipAutoPilot         = $True
    DriverPack            = $False      # $True for HP/Dell/Lenovo auto driver packs
};

# ─────────────────────────────────────────────────────────────────────────────
#  ASSEMBLIES
# ─────────────────────────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ─────────────────────────────────────────────────────────────────────────────
#  XAML — full-width log monitor, ANS branded, no interactive controls
# ─────────────────────────────────────────────────────────────────────────────
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="ANS OSDCloud Deployment Console"
    Height="700" Width="1080"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    ResizeMode="NoResize">

    <Border CornerRadius="10"
            Background="#0E0E0E"
            BorderBrush="#2A2A2A"
            BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="50" ShadowDepth="0" Opacity="0.9"/>
        </Border.Effect>

        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="64"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="28"/>
            </Grid.RowDefinitions>

            <!-- HEADER -->
            <Border Grid.Row="0"
                    Background="#141414"
                    BorderBrush="#222222"
                    BorderThickness="0,0,0,1"
                    CornerRadius="10,10,0,0">
                <Grid Margin="20,0,20,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <!-- ANS logo mark -->
                    <Viewbox Grid.Column="0" Width="34" Height="34" Margin="0,0,14,0">
                        <Canvas Width="110" Height="110">
                            <Ellipse Canvas.Left="0"  Canvas.Top="65" Width="15" Height="15" Fill="#E50019"/>
                            <Ellipse Canvas.Left="89" Canvas.Top="0"  Width="15" Height="15" Fill="#E50019"/>
                            <Ellipse Canvas.Left="57" Canvas.Top="27" Width="15" Height="15" Fill="#E50019"/>
                            <Ellipse Canvas.Left="60" Canvas.Top="96" Width="15" Height="15" Fill="#E50019"/>
                            <Ellipse Canvas.Left="44" Canvas.Top="44" Width="22" Height="22" Fill="#E50019"/>
                            <Line X1="7"  Y1="72"  X2="55" Y2="55" Stroke="#E50019" StrokeThickness="3" Opacity="0.6"/>
                            <Line X1="96" Y1="7"   X2="55" Y2="55" Stroke="#E50019" StrokeThickness="3" Opacity="0.6"/>
                            <Line X1="64" Y1="34"  X2="55" Y2="55" Stroke="#E50019" StrokeThickness="3" Opacity="0.6"/>
                            <Line X1="67" Y1="103" X2="55" Y2="55" Stroke="#E50019" StrokeThickness="3" Opacity="0.6"/>
                        </Canvas>
                    </Viewbox>

                    <!-- Title -->
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="Appalachian"
                                       FontFamily="Segoe UI"
                                       FontSize="13" FontWeight="Normal"
                                       Foreground="#96999C"/>
                            <TextBlock Text=" Network Services"
                                       FontFamily="Segoe UI"
                                       FontSize="13" FontWeight="SemiBold"
                                       Foreground="#E8E8E8"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                            <TextBlock Text="OSDCloud"
                                       FontFamily="Cascadia Code, Consolas"
                                       FontSize="11"
                                       Foreground="#E50019"/>
                            <TextBlock Text=" / Deployment Console"
                                       FontFamily="Cascadia Code, Consolas"
                                       FontSize="11"
                                       Foreground="#3A3A3A"/>
                        </StackPanel>
                    </StackPanel>

                    <!-- Status -->
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#333333" Margin="0,0,8,0"/>
                        <TextBlock x:Name="TxtStatusLabel"
                                   Text="Initializing"
                                   FontFamily="Cascadia Code, Consolas"
                                   FontSize="12" Foreground="#555555"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- LOG -->
            <Grid Grid.Row="1" Background="#0A0A0A">
                <ScrollViewer x:Name="LogScroller"
                              VerticalScrollBarVisibility="Auto"
                              HorizontalScrollBarVisibility="Disabled"
                              Background="Transparent">
                    <RichTextBox x:Name="RtbLog"
                                 Background="Transparent"
                                 BorderThickness="0"
                                 IsReadOnly="True"
                                 FontFamily="Cascadia Code, Consolas, Courier New"
                                 FontSize="12"
                                 Foreground="#C8C8C8"
                                 Padding="24,16"
                                 HorizontalAlignment="Stretch"
                                 IsDocumentEnabled="True"
                                 VerticalScrollBarVisibility="Disabled"
                                 HorizontalScrollBarVisibility="Disabled"
                                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                </ScrollViewer>
            </Grid>

            <!-- PROGRESS -->
            <Border Grid.Row="2"
                    Background="#141414"
                    BorderBrush="#222222"
                    BorderThickness="0,1,0,0"
                    Padding="24,10">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="6"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,7">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="TxtProgress"
                                   Text="Awaiting deployment..."
                                   FontFamily="Cascadia Code, Consolas"
                                   FontSize="11" Foreground="#555555"/>
                        <TextBlock x:Name="TxtPercent"
                                   Grid.Column="1"
                                   Text="0%"
                                   FontFamily="Cascadia Code, Consolas"
                                   FontSize="11" Foreground="#555555"/>
                    </Grid>
                    <Border Grid.Row="1" Background="#1E1E1E" CornerRadius="3">
                        <Border x:Name="ProgressFill"
                                Background="#E50019"
                                CornerRadius="3"
                                HorizontalAlignment="Left"
                                Width="0"/>
                    </Border>
                </Grid>
            </Border>

            <!-- STATUS BAR -->
            <Border Grid.Row="3"
                    Background="#111111"
                    BorderBrush="#1E1E1E"
                    BorderThickness="0,1,0,0"
                    CornerRadius="0,0,10,10"
                    Padding="24,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Appalachian Network Services  —  appnetonline.com"
                               FontFamily="Cascadia Code, Consolas"
                               FontSize="10" Foreground="#2A2A2A"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtClock"
                               Grid.Column="1"
                               FontFamily="Cascadia Code, Consolas"
                               FontSize="10" Foreground="#2A2A2A"
                               VerticalAlignment="Center" Margin="0,0,20,0"/>
                    <TextBlock x:Name="TxtVersion"
                               Grid.Column="2"
                               Text="v2.0"
                               FontFamily="Cascadia Code, Consolas"
                               FontSize="10" Foreground="#2A2A2A"
                               VerticalAlignment="Center"/>
                </Grid>
            </Border>

        </Grid>
    </Border>
</Window>
'@

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD WINDOW
# ─────────────────────────────────────────────────────────────────────────────
try {
    $reader = [System.Xml.XmlNodeReader]::new($XAML)
    $Window = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    Write-Host "XAML Error : $($_.Exception.Message)"        -ForegroundColor Red
    Write-Host "Line       : $($_.Exception.LineNumber)"     -ForegroundColor Yellow
    Write-Host "Inner      : $($_.Exception.InnerException.Message)" -ForegroundColor Magenta
    exit 1
}

Function Get-Control { Param($Name) $Window.FindName($Name) }

$RtbLog = Get-Control 'RtbLog'
$LogScroller = Get-Control 'LogScroller'
$StatusDot = Get-Control 'StatusDot'
$TxtStatusLabel = Get-Control 'TxtStatusLabel'
$TxtProgress = Get-Control 'TxtProgress'
$TxtPercent = Get-Control 'TxtPercent'
$ProgressFill = Get-Control 'ProgressFill'
$TxtClock = Get-Control 'TxtClock'

# Fix .NET Framework RichTextBox PageWidth — prevents vertical character-per-line rendering
$RtbLog.Document.PageWidth = 2000
$RtbLog.Document.LineHeight = [Double]::NaN
$RtbLog.HorizontalContentAlignment = 'Stretch'
$Window.Add_SizeChanged({
        $RtbLog.Document.PageWidth = [Math]::Max($LogScroller.ActualWidth - 48, 400)
    })

# ─────────────────────────────────────────────────────────────────────────────
#  SHARED STATE
# ─────────────────────────────────────────────────────────────────────────────
$script:MessageQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:IsDeploying = $False

$script:ProgressMap = [ordered]@{
    'initializing'          = @(2, 'Initializing OSDCloud...')
    'starting osdcloud'     = @(5, 'Starting OSDCloud engine...')
    'windows image'         = @(8, 'Locating Windows image...')
    'downloading'           = @(15, 'Downloading OS image...')
    'esd'                   = @(22, 'Processing ESD file...')
    'formatting'            = @(30, 'Formatting target disk...')
    'applying image'        = @(45, 'Applying Windows image...')
    'expand-windowsimage'   = @(50, 'Expanding Windows image...')
    'windows image applied' = @(60, 'Image applied successfully.')
    'installing drivers'    = @(65, 'Installing drivers...')
    'driver'                = @(68, 'Processing drivers...')
    'setting up windows'    = @(72, 'Configuring Windows...')
    'oobe'                  = @(76, 'Setting up OOBE...')
    'autopilot'             = @(79, 'Registering Autopilot...')
    'bitlocker'             = @(82, 'Configuring BitLocker...')
    'winre'                 = @(85, 'Rebuilding WinRE...')
    'finishing'             = @(90, 'Finishing deployment...')
    'complete'              = @(100, 'Deployment complete!')
    'restart'               = @(100, 'Complete — system restarting...')
};

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
};

Function Write-LogDivider {
    Param(
        [string]
        $Label = '', 
        [string]
        $Color = '#E50019'
    )
    Write-LogLine ''
    If ($Label) { Write-LogLine "  $Label" $Color $True }
    Write-LogLine ('  ' + ([string][char]0x2500 * 56)) '#2A2A2A'
    Write-LogLine ''
};

Function Set-Status {
    Param(
        [string]
        $Label, 
        [string]
        $DotColor, 
        [string]
        $TextColor
    )
    $StatusDot.Fill = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($DotColor)
    $TxtStatusLabel.Text = $Label
    $TxtStatusLabel.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($TextColor)
};

Function Update-Progress {
    Param([int]$Pct, [string]$Label)
    $TxtProgress.Text = $Label
    $TxtPercent.Text = "$Pct%"
    $parent = $ProgressFill.Parent
    If ($parent -and $parent.ActualWidth -gt 0) {
        $ProgressFill.Width = [Math]::Round($parent.ActualWidth * ($Pct / 100), 1)
    };
    $color = If ($Pct -lt 50) { '#E50019' } ElseIf ($Pct -lt 90) { '#C8820A' } Else { '#3A9B50' }
    $ProgressFill.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($color)
};

Function Get-LineStyle {
    Param([string]$Line)
    $l = $Line.ToLower()
    If ($l -match 'error|fail|exception|critical') { Return @{ Color = '#E50019'; Bold = $False } }
    If ($l -match 'warning|warn') { Return @{ Color = '#C8820A'; Bold = $False } }
    If ($l -match 'success|complete|done|finished') { Return @{ Color = '#3A9B50'; Bold = $True } }
    If ($l -match '^\s*\[') { Return @{ Color = '#AEB0B3'; Bold = $False } }
    If ($l -match 'verbose|debug') { Return @{ Color = '#383838'; Bold = $False } }
    Return @{ Color = '#C8C8C8'; Bold = $False }
};

Function Get-ProgressHint {
    Param([string]$Line)
    $l = $Line.ToLower()
    ForEach ($key in $script:ProgressMap.Keys) {
        If ($l -match [regex]::Escape($key)) {
            y
            Return $script:ProgressMap[$key] 
        };
    };
    Return $Null
};

# ─────────────────────────────────────────────────────────────────────────────
#  DISPATCHER TIMER — drains queue onto UI thread every 80ms
# ─────────────────────────────────────────────────────────────────────────────
$DispatchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$DispatchTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$DispatchTimer.Add_Tick({
        $TxtClock.Text = (Get-Date).ToString('HH:mm:ss')
        $msg = [hashtable]$Null
        $n = 0
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
        };
    })
$DispatchTimer.Start()

# ─────────────────────────────────────────────────────────────────────────────
#  RUNSPACE — OSDCloud runs here, never blocks the UI thread
# ─────────────────────────────────────────────────────────────────────────────
Function Start-DeploymentRunspace {
    Param([hashtable]$Config)

    $script:IsDeploying = $True

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Config', $Config)
    $rs.SessionStateProxy.SetVariable('MessageQueue', $script:MessageQueue)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $Null = $ps.AddScript({

            Function Enqueue {
                Param([string]$Text, [string]$Type = 'line')
                $MessageQueue.Enqueue(@{ Type = $Type; Text = $Text })
            };

            try {
                Enqueue 'ANS OSDCloud Deployment Console'
                Enqueue "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                Enqueue ''

                If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
                    Enqueue 'Loading OSD module...'
                    Import-Module OSD -ErrorAction Stop
                };
                Enqueue "OSD module v$((Get-Module OSD).Version) loaded."
                Enqueue ''
                Enqueue "Target  : Windows $($Config.OSVersion) $($Config.OSEdition)"
                Enqueue "Language: $($Config.OSLanguage)   Arch: $($Config.OSArch)"
                Enqueue "ZTI     : $($Config.ZTI)"
                Enqueue ''
                Enqueue 'Starting OSDCloud in Zero Touch mode...'
                Enqueue ''
                <#
                # ══════════════════════════════════════════════════════════════
                #  SAFE TEST MODE — comment out and uncomment real block below
                #  when ready for live deployment
                # ══════════════════════════════════════════════════════════════
                $fakeLines = @(
                    @{ Text = 'Initializing OSDCloud environment...'; Delay = 800 }
                    @{ Text = 'Starting OSDCloud deployment...'; Delay = 600 }
                    @{ Text = '[OSDCloud] Checking prerequisites...'; Delay = 1200 }
                    @{ Text = 'VERBOSE: PowerShell 5.1 detected — compatible'; Delay = 400 }
                    @{ Text = '[OSDCloud] Locating Windows image source...'; Delay = 900 }
                    @{ Text = 'Downloading Windows image from Microsoft CDN...'; Delay = 700 }
                    @{ Text = 'VERBOSE: Resolving ESD download URL...'; Delay = 500 }
                    @{ Text = 'VERBOSE: ESD URL resolved successfully'; Delay = 400 }
                    @{ Text = 'Downloading [####                    ] 18%  234 MB/s'; Delay = 900 }
                    @{ Text = 'Downloading [########                ] 34%  198 MB/s'; Delay = 900 }
                    @{ Text = 'Downloading [############            ] 51%  221 MB/s'; Delay = 900 }
                    @{ Text = 'Downloading [################        ] 67%  244 MB/s'; Delay = 900 }
                    @{ Text = 'Downloading [####################    ] 83%  209 MB/s'; Delay = 900 }
                    @{ Text = 'Downloading [########################] 100% — Complete'; Delay = 700 }
                    @{ Text = ''; Delay = 200 }
                    @{ Text = '[OSDCloud] Formatting target disk...'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Partition style: GPT'; Delay = 400 }
                    @{ Text = 'VERBOSE: Creating EFI partition (100MB)...'; Delay = 600 }
                    @{ Text = 'VERBOSE: Creating MSR partition (16MB)...'; Delay = 400 }
                    @{ Text = 'VERBOSE: Creating Windows partition...'; Delay = 400 }
                    @{ Text = 'VERBOSE: Creating Recovery partition (984MB)...'; Delay = 600 }
                    @{ Text = 'Disk formatted successfully.'; Delay = 500 }
                    @{ Text = ''; Delay = 200 }
                    @{ Text = '[OSDCloud] Applying image to disk...'; Delay = 1000 }
                    @{ Text = 'Expand-WindowsImage — applying ESD to W:\...'; Delay = 700 }
                    @{ Text = 'VERBOSE: Apply progress:  10%'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Apply progress:  25%'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Apply progress:  40%'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Apply progress:  58%'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Apply progress:  74%'; Delay = 1200 }
                    @{ Text = 'VERBOSE: Apply progress:  91%'; Delay = 1200 }
                    @{ Text = 'Windows image applied successfully.'; Delay = 700 }
                    @{ Text = ''; Delay = 200 }
                    @{ Text = '[OSDCloud] Installing drivers...'; Delay = 1000 }
                    @{ Text = 'VERBOSE: Detecting manufacturer — Microsoft Corporation'; Delay = 600 }
                    @{ Text = 'Driver: searching WinGet for applicable packages...'; Delay = 800 }
                    @{ Text = 'VERBOSE: Found 4 driver packages'; Delay = 500 }
                    @{ Text = 'VERBOSE: Installing: Intel.WiFi.Driver 22.240.0'; Delay = 800 }
                    @{ Text = 'WARNING: Driver package not signed — skipping Intel.Bluetooth'; Delay = 600 }
                    @{ Text = 'VERBOSE: Drivers staged to offline image'; Delay = 600 }
                    @{ Text = ''; Delay = 200 }
                    @{ Text = '[OSDCloud] Setting up Windows...'; Delay = 1000 }
                    @{ Text = 'VERBOSE: Applying unattend.xml...'; Delay = 500 }
                    @{ Text = 'VERBOSE: Setting up OOBE configuration...'; Delay = 600 }
                    @{ Text = 'VERBOSE: Configuring bootloader (bcdboot)...'; Delay = 500 }
                    @{ Text = 'VERBOSE: Rebuilding WinRE image...'; Delay = 800 }
                    @{ Text = 'VERBOSE: WinRE registered successfully'; Delay = 400 }
                    @{ Text = ''; Delay = 200 }
                    @{ Text = '[OSDCloud] Finishing deployment...'; Delay = 800 }
                    @{ Text = 'VERBOSE: Dismounting Windows image...'; Delay = 500 }
                    @{ Text = 'VERBOSE: Cleaning up temp files...'; Delay = 400 }
                    @{ Text = 'Complete! Deployment finished successfully.'; Delay = 600 }
                    @{ Text = 'Restart required — rebooting in 10 seconds...'; Delay = 400 }
                )
                ForEach ($entry in $fakeLines) {
                    If ($entry.Text -ne '') { Enqueue $entry.Text }
                    Start-Sleep -Milliseconds $entry.Delay
                };
                $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
                #>
                # ══════════════════════════════════════════════════════════════
                #  REAL OSDCLOUD — uncomment this, comment out test block above
                # ══════════════════════════════════════════════════════════════

                $Params = @{
                    OSVersion     = $Config.OSVersion
                    OSEdition     = $Config.OSEdition
                    OSLanguage    = $Config.OSLanguage
                    OSArch        = $Config.OSArch
                    ZTI           = $Config.ZTI
                    SkipAutoPilot = $Config.SkipAutoPilot
                };

                $Params = @{
                    OSVersion  = $Config.OSVersion
                    OSEdition  = $Config.OSEdition
                    OSLanguage = $Config.OSLanguage
                    OSArch     = $Config.OSArch
                };

                $OptionalKeys = @(
                    'ZTI', 'SkipAutoPilot', 'Restart', 'RecoveryPartition', 'OEMActivation',
                    'WindowsUpdate', 'WindowsUpdateDrivers', 'WindowsDefenderUpdate',
                    'SetTimeZone', 'ClearDiskConfirm', 'ShutdownSetupComplete',
                    'SyncMSUpCatDriverUSB', 'CheckSHA1'
                );

                ForEach ($Key in $OptionalKeys) {
                    If ($Config.PSObject.Properties[$Key]) {
                        $Params[$Key] = [bool]$Config.$Key
                    };
                };

                If ($Config.DriverPack) { $Params['DriverPack'] = $True }

                $VerbosePreference = 'Continue'
                Start-OSDCloud @Params *>&1 | ForEach-Object {
                    $line = If ($_ -is [System.Management.Automation.ErrorRecord]) {
                        "ERROR: $($_.Exception.Message)"
                    }
                    ElseIf ($_ -is [System.Management.Automation.WarningRecord]) {
                        "WARNING: $($_.Message)"
                    }
                    ElseIf ($_ -is [System.Management.Automation.VerboseRecord]) {
                        "VERBOSE: $($_.Message)"
                    }
                    ElseIf ($_ -is [System.Management.Automation.InformationRecord]) {
                        $_.MessageData.ToString()
                    }
                    Else { $_.ToString() }
                    If ($line -and $line.Trim()) { Enqueue $line }
                };

                $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })

            }
            catch {
                $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
                $MessageQueue.Enqueue(@{ Type = 'line'; Text = $_.ScriptStackTrace })
            }
        })

    $script:DeployRunspace = $rs
    $script:DeployPipeline = $ps
    $Null = $ps.BeginInvoke()
};

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
};