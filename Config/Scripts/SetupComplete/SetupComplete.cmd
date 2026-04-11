@ECHO OFF
:: =============================================================================
:: SetupComplete.cmd
:: USB path : \OSDCloud\Config\Scripts\SetupComplete\SetupComplete.cmd
::
:: OSDCloud automatically:
::   1. Copies this entire folder from the USB to C:\OSDCloud\Scripts\SetupComplete\
::   2. Wires C:\Windows\Setup\Scripts\SetupComplete.cmd to call this file
::
:: Do not rename this file.
:: All logic lives in Bootstrap.ps1 — edit that instead.
:: =============================================================================

powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Bootstrap.ps1"
