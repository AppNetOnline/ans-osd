#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud deployment runspace script.
.DESCRIPTION
    Runs inside an isolated PowerShell runspace launched by Invoke-OSDCloudGUI.ps1.
    Three variables are injected by the parent before this script runs:
        $Config       — hashtable of deployment options
        $MessageQueue — ConcurrentQueue[hashtable] shared with the UI thread
        $MyOSDCloud   — ordered hashtable used to seed $Global:MyOSDCloud
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
}

Function Write-Raw {
    Param([string]$Text)
    $RawLog.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff')  $Text")
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
# Restore $Global:MyOSDCloud so Start-OSDCloud (in child process) can read it
$Global:MyOSDCloud = $MyOSDCloud

try {
    Enqueue 'ANS OSDCloud Deployment Console'
    Enqueue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Enqueue ''

    If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
        Enqueue 'Loading OSD module...'
        Import-Module OSD -ErrorAction Stop
    }
    Enqueue "OSD module v$((Get-Module OSD).Version) loaded."
    Enqueue "Raw log : $RawLogPath"
    Enqueue ''

    # ── Hardware detection ────────────────────────────────────────────────────
    $HWProduct      = Get-MyComputerProduct
    $HWModel        = Get-MyComputerModel
    $HWManufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer

    # Auto driver pack
    $OSVerLabel = If ($Config.OSName -match 'Windows\s+\d+') { $Matches[0] } Else { 'Windows 11' }
    $DriverPack = Get-OSDCloudDriverPack -Product $HWProduct -OSVersion $OSVerLabel -ErrorAction SilentlyContinue
    If ($DriverPack) {
        $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
        Enqueue "Driver pack : $($DriverPack.Name)"
    }

    # HP-specific BIOS / HPIA settings
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
    }

    # Lenovo-specific BIOS settings
    If ($HWManufacturer -match 'Lenovo') {
        Enqueue 'Lenovo device detected — applying BIOS settings'
        try {
            Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/gwblok/garytown/master/OSD/CloudOSD/Manage-LenovoBiosSettings.ps1')
            Manage-LenovoBIOSSettings -SetSettings
        }
        catch { Enqueue "WARNING: Lenovo BIOS settings script failed: $($_.Exception.Message)" }
    }

    Enqueue ''
    $targetLabel = If ($Config.OSName) { $Config.OSName } Else { "$($Config.OSEdition) (OSDCloud auto-select)" }
    Enqueue "Target  : $targetLabel"
    Enqueue "Language: $($Config.OSLanguage)"
    Enqueue "ZTI     : $($Config.ZTI)"
    Enqueue ''
    Enqueue 'Starting OSDCloud in Zero Touch mode...'
    Enqueue ''

    <#
    # ══════════════════════════════════════════════════════════════════════════
    #  SAFE TEST MODE — uncomment this block and comment out REAL OSDCLOUD
    #  below to simulate a deployment without touching any disks.
    # ══════════════════════════════════════════════════════════════════════════
    $fakeLines = @(
        @{ Text = 'Initializing OSDCloud environment...';              Delay = 800  }
        @{ Text = 'Starting OSDCloud deployment...';                   Delay = 600  }
        @{ Text = '[OSDCloud] Checking prerequisites...';              Delay = 1200 }
        @{ Text = '[OSDCloud] Locating Windows image source...';       Delay = 900  }
        @{ Text = 'Download Operating System — fetching ESD...';       Delay = 700  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Formatting target disk...';              Delay = 1200 }
        @{ Text = 'Disk formatted successfully.';                       Delay = 500  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Applying image to disk...';              Delay = 1000 }
        @{ Text = 'Expand-WindowsImage — applying ESD to W:\...';      Delay = 700  }
        @{ Text = 'Windows image applied successfully.';               Delay = 700  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Installing drivers...';                  Delay = 1000 }
        @{ Text = 'WARNING: Driver package not signed — skipping Intel.Bluetooth'; Delay = 600 }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Setting up Windows...';                  Delay = 1000 }
        @{ Text = 'Rebuilding WinRE image...';                         Delay = 800  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = 'OSDCloud Finished';                                 Delay = 600  }
    )
    ForEach ($entry in $fakeLines) {
        If ($entry.Text -ne '') { Enqueue $entry.Text }
        Start-Sleep -Milliseconds $entry.Delay
    }

    # Simulate BITS download progress separately
    For ($i = 0; $i -le 100; $i += 5) {
        $mapped = 15 + [math]::Round($i * 0.14)
        $MessageQueue.Enqueue(@{ Type = 'progress'; Percent = [int]$mapped; Label = "Downloading OS image... ($i%)" })
        Start-Sleep -Milliseconds 300
    }

    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
    #>

    # ══════════════════════════════════════════════════════════════════════════
    #  REAL OSDCLOUD
    # ══════════════════════════════════════════════════════════════════════════

    # ── Build Start-OSDCloud params ───────────────────────────────────────────
    $Params = @{}

    # String params — only included when non-empty
    ForEach ($key in @('OSName', 'OSEdition', 'OSLanguage', 'OSActivation', 'Manufacturer', 'Product')) {
        If ($Config.ContainsKey($key) -and $Config[$key]) { $Params[$key] = $Config[$key] }
    }

    # Switch params — only included when explicitly $True
    ForEach ($key in @('ZTI', 'SkipAutopilot', 'Restart', 'Shutdown', 'Firmware', 'Screenshot', 'SkipODT', 'Preview')) {
        If ($Config.ContainsKey($key) -and [bool]$Config[$key]) { $Params[$key] = $True }
    }

    # ── Write temp files for child process ───────────────────────────────────
    $TranscriptPath  = Join-Path $env:TEMP "OSDCloud-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $RunnerPath      = Join-Path $env:TEMP "Run-OSDCloud-$([guid]::NewGuid()).ps1"
    $ParamsPath      = Join-Path $env:TEMP "OSDCloud-Params-$([guid]::NewGuid()).clixml"
    $MyOSDCloudPath  = Join-Path $env:TEMP "OSDCloud-MyOSDCloud-$([guid]::NewGuid()).clixml"

    $Params              | Export-Clixml -Path $ParamsPath
    $Global:MyOSDCloud   | Export-Clixml -Path $MyOSDCloudPath

    $OSDModulePath = (Get-Module OSD).Path

    Set-Content -Path $RunnerPath -Encoding UTF8 -Value @"
`$ErrorActionPreference   = 'Continue'
`$VerbosePreference       = 'Continue'
`$WarningPreference       = 'Continue'
`$InformationPreference   = 'Continue'
`$ProgressPreference      = 'SilentlyContinue'

Import-Module '$OSDModulePath' -Force
`$Global:MyOSDCloud = Import-Clixml -Path '$MyOSDCloudPath'
`$Params = Import-Clixml -Path '$ParamsPath'

Start-Transcript -Path '$TranscriptPath' -Force | Out-Null

Try {
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
    )

    # ── Start child process ───────────────────────────────────────────────────
    $Process = Start-Process `
        -FilePath    'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`"" `
        -WindowStyle Hidden `
        -PassThru

    $LastIndex           = 0
    $LastDownloadPct     = -1

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
            If ($SkipLine)                           { Continue }

            Write-Raw $Line

            If ($Trimmed -match '^VERBOSE:')         { Continue }   # skip verbose from display

            If ($Trimmed -match '^ERROR:')           { Enqueue $Line 'error' }
            ElseIf ($Trimmed -match '^WARNING:')     { Enqueue $Line 'warning' }
            Else                                     { Enqueue $Line }
        }
    }

    # ── Poll loop — tails transcript + monitors BITS download progress ────────
    While (-not $Process.HasExited) {
        # BITS progress — OSDCloud uses Start-BitsTransfer for ESD download.
        # BytesTotal/BytesTransferred are available system-wide; no pre-knowledge needed.
        $BitsJob = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.JobState -in 'Transferring', 'Queued', 'Connecting' } |
            Select-Object -First 1

        If ($BitsJob -and $BitsJob.BytesTotal -gt 0) {
            $dlPct = [math]::Floor($BitsJob.BytesTransferred / $BitsJob.BytesTotal * 100)
            If ($dlPct -ne $LastDownloadPct) {
                $LastDownloadPct = $dlPct
                $doneMB  = [math]::Round($BitsJob.BytesTransferred / 1MB)
                $totalMB = [math]::Round($BitsJob.BytesTotal / 1MB)
                Enqueue "Downloading ESD: $dlPct%  ($doneMB MB / $totalMB MB)"
                # Map download 0-100% into overall bar range 15-29%
                $mapped = 15 + [math]::Round($dlPct * 0.14)
                $MessageQueue.Enqueue(@{
                    Type    = 'progress'
                    Percent = [int]$mapped
                    Label   = "Downloading OS image... ($dlPct%)"
                })
            }
        }

        Read-NewTranscriptLines
        Start-Sleep -Milliseconds 500
    }

    $Process.WaitForExit()

    # ── Drain any remaining transcript lines after process exits ──────────────
    Read-NewTranscriptLines

    # ── Cleanup temp files ────────────────────────────────────────────────────
    Remove-Item -Path $RunnerPath, $ParamsPath, $MyOSDCloudPath -Force -ErrorAction SilentlyContinue

    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
}
catch {
    Write-Raw "EXCEPTION: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
    $MessageQueue.Enqueue(@{ Type = 'line';  Text = $_.ScriptStackTrace })
}
finally {
    $RawLog.Close()
}
