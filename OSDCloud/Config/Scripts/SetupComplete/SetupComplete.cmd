@ECHO OFF
:: OSDCloud entry point ? calls Bootstrap.ps1 which downloads the latest
:: PostOS script from GitHub and runs it with secrets.json from this folder.
powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Bootstrap.ps1"
