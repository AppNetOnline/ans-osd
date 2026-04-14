#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud deployment runspace script.
.DESCRIPTION
    Runs inside an isolated PowerShell runspace launched by Invoke-OSDCloudGUI.ps1.
    Variables injected by the parent before this script runs:
        $Config       — hashtable of deployment options
        $MessageQueue — ConcurrentQueue[hashtable] shared with the UI thread
        $MyOSDCloud   — ordered hashtable used to seed $Global:MyOSDCloud
        $GithubBase   — raw GitHub base URL (e.g. .../AppNetOnline/ans-osd/main)
    Do not run this script directly.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Hosted  : https://github.com/AppNetOnline/ans-osd/blob/main/winpe/Invoke-OSDCloudDeploy.ps1
#>

# ─────────────────────────────────────────────────────────────────────────────
#  RAW LOG — every output line written before GUI parsing
# ─────────────────────────────────────────────────────────────────────────────
$RawLogPath = "$env:TEMP\ANS-OSDCloud-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$RawLog     = [System.IO.StreamWriter]::new($RawLogPath, $False, [System.Text.Encoding]::UTF8)
$RawLog.AutoFlush = $True

# ─────────────────────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────────────────────
Function Enqueue {
    Param([string]$Text, [string]$Type = 'line')
    $MessageQueue.Enqueue(@{ Type = $Type; Text = $Text })
};

Function Write-Raw {
    Param([string]$Text)
    $RawLog.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff')  $Text")
};

# ─────────────────────────────────────────────────────────────────────────────
#  MONITORING HELPERS
# ─────────────────────────────────────────────────────────────────────────────
$script:DBConn      = $null
$script:DBRowId     = $null
$script:StartTime   = Get-Date

Function Initialize-Monitor {
    <#
    Loads GitHubDB from the shared/ folder, finds secrets.json on the USB,
    and builds the DB connection. Returns $true if monitoring is ready.
    All failures are non-fatal — deployment always continues.
    #>
    try {
        # Fetch and import GitHubDB module from shared/
        $modulePath = Join-Path $env:TEMP 'GitHubDB.psm1'
        $moduleContent = Invoke-RestMethod "$GithubBase/shared/GitHubDB.psm1" -UseBasicParsing -ErrorAction Stop
        Set-Content -Path $modulePath -Value $moduleContent -Encoding UTF8
        Import-Module $modulePath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop

        # Find secrets.json on the OSDCloud USB (searched across all drives)
        $secretsFile = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.Root 'OSDCloud\Config\Scripts\SetupComplete\secrets.json' } |
            Where-Object   { Test-Path $_ -ErrorAction SilentlyContinue } |
            Select-Object  -First 1

        If (-not $secretsFile) {
            Enqueue 'Monitoring: secrets.json not found on USB — skipping'
            Return $false
        };

        $sec = Get-Content $secretsFile -Raw | ConvertFrom-Json
        if (-not $sec.GitHubDBToken) {
            Enqueue 'Monitoring: GitHubDBToken missing from secrets.json — skipping'
            Return $false
        }

        $script:DBConn = @{
            Owner  = 'AppNetOnline'
            Repo   = 'deployment-db'
            Path   = 'data/deployments.json'
            Token  = $sec.GitHubDBToken
            Branch = 'main'
        };
        Return $true
    }
    catch {
        Enqueue "Monitoring: init failed ($($_.Exception.Message)) — skipping"
        Return $false
    }
};

