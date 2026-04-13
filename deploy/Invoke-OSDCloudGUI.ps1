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
    # ── Start-OSDCloud string parameters ──────────────────────────────────────
    OSName                = ''          # Full name e.g. "Windows 11 23H2 x64" — leave blank to let OSDCloud prompt
    OSEdition             = 'Pro'       # Home | Pro | Enterprise | Education
    OSLanguage            = 'en-us'
    OSActivation          = ''          # Retail | Volume — leave blank for default
    Manufacturer          = ''          # e.g. 'Dell' — leave blank for auto-detect
    Product               = ''          # e.g. 'Latitude 5540' — leave blank for auto-detect

    # ── Start-OSDCloud switch parameters ──────────────────────────────────────
    ZTI                   = $True      # Zero Touch — suppresses all OSDCloud prompts
    SkipAutopilot         = $True      # Skip Autopilot hash collection
    Restart               = $False     # Restart after deployment
    Shutdown              = $False     # Shutdown after deployment
    Firmware              = $False     # Apply firmware updates
    Screenshot            = $False     # Capture screenshots during deployment
    SkipODT               = $False     # Skip Office Deployment Tool
    Preview               = $False     # Use preview/insider images

    # ── $Global:MyOSDCloud behaviour keys (not passed to Start-OSDCloud) ──────
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
};

