#Requires -Version 5.1
<#
.SYNOPSIS
    ANS OSDCloud deployment runspace script.
.DESCRIPTION
    Runs inside an isolated PowerShell runspace launched by Invoke-OSDCloudGUI.ps1.
    Two variables are injected by the parent before this script runs:
        $Config       — hashtable of deployment options
        $MessageQueue — ConcurrentQueue[hashtable] shared with the UI thread
    Do not load this script directly; it will have no $Config or $MessageQueue.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Hosted  : https://github.com/AppNetOnline/ans-osd/blob/main/deploy/Invoke-OSDCloudDeploy.ps1
#>

# ─────────────────────────────────────────────────────────────────────────────
#  QUEUE HELPER — posts a message back to the UI thread
# ─────────────────────────────────────────────────────────────────────────────
Function Enqueue {
    Param([string]$Text, [string]$Type = 'line')
    $MessageQueue.Enqueue(@{ Type = $Type; Text = $Text })
}

# ─────────────────────────────────────────────────────────────────────────────
#  DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────
try {
    Enqueue 'ANS OSDCloud Deployment Console'
    Enqueue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Enqueue ''

    If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
        Enqueue 'Loading OSD module...'
        Import-Module OSD -ErrorAction Stop
    }
    Enqueue "OSD module v$((Get-Module OSD).Version) loaded."
    Enqueue ''
    Enqueue "Target  : Windows $($Config.OSVersion) $($Config.OSEdition)"
    Enqueue "Language: $($Config.OSLanguage)   Arch: $($Config.OSArch)"
    Enqueue "ZTI     : $($Config.ZTI)"
    Enqueue ''
    Enqueue 'Starting OSDCloud in Zero Touch mode...'
    Enqueue ''

    <#
    # ══════════════════════════════════════════════════════════════════════════
    #  SAFE TEST MODE — comment out the real block below and uncomment this
    #  section to simulate a deployment without touching any disks.
    # ══════════════════════════════════════════════════════════════════════════
    $fakeLines = @(
        @{ Text = 'Initializing OSDCloud environment...';              Delay = 800  }
        @{ Text = 'Starting OSDCloud deployment...';                   Delay = 600  }
        @{ Text = '[OSDCloud] Checking prerequisites...';              Delay = 1200 }
        @{ Text = 'VERBOSE: PowerShell 5.1 detected — compatible';    Delay = 400  }
        @{ Text = '[OSDCloud] Locating Windows image source...';       Delay = 900  }
        @{ Text = 'Downloading Windows image from Microsoft CDN...';   Delay = 700  }
        @{ Text = 'VERBOSE: Resolving ESD download URL...';            Delay = 500  }
        @{ Text = 'VERBOSE: ESD URL resolved successfully';            Delay = 400  }
        @{ Text = 'Downloading [####                    ] 18%  234 MB/s'; Delay = 900 }
        @{ Text = 'Downloading [########                ] 34%  198 MB/s'; Delay = 900 }
        @{ Text = 'Downloading [############            ] 51%  221 MB/s'; Delay = 900 }
        @{ Text = 'Downloading [################        ] 67%  244 MB/s'; Delay = 900 }
        @{ Text = 'Downloading [####################    ] 83%  209 MB/s'; Delay = 900 }
        @{ Text = 'Downloading [########################] 100% — Complete'; Delay = 700 }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Formatting target disk...';              Delay = 1200 }
        @{ Text = 'VERBOSE: Partition style: GPT';                     Delay = 400  }
        @{ Text = 'VERBOSE: Creating EFI partition (100MB)...';        Delay = 600  }
        @{ Text = 'VERBOSE: Creating MSR partition (16MB)...';         Delay = 400  }
        @{ Text = 'VERBOSE: Creating Windows partition...';            Delay = 400  }
        @{ Text = 'VERBOSE: Creating Recovery partition (984MB)...';   Delay = 600  }
        @{ Text = 'Disk formatted successfully.';                       Delay = 500  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Applying image to disk...';              Delay = 1000 }
        @{ Text = 'Expand-WindowsImage — applying ESD to W:\...';      Delay = 700  }
        @{ Text = 'VERBOSE: Apply progress:  10%';                     Delay = 1200 }
        @{ Text = 'VERBOSE: Apply progress:  25%';                     Delay = 1200 }
        @{ Text = 'VERBOSE: Apply progress:  40%';                     Delay = 1200 }
        @{ Text = 'VERBOSE: Apply progress:  58%';                     Delay = 1200 }
        @{ Text = 'VERBOSE: Apply progress:  74%';                     Delay = 1200 }
        @{ Text = 'VERBOSE: Apply progress:  91%';                     Delay = 1200 }
        @{ Text = 'Windows image applied successfully.';               Delay = 700  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Installing drivers...';                  Delay = 1000 }
        @{ Text = 'VERBOSE: Detecting manufacturer — Microsoft Corporation'; Delay = 600 }
        @{ Text = 'Driver: searching WinGet for applicable packages...'; Delay = 800 }
        @{ Text = 'VERBOSE: Found 4 driver packages';                  Delay = 500  }
        @{ Text = 'VERBOSE: Installing: Intel.WiFi.Driver 22.240.0';  Delay = 800  }
        @{ Text = 'WARNING: Driver package not signed — skipping Intel.Bluetooth'; Delay = 600 }
        @{ Text = 'VERBOSE: Drivers staged to offline image';          Delay = 600  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Setting up Windows...';                  Delay = 1000 }
        @{ Text = 'VERBOSE: Applying unattend.xml...';                 Delay = 500  }
        @{ Text = 'VERBOSE: Setting up OOBE configuration...';         Delay = 600  }
        @{ Text = 'VERBOSE: Configuring bootloader (bcdboot)...';      Delay = 500  }
        @{ Text = 'VERBOSE: Rebuilding WinRE image...';                Delay = 800  }
        @{ Text = 'VERBOSE: WinRE registered successfully';            Delay = 400  }
        @{ Text = '';                                                   Delay = 200  }
        @{ Text = '[OSDCloud] Finishing deployment...';                Delay = 800  }
        @{ Text = 'VERBOSE: Dismounting Windows image...';             Delay = 500  }
        @{ Text = 'VERBOSE: Cleaning up temp files...';                Delay = 400  }
        @{ Text = 'Complete! Deployment finished successfully.';        Delay = 600  }
        @{ Text = 'Restart required — rebooting in 10 seconds...';     Delay = 400  }
    )
    ForEach ($entry in $fakeLines) {
        If ($entry.Text -ne '') { Enqueue $entry.Text }
        Start-Sleep -Milliseconds $entry.Delay
    }
    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
    #>

    # ══════════════════════════════════════════════════════════════════════════
    #  REAL OSDCLOUD
    # ══════════════════════════════════════════════════════════════════════════
    $Params = @{
        OSVersion  = $Config.OSVersion
        OSEdition  = $Config.OSEdition
        OSLanguage = $Config.OSLanguage
        OSArch     = $Config.OSArch
    }

    $OptionalKeys = @(
        'ZTI', 'SkipAutoPilot', 'Restart', 'RecoveryPartition', 'OEMActivation',
        'WindowsUpdate', 'WindowsUpdateDrivers', 'WindowsDefenderUpdate',
        'SetTimeZone', 'ClearDiskConfirm', 'ShutdownSetupComplete',
        'SyncMSUpCatDriverUSB', 'CheckSHA1'
    )

    ForEach ($Key in $OptionalKeys) {
        If ($Config.ContainsKey($Key)) {
            $Params[$Key] = [bool]$Config[$Key]
        }
    }

    If ($Config.DriverPack) { $Params['DriverPack'] = $True }

    $VerbosePreference = 'Continue'
    Start-OSDCloud @Params *>&1 | ForEach-Object {
        $line = switch ($_.GetType().Name) {
            'ErrorRecord'       { "ERROR: $($_.Exception.Message)" }
            'WarningRecord'     { "WARNING: $($_.Message)" }
            'VerboseRecord'     { "VERBOSE: $($_.Message)" }
            'InformationRecord' { $_.MessageData.ToString() }
            default             { $_.ToString() }
        }
        If ($line -and $line.Trim()) { Enqueue $line }
    }

    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
}
catch {
    $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
    $MessageQueue.Enqueue(@{ Type = 'line';  Text = $_.ScriptStackTrace })
}
