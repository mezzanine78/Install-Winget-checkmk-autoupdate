<#
Update-CheckmkAgent.ps1 - in-place update of the Checkmk Windows agent from the Checkmk site.
Checkmk Community (Raw) has no built-in agent updater; this fills the gap. DX / MSP Bergin CT.

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

Files: task copy of this script in C:\Windows\Scripts\DX\Scripts, transcript + msiexec verbose log in
C:\Windows\Scripts\DX\Logs (-ScriptDir / -LogDir; built from %SystemRoot%). New folders there get SYSTEM +
Administrators full control only (SIDs, inheritance protected). A -ScriptDir / -LogDir under the old C:\DX root
is mapped to the same place under C:\Windows\Scripts\DX.
-InstallScheduledTask migrates an old C:\DX install: copies this script's logs from C:\DX\Logs, re-points the
task \DX\DX Checkmk Agent Update at the new copy, and only once the task is confirmed on the new path deletes
the files this script owns under C:\DX (its script copy and its logs) and any of those folders left empty.
C:\DX itself is removed only if it is empty (other DX tools may live there).
Default base is the public site https://mon.ausict.com/dx (Cloudflare, TLS 1.3 only). Windows only has
TLS 1.3 from Server 2022 / Windows 11, so Server 2012 R2 / 2016 / 2019 must use a LAN http base:
  -BaseUrl http://10.23.23.21/dx
