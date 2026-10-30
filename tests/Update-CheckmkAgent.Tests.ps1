# Pester 5 tests for the C:\DX -> C:\Windows\Scripts\DX move in Update-CheckmkAgent.ps1.
# Runs on pwsh (Linux or Windows): the ScheduledTasks and ACL cmdlets are replaced by fakes, and the old/new roots
# point at a temp folder. Run: Invoke-Pester ./tests
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The script under test reads its settings by dynamic scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    $script:Ps1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Update-CheckmkAgent.ps1'
    $env:CMK_TEST_EXPORT_FUNCTIONS = '1'
    & $script:Ps1
    $env:CMK_TEST_EXPORT_FUNCTIONS = $null
    $script:RealProtect = (Get-Item function:Protect-DXFolder).ScriptBlock

    # ---- fakes for Windows-only cmdlets ----
    function global:New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function global:New-ScheduledTaskTrigger { param([switch]$Weekly, $DaysOfWeek, $At, $RandomDelay) 'trigger' }
    function global:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) 'principal' }
    function global:New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable, $ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries) 'settings' }
    function global:Get-ScheduledTask {
        param($TaskPath, $TaskName)
        $global:T.Tasks["$TaskPath$TaskName"]
    }
    function global:Register-ScheduledTask {
        param($TaskName, $TaskPath, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
        $global:T.Registered++
        if (-not $global:T.RegisterIsNoop) { $global:T.Tasks["$TaskPath$TaskName"] = [pscustomobject]@{ Actions = @($Action) } }
    }
    function global:Unregister-ScheduledTask { param($TaskPath, $TaskName, [switch]$Confirm) $global:T.Tasks.Remove("$TaskPath$TaskName") }
    function global:Protect-DXFolder { param([string]$Path) $global:T.Protected += $Path }

    function global:New-TestEnv {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cmkt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $global:T = @{ Tmp = $tmp; Tasks = @{}; Registered = 0; RegisterIsNoop = $false; Protected = @() }
        $env:SystemRoot = Join-Path $tmp 'Windows'
        # settings the script normally sets in its own scope
        $global:DxRoot = Join-Path $tmp 'Windows/Scripts/DX'
        $global:LegacyRoot = Join-Path $tmp 'DX'
        $global:ScriptFileName = 'Update-CheckmkAgent.ps1'
        $global:OwnedLogPattern = '^(Update-CheckmkAgent|CheckmkAgent)-\d{8}-\d{6}\.log$'
        $global:TaskName = 'DX Checkmk Agent Update'; $global:TaskPath = '\DX\'
        $global:OldTaskName = 'BCT Checkmk Agent Update'; $global:OldTaskPath = '\BCT\'
        $global:ScriptDir = Join-Path $global:DxRoot 'Scripts'
        $global:LogDir = Join-Path $global:DxRoot 'Logs'
        $global:BaseUrl = 'https://mon.ausict.com/dx'; $global:TargetVersion = ''; $global:MsiUrl = ''; $global:msiExplicit = $false
        $global:InstallIfMissing = $false; $global:DryRun = $false; $global:TaskDay = 'Tuesday'; $global:TaskTime = '03:00'; $global:ScriptUrl = ''
        return $tmp
    }
    function global:New-LegacyInstall([switch]$OtherStuff) {
        $old = $global:LegacyRoot
        New-Item -ItemType Directory -Path (Join-Path $old 'Scripts'), (Join-Path $old 'Logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'Scripts/Update-CheckmkAgent.ps1') -Value 'old copy'
        Set-Content -LiteralPath (Join-Path $old 'Logs/Update-CheckmkAgent-20261020-030512.log') -Value 'old transcript'
        Set-Content -LiteralPath (Join-Path $old 'Logs/CheckmkAgent-20261020-030601.log') -Value 'old msi log'
        if ($OtherStuff) {
            Set-Content -LiteralPath (Join-Path $old 'Logs/DX-CFIP-Collector.log') -Value 'another tool'
            New-Item -ItemType Directory -Path (Join-Path $old 'OtherTool') | Out-Null
            Set-Content -LiteralPath (Join-Path $old 'OtherTool/x.ps1') -Value 'x'
        }
        $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $global:T.Tasks['\DX\DX Checkmk Agent Update'] = [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = $psExe
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $old 'Scripts/Update-CheckmkAgent.ps1')`" -BaseUrl `"https://mon.ausict.com/dx`"" }) }
    }
}

AfterAll {
    foreach ($f in 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet',
        'Get-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Protect-DXFolder', 'New-TestEnv', 'New-LegacyInstall') {
        Remove-Item -Path "function:global:$f" -ErrorAction SilentlyContinue
    }
}

Describe 'paths' {
    BeforeEach { $null = New-TestEnv; $global:DxRoot = 'C:\Windows\Scripts\DX'; $global:LegacyRoot = 'C:\DX' }
    AfterEach { Remove-Item -LiteralPath $T.Tmp -Recurse -Force }

    It 'empty -ScriptDir/-LogDir -> default under C:\Windows\Scripts\DX' {
        Test-DXSamePath (Resolve-DXPath '' 'C:\Windows\Scripts\DX\Scripts') 'C:\Windows\Scripts\DX\Scripts' | Should -BeTrue
    }
    It 'anything under C:\DX maps to the same place under the new root (<in>)' -ForEach @(
        @{ in = 'C:\DX\Logs'; out = 'C:\Windows\Scripts\DX\Logs' }
        @{ in = 'c:\dx\Scripts\'; out = 'C:\Windows\Scripts\DX\Scripts' }
        @{ in = 'C:\DX\Sub\Deep'; out = 'C:\Windows\Scripts\DX\Sub\Deep' }
        @{ in = 'C:\DX'; out = 'C:\Windows\Scripts\DX' }
    ) {
        Test-DXSamePath (Resolve-DXPath $in 'unused') $out | Should -BeTrue
    }
    It 'paths not under C:\DX stay as they are (<in>)' -ForEach @(@{ in = 'D:\Tools\Logs' }, @{ in = 'C:\DXTools\Logs' }, @{ in = '\\srv\share\logs' }) {
        Resolve-DXPath $in 'unused' | Should -BeExactly $in
    }
    It 'the script builds its root from $env:SystemRoot and defaults to it' {
        $src = Get-Content -LiteralPath $script:Ps1 -Raw
        $src | Should -Match ([regex]::Escape("Join-Path `$env:SystemRoot 'Scripts\DX'"))
        $src | Should -Match ([regex]::Escape("Resolve-DXPath `$ScriptDir ([IO.Path]::Combine(`$DxRoot, 'Scripts'))"))
        $src | Should -Match ([regex]::Escape("Resolve-DXPath `$LogDir ([IO.Path]::Combine(`$DxRoot, 'Logs'))"))
        $src | Should -Not -Match "(?m)^\s*\[string\]\`$(ScriptDir|LogDir)\s*=\s*'C:\\DX"
    }
}

Describe 'Test-DXTextHasPath' {
    It 'C:\DX as a folder does not match C:\DXTools' {
        Test-DXTextHasPath '-File "C:\DXTools\x.ps1"' 'C:\DX' -AsFolder | Should -BeFalse
        Test-DXTextHasPath '-File "c:\dx\Scripts\x.ps1"' 'C:\DX' -AsFolder | Should -BeTrue
    }
}

Describe 'end-to-end dry run (-File, test mode)' {
    It 'prints the new script path under %SystemRoot%\Scripts\DX and exits 0' {
        $tmp = New-TestEnv
        $env:CMK_TEST_SKIP_ADMIN = '1'; $env:CMK_INSTALLED_VERSION = '2.5.0p17'   # New-TestEnv set SystemRoot to <tmp>/Windows
        try {
            $out = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Ps1 -DryRun -InstallScheduledTask -TargetVersion 2.5.0p17 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $tmp 'Windows') | Should -BeFalse -Because 'a dry run creates no folders'
        } finally { $env:CMK_TEST_SKIP_ADMIN = $null; $env:CMK_INSTALLED_VERSION = $null; Remove-Item -LiteralPath $tmp -Recurse -Force }
        $out | Should -Match ('would save script to ' + [regex]::Escape($env:SystemRoot) + '[\\/]Scripts[\\/]DX[\\/]Scripts[\\/]Update-CheckmkAgent\.ps1')
        $out | Should -Not -Match '-LogDir'
        $out | Should -Not -Match 'C:\\DX\\Scripts\\Update'
    }
}

Describe 'Install-Task' {
    BeforeEach { $null = New-TestEnv }
    AfterEach { Remove-Item -LiteralPath $T.Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'fresh install: script copy + task under the new root, folders ACL-protected, no -LogDir arg' {
        Install-Task 6>&1 | Out-Null
        $target = Join-Path $ScriptDir 'Update-CheckmkAgent.ps1'
        Test-Path -LiteralPath $target | Should -BeTrue
        (Get-Content -LiteralPath $target -Raw) | Should -Match 'function Compare-CmkVersion'
        $a = $T.Tasks['\DX\DX Checkmk Agent Update'].Actions[0]
        $a.Arguments | Should -Match ([regex]::Escape("-File `"$target`""))
        $a.Arguments | Should -Not -Match '-LogDir'
        $a.Execute | Should -Match 'powershell\.exe$'
        $T.Protected | Should -Contain $DxRoot
        $T.Protected | Should -Contain $ScriptDir
        $T.Protected | Should -Contain $LogDir
        Test-Path -LiteralPath $LegacyRoot | Should -BeFalse
    }

    It 'keeps the task folder and name' {
        Install-Task 6>&1 | Out-Null
        @($T.Tasks.Keys) | Should -Be @('\DX\DX Checkmk Agent Update')
    }

    It 're-points a task that runs the old C:\DX copy and migrates logs' {
        New-LegacyInstall
        $out = Install-Task 6>&1 | Out-String
        $out | Should -Match 'runs from the old root'
        $ta = $T.Tasks['\DX\DX Checkmk Agent Update'].Actions[0].Arguments
        $ta | Should -Match ([regex]::Escape((Join-Path $ScriptDir 'Update-CheckmkAgent.ps1')))
        Test-DXTextHasPath $ta $LegacyRoot -AsFolder | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $LogDir 'Update-CheckmkAgent-20261020-030512.log') | Should -Be 'old transcript'
        Get-Content -LiteralPath (Join-Path $LogDir 'CheckmkAgent-20261020-030601.log') | Should -Be 'old msi log'
    }

    It 'cleanup: deletes only our files, keeps unknown files and C:\DX with other content' {
        New-LegacyInstall -OtherStuff
        Install-Task 6>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Scripts/Update-CheckmkAgent.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Scripts') | Should -BeFalse      # left empty -> removed
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Logs/Update-CheckmkAgent-20261020-030512.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Logs/CheckmkAgent-20261020-030601.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Logs/DX-CFIP-Collector.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'OtherTool/x.ps1') | Should -BeTrue
        Test-Path -LiteralPath $LegacyRoot | Should -BeTrue
    }

    It 'cleanup: removes C:\DX when only our files were in it' {
        New-LegacyInstall
        Install-Task 6>&1 | Out-Null
        Test-Path -LiteralPath $LegacyRoot | Should -BeFalse
    }

    It 'migration never overwrites a log already in the new folder' {
        New-LegacyInstall
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $LogDir 'CheckmkAgent-20261020-030601.log') -Value 'new one'
        Install-Task 6>&1 | Out-Null
        Get-Content -LiteralPath (Join-Path $LogDir 'CheckmkAgent-20261020-030601.log') | Should -Be 'new one'
    }

    It 'old files stay if the task cannot be confirmed on the new path' {
        New-LegacyInstall
        $T.RegisterIsNoop = $true
        $out = Install-Task 6>&1 | Out-String
        $out | Should -Match 'could not confirm'
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Scripts/Update-CheckmkAgent.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Logs/CheckmkAgent-20261020-030601.log') | Should -BeTrue
    }

    It 'old files stay if registration throws' {
        New-LegacyInstall
        Mock Register-ScheduledTask { throw 'access denied' }
        { Install-Task 6>&1 | Out-Null } | Should -Throw '*access denied*'
        Test-Path -LiteralPath (Join-Path $LegacyRoot 'Scripts/Update-CheckmkAgent.ps1') | Should -BeTrue
    }

    It 'old copy found only by file (task already gone) is still cleaned up' {
        New-LegacyInstall
        $T.Tasks.Clear()
        Install-Task 6>&1 | Out-Null
        Test-Path -LiteralPath $LegacyRoot | Should -BeFalse
        $T.Tasks['\DX\DX Checkmk Agent Update'] | Should -Not -BeNullOrEmpty
    }

    It 'is idempotent: a second run gives the same task, files and no errors' {
        New-LegacyInstall -OtherStuff
        Install-Task 6>&1 | Out-Null
        $ta1 = $T.Tasks['\DX\DX Checkmk Agent Update'].Actions[0].Arguments
        $files1 = @(Get-ChildItem -LiteralPath $T.Tmp -Recurse -File | ForEach-Object FullName | Sort-Object)
        $out = Install-Task 6>&1 | Out-String
        $out | Should -Not -Match 'ERROR|WARN'
        $out | Should -Not -Match 'runs from the old root'
        $T.Tasks['\DX\DX Checkmk Agent Update'].Actions[0].Arguments | Should -BeExactly $ta1
        @(Get-ChildItem -LiteralPath $T.Tmp -Recurse -File | ForEach-Object FullName | Sort-Object) | Should -Be $files1
        $T.Registered | Should -Be 2
    }

    It '-DryRun changes nothing' {
        New-LegacyInstall -OtherStuff
        $before = @(Get-ChildItem -LiteralPath $T.Tmp -Recurse | ForEach-Object FullName | Sort-Object)
        $global:DryRun = $true
        $out = Install-Task 6>&1 | Out-String
        $out | Should -Match 'DRY RUN: would copy 2 old log'
        $out | Should -Match 'DRY RUN: would remove old script copy'
        $T.Registered | Should -Be 0
        @(Get-ChildItem -LiteralPath $T.Tmp -Recurse | ForEach-Object FullName | Sort-Object) | Should -Be $before
    }

    It 'a custom -LogDir outside the DX root is passed to the task and not ACL-changed' {
        $global:LogDir = Join-Path $T.Tmp 'custom-logs'
        Install-Task 6>&1 | Out-Null
        $T.Tasks['\DX\DX Checkmk Agent Update'].Actions[0].Arguments | Should -Match ([regex]::Escape("-LogDir `"$LogDir`""))
        $T.Protected | Should -Not -Contain $LogDir
    }

    It 'still removes the pre-rename \BCT\ task' {
        $T.Tasks['\BCT\BCT Checkmk Agent Update'] = [pscustomobject]@{ Actions = @() }
        Install-Task 6>&1 | Out-Null
        $T.Tasks.ContainsKey('\BCT\BCT Checkmk Agent Update') | Should -BeFalse
    }
}

Describe 'Initialize-DXFolder' {
    BeforeEach { $null = New-TestEnv }
    AfterEach { Remove-Item -LiteralPath $T.Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'protects new folders under the DX root once, not on every run' {
        Initialize-DXFolder $LogDir
        $T.Protected | Should -Be @($DxRoot, $LogDir)
        $T.Protected = @()
        Initialize-DXFolder $LogDir
        $T.Protected.Count | Should -Be 0
        Initialize-DXFolder $LogDir -Reprotect
        $T.Protected | Should -Be @($DxRoot, $LogDir)
    }
}

Describe 'Protect-DXFolder (real code, fake ACL cmdlets)' {
    It 'grants FullControl to S-1-5-18 and S-1-5-32-544 only, inheritance protected' {
        $acl = [pscustomobject]@{ Access = @('inherited-users-read'); Removed = @(); Added = @(); Protected = '' }
        $acl | Add-Member ScriptMethod SetAccessRuleProtection { param($a, $b) $this.Protected = "$a,$b" }
        $acl | Add-Member ScriptMethod RemoveAccessRule { param($r) $this.Removed += $r; $true }
        $acl | Add-Member ScriptMethod AddAccessRule { param($r) $this.Added += $r }
        $global:FakeAcl = $acl; $global:SetAclCalls = @()
        function global:Get-Acl { param([string]$LiteralPath) $global:FakeAcl }
        function global:Set-Acl { param([string]$LiteralPath, $AclObject) $global:SetAclCalls += $LiteralPath }
        Mock New-Object -ParameterFilter { $TypeName -like '*SecurityIdentifier' } { [pscustomobject]@{ Value = $ArgumentList[0] } }
        Mock New-Object -ParameterFilter { $TypeName -like '*FileSystemAccessRule' } {
            [pscustomobject]@{ IdentityReference = $ArgumentList[0]; FileSystemRights = $ArgumentList[1]; InheritanceFlags = $ArgumentList[2]; Type = $ArgumentList[4] } }
        try {
            $real = $script:RealProtect
            & $real -Path 'C:\Windows\Scripts\DX\Scripts' 6>&1 | Out-Null
        } finally { Remove-Item function:global:Get-Acl, function:global:Set-Acl }
        $acl.Protected | Should -Be 'True,False'
        $acl.Removed | Should -Be @('inherited-users-read')
        @($acl.Added | ForEach-Object { $_.IdentityReference.Value }) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        @($acl.Added | ForEach-Object { [string]$_.FileSystemRights }) | Should -Be @('FullControl', 'FullControl')
        @($acl.Added | ForEach-Object { [string]$_.InheritanceFlags }) | Should -Be @('ContainerInherit, ObjectInherit', 'ContainerInherit, ObjectInherit')
        $global:SetAclCalls | Should -Be @('C:\Windows\Scripts\DX\Scripts')
    }
}

Describe 'version helpers still exported' {
    It 'Compare-CmkVersion works' { Compare-CmkVersion '2.5.0p17' '2.5.0p16' | Should -Be 1 }
}
