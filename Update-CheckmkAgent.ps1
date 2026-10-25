<#
Update-CheckmkAgent.ps1 - in-place update of the Checkmk Windows agent from the Checkmk site.
Checkmk Community (Raw) has no built-in agent updater; this fills the gap. BCT / MSP Bergin CT.

Runs under Windows PowerShell 5.1 (Server 2012 R2 - 2025) and pwsh 7, elevated or as SYSTEM.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-CheckmkAgent.ps1 [-DryRun] [-Force]
  irm <raw-url>/Update-CheckmkAgent.ps1 | iex                       # defaults (+ CMK_* env overrides)
  & ([scriptblock]::Create((irm <raw-url>/Update-CheckmkAgent.ps1))) -DryRun   # irm with parameters

How the server's agent version is found WITHOUT credentials (first hit wins):
  1. -TargetVersion (or env CMK_TARGET_VERSION)
  2. <BaseUrl>/check_mk/agents/ directory listing -> check-mk-agent_<ver>-1_all.deb filename
  3. download the MSI and read its ProductVersion (WindowsInstaller COM)
The MSI is only downloaded/installed when the server version is newer (or -Force).
The upgrade is msiexec /i in place (never uninstalls), so agent controller TLS registration is kept.

Exit codes (RMM / N-central):
  0 = up to date, or updated successfully
  1 = error (download/install/verify failed, not elevated, version undeterminable)
  2 = agent not installed (nothing done; use -InstallIfMissing to install fresh)
  3 = updated, reboot required (msiexec 3010/1641)
  4 = -DryRun only: an update is available (nothing changed)