-InstallScheduledTask also removes the old task \BCT\BCT Checkmk Agent Update (migration); C:\BCT\ folders are left alone.
No secrets in this file. Env vars CMK_TEST_* are test-only and honoured only with -DryRun.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = '',            # default https://mon.ausict.com/dx (env CMK_BASEURL)
    [string]$TargetVersion = '',      # e.g. 2.5.0p17 - skips discovery (env CMK_TARGET_VERSION)
    [string]$MsiUrl = '',             # override MSI URL (env CMK_MSI_URL)
    [switch]$Force,                   # reinstall even if not newer (env CMK_FORCE=1)
    [switch]$DryRun,                  # report only, change nothing (env CMK_DRYRUN=1)
    [switch]$InstallIfMissing,        # install fresh if no agent present (env CMK_INSTALL_IF_MISSING=1)
    [switch]$InstallScheduledTask,    # save script to C:\Windows\Scripts\DX\Scripts and register weekly SYSTEM task
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string]$TaskDay = 'Tuesday',
    [string]$TaskTime = '03:00',      # local time HH:mm, task gets up to 30 min random delay
    [string]$ScriptUrl = '',          # optional: where the task copy is downloaded from if no local text
    [string]$ScriptDir = '',          # default %SystemRoot%\Scripts\DX\Scripts (C:\Windows\Scripts\DX\Scripts)
    [string]$LogDir = ''              # default %SystemRoot%\Scripts\DX\Logs
)

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    $Tag      = '[cmk-update]'
    $TaskName = 'DX Checkmk Agent Update'
    $TaskPath = '\DX\'
    $OldTaskName = 'BCT Checkmk Agent Update'   # migration: pre-rename task, removed by -InstallScheduledTask
    $OldTaskPath = '\BCT\'
    # File root: C:\Windows\Scripts\DX (follows %SystemRoot%). Before 2026-10-31 it was C:\DX (migrated by -InstallScheduledTask).
    $DxRoot     = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'Scripts\DX' } else { 'C:\Windows\Scripts\DX' }
    $LegacyRoot = 'C:\DX'
    $ScriptFileName  = 'Update-CheckmkAgent.ps1'
    $OwnedLogPattern = '^(Update-CheckmkAgent|CheckmkAgent)-\d{8}-\d{6}\.log$'   # the only log names this script writes
    $state    = @{ TranscriptOn = $false; TlsHinted = $false }   # block-local, so nothing leaks into an irm|iex session

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
            Log "agents listing $url not readable: $($_.Exception.Message)" 'WARN'; Write-TlsHint $url; return ''
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
        $target = [IO.Path]::Combine($ScriptDir, $ScriptFileName)
        $txt = Get-ScriptText
        Log "script text for the task copy: $($txt.Length) chars"
        $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`" -BaseUrl `"$BaseUrl`""
        if ($TargetVersion)    { $argList += " -TargetVersion `"$TargetVersion`"" }
        if ($msiExplicit)      { $argList += " -MsiUrl `"$MsiUrl`"" }
        if ($InstallIfMissing) { $argList += ' -InstallIfMissing' }
        if (-not (Test-DXSamePath $LogDir ([IO.Path]::Combine($DxRoot, 'Logs')))) { $argList += " -LogDir `"$LogDir`"" }
        $before = Get-DXTaskAction $TaskPath $TaskName
        $legacy = Get-DXLegacyLocation $before
        if ($before -and (Test-DXTextHasPath $before $LegacyRoot -AsFolder)) { Log "task $TaskPath$TaskName runs from the old root $LegacyRoot; re-pointing it to $target" }
        if ($DryRun) {
            Log "DRY RUN: would save script to $target and register task '$TaskName' weekly $TaskDay $TaskTime as SYSTEM"
            Log "DRY RUN: action powershell.exe $argList"
            Copy-DXLegacyLog $legacy -DryRun
            Invoke-DXLegacyCleanup $legacy $target -DryRun
            Invoke-OldTaskCleanup
            return
        }
        Initialize-DXFolder $ScriptDir -Reprotect
        Initialize-DXFolder $LogDir -Reprotect
        Copy-DXLegacyLog $legacy
        [IO.File]::WriteAllText($target, $txt, (New-Object Text.UTF8Encoding($true)))
        Log "saved script to $target ($((Get-Item -LiteralPath $target).Length) bytes)"
        $at = [datetime]::ParseExact($TaskTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $action    = New-ScheduledTaskAction -Execute $psExe -Argument $argList
            $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $TaskDay -At $at -RandomDelay (New-TimeSpan -Minutes 30)
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description 'Weekly in-place update of the Checkmk agent from the Checkmk site (Update-CheckmkAgent.ps1)' -Force | Out-Null
        } else {
            $day = $TaskDay.Substring(0, 3).ToUpper()
            & schtasks.exe /Create /F /RU SYSTEM /RL HIGHEST /SC WEEKLY /D $day /ST $TaskTime /TN "$TaskPath$TaskName" /TR "`"$psExe`" $argList" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks.exe failed ($LASTEXITCODE)" }
        }
        Log "registered scheduled task $TaskPath$TaskName (weekly $TaskDay $TaskTime +0-30 min, SYSTEM)"
        # Old C:\DX files are only removed once the task is confirmed to run the new copy.
        $after = Get-DXTaskAction $TaskPath $TaskName
        if ($after -and (Test-DXTextHasPath $after $target)) {
            Log "task action confirmed: $target"
            Invoke-DXLegacyCleanup $legacy $target
        } elseif ($legacy.Found) {
            Log "could not confirm the task runs $target; old files under $LegacyRoot left in place" 'WARN'
        }
        Invoke-OldTaskCleanup
    }

    # ---------- C:\DX -> C:\Windows\Scripts\DX ----------
    function ConvertTo-DXNormPath([string]$Path) { return ([string]$Path).Replace('/', '\').TrimEnd('\').ToUpperInvariant() }
    function Test-DXSamePath([string]$A, [string]$B) { return ((ConvertTo-DXNormPath $A) -eq (ConvertTo-DXNormPath $B)) }
    function Test-DXUnderPath([string]$Path, [string]$Root) {
        # $Path is $Root itself or inside it (case-insensitive, / or \).
        $p = ConvertTo-DXNormPath $Path; $r = ConvertTo-DXNormPath $Root
        if (-not $p -or -not $r) { return $false }
        return ($p -eq $r -or $p.StartsWith($r + '\'))
    }
    function Test-DXTextHasPath([string]$Text, [string]$Path, [switch]$AsFolder) {
        # $Text (task action / XML) mentions $Path (-AsFolder: something inside folder $Path; C:\DX must not match C:\DXTools).
        if (-not $Text -or -not $Path) { return $false }
        $n = ConvertTo-DXNormPath $Path
        if ($AsFolder) { $n += '\' }
        return ($Text.Replace('/', '\').ToUpperInvariant().Contains($n))
    }
    function Resolve-DXPath([string]$Value, [string]$Default) {
        # '' -> default; anything under the old C:\DX root -> same place under the new root; else unchanged.
        if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
        $v = $Value.Trim()
        if (Test-DXUnderPath $v $LegacyRoot) {
            $rest = $v.Replace('/', '\').TrimEnd('\').Substring($LegacyRoot.TrimEnd('\').Length).TrimStart('\')
            $n = $DxRoot
            if ($rest) { $n = $DxRoot.TrimEnd('\') + '\' + $rest }
            Log "$v is under the old root $LegacyRoot; using $n"
            return $n
        }
        return $v
    }

    function Protect-DXFolder([string]$Path) {
        # SYSTEM (S-1-5-18) + BUILTIN\Administrators (S-1-5-32-544) full control, inheritance from C:\Windows removed.
        # SIDs, not names, so it works on non-English Windows. Same as the other DX tools under C:\Windows\Scripts\DX.
        try {
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
            $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit,
                                [System.Security.AccessControl.PropagationFlags]::None, 'Allow')))
            }
            Set-Acl -LiteralPath $Path -AclObject $acl
        } catch { Log "could not set SYSTEM/Administrators ACL on ${Path}: $($_.Exception.Message)" 'WARN' }
    }

    function Initialize-DXFolder([string]$Path, [switch]$Reprotect) {
        # Creates $Path. Folders under C:\Windows\Scripts\DX (and that root) get the SYSTEM/Administrators ACL when
        # created, or always with -Reprotect (-InstallScheduledTask). Custom folders elsewhere are left as they are.
        $under = Test-DXUnderPath $Path $DxRoot
        $dirs = @()
        if ($under -and -not (Test-DXSamePath $Path $DxRoot)) { $dirs += $DxRoot }
        $dirs += $Path
        foreach ($d in $dirs) {
            $created = $false
            if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null; $created = $true }
            if ($under -and ($created -or $Reprotect)) { Protect-DXFolder $d }
        }
    }

    function Get-DXTaskAction([string]$Path, [string]$Name) {
        # Action of the existing task ("exe args", or the task XML via schtasks), '' if there is no task.
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
            if (-not $t) { return '' }
            return (@($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ')
        }
        if (Get-Command schtasks.exe -ErrorAction SilentlyContinue) {
            $xml = & schtasks.exe /Query /TN "$Path$Name" /XML 2>$null
            if ($LASTEXITCODE -ne 0) { return '' }
            return (@($xml) -join "`n")
        }
        return ''
    }

    function Get-DXLegacyLocation([string]$TaskAction) {
        # Folders under C:\DX that may hold this script's files: the old defaults C:\DX\Scripts and C:\DX\Logs, plus
        # the -File folder / -LogDir of the existing task if those are under C:\DX.
        $sd = @([IO.Path]::Combine($LegacyRoot, 'Scripts')); $ld = @([IO.Path]::Combine($LegacyRoot, 'Logs'))
        if ($TaskAction) {
            $a = $TaskAction.Replace('&quot;', '"')
            if ($a -match '-File\s+"([^"]+)"' -and (Test-DXUnderPath $Matches[1] $LegacyRoot)) { $sd += (Split-Path -Parent $Matches[1]) }
            if ($a -match '-LogDir\s+"([^"]+)"' -and (Test-DXUnderPath $Matches[1] $LegacyRoot)) { $ld += $Matches[1] }
        }
        $sd = @($sd | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
        $ld = @($ld | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
        $found = $false
        foreach ($d in $sd) { if (Test-Path -LiteralPath ([IO.Path]::Combine($d, $ScriptFileName))) { $found = $true } }
        foreach ($d in $ld) { if (@(Get-DXOwnedLog $d).Count) { $found = $true } }
        if ($TaskAction -and (Test-DXTextHasPath $TaskAction $LegacyRoot -AsFolder)) { $found = $true }
        return [pscustomobject]@{ Found = $found; ScriptDirs = $sd; LogDirs = $ld }
    }

    function Get-DXOwnedLog([string]$Dir) {
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -File -Force | Where-Object { $_.Name -match $OwnedLogPattern })
    }

    function Copy-DXLegacyLog($Legacy, [switch]$DryRun) {
        # Copies this script's old logs to the new log folder (never overwrites a file already there).
        foreach ($d in $Legacy.LogDirs) {
            if (Test-DXSamePath $d $LogDir) { continue }
            $n = 0
            foreach ($f in @(Get-DXOwnedLog $d)) {
                $dst = [IO.Path]::Combine($LogDir, $f.Name)
                if (Test-Path -LiteralPath $dst) { continue }
                if (-not $DryRun) { Copy-Item -LiteralPath $f.FullName -Destination $dst }
                $n++
            }
            if ($n) {
                if ($DryRun) { Log "DRY RUN: would copy $n old log(s) from $d to $LogDir" }
                else { Log "migration: copied $n old log(s) from $d to $LogDir" }
            }
        }
    }

    function Invoke-DXLegacyCleanup($Legacy, [string]$Target, [switch]$DryRun) {
        # Deletes ONLY this script's files under C:\DX: its script copy and its logs (a log only once a copy exists in
        # the new log folder), then those folders and C:\DX itself if they are empty. Anything else stays.
        if (-not $Legacy.Found) { return }
        $pre = 'removed'; if ($DryRun) { $pre = 'DRY RUN: would remove' }
        try {
            foreach ($d in $Legacy.ScriptDirs) {
                $f = [IO.Path]::Combine($d, $ScriptFileName)
                if ((Test-Path -LiteralPath $f) -and -not (Test-DXSamePath $f $Target)) {
                    if (-not $DryRun) { Remove-Item -LiteralPath $f -Force }
                    Log "$pre old script copy $f"
                }
            }
            foreach ($d in $Legacy.LogDirs) {
                if (Test-DXSamePath $d $LogDir) { continue }
                $n = 0; $kept = 0
                foreach ($f in @(Get-DXOwnedLog $d)) {
                    if ($DryRun -or (Test-Path -LiteralPath ([IO.Path]::Combine($LogDir, $f.Name)))) {
                        if (-not $DryRun) { Remove-Item -LiteralPath $f.FullName -Force }
                        $n++
                    } else { $kept++ }
                }
                if ($n) { Log "$pre $n old log(s) from $d (copied to $LogDir)" }
                if ($kept) { Log "kept $kept old log(s) in $d (no copy in $LogDir)" 'WARN' }
            }
            if ($DryRun) { Log "DRY RUN: would then remove those folders and $LegacyRoot only if empty"; return }
            $dirs = @(@($Legacy.ScriptDirs) + @($Legacy.LogDirs) | Select-Object -Unique | Sort-Object { $_.Length } -Descending)
            foreach ($d in @($dirs + $LegacyRoot)) {
                if (-not (Test-DXUnderPath $d $LegacyRoot) -or -not (Test-Path -LiteralPath $d)) { continue }
                $left = @(Get-ChildItem -LiteralPath $d -Force)
                if ($left.Count -eq 0) { Remove-Item -LiteralPath $d -Force; Log "removed empty folder $d" }
                else { Log "kept $d (still holds: $(@($left | Select-Object -First 5 | ForEach-Object Name) -join ', '))" }
            }
        } catch { Log "old C:\DX cleanup incomplete: $($_.Exception.Message)" 'WARN' }
    }

    # Migration: remove the pre-rename task \BCT\BCT Checkmk Agent Update if present (respects -DryRun).
    # Old C:\BCT\Scripts / C:\BCT\Logs files are deliberately left in place.
    function Invoke-OldTaskCleanup {
        $old = "$OldTaskPath$OldTaskName"
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $t = Get-ScheduledTask -TaskPath $OldTaskPath -TaskName $OldTaskName -ErrorAction SilentlyContinue
            if (-not $t) { Log "old task $old not present"; return }
            if ($DryRun) { Log "DRY RUN: would remove old task $old"; return }
            Unregister-ScheduledTask -TaskPath $OldTaskPath -TaskName $OldTaskName -Confirm:$false
            Log "removed old task $old (C:\BCT\ files left in place; delete manually if wanted)"
        } elseif (Get-Command schtasks.exe -ErrorAction SilentlyContinue) {
            & schtasks.exe /Query /TN $old 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "old task $old not present"; return }
            if ($DryRun) { Log "DRY RUN: would remove old task $old"; return }
            & schtasks.exe /Delete /F /TN $old | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "could not remove old task $old (schtasks $LASTEXITCODE)" 'WARN'; return }
            Log "removed old task $old (C:\BCT\ files left in place; delete manually if wanted)"
        } else {
            Log "old task ${old}: no task scheduler tools found, skipped" 'WARN'
        }
    }

    # Cloudflare in front of mon.ausict.com only accepts TLS 1.3, which Windows only has from build 20348
    # (Server 2022 / Windows 11). Older builds must use a LAN http base URL.
    function Write-TlsHint([string]$Url) {
        if ($Url -notlike 'https:*' -or $state.TlsHinted) { return }
        $state.TlsHinted = $true
        $os = [Environment]::OSVersion
        if ($os.Platform -eq 'Win32NT' -and $os.Version.Build -lt 20348) {
            $msg = ("HTTPS to $Url failed. This OS (build {0}; Server 2012 R2/2016/2019) has no TLS 1.3, which the public site requires. " +
                    "Use the LAN http URL instead: -BaseUrl http://10.23.23.21/dx") -f $os.Version.Build
            Log $msg 'WARN'
        } else {
            Log "HTTPS to $Url failed. If the public site is unreachable from here, use the LAN http URL: -BaseUrl http://10.23.23.21/dx" 'WARN'
        }
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

    # Expose helpers for unit tests (test-only, never used in normal runs).
    if ($env:CMK_TEST_EXPORT_FUNCTIONS -eq '1') {
        foreach ($fn in @('ConvertTo-CmkVersion', 'Compare-CmkVersion', 'Log', 'Get-ScriptText', 'Install-Task', 'Invoke-OldTaskCleanup',
                          'ConvertTo-DXNormPath', 'Test-DXSamePath', 'Test-DXUnderPath', 'Test-DXTextHasPath', 'Resolve-DXPath',
                          'Protect-DXFolder', 'Initialize-DXFolder', 'Get-DXTaskAction', 'Get-DXLegacyLocation', 'Get-DXOwnedLog',
                          'Copy-DXLegacyLog', 'Invoke-DXLegacyCleanup')) {
            Set-Item -Path "function:global:$fn" -Value (Get-Item -Path "function:$fn").ScriptBlock
        }
        return
    }

    # ================= main =================
    $tmp = $null
    try {
        $testMode = $false
        $ScriptDir = Resolve-DXPath $ScriptDir ([IO.Path]::Combine($DxRoot, 'Scripts'))
        $LogDir    = Resolve-DXPath $LogDir ([IO.Path]::Combine($DxRoot, 'Logs'))
        # ----- resolve settings: parameter > CMK_* env var > default -----
        if (-not $BaseUrl)       { $BaseUrl = $env:CMK_BASEURL }
        if (-not $BaseUrl)       { $BaseUrl = 'https://mon.ausict.com/dx' }
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
            # C:\Windows\... needs admin; a failure here must not hide the clearer 'run elevated' message below.
            try { Initialize-DXFolder $LogDir } catch { Log "log folder ${LogDir}: $($_.Exception.Message)" 'WARN' }
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
        # TLS 1.2 always; TLS 1.3 only where the enum exists (.NET 4.8+) AND the OS supports it (build >= 20348).
        # Setting Tls13 on older Schannel can break the handshake for every protocol, so it is not forced there.
        $proto = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            $osv = [Environment]::OSVersion
            if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13' -and
                ($osv.Platform -ne 'Win32NT' -or $osv.Version.Build -ge 20348)) {
                $proto = $proto -bor [Net.SecurityProtocolType]'Tls13'
            }
        } catch { Log "TLS 1.3 not available in this .NET: $($_.Exception.Message)" 'WARN' }
        [Net.ServicePointManager]::SecurityProtocol = $proto
        Log "SecurityProtocol: $([Net.ServicePointManager]::SecurityProtocol)"
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
        Initialize-DXFolder $LogDir
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
        $em = $_.Exception.Message
        if ($em -match '(?i)connect|SSL|TLS|secure channel|underlying connection|establish trust|handshake') {
            Write-TlsHint $BaseUrl
            if ($MsiUrl) { Write-TlsHint $MsiUrl }
        }
        Done 1 $em
    }
    finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