Function Get-HardwareInfo {
    <# Collects hardware details via CIM — best-effort, partial data is acceptable. #>
    $hw = @{}
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem        -ErrorAction SilentlyContinue
        $bios = Get-CimInstance Win32_BIOS                  -ErrorAction SilentlyContinue
        $cpu  = Get-CimInstance Win32_Processor             -ErrorAction SilentlyContinue | Select-Object -First 1
        $disk = Get-CimInstance Win32_DiskDrive             -ErrorAction SilentlyContinue | Sort-Object Size -Descending | Select-Object -First 1
        $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $macs = Get-CimInstance Win32_NetworkAdapter        -ErrorAction SilentlyContinue |
                    Where-Object { $_.MACAddress -and $_.PhysicalAdapter } |
                    ForEach-Object { $_.MACAddress } |
                    Select-Object -First 3

        $hw.Hostname        = $env:COMPUTERNAME
        $hw.Manufacturer    = $cs.Manufacturer
        $hw.Model           = $cs.Model
        $hw.SerialNumber    = $bios.SerialNumber
        $hw.UUID            = $prod.UUID
        $hw.CPU             = $cpu.Name.Trim()
        $hw.CPUCores        = [int]$cpu.NumberOfCores
        $hw.CPULogicalProcs = [int]$cpu.NumberOfLogicalProcessors
        $hw.CPUSpeedMHz     = [int]$cpu.MaxClockSpeed
        $hw.RAMGb           = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $hw.DiskGB          = if ($disk.Size) { [math]::Round($disk.Size / 1GB) } else { $null }
        $hw.BIOSVersion     = $bios.SMBIOSBIOSVersion
        $hw.BIOSDate        = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { $null }
        $hw.MACAddresses    = ($macs -join ', ')
    }
    catch { <# best-effort — return whatever was collected #> }
    Return $hw
};

Function Get-GeoInfo {
    <# Gets public IP and approximate location from ip-api.com (free, no key). #>
    try {
        $geo = Invoke-RestMethod 'http://ip-api.com/json' -UseBasicParsing -ErrorAction Stop
        Return @{
            PublicIP = $geo.query
            ISP      = $geo.isp
            City     = $geo.city
            Region   = $geo.regionName
            Country  = $geo.country
            Timezone = $geo.timezone
        };
    }
    catch { Return @{} }
};

Function New-DeployRecord {
    Param([hashtable]$HW, [hashtable]$Geo, [string]$OSTarget, [string]$OSDVersion)
    If (-not $script:DBConn) { Return }
    try {
        $row = @{
            Status          = 'Running'
            StartTime       = $script:StartTime.ToString('o')
            EndTime         = $null
            DurationMinutes = $null
            ErrorMessage    = $null
            OSTarget        = $OSTarget
            OSDCloudVersion = $OSDVersion
        };
        ForEach ($k in $HW.Keys) { $row[$k] = $HW[$k] };
        ForEach ($k in $Geo.Keys) { $row[$k] = $Geo[$k] };

        $added           = Add-GHDBRow -Connection $script:DBConn -Row $row
        $script:DBRowId  = $added.id
        Enqueue "Monitoring: record created (id=$($script:DBRowId))"
    }
    catch { Enqueue "Monitoring: failed to create record ($($_.Exception.Message))" }
};

Function Complete-DeployRecord {
    If (-not $script:DBConn -or -not $script:DBRowId) { Return }
    try {
        $end = Get-Date
        Update-GHDBRow -Connection $script:DBConn -Id $script:DBRowId -Updates @{
            Status          = 'Complete'
            EndTime         = $end.ToString('o')
            DurationMinutes = [math]::Round(($end - $script:StartTime).TotalMinutes, 1)
        };
        Enqueue 'Monitoring: record updated (Complete)'
    }
    catch { Enqueue "Monitoring: failed to update record ($($_.Exception.Message))" }
};