# Build $Global:MyOSDCloud from $DeployConfig so Start-OSDCloud picks up the same values
$Global:MyOSDCloud = [ordered]@{
    Restart               = [bool]$DeployConfig.Restart
    RecoveryPartition     = [bool]$DeployConfig.RecoveryPartition
    OEMActivation         = [bool]$DeployConfig.OEMActivation
    WindowsUpdate         = [bool]$DeployConfig.WindowsUpdate
    WindowsUpdateDrivers  = [bool]$DeployConfig.WindowsUpdateDrivers
    WindowsDefenderUpdate = [bool]$DeployConfig.WindowsDefenderUpdate
    SetTimeZone           = [bool]$DeployConfig.SetTimeZone
    ClearDiskConfirm      = [bool]$DeployConfig.ClearDiskConfirm
    ShutdownSetupComplete = [bool]$DeployConfig.ShutdownSetupComplete
    SyncMSUpCatDriverUSB  = [bool]$DeployConfig.SyncMSUpCatDriverUSB
    CheckSHA1             = [bool]$DeployConfig.CheckSHA1
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
    WindowStartupLocation="Manual"
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

                    <!-- Status + Minimize -->
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#333333" Margin="0,0,8,0"/>
                        <TextBlock x:Name="TxtStatusLabel"
                                   Text="Initializing"
                                   FontFamily="Cascadia Code, Consolas"
                                   FontSize="12" Foreground="#555555"
                                   Margin="0,0,16,0"/>
                        <Button x:Name="BtnMinimize"
                                Content="&#x2212;"
                                Width="26" Height="26"
                                Cursor="Hand"
                                ToolTip="Minimize"
                                FontFamily="Segoe UI" FontSize="14"
                                Foreground="#555555"
                                Background="Transparent"
                                BorderThickness="0">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="Bd"
                                                        Background="{TemplateBinding Background}"
                                                        CornerRadius="4">
                                                    <ContentPresenter HorizontalAlignment="Center"
                                                                      VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                                                        <Setter Property="Foreground" Value="#C8C8C8"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </Button.Style>
                        </Button>
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
$BtnMinimize = Get-Control 'BtnMinimize'

# Fit window to working area (respects taskbar)
$workArea = [System.Windows.SystemParameters]::WorkArea
$Window.Left = $workArea.Left
$Window.Top = $workArea.Top
$Window.Width = $workArea.Width
$Window.Height = $workArea.Height

$BtnMinimize.Add_Click({ $Window.WindowState = 'Minimized' })

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
    Param(
        [hashtable]
        $Config
    )

    $script:IsDeploying = $True

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Config', $Config)
    $rs.SessionStateProxy.SetVariable('MessageQueue', $script:MessageQueue)
    $rs.SessionStateProxy.SetVariable('MyOSDCloud', $Global:MyOSDCloud)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $Null = $ps.AddScript({

            # Raw log file — every line written here before GUI parsing
            $RawLogPath = "$env:TEMP\ANS-OSDCloud-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
            $RawLog = [System.IO.StreamWriter]::new($RawLogPath, $False, [System.Text.Encoding]::UTF8)
            $RawLog.AutoFlush = $True

            Function Enqueue {
                Param([string]$Text, [string]$Type = 'line')
                $MessageQueue.Enqueue(@{ Type = $Type; Text = $Text })
            };

            Function Write-Raw {
                Param([string]$Text)
                $RawLog.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff')  $Text")
            }

            # Make $Global:MyOSDCloud available in this runspace so Start-OSDCloud can read it
            $Global:MyOSDCloud = $MyOSDCloud

            try {
                Enqueue 'ANS OSDCloud Deployment Console'
                Enqueue "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                Enqueue ''

                If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
                    Enqueue 'Loading OSD module...'
                    Import-Module OSD -ErrorAction Stop
                };
                Enqueue "OSD module v$((Get-Module OSD).Version) loaded."
                Enqueue "Raw log : $RawLogPath"
                Enqueue ''

                # ── Patch Save-WebFile inside the OSD module scope ────────────
                # The original uses bare `Invoke-Expression curl.exe` with no stderr
                # redirect and no exit-code check. Under ErrorActionPreference=Stop
                # (which OSD sets internally) any non-zero curl exit becomes a
                # terminating error that aborts the entire deployment.
                # Fixes applied here:
                #   --no-progress-meter  → silences the "% Total" progress table
                #   2>&1 | Out-Null      → stderr never hits the PS error stream
                #   $local:EAP=Continue  → non-zero exit stays non-terminating
                #   $LASTEXITCODE check  → logs failures as warnings, not crashes
                
                <#
                $OSDModule = Get-Module OSD
                & $OSDModule {
                    Function Save-WebFile {
                        [CmdletBinding()]
                        [OutputType([System.IO.FileInfo])]
                        param (
                            [Parameter(Position = 0, Mandatory, ValueFromPipelineByPropertyName)]
                            [Alias('FileUri')][System.String]$SourceUrl,
                            [Parameter(ValueFromPipelineByPropertyName)]
                            [Alias('FileName')][System.String]$DestinationName,
                            [Alias('Path')][System.String]$DestinationDirectory = (Join-Path $env:TEMP 'OSD'),
                            [System.Management.Automation.SwitchParameter]$Overwrite,
                            [System.Management.Automation.SwitchParameter]$WebClient
                        )

                        Write-Verbose "SourceUrl: $SourceUrl"
                        Write-Verbose "DestinationDirectory: $DestinationDirectory"

                        if (-not (Test-Path $DestinationDirectory)) {
                            New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        }

                        $testFile = New-Item -Path (Join-Path $DestinationDirectory "$(Get-Random).tmp") -ItemType File -ErrorAction SilentlyContinue
                        if ($testFile) { Remove-Item $testFile.FullName -Force | Out-Null }
                        else { Write-Warning 'Unable to write to Destination Directory'; return $null }

                        if (-not $PSBoundParameters['DestinationName']) {
                            $DestinationName = ([System.Uri]$SourceUrl).AbsolutePath.Split('/')[-1]
                        }

                        $DestinationFullName = Join-Path ((Get-Item $DestinationDirectory -Force).FullName) $DestinationName

                        if ((-not $Overwrite) -and (Test-Path $DestinationFullName)) {
                            Write-Verbose 'File already cached'
                            return Get-Item $DestinationFullName -Force
                        }

                        $SourceUrl = [Uri]::EscapeUriString($SourceUrl.Replace('%', '~')).Replace('~', '%')

                        $UseWebClient = $false
                        if ($WebClient) { $UseWebClient = $true }
                        elseif (([System.Net.WebRequest]::DefaultWebProxy).Address) { $UseWebClient = $true }
                        elseif (!(Test-CommandCurlExe)) { $UseWebClient = $true }

                        if ($UseWebClient) {
                            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls1
                            $wc = New-Object System.Net.WebClient
                            try { $wc.DownloadFile($SourceUrl, $DestinationFullName) }
                            catch { Write-Warning "WebClient download failed: $_" }
                            finally { $wc.Dispose() }
                        }
                        else {
                            try { $remote = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $SourceUrl }
                            catch { Write-Warning "HEAD request failed: $_"; return $null }

                            $remoteLength = [Int64]($remote.Headers.'Content-Length' | Select-Object -First 1)
                            $remoteAcceptsRanges = ($remote.Headers.'Accept-Ranges' | Select-Object -First 1) -eq 'bytes'

                            $local:ErrorActionPreference = 'Continue'
                            Invoke-Expression "& curl.exe --insecure --location --no-progress-meter --output `"$DestinationFullName`" --url `"$SourceUrl`" 2>&1" | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                Write-Warning "curl.exe exited $LASTEXITCODE downloading $([System.IO.Path]::GetFileName($DestinationFullName))"
                            }

                            $RetryDelay = 1; $MaxRetry = 10; $RetryCount = 0
                            while (
                                (Test-Path $DestinationFullName) -and
                                ((Get-Item $DestinationFullName).Length -lt $remoteLength) -and
                                $remoteAcceptsRanges -and ($RetryCount -lt $MaxRetry)
                            ) {
                                Write-Verbose "Incomplete download; retrying in $RetryDelay s (attempt $($RetryCount+1))"
                                Start-Sleep -Seconds $RetryDelay
                                $RetryDelay *= 2; $RetryCount++
                                $local:ErrorActionPreference = 'Continue'
                                Invoke-Expression "& curl.exe --insecure --location --no-progress-meter --continue-at - --output `"$DestinationFullName`" --url `"$SourceUrl`" 2>&1" | Out-Null
                                if ($LASTEXITCODE -ne 0) {
                                    Write-Warning "curl.exe retry $RetryCount exited $LASTEXITCODE"
                                }
                            }

                            if ((Test-Path $DestinationFullName) -and ((Get-Item $DestinationFullName).Length -lt $remoteLength)) {
                                Write-Warning "Download still incomplete after $RetryCount retries: $([System.IO.Path]::GetFileName($DestinationFullName))"
                            }
                        }

                        if (Test-Path $DestinationFullName) { Get-Item $DestinationFullName -Force }
                        else { Write-Warning "Could not download $DestinationFullName"; $null }
                    };
                };
                Enqueue 'Save-WebFile patched (curl silent mode).'
                Enqueue ''
                #>

                # ── Hardware detection (requires OSD module) ──────────────────
                $HWProduct = Get-MyComputerProduct
                $HWModel = Get-MyComputerModel
                $HWManufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer

                # Auto driver pack — derive OS version label from OSName or fall back to Windows 11
                $OSVerLabel = If ($Config.OSName -match 'Windows\s+\d+') { $Matches[0] } Else { 'Windows 11' }
                $DriverPack = Get-OSDCloudDriverPack -Product $HWProduct -OSVersion $OSVerLabel -ErrorAction SilentlyContinue
                If ($DriverPack) {
                    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
                    Enqueue "Driver pack : $($DriverPack.Name)"
                };

                # HP-specific BIOS / HPIA settings
                If (Test-HPIASupport) {
                    Enqueue 'HP device detected — enabling HPIA / BIOS / TPM updates'
                    $Global:MyOSDCloud.HPTPMUpdate = [bool]$True
                    $Global:MyOSDCloud.HPBIOSUpdate = [bool]$True
                    If ($HWProduct -ne '83B2' -and $HWModel -notmatch 'zbook') {
                        $Global:MyOSDCloud.HPIAALL = [bool]$True
                    }
                    try {
                        Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-HPBiosSettings.ps1')
                        Manage-HPBiosSettings -SetSettings
                    }
                    catch { Enqueue "WARNING: HP BIOS settings script failed: $($_.Exception.Message)" }
                };

                # Lenovo-specific BIOS settings
                If ($HWManufacturer -match 'Lenovo') {
                    Enqueue 'Lenovo device detected — applying BIOS settings'
                    try {
                        Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1')
                        Manage-LenovoBIOSSettings -SetSettings
                    }
                    catch { Enqueue "WARNING: Lenovo BIOS settings script failed: $($_.Exception.Message)" }
                };

                Enqueue ''
                $targetLabel = If ($Config.OSName) { $Config.OSName } Else { "$($Config.OSEdition) (OSDCloud auto-select)" }
                Enqueue "Target  : $targetLabel"
                Enqueue "Language: $($Config.OSLanguage)"
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

                # ── Build params using only Start-OSDCloud's supported parameter set ──
                $Params = @{}

                # String params — included only when the config key exists and is non-empty
                $StringParams = @('OSName', 'OSEdition', 'OSLanguage', 'OSActivation', 'Manufacturer', 'Product')
                ForEach ($key in $StringParams) {
                    If ($Config.ContainsKey($key) -and $Config[$key]) { 
                        $Params[$key] = $Config[$key] 
                    };
                };

                # Switch params — included only when explicitly $True
                $SwitchParams = @('ZTI', 'SkipAutopilot', 'Restart', 'Shutdown', 'Firmware', 'Screenshot', 'SkipODT', 'Preview')
                ForEach ($key in $SwitchParams) {
                    If ($Config.ContainsKey($key) -and [bool]$Config[$key]) { 
                        $Params[$key] = $True 
                    };
                };

                $VerbosePreference = 'Continue'

                $ErrorActionPreference = 'SilentlyContinue';

                Start-OSDCloud @Params 3>&1 4>&1 6>&1 2>$Null | ForEach-Object {
                    $raw = $Null;

                    if ($_ -is [System.Management.Automation.WarningRecord]) {
                        $raw = "WARNING: $($_.Message)";
                    }
                    elseif ($_ -is [System.Management.Automation.VerboseRecord]) {
                        $raw = "VERBOSE: $($_.Message)";
                    }
                    elseif ($_ -is [System.Management.Automation.InformationRecord]) {
                        $raw = [string]$_.MessageData;
                    }
                    elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                        # This catches curl's stderr. Use 'Continue' to ignore it, 
                        # or process it differently if you need the actual error text.
                        return; 
                    }
                    else {
                        $raw = $_.ToString();
                    };

                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        Write-Raw $raw;
                        Enqueue $raw;
                    };
                };


                $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' });

            }
            catch {
                Write-Raw "EXCEPTION: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
                $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
                $MessageQueue.Enqueue(@{ Type = 'line'; Text = $_.ScriptStackTrace })
            }
            finally {
                $RawLog.Close()
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