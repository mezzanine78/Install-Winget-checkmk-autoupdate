# windows-tools

Small PowerShell tools for Windows endpoints, built to run with a one-liner.

## Install-Winget.ps1

Provisions winget (App Installer) for **all users**, using the latest
[microsoft/winget-cli](https://github.com/microsoft/winget-cli/releases/latest) release.
Built for RMM jobs running as SYSTEM in Windows PowerShell 5.1. Also works elevated in pwsh.

```powershell
irm https://raw.githubusercontent.com/mezzanine78/windows-tools/main/Install-Winget.ps1 | iex
```

- Needs Administrator or SYSTEM; otherwise it stops with exit code 1.
- Picks the x64 / arm64 / x86 dependencies for the machine.
- Exit code 0 on success, 1 on failure. In an interactive console it sets `$LASTEXITCODE`
  instead of closing your window.
- Existing users get winget at their next sign-in; new users get it straight away.