Logs: transcript + msiexec verbose log in C:\BCT\Logs (-LogDir).
Server 2016 and older: use the LAN http base (default). The public https site is TLS 1.3-only.
No secrets in this file. Env vars CMK_TEST_* are test-only and honoured only with -DryRun.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = '',            # default http://10.23.23.21/dx (env CMK_BASEURL)
    [string]$TargetVersion = '',      # e.g. 2.5.0p17 - skips discovery (env CMK_TARGET_VERSION)
    [string]$MsiUrl = '',             # override MSI URL (env CMK_MSI_URL)
    [switch]$Force,                   # reinstall even if not newer (env CMK_FORCE=1)
    [switch]$DryRun,                  # report only, change nothing (env CMK_DRYRUN=1)
    [switch]$InstallIfMissing,        # install fresh if no agent present (env CMK_INSTALL_IF_MISSING=1)
    [switch]$InstallScheduledTask,    # save script to C:\BCT\Scripts and register weekly SYSTEM task
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string]$TaskDay = 'Tuesday',
    [string]$TaskTime = '03:00',      # local time HH:mm, task gets up to 30 min random delay
    [string]$ScriptUrl = '',          # optional: where the task copy is downloaded from if no local text
    [string]$ScriptDir = 'C:\BCT\Scripts',
    [string]$LogDir = 'C:\BCT\Logs'
)

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    $Tag      = '[cmk-update]'
    $TaskName = 'BCT Checkmk Agent Update'
    $state    = @{ TranscriptOn = $false }   # block-local, so nothing leaks into an irm|iex session

    function Log([string]$Msg, [string]$Level = 'INFO') {
        $line = '{0} {1} {2,-5} {3}' -f $Tag, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Write-Host $line
    }

    function Done([int]$Code, [string]$Msg) {
        if ($Code -eq 1) { Log "FAILED: $Msg" 'ERROR' } else { Log "$Msg (exit $Code)" }
        if ($state.TranscriptOn) { try { Stop-Transcript | Out-Null } catch { $null = $_ } }
        $global:LASTEXITCODE = $Code
        # Exit the process only when non-interactive (RMM / SYSTEM / -File / -Command) so an
        # interactive console running irm | iex isn't closed on you.
        if (-not [Environment]::UserInteractive -or
            ([Environment]::GetCommandLineArgs() -match '^-(c|command|noni|noninteractive|file|f|encodedcommand|e|ec)$')) {
            exit $Code
        }
    }

    function EnvFlag([string]$Name) { $v = [Environment]::GetEnvironmentVariable($Name); return ($v -match '^(1|true|yes|on)$') }

    # ---------- version handling ----------
    # Checkmk versions: 2.5.0b3 < 2.5.0 < 2.5.0p1 < 2.5.0p17 < 2.5.1. Also accepts deb form
    # 2.5.0p17-1, edition suffixes (2.5.0p17.cre) and MSI 4-part 2.5.0.17 (4th part = patch level,
    # 0 = GA). A 4th part >= 1000 looks like a build number: only major.minor.patch is trusted.
    function ConvertTo-CmkVersion([string]$Text) {
        if (-not $Text) { return $null }
        $t = $Text.Trim() -replace '^[vV]', ''
        if ($t -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
            $n = [int64]$Matches[4]
            if ($n -ge 1000) {
                return [pscustomobject]@{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]; Rank = 2; Num = 0; Exact = $false; Text = $t }
            }
            $rank = 2; if ($n -gt 0) { $rank = 3 }
            return [pscustomobject]@{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]; Rank = $rank; Num = $n; Exact = $true; Text = $t }
        }
        if ($t -match '^(\d+)\.(\d+)\.(\d+)(?:([ibp])(\d+))?(?:[-.+~].*)?$') {
            $rank = 2; $n = 0
            if ($Matches[4]) {
                $n = [int64]$Matches[5]
                switch ($Matches[4]) { 'i' { $rank = 0 } 'b' { $rank = 1 } 'p' { $rank = 3 } }
            }
            return [pscustomobject]@{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]; Rank = $rank; Num = $n; Exact = $true; Text = $t }
        }
        return $null
    }

    # Returns -1 / 0 / 1 (A older / same / newer than B), or $null if it can't be decided.
    function Compare-CmkVersion([string]$A, [string]$B) {
        $x = ConvertTo-CmkVersion $A; $y = ConvertTo-CmkVersion $B
        if (-not $x -or -not $y) { return $null }
        foreach ($p in 'Major', 'Minor', 'Patch') {
            if ($x.$p -lt $y.$p) { return -1 }
            if ($x.$p -gt $y.$p) { return 1 }
        }
        if (-not ($x.Exact -and $y.Exact)) { return $null }
        foreach ($p in 'Rank', 'Num') {
            if ($x.$p -lt $y.$p) { return -1 }
            if ($x.$p -gt $y.$p) { return 1 }
        }
        return 0
    }

    # Expose helpers for unit tests (test-only, never used in normal runs).
    if ($env:CMK_TEST_EXPORT_FUNCTIONS -eq '1') {
        Set-Item -Path 'function:global:ConvertTo-CmkVersion' -Value ${function:ConvertTo-CmkVersion}
        Set-Item -Path 'function:global:Compare-CmkVersion' -Value ${function:Compare-CmkVersion}
        return
    }

    function Get-InstalledAgent {
        $r = [pscustomobject]@{ Installed = $false; Version = ''; Source = ''; Exe = '' }
        $exeCandidates = @()
        foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if ($pf) { $exeCandidates += (Join-Path $pf 'checkmk\service\check_mk_agent.exe') }
        }
        foreach ($c in $exeCandidates) { if (Test-Path -LiteralPath $c) { $r.Exe = $c; break } }

        # registry uninstall keys (64- and 32-bit views)
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $reg = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -match '(?i)check[\s_]*mk' -and $_.DisplayName -match '(?i)agent' } |
               Select-Object -First 1
        if ($reg) { $r.Installed = $true }

        if ($r.Exe) {
            $r.Installed = $true
            try {
                $out = (& $r.Exe version 2>$null | Out-String)
                if ($out -match '(\d+\.\d+\.\d+(?:[ibp]\d+)?)') { $r.Version = $Matches[1]; $r.Source = 'check_mk_agent.exe version' }
            } catch { $null = $_ }
            if (-not $r.Version) {
                $fv = (Get-Item -LiteralPath $r.Exe).VersionInfo.ProductVersion
                if ($fv -and (ConvertTo-CmkVersion $fv)) { $r.Version = $fv.Trim(); $r.Source = 'exe ProductVersion' }
            }
        }
        if (-not $r.Version -and $reg -and $reg.DisplayVersion) { $r.Version = [string]$reg.DisplayVersion; $r.Source = "registry ($($reg.DisplayName))" }
        return $r
    }

    function Get-ServerVersionFromListing([string]$Base) {
        $url = "$Base/check_mk/agents/"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
        } catch {
            Log "agents listing $url not readable: $($_.Exception.Message)" 'WARN'; return ''
        }
        $found = [regex]::Matches([string]$resp.Content, 'check-mk-agent_([0-9][0-9A-Za-z.+~]*)-\d+_all\.deb') |
                 ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        if (-not $found) { Log "no check-mk-agent_*.deb in $url" 'WARN'; return '' }
        $best = ''
        foreach ($v in @($found)) {
            if (-not $best) { $best = $v; continue }
            $c = Compare-CmkVersion $v $best
            if ($c -eq 1) { $best = $v }
        }
        return $best
    }

    function Get-MsiProductVersion([string]$Path) {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $v = ''
        if ($rec) { $v = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
        $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
        [Runtime.InteropServices.Marshal]::ReleaseComObject($wi) | Out-Null
        return [string]$v
    }

    function Save-Msi([string]$Url, [string]$Dir) {
        $f = Join-Path $Dir 'check_mk_agent.msi'
        Log "downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $f -UseBasicParsing -TimeoutSec 600
        $len = (Get-Item -LiteralPath $f).Length
        $hdr = New-Object byte[] 8
        $fs = [IO.File]::OpenRead($f); try { [void]$fs.Read($hdr, 0, 8) } finally { $fs.Close() }
        # MSI = OLE compound file, signature D0 CF 11 E0 A1 B1 1A E1 (rejects HTML login/error pages)
        if ($len -lt 100KB -or $hdr[0] -ne 0xD0 -or $hdr[1] -ne 0xCF -or $hdr[2] -ne 0x11 -or $hdr[3] -ne 0xE0) {
            throw "downloaded file from $Url is not an MSI ($len bytes)"
        }
        $sig = Get-AuthenticodeSignature -FilePath $f
        Log ("MSI {0:N0} bytes, signature {1} {2}" -f $len, $sig.Status, $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }))
        return $f
    }

    function Get-ScriptText {
        # 1) running from a file -> that file; 2) irm|iex or scriptblock -> full text from the AST
        #    (root of this script's parse tree = the exact text that was executed, incl. param block);
        # 3) -ScriptUrl download as last resort.
        $outerPath = $PSCommandPath   # set when run from a file (-File / .\script.ps1), empty under iex
        if ($outerPath -and (Test-Path -LiteralPath $outerPath)) { return [IO.File]::ReadAllText($outerPath) }
        $root = {}.Ast
        while ($root.Parent) { $root = $root.Parent }
        $txt = $root.Extent.Text
        if ($txt -and $txt -match 'Update-CheckmkAgent\.ps1' -and $txt -match 'function Compare-CmkVersion') { return $txt }
        if ($ScriptUrl) { return [string](Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 120).Content }
        throw 'cannot determine script text; run from a file or pass -ScriptUrl'
    }

    function Install-Task {
        $target = [IO.Path]::Combine($ScriptDir, 'Update-CheckmkAgent.ps1')
        $txt = Get-ScriptText
        Log "script text for the task copy: $($txt.Length) chars"
        $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`" -BaseUrl `"$BaseUrl`""
        if ($TargetVersion)    { $argList += " -TargetVersion `"$TargetVersion`"" }
        if ($msiExplicit)      { $argList += " -MsiUrl `"$MsiUrl`"" }
        if ($InstallIfMissing) { $argList += ' -InstallIfMissing' }
        if ($LogDir -ne 'C:\BCT\Logs') { $argList += " -LogDir `"$LogDir`"" }
        if ($DryRun) {
            Log "DRY RUN: would save script to $target and register task '$TaskName' weekly $TaskDay $TaskTime as SYSTEM"
            Log "DRY RUN: action powershell.exe $argList"
            return
        }
        New-Item -Path $ScriptDir -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText($target, $txt, (New-Object Text.UTF8Encoding($true)))
        Log "saved script to $target ($((Get-Item -LiteralPath $target).Length) bytes)"
        $at = [datetime]::ParseExact($TaskTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $action    = New-ScheduledTaskAction -Execute $psExe -Argument $argList
            $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $TaskDay -At $at -RandomDelay (New-TimeSpan -Minutes 30)
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $TaskName -TaskPath '\BCT\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description 'Weekly in-place update of the Checkmk agent from the Checkmk site (Update-CheckmkAgent.ps1)' -Force | Out-Null
        } else {
            $day = $TaskDay.Substring(0, 3).ToUpper()
            & schtasks.exe /Create /F /RU SYSTEM /RL HIGHEST /SC WEEKLY /D $day /ST $TaskTime /TN "\BCT\$TaskName" /TR "`"$psExe`" $argList" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks.exe failed ($LASTEXITCODE)" }
        }
        Log "registered scheduled task \BCT\$TaskName (weekly $TaskDay $TaskTime +0-30 min, SYSTEM)"
    }

    function Wait-AgentService {
        $svc = Get-Service -Name 'CheckMkService' -ErrorAction SilentlyContinue
        if (-not $svc) { throw 'service CheckMkService not found after install' }
        if ($svc.Status -ne 'Running') {
            Log "CheckMkService is $($svc.Status), starting" 'WARN'
            try { Start-Service -Name 'CheckMkService' } catch { Log "Start-Service: $($_.Exception.Message)" 'WARN' }
        }
        $deadline = (Get-Date).AddSeconds(90)
        do {
            $svc.Refresh()
            if ($svc.Status -eq 'Running') { return }
            Start-Sleep -Seconds 3
        } while ((Get-Date) -lt $deadline)
        throw "CheckMkService not running after install (status $($svc.Status))"
    }

    # ================= main =================
    $tmp = $null
    try {
        $testMode = $false
        # ----- resolve settings: parameter > CMK_* env var > default -----
        if (-not $BaseUrl)       { $BaseUrl = $env:CMK_BASEURL }
        if (-not $BaseUrl)       { $BaseUrl = 'http://10.23.23.21/dx' }
        $BaseUrl = $BaseUrl.TrimEnd('/')
        if (-not $TargetVersion) { $TargetVersion = $env:CMK_TARGET_VERSION }
        if (-not $MsiUrl)        { $MsiUrl = $env:CMK_MSI_URL }
        $msiExplicit = [bool]$MsiUrl
        if (-not $MsiUrl)        { $MsiUrl = "$BaseUrl/check_mk/agents/windows/check_mk_agent.msi" }
        if (EnvFlag 'CMK_FORCE')              { $Force = [switch]$true }
        if (EnvFlag 'CMK_DRYRUN')             { $DryRun = [switch]$true }
        if (EnvFlag 'CMK_INSTALL_IF_MISSING') { $InstallIfMissing = [switch]$true }
        if ($DryRun -and (EnvFlag 'CMK_TEST_SKIP_ADMIN')) { $testMode = $true }   # test-only, DryRun only

        if (-not $testMode) {
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
            $tlog = Join-Path $LogDir ('Update-CheckmkAgent-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try { Start-Transcript -Path $tlog -Force | Out-Null; $state.TranscriptOn = $true } catch { Log "transcript not started: $($_.Exception.Message)" 'WARN' }

            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $isSystem = $id.User.Value -eq 'S-1-5-18'
            $isAdmin  = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not ($isSystem -or $isAdmin)) { Done 1 'run elevated (Administrator) or as SYSTEM'; return }
            Log "running as $($id.Name) on $env:COMPUTERNAME, PowerShell $($PSVersionTable.PSVersion)"
        } else {
            Log 'TEST MODE (CMK_TEST_SKIP_ADMIN + DryRun): admin check, transcript and Windows probes skipped' 'WARN'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($DryRun) { Log 'DRY RUN - nothing will be changed' }
        Log "base $BaseUrl"

        if ($InstallScheduledTask) { Install-Task }

        # ----- installed version -----
        if ($testMode -and $env:CMK_INSTALLED_VERSION) {
            $inst = [pscustomobject]@{ Installed = ($env:CMK_INSTALLED_VERSION -ne 'none'); Version = $env:CMK_INSTALLED_VERSION; Source = 'CMK_INSTALLED_VERSION (test)'; Exe = '' }
            if (-not $inst.Installed) { $inst.Version = '' }
        } elseif ($testMode) {
            throw 'test mode needs CMK_INSTALLED_VERSION'
        } else {
            $inst = Get-InstalledAgent
        }
        if (-not $inst.Installed) {
            if (-not $InstallIfMissing) { Done 2 'Checkmk agent is not installed; nothing done (use -InstallIfMissing to install)'; return }
            Log 'Checkmk agent not installed; -InstallIfMissing set, will install' 'WARN'
        } else {
            Log "installed agent: $($inst.Version) [$($inst.Source)]"
        }

        # ----- server version (no credentials) -----
        $srcVer = ''; $srvSource = ''
        if ($TargetVersion) { $srcVer = $TargetVersion; $srvSource = 'TargetVersion' }
        if (-not $srcVer) {
            $srcVer = Get-ServerVersionFromListing $BaseUrl
            if ($srcVer) { $srvSource = 'agents directory listing' }
        }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cmk-agent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $msi = $null
        if (-not $srcVer) {
            if ($testMode) { throw 'server version not found in listing (MSI ProductVersion fallback needs Windows)' }
            New-Item -Path $tmp -ItemType Directory -Force | Out-Null
            $msi = Save-Msi $MsiUrl $tmp
            $srcVer = Get-MsiProductVersion $msi
            $srvSource = 'MSI ProductVersion'
        }
        if (-not (ConvertTo-CmkVersion $srcVer)) { throw "server version '$srcVer' ($srvSource) is not a recognised Checkmk version" }
        Log "server agent: $srcVer [$srvSource]"

        # ----- decide -----
        $need = $false; $why = ''
        if (-not $inst.Installed) { $need = $true; $why = 'not installed' }
        else {
            $cmp = Compare-CmkVersion $srcVer $inst.Version
            if ($null -eq $cmp) {
                if ($Force) { $need = $true; $why = 'versions not comparable, -Force' }
                else { Log "cannot compare '$($inst.Version)' with '$srcVer' exactly (MSI build-number form?); use -TargetVersion or -Force" 'WARN'; Done 0 'no change'; return }
            }
            elseif ($cmp -gt 0) { $need = $true; $why = "newer ($($inst.Version) -> $srcVer)" }
            elseif ($Force)     { $need = $true; $why = "-Force (installed $($inst.Version), server $srcVer)" }
            elseif ($cmp -lt 0) { Log "installed $($inst.Version) is NEWER than server $srcVer; not downgrading" 'WARN' }
        }
        if (-not $need) { Done 0 "up to date ($($inst.Version))"; return }
        if ($DryRun)    { Done 4 "DRY RUN: update available - would install $srcVer from $MsiUrl ($why)"; return }

        # ----- install (in place, keeps registration) -----
        if (-not $msi) {
            New-Item -Path $tmp -ItemType Directory -Force | Out-Null
            $msi = Save-Msi $MsiUrl $tmp
        }
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        $msiLog = Join-Path $LogDir ('CheckmkAgent-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Log "installing ($why): msiexec /i /qn /norestart, log $msiLog"
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
             -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"") -Wait -PassThru
        $rc = $p.ExitCode
        $reboot = $false
        switch ($rc) {
            0       { Log 'msiexec finished (0)' }
            3010    { $reboot = $true; Log 'msiexec finished, reboot required (3010)' 'WARN' }
            1641    { $reboot = $true; Log 'msiexec finished, reboot initiated (1641)' 'WARN' }
            1618    { throw 'msiexec 1618: another installation is in progress; retry later' }
            default { throw "msiexec failed with $rc (see $msiLog)" }
        }

        # ----- verify -----
        Wait-AgentService
        Log 'CheckMkService running'
        $after = Get-InstalledAgent
        Log "installed agent now: $($after.Version) [$($after.Source)]"
        $c2 = Compare-CmkVersion $after.Version $srcVer
        if ($null -ne $c2 -and $c2 -lt 0) {
            if ($reboot) { Log "version still $($after.Version); expected after reboot" 'WARN' }
            else { throw "version after install is $($after.Version), expected $srcVer" }
        }
        if ($reboot) { Done 3 "updated to $srcVer; reboot required"; return }
        Done 0 "updated to $srcVer"
    }
    catch {
        Done 1 $_.Exception.Message
    }
    finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
