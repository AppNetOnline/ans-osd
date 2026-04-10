# ANS OSDCloud Deployment

Zero-touch Windows 11 deployment using OSDCloud with automated app installs,
SentinelOne, ConnectWise Automate, OOBE suppression, and ANSAdmin local admin.

---

## Project Structure

```
ans-osd/
├── README.md
│
├── admin/                          ← Run on your admin workstation
│   └── Build-ANSWorkspace.ps1      ← Builds template, workspace, WinPE, USB
│
├── deploy/                         ← Push these to your PUBLIC GitHub repo
│   ├── Deploy-ANS.ps1              ← StartURL target baked into WinPE
│   ├── PostOS-Choco.ps1            ← PostOS: Chocolatey method
│   ├── PostOS-Direct.ps1           ← PostOS: Direct URL method
│   └── manifest.json               ← App list for PostOS-Direct
│
└── usb/                            ← Copy these to USB after New-OSDCloudUSB
    └── SetupComplete/              ← USB path: \OSDCloud\Config\Scripts\SetupComplete\
        ├── SetupComplete.cmd       ← OSDCloud entry point (do not rename)
        ├── Bootstrap.ps1           ← Downloads PostOS from GitHub, runs it
        └── secrets.json            ← FILL IN before deploying — never commit this
```

---

## Prerequisites (admin workstation)

1. **Windows ADK**
   `winget install Microsoft.WindowsADK`
   Or: https://go.microsoft.com/fwlink/?linkid=2243390

2. **WinPE Addon for ADK**
   https://go.microsoft.com/fwlink/?linkid=2243391

3. **OSD PowerShell Module** (Build-ANSWorkspace.ps1 installs this automatically)
   ```powershell
   Install-Module OSD -Force
   ```

---

## Quick Start

### 1. Configure

Edit the `# --- EDIT THESE ---` sections in each file before use:

| File | What to edit |
|---|---|
| `admin/Build-ANSWorkspace.ps1` | `$DeployScriptURL`, `$TemplateName`, `$WorkspacePath`, `$CloudDrivers` |
| `github/Deploy-ANS.ps1` | `$OSEdition`, `$OSActivation`, `$OSLanguage` if not Enterprise/Volume/en-us |
| `usb/SetupComplete/Bootstrap.ps1` | `$GitHubBaseURL`, `$PostOSMethod` |
| `usb/SetupComplete/secrets.json` | All fields — real passwords and keys |

### 2. Push GitHub files

Push everything in `github/` to your public repo:
```
https://github.com/your-org/ans-osd/
```

### 3. Build the workspace and USB

```powershell
# Run as Administrator on your admin workstation
.\admin\Build-ANSWorkspace.ps1
```

This runs in order:
- `New-OSDCloudTemplate` (~10-15 min, once only)
- `New-OSDCloudWorkspace`
- `Edit-OSDCloudWinPE -StartURL` (bakes Deploy-ANS.ps1 into boot.wim)
- Stages `SetupComplete.cmd` and `Bootstrap.ps1` into the workspace
- `New-OSDCloudISO`
- `New-OSDCloudUSB` (prompts for disk selection)

### 4. Place secrets on the USB

After USB creation, copy your filled-in `secrets.json` to:
```
USB:\OSDCloud\Config\Scripts\SetupComplete\secrets.json
```

### 5. Deploy

Boot target machine from USB. Everything runs automatically.

---

## Deployment Flow

```
WinPE boot
  → Deploy-ANS.ps1 (GitHub, via startnet.cmd)
      → $Global:MyOSDCloud vars set
      → Start-OSDCloud (applies OS, drivers, copies SetupComplete\ from USB)

First boot — SetupComplete (SYSTEM, before OOBE)
  → Bootstrap.ps1
      → Downloads PostOS-Choco.ps1 (or Direct) from GitHub
      → Runs it with secrets.json path

PostOS script
  → Loads secrets.json → SecretStore vault
  → Creates ANSAdmin (local administrator)
  → Configures single-use auto-logon
  → Writes Unattend.xml (suppresses OOBE)
  → Installs Chocolatey + apps
  → Installs SentinelOne
  → Installs ConnectWise Automate
  → Deletes secrets.json from disk, purges vault

OOBE suppressed → auto-logs in as ANSAdmin → desktop ready
```

---

## Updating

| What changed | Action |
|---|---|
| PostOS logic or app list | Push to GitHub — next deploy picks it up |
| Secrets (password, S1 token, CWA key) | Edit `secrets.json` on each USB |
| Switch Choco ↔ Direct method | Change `$PostOSMethod` in `Bootstrap.ps1` on USB |
| WinPE (add drivers, change URL) | `Build-ANSWorkspace.ps1 -SkipTemplate -SkipWorkspace` |
| New USB from existing workspace | `Update-OSDCloudUSB` |
| OS version | Update `$OSReleaseID` / `$OSName` in `Deploy-ANS.ps1` on GitHub |

---

## Logs (on deployed machine)

```
C:\OSDCloud\Logs\
├── Bootstrap.log
├── PostOS-Choco.log        (or PostOS-Direct.log)
├── SentinelOne.log
├── CWA.log
└── SetupComplete.log       (OSDCloud Windows Update log)
```

---

## Security Notes

- `secrets.json` must **never** be committed to any repository
- The GitHub repo is fully public — it contains zero credentials
- `secrets.json` is deleted from the deployed machine after PostOS runs
- `ANSAdmin` auto-logon fires once only (`AutoLogonCount = 1`), then Windows clears the password from registry automatically