Function Fail-DeployRecord {
    Param([string]$ErrorMessage)
    If (-not $script:DBConn -or -not $script:DBRowId) { Return };
    try {
        $end = Get-Date
        Update-GHDBRow -Connection $script:DBConn -Id $script:DBRowId -Updates @{
            Status          = 'Error'
            EndTime         = $end.ToString('o')
            DurationMinutes = [math]::Round(($end - $script:StartTime).TotalMinutes, 1)
            ErrorMessage    = $ErrorMessage
        };
    }
    catch { <# swallow — must not mask the original error #> }
};

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
$Global:MyOSDCloud = $MyOSDCloud

# Initialize monitoring before anything else so we capture the full duration
$monitorActive = Initialize-Monitor

try {
    Enqueue 'ANS OSDCloud Deployment Console'
    Enqueue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Enqueue ''

    If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
        Enqueue 'Loading OSD module...'
        Import-Module OSD -WarningAction SilentlyContinue -ErrorAction Stop
    };
    $osdVersion = (Get-Module OSD).Version.ToString()
    Enqueue "OSD module v$osdVersion loaded."
    Enqueue "Raw log : $RawLogPath"
    Enqueue ''

    # ── Hardware detection ────────────────────────────────────────────────────
    $HW          = Get-HardwareInfo
    $Geo         = Get-GeoInfo
    $HWProduct   = Get-MyComputerProduct
    $HWModel     = Get-MyComputerModel
    $HWMfr       = $HW.Manufacturer

    Enqueue "Hardware : $($HW.Manufacturer) $($HW.Model) — S/N $($HW.SerialNumber)"
    Enqueue "CPU      : $($HW.CPU) ($($HW.CPUCores)C/$($HW.CPULogicalProcs)T)"
    Enqueue "RAM      : $($HW.RAMGb) GB    Disk: $($HW.DiskGB) GB"
    Enqueue "Location : $($Geo.City), $($Geo.Region) ($($Geo.PublicIP))"
    Enqueue ''

    # Auto driver pack
    $OSVerLabel = If ($Config.OSName -match 'Windows\s+\d+') { $Matches[0] } Else { 'Windows 11' }
    $DriverPack = Get-OSDCloudDriverPack -Product $HWProduct -OSVersion $OSVerLabel -ErrorAction SilentlyContinue
    If ($DriverPack) {
        $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
        Enqueue "Driver pack : $($DriverPack.Name)"
    };

    # HP-specific BIOS / HPIA
    If (Test-HPIASupport) {
        Enqueue 'HP device detected — enabling HPIA / BIOS / TPM updates'
        $Global:MyOSDCloud.HPTPMUpdate  = [bool]$True
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

    # Lenovo-specific BIOS
    If ($HWMfr -match 'Lenovo') {
        Enqueue 'Lenovo device detected — applying BIOS settings'
        try {
            Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1')
            Manage-LenovoBIOSSettings -SetSettings
        }
        catch { Enqueue "WARNING: Lenovo BIOS settings script failed: $($_.Exception.Message)" }
    };

    Enqueue ''
    $targetLabel = If ($Config.OSName) { $Config.OSName } Else { "Windows $($Config.OSEdition) $($Config.OSLanguage)" }
    Enqueue "Target  : $targetLabel"
    Enqueue "ZTI     : $($Config.ZTI)"
    Enqueue ''

    # ── Create deployment record ──────────────────────────────────────────────
    If ($monitorActive) {
        New-DeployRecord -HW $HW -Geo $Geo -OSTarget $targetLabel -OSDVersion $osdVersion
    };

    Enqueue 'Starting OSDCloud in Zero Touch mode...'
    Enqueue ''

    <#
    # ══════════════════════════════════════════════════════════════════════════
    #  SAFE TEST MODE — uncomment this block and comment out REAL OSDCLOUD
    # ══════════════════════════════════════════════════════════════════════════
    $fakeLines = @(
        @{ Text = 'Initializing OSDCloud environment...';            Delay = 800  }
        @{ Text = 'Starting OSDCloud deployment...';                 Delay = 600  }
        @{ Text = '[OSDCloud] Checking prerequisites...';            Delay = 1200 }
        @{ Text = '[OSDCloud] Locating Windows image source...';     Delay = 900  }
        @{ Text = 'Download Operating System — fetching ESD...';     Delay = 700  }
        @{ Text = '';                                                 Delay = 200  }
        @{ Text = '[OSDCloud] Formatting target disk...';            Delay = 1200 }
        @{ Text = 'Disk formatted successfully.';                     Delay = 500  }
        @{ Text = '[OSDCloud] Applying image to disk...';            Delay = 1000 }
        @{ Text = 'Windows image applied successfully.';             Delay = 700  }
        @{ Text = '[OSDCloud] Installing drivers...';                Delay = 1000 }
        @{ Text = '[OSDCloud] Setting up Windows...';                Delay = 1000 }
        @{ Text = 'OSDCloud Finished';                               Delay = 600  }
    )
    ForEach ($entry in $fakeLines) {
        If ($entry.Text) { Enqueue $entry.Text }
        Start-Sleep -Milliseconds $entry.Delay
    }
    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
    If ($monitorActive) { Complete-DeployRecord }
    Return
    #>

    # ══════════════════════════════════════════════════════════════════════════
    #  REAL OSDCLOUD
    # ══════════════════════════════════════════════════════════════════════════

    # ── Build Start-OSDCloud params ───────────────────────────────────────────
    $Params = @{}
    ForEach ($key in @('OSName', 'OSEdition', 'OSLanguage', 'OSActivation', 'Manufacturer', 'Product')) {
        If ($Config.ContainsKey($key) -and $Config[$key]) { $Params[$key] = $Config[$key] };
    };
    ForEach ($key in @('ZTI', 'SkipAutopilot', 'Restart', 'Shutdown', 'Firmware', 'Screenshot', 'SkipODT', 'Preview')) {
        If ($Config.ContainsKey($key) -and [bool]$Config[$key]) { $Params[$key] = $True };
    };

    # ── Write temp files for child process ───────────────────────────────────
    $TranscriptPath = Join-Path $env:TEMP "OSDCloud-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $RunnerPath     = Join-Path $env:TEMP "Run-OSDCloud-$([guid]::NewGuid()).ps1"
    $ParamsPath     = Join-Path $env:TEMP "OSDCloud-Params-$([guid]::NewGuid()).clixml"
    $MyOSDCloudPath = Join-Path $env:TEMP "OSDCloud-MyOSDCloud-$([guid]::NewGuid()).clixml"

    $Params            | Export-Clixml -Path $ParamsPath
    $Global:MyOSDCloud | Export-Clixml -Path $MyOSDCloudPath

    $OSDModulePath = (Get-Module OSD).Path

    Set-Content -Path $RunnerPath -Encoding UTF8 -Value @"
`$ErrorActionPreference   = 'Continue'
`$VerbosePreference       = 'Continue'
`$WarningPreference       = 'Continue'
`$InformationPreference   = 'Continue'
`$ProgressPreference      = 'SilentlyContinue'

Start-Transcript -Path '$TranscriptPath' -Force | Out-Null

Try {
    Import-Module '$OSDModulePath' -Force -WarningAction SilentlyContinue -ErrorAction Stop
    `$Global:MyOSDCloud = Import-Clixml -Path '$MyOSDCloudPath' -ErrorAction Stop
    `$Params = Import-Clixml -Path '$ParamsPath' -ErrorAction Stop
    Start-OSDCloud @Params
}
Catch {
    Write-Host ('ERROR: ' + `$_.Exception.Message)
    If (`$_.ScriptStackTrace) { Write-Host `$_.ScriptStackTrace }
}
Finally {
    Stop-Transcript | Out-Null
}
"@

    Enqueue "Transcript : $TranscriptPath"
    Enqueue ''

    # ── Noise patterns filtered out of transcript ─────────────────────────────
    $NoisePatterns = @(
        '^\s*% '
        '^\s*% Total'
        '^\s*% Received'
        'Xferd'
        'Average Speed'
        '^\s*Time'
        '^\s*Current"?\s*$'
        '^\s*Dload\s+Upload\s+Total\s+Spent\s+Left\s+Speed\s*$'
        '^\*{10,}'
        '^Windows PowerShell transcript start'
        '^Windows PowerShell transcript end'
        '^Start time:'
        '^End time:'
        '^Username:'
        '^RunAs User:'
        '^Configuration Name:'
        '^Machine:'
        '^Host Application:'
        '^Process ID:'
        '^PSVersion:'
        '^PSEdition:'
        '^PSCompatibleVersions:'
        '^BuildVersion:'
        '^CLRVersion:'
        '^WSManStackVersion:'
        '^PSRemotingProtocolVersion:'
        '^SerializationVersion:'
    );

    # ── Start child process ───────────────────────────────────────────────────
    $Process = Start-Process `
        -FilePath    'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`"" `
        -WindowStyle Hidden `
        -PassThru

    $LastIndex          = 0
    $LastDownloadPct    = -1
    $DownloadTotalBytes = 0     # extracted from VERBOSE transcript lines
    $DownloadDestPath   = ''    # extracted from VERBOSE transcript lines

    Function Read-NewTranscriptLines {
        If (-not (Test-Path $TranscriptPath)) { Return }
        $Lines = Get-Content -Path $TranscriptPath -ErrorAction SilentlyContinue
        If ($Lines.Count -le $script:LastIndex) { Return }
        $NewLines = $Lines[$script:LastIndex..($Lines.Count - 1)]
        $script:LastIndex = $Lines.Count
        ForEach ($Line in $NewLines) {
            If ([string]::IsNullOrWhiteSpace($Line)) { Continue }
            $Trimmed  = $Line.Trim()
            $SkipLine = $False
            ForEach ($Pattern in $NoisePatterns) {
                If ($Trimmed -match $Pattern) { $SkipLine = $True; Break }
            }
            If ($SkipLine)                       { Continue }
            Write-Raw $Line
            If ($Trimmed -match '^VERBOSE:') {
                # Extract download metadata for file-size progress polling
                If ($Trimmed -match '^VERBOSE: received (\d+)-byte response of content type application/octet-stream') {
                    $sz = [long]$Matches[1]
                    If ($sz -gt 1048576 -and $sz -gt $script:DownloadTotalBytes) {
                        $script:DownloadTotalBytes = $sz
                    }
                }
                ElseIf ($Trimmed -match '^VERBOSE: ImageFileDestination: (.+)') {
                    $p = $Matches[1].Trim()
                    If ($p -match '\.(esd|wim|swm)$') { $script:DownloadDestPath = $p }
                }
                Continue
            }
            If ($Trimmed -match '^ERROR:')       { Enqueue $Line 'error'   }
            ElseIf ($Trimmed -match '^WARNING:') { Enqueue $Line 'warning' }
            Else                                 { Enqueue $Line           }
        };
    };

    # ── Poll loop — download progress + transcript tail ───────────────────────
    While (-not $Process.HasExited) {
        # Download progress — file-size polling (works in WinPE without BITS).
        # Falls back to BITS only if the service happens to be running.
        $dlPct   = -1
        $doneMB  = 0
        $totalMB = 0

        If ($script:DownloadDestPath -and $script:DownloadTotalBytes -gt 0) {
            $fi = Get-Item -Path $script:DownloadDestPath -ErrorAction SilentlyContinue
            If ($fi -and $fi.Length -gt 0) {
                $dlPct   = [math]::Min(99, [math]::Floor($fi.Length / $script:DownloadTotalBytes * 100))
                $doneMB  = [math]::Round($fi.Length / 1MB)
                $totalMB = [math]::Round($script:DownloadTotalBytes / 1MB)
                If ($fi.Length -ge $script:DownloadTotalBytes) {
                    $dlPct = 100
                    $script:DownloadDestPath = ''   # stop monitoring once complete
                };
            };
        }
        ElseIf ((Get-Service -Name BITS -ErrorAction SilentlyContinue).Status -eq 'Running') {
            # Fallback: BITS (not available in most WinPE environments)
            try {
                $BitsJob = Get-BitsTransfer -AllUsers -ErrorAction Stop |
                    Where-Object { $_.JobState -in 'Transferring', 'Queued', 'Connecting' } |
                    Select-Object -First 1
                If ($BitsJob -and $BitsJob.BytesTotal -gt 0) {
                    $dlPct   = [math]::Floor($BitsJob.BytesTransferred / $BitsJob.BytesTotal * 100)
                    $doneMB  = [math]::Round($BitsJob.BytesTransferred / 1MB)
                    $totalMB = [math]::Round($BitsJob.BytesTotal / 1MB)
                }
            } catch {}
        }

        If ($dlPct -ge 0 -and $dlPct -ne $LastDownloadPct) {
            $LastDownloadPct = $dlPct
            Enqueue "Downloading ESD: $dlPct%  ($doneMB MB / $totalMB MB)"
            $mapped = 15 + [math]::Round($dlPct * 0.14)
            $MessageQueue.Enqueue(@{
                Type    = 'progress'
                Percent = [int]$mapped
                Label   = "Downloading OS image... ($dlPct%)"
            })
        };

        Read-NewTranscriptLines
        Start-Sleep -Milliseconds 500
    };

    $Process.WaitForExit()
    Read-NewTranscriptLines

    Remove-Item -Path $RunnerPath, $ParamsPath, $MyOSDCloudPath -Force -ErrorAction SilentlyContinue

    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })

    If ($monitorActive) { Complete-DeployRecord };
}
catch {
    Write-Raw "EXCEPTION: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
    $MessageQueue.Enqueue(@{ Type = 'line';  Text = $_.ScriptStackTrace })
    If ($monitorActive) { Fail-DeployRecord -ErrorMessage $_.Exception.Message };
}
finally {
    $RawLog.Close()
}