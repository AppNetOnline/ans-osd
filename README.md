# ANS OSDCloud

Zero-infrastructure Windows imaging for Appalachian Network Services customers.

Boot any machine from a USB drive and get a fully configured, company-ready Windows install — no SCCM, no MDT, no servers, no VPNs, no technician interaction required.

---

## The Goal

Most imaging solutions require on-prem infrastructure — deployment servers, PXE, SCCM, MDT, or a technician sitting at the machine walking through prompts.

This project eliminates all of that. A customer receives a USB drive, boots it, and walks away. The machine images itself, installs company software, registers with RMM, and is desktop-ready without any infrastructure on the customer's end. Everything is hosted on GitHub and Microsoft's CDN. The only thing on the USB is a boot image and a `secrets.json` file with the customer's credentials.

---

## How It Works

```
USB boot
  └── WinPE starts
        └── startnet.cmd fetches Invoke-OSDCloudGUI.ps1 from GitHub
              └── ANS deployment console opens (WPF GUI)
                    └── Fetches OSDCloudGUI.xaml + Invoke-OSDCloudDeploy.ps1 from GitHub
                          └── Runs Start-OSDCloud in background
                                ├── Downloads Windows from Microsoft CDN
                                ├── Formats disk, applies image
                                ├── Installs drivers
                                └── Copies SetupComplete scripts from USB

First boot (SYSTEM, before OOBE)
  └── SetupComplete.cmd runs Bootstrap.ps1 (from USB)
        └── Fetches PostOS script from GitHub
              ├── Creates ANSAdmin local admin
              ├── Suppresses OOBE
              ├── Installs Chocolatey + apps (from manifest.json)
              ├── Installs SentinelOne
              ├── Installs ConnectWise Automate
              └── Deletes secrets.json from disk

Auto-login as ANSAdmin → desktop ready
```

No servers. No VPN. No prompts. The machine calls home to GitHub for all logic and Microsoft's CDN for the OS — the same infrastructure that runs the internet.

---

## Repository Structure

```
ans-osd/
│
├── winpe/                          ← Runs during WinPE / imaging phase
│   ├── Deploy-ANS.ps1              ← Terminal-mode entry point (no GUI)
│   ├── Invoke-OSDCloudGUI.ps1     ← GUI-mode launcher — baked into WinPE, fetches companions
│   ├── Invoke-OSDCloudDeploy.ps1  ← Deployment runspace logic, fetched by GUI at runtime
│   └── OSDCloudGUI.xaml           ← WPF UI layout, fetched by GUI at runtime
│
├── postos/                         ← Fetched by Bootstrap after first boot
│   ├── PostOS-Choco.ps1           ← Chocolatey-based app install method
│   ├── PostOS-Direct.ps1          ← Direct URL app install method
│   ├── manifest.json              ← App list for PostOS-Direct
│   └── Unattend.xml               ← Windows answer file (OOBE suppression)
│
├── shared/                         ← Shared functions used by multiple scripts
│   └── ans-osd-functions.ps1
│
├── admin/          [gitignored]    ← Run on your admin workstation to build USB media
│   ├── Build-ANSWorkspace.ps1     ← Builds WinPE template, workspace, ISO, USB
│   ├── Hyper-V.ps1                ← Test VM helper
│   └── rebuild.ps1                ← Quick rebuild shortcut
│
└── usb/            [gitignored]    ← Copy to USB after New-OSDCloudUSB
    └── SetupComplete/
        ├── SetupComplete.cmd      ← OSDCloud entry point (do not rename)
        ├── Bootstrap.ps1          ← Downloads PostOS from GitHub, runs it
        └── secrets.json           ← FILL IN per customer — never commit this
```

> `admin/` and `usb/` are gitignored. They exist locally on your admin workstation only.
> `secrets.json` must never be committed under any circumstances.

---

## Prerequisites

Install these on your admin workstation before running `Build-ANSWorkspace.ps1`:

| Tool | Install |
|---|---|
| Windows ADK | `winget install Microsoft.WindowsADK` |
| WinPE Addon for ADK | [Download](https://go.microsoft.com/fwlink/?linkid=2243391) |
| OSD PowerShell Module | `Install-Module OSD -Force` |

---

## Setup

### 1. Configure

Edit the `# --- EDIT THESE ---` sections in each file before first use:

| File | What to edit |
|---|---|
| `winpe/Invoke-OSDCloudGUI.ps1` | `$DeployConfig` — OS version, edition, options |
| `winpe/Deploy-ANS.ps1` | OS name, edition, language if using terminal mode |
| `admin/Build-ANSWorkspace.ps1` | `$DeployScriptURL`, `$WorkspacePath`, `$CloudDrivers` |
| `usb/SetupComplete/Bootstrap.ps1` | `$GitHubBaseURL`, `$PostOSMethod` |
| `usb/SetupComplete/secrets.json` | All fields — real passwords, S1 token, CWA key |

### 2. Push to GitHub

Push this repo to your public GitHub org. The USB boot process pulls scripts from:
```
https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/winpe/
https://raw.githubusercontent.com/AppNetOnline/ans-osd/main/postos/
```

### 3. Build the USB

```powershell
# Run as Administrator on your admin workstation
.\admin\Build-ANSWorkspace.ps1
```

This runs in order:
1. `New-OSDCloudTemplate` — builds base WinPE image (~10-15 min, once only)
2. `New-OSDCloudWorkspace` — copies template to your workspace
3. `Edit-OSDCloudWinPE` — bakes `Invoke-OSDCloudGUI.ps1` URL into `startnet.cmd`
4. Stages `SetupComplete.cmd` and `Bootstrap.ps1` into workspace
5. `New-OSDCloudISO` — builds bootable ISO
6. `New-OSDCloudUSB` — writes ISO to USB (prompts for disk selection)

Use `-SkipTemplate` and `-SkipWorkspace` on subsequent runs to skip already-built steps.

### 4. Place secrets on the USB

After USB creation, copy your customer-specific `secrets.json` to:
```
USB:\OSDCloud\Config\Scripts\SetupComplete\secrets.json
```

This file is never on GitHub. Each USB gets its own copy per customer.

### 5. Image a machine

Hand the USB to a customer or technician:
1. Boot target machine from USB
2. Walk away — everything runs automatically
3. Machine reboots to a configured Windows desktop

---

## Updating Without Rebuilding USB

Because the imaging logic lives on GitHub, most updates don't require a new USB:

| What changed | Action |
|---|---|
| OS version or deployment options | Edit `winpe/Invoke-OSDCloudGUI.ps1`, push to GitHub |
| PostOS logic or app list | Edit `postos/` scripts, push to GitHub |
| Secrets (password, S1 token, CWA key) | Edit `secrets.json` on each USB |
| Switch Choco ↔ Direct app method | Change `$PostOSMethod` in `Bootstrap.ps1` on USB |
| WinPE itself (new drivers, new URL) | Run `Build-ANSWorkspace.ps1 -SkipTemplate -SkipWorkspace` |

---

## Branching Strategy

`main` is the live production branch — changes here affect all USBs immediately on next boot.

For testing changes before they hit production:
```bash
git checkout -b feature/my-change
# push branch, update $GithubRaw in Invoke-OSDCloudGUI.ps1 to point to branch
# test on a machine, then PR back to main
```

When merged to `main`, the branch URL in `Invoke-OSDCloudGUI.ps1` goes back to `main`.

---

## Logs

Logs written to the deployed machine at `C:\OSDCloud\Logs\`:

| File | Contents |
|---|---|
| `Bootstrap.log` | SetupComplete bootstrap output |
| `PostOS-Choco.log` / `PostOS-Direct.log` | App install output |
| `SentinelOne.log` | S1 agent install |
| `CWA.log` | ConnectWise Automate install |
| `ANS-OSDCloud-*.log` | Raw WinPE deployment output |

---

## Security

- `secrets.json` is **never committed** — it is deleted from the deployed machine after PostOS runs
- The GitHub repo is fully public — it contains zero credentials
- `ANSAdmin` auto-logon fires exactly once (`AutoLogonCount = 1`), then Windows clears the password from registry automatically
- All scripts pull from a specific branch/commit — pin to a tag for production deployments if needed
