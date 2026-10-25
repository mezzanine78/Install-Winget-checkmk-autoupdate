# Install-Winget.ps1 - provision winget (App Installer) for ALL users on this machine.
# Run elevated or as SYSTEM (e.g. N-central / RMM) in Windows PowerShell 5.1 or pwsh:
#   irm https://raw.githubusercontent.com/mezzanine78/windows-tools/main/Install-Winget.ps1 | iex
# Downloads the latest microsoft/winget-cli release (msixbundle, License1.xml,
# DesktopAppInstaller_Dependencies.zip) and runs Add-AppxProvisionedPackage -Online.
# Exit code: 0 = success, 1 = failure. Safe for irm | iex (no param block, no $PSScriptRoot).

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'

    function Done([int]$Code, [string]$Msg) {
        if ($Code -eq 0) { Write-Host "[winget] $Msg" -ForegroundColor Green }
        else             { Write-Host "[winget] FAILED: $Msg" -ForegroundColor Red }
        $global:LASTEXITCODE = $Code
        # Exit the process only when non-interactive (RMM / SYSTEM / -Command), so an
        # interactive console running irm | iex isn't closed on you.
        if (-not [Environment]::UserInteractive -or
            ([Environment]::GetCommandLineArgs() -match '^-(c|command|noni|noninteractive|file|f|encodedcommand|e|ec)$')) {
            exit $Code
        }
    }

    try {
        # --- admin / SYSTEM check ---
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isSystem = $id.User.Value -eq 'S-1-5-18'
        $isAdmin  = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not ($isSystem -or $isAdmin)) { Done 1 'run elevated (Administrator) or as SYSTEM'; return }
        Write-Host "[winget] running as $($id.Name)"

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # --- architecture ---
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'x86' { 'x86' }
            default { throw "unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
        }
        if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $arch = 'x64' }   # 32-bit host on 64-bit OS

        # --- latest release ---
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                               -Headers @{ 'User-Agent' = 'Install-Winget.ps1' } -UseBasicParsing
        Write-Host "[winget] latest release $($r.tag_name)"
        function U([string]$Pattern) {
            $u = ($r.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1).browser_download_url
            if (-not $u) { throw "release $($r.tag_name) has no asset matching '$Pattern'" }
            $u
        }

        $t = Join-Path $env:TEMP ("winget-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -Path $t -ItemType Directory -Force | Out-Null
        try {
            $bundle = Join-Path $t 'winget.msixbundle'
            $lic    = Join-Path $t 'License1.xml'
            $zip    = Join-Path $t 'deps.zip'
            Invoke-WebRequest -Uri (U '*.msixbundle')                          -OutFile $bundle -UseBasicParsing
            Invoke-WebRequest -Uri (U '*License1.xml')                         -OutFile $lic    -UseBasicParsing
            Invoke-WebRequest -Uri (U 'DesktopAppInstaller_Dependencies.zip')  -OutFile $zip    -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath (Join-Path $t 'deps') -Force

            $deps = @(Get-ChildItem -Path (Join-Path $t "deps\$arch") -Filter '*.appx' -ErrorAction SilentlyContinue).FullName
            if (-not $deps) { throw "no $arch dependency packages found in DesktopAppInstaller_Dependencies.zip" }
            Write-Host "[winget] provisioning for all users ($arch, $($deps.Count) dependencies)"

            Add-AppxProvisionedPackage -Online -PackagePath $bundle -LicensePath $lic -DependencyPackagePath $deps | Out-Null
        }
        finally { Remove-Item -Path $t -Recurse -Force -ErrorAction SilentlyContinue }

        # --- verify ---
        $prov = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' |
                Sort-Object { [version]$_.Version } | Select-Object -Last 1
        if (-not $prov) { throw 'Microsoft.DesktopAppInstaller is not in the provisioned package list' }

        $exe = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
               Where-Object FullName -like "*Microsoft.DesktopAppInstaller_*_$($arch)__8wekyb3d8bbwe*" |
               Sort-Object { [version](($_.Directory.Name -split '_')[1]) } | Select-Object -Last 1
        $ver = if ($exe) { (& $exe.FullName --version 2>$null | Select-Object -First 1) } else { 'n/a (appears after next user sign-in)' }

        Done 0 "provisioned App Installer $($prov.Version); winget $ver"
    }
    catch {
        Done 1 $_.Exception.Message
    }
}
