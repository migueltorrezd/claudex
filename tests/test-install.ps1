# Exercises the non-ConfigOnly install/doctor/setup delegation paths that
# tests/test-setup.ps1 never reaches (it only ever passes -ConfigOnly).
#
# Safety note: scripts/setup.ps1 has no -NoPath (or equivalent) parameter and
# never forwards one to scripts/install.ps1, so any real, unmodified
# setup.ps1 run without -ConfigOnly will always call
# Add-InstallDirectoryToPath, which mutates the real per-user PATH in
# HKCU\Environment via [Environment]::SetEnvironmentVariable(...,'User').
# That is a real system mutation this suite must never perform. So:
#   - Test A calls the real scripts/install.ps1 directly with -NoPath so the
#     PATH-mutating branch never runs, and -NoService so no Scheduled Task is
#     registered.
#   - Test B calls the real scripts/doctor.ps1 -NoService directly against
#     the artifacts Test A produced.
#   - Test C exercises the real scripts/setup.ps1 delegation branch (the
#     "WITHOUT -ConfigOnly" path the task asks for) end to end, including a
#     real final scripts/doctor.ps1 call, but does so against a byte-for-byte
#     copy of setup.ps1/doctor.ps1 in a scratch "repo" whose scripts/install.ps1
#     is a recording stub. This proves setup.ps1's delegation, flag threading
#     (-NoLogin/-NoService/-WithAgent), and final doctor verification all work,
#     without ever running the real install.ps1's PATH/Scheduled-Task code
#     with -ConfigOnly absent.
#   - Test D unit-tests install.ps1's Scheduled-Task ownership check
#     (Test-ManagedProxyTask) directly against fabricated task objects; it
#     never creates or deletes a real Windows Scheduled Task.
#
# A snapshot of real machine state (User PATH, the real 'Claudex Proxy'
# Scheduled Task, and %APPDATA%\Claudex) is taken before anything runs and
# compared after everything finishes, so a regression that reintroduces a
# real mutation fails this suite instead of silently touching the machine.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$realInstall = Join-Path $repoRoot 'scripts\install.ps1'
$realDoctor = Join-Path $repoRoot 'scripts\doctor.ps1'
$realSetup = Join-Path $repoRoot 'scripts\setup.ps1'
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("claudex-install-test-$PID-$([Guid]::NewGuid().ToString('N'))")

# ---------------------------------------------------------------------------
# Shared helpers (copied from tests/test-setup.ps1 rather than dot-sourced,
# so this file never re-runs that file's own suite).
# ---------------------------------------------------------------------------

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [switch]$AllowFailure
    )

    $processArguments = @('-NoProfile', '-NonInteractive', '-File', $Path) + $Arguments
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = (($processArguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            $startInfo.EnvironmentVariables.Remove($key)
        }
        else {
            $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start PowerShell for $Path"
        }
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $output = $standardOutput + $standardError
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "PowerShell file exited with code ${exitCode}: $Path`n$output"
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = [int]$exitCode
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()][string]$Expected,
        [AllowNull()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -cne [string]$Actual) {
        throw "Assertion failed: $Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-OutputContainsLine {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (($Output -split "`r?`n") -cnotcontains $Line) {
        throw "Expected output line '$Line' was not present:`n$Output"
    }
}

function Assert-OutputDoesNotContain {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Substring
    )

    if ($Output.IndexOf($Substring, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Did not expect output to contain '$Substring':`n$Output"
    }
}

# Ambient CCX_*/ANTHROPIC_* variables are cleared for every child process so
# nothing on the host running this suite leaks into the scenarios below.
$ambientNamesToClear = @(
    'CCX_CONFIG_FILE', 'CCX_CONFIG_DIR', 'CCX_CONFIG_SOURCE', 'CCX_INSTALL_DIR',
    'CCX_AGENT_DIR', 'CCX_SUBAGENT_EFFORT', 'CCX_MODEL', 'CCX_MAIN_EFFORT',
    'CCX_BG_MODEL', 'CCX_BG_EFFORT', 'CCX_BACKGROUND_MODEL',
    'CCX_BACKGROUND_EFFORT', 'CCX_SMALL_FAST_MODEL', 'CCX_CONTEXT_WINDOW',
    'CCX_PROXY_URL', 'CCX_SHIM_URL', 'CCX_REAL_CLAUDE', 'CCX_SKIP_HEALTH_CHECK',
    'CLAUDE_CODE_EFFORT_LEVEL', 'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL',
    'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'XDG_CONFIG_HOME',
    'CCX_TEST_INSTALL_RECORD'
)

function New-BaseEnvironment {
    $environment = @{}
    foreach ($name in $ambientNamesToClear) {
        $environment[$name] = $null
    }
    # A known-good PATHEXT guarantees the .cmd stubs below are resolved by
    # Get-Command regardless of the host's own PATHEXT customization.
    $environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    return $environment
}

function Merge-Environment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Overrides
    )

    $merged = New-BaseEnvironment
    foreach ($key in $Overrides.Keys) {
        $merged[$key] = $Overrides[$key]
    }
    return $merged
}

# ---------------------------------------------------------------------------
# Real-machine-state snapshot: taken before anything runs, re-checked after
# everything finishes. All reads; nothing here mutates the machine.
# ---------------------------------------------------------------------------

function Get-RealClaudexProxyTaskCount {
    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        return -1
    }
    return @(Get-ScheduledTask -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue).Count
}

function Assert-NoConflictingRealClaudexProxyTask {
    # Tests B and C pin CCX_PROXY_URL to a deliberately unreachable loopback
    # port so the proxy-health check is deterministically unhealthy (see
    # Get-UnusedLoopbackProxyUrl below). doctor.ps1's Scheduled Task branch is
    # PASS if Running, INFO if the proxy is otherwise healthy, else FAIL --
    # there is no -NoService exemption there. On a host where a real
    # 'Claudex Proxy' task already exists but is not Running, our forced
    # unhealthy proxy would drive that branch to FAIL, which is a real,
    # pre-existing host condition rather than a defect in this suite. Fail
    # fast with an explicit explanation instead of a confusing exit-1 dump
    # from deep inside Test B or C.
    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        return
    }
    $existingTasks = @(Get-ScheduledTask -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue)
    if ($existingTasks.Count -eq 0) {
        return
    }
    $state = [string]$existingTasks[0].State
    if ($state -ne 'Running') {
        throw "This host already has a real 'Claudex Proxy' Scheduled Task in state '$state'. " +
            "doctor.ps1's Scheduled Task check will FAIL whenever the proxy is unhealthy, and Tests " +
            "B/C intentionally force the proxy unhealthy (see Get-UnusedLoopbackProxyUrl) so the " +
            "-NoService health-check exemption is exercised deterministically. This is a real, " +
            "pre-existing host condition, not a defect in this test suite; start or remove the real " +
            "task before rerunning tests/test-install.ps1."
    }
}

function Get-RealAppDataClaudexState {
    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }
    if (-not $appData) {
        return $false
    }
    return (Test-Path -LiteralPath (Join-Path $appData 'Claudex') -PathType Container)
}

function Get-UnusedLoopbackProxyUrl {
    # The default http://127.0.0.1:18765 cannot be assumed free: a real
    # Claudex proxy may already be running on the host that runs this suite.
    # Binding an ephemeral loopback port and immediately releasing it gives a
    # deterministic, almost-certainly-unreachable URL so the -NoService
    # "proxy is not running" doctor.ps1 branch is exercised reliably instead
    # of accidentally reaching a real, already-healthy service.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
    return "http://127.0.0.1:$port"
}

$beforeUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$beforeMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$beforeTaskCount = Get-RealClaudexProxyTaskCount
$beforeAppDataClaudex = Get-RealAppDataClaudexState
Assert-NoConflictingRealClaudexProxyTask
$unusedProxyUrl = Get-UnusedLoopbackProxyUrl

try {
    # -----------------------------------------------------------------------
    # Scratch layout
    # -----------------------------------------------------------------------
    $stubDir = Join-Path $testRoot 'stub-bin'
    $installDir = Join-Path $testRoot 'install'
    $agentDir = Join-Path $testRoot 'agents'
    $configDirA = Join-Path $testRoot 'config-a'
    $configDirC = Join-Path $testRoot 'config-c'
    $tempRepo = Join-Path $testRoot 'temp-repo'
    $tempRepoScripts = Join-Path $tempRepo 'scripts'
    $recordFile = Join-Path $testRoot 'install-record.json'

    foreach ($directory in @($stubDir, $installDir, $agentDir, $configDirA, $configDirC, $tempRepoScripts)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # Deterministic stand-ins for 'claude' and 'claude-code-proxy'. Both
    # always exit 0 so codex auth status reads as healthy and no interactive
    # login or real proxy download is ever triggered.
    $claudeStubPath = Join-Path $stubDir 'claude.cmd'
    [IO.File]::WriteAllText($claudeStubPath, @'
@echo off
if "%~1"=="--version" (
  echo claude-stub 0.0.0
)
exit /b 0
'@ + "`r`n")

    $proxyStubPath = Join-Path $stubDir 'claude-code-proxy.cmd'
    [IO.File]::WriteAllText($proxyStubPath, @'
@echo off
if "%~1"=="--version" (
  echo claude-code-proxy-stub 0.0.0
)
exit /b 0
'@ + "`r`n")

    $stubPath = "$stubDir;$env:Path"

    # =========================================================================
    # Test A: the real scripts/install.ps1, non-interactively, with -NoPath
    # and -NoService so neither the real User PATH nor a real Scheduled Task
    # is ever touched.
    # =========================================================================
    $installEnvironment = Merge-Environment @{
        CCX_INSTALL_DIR = $installDir
        CCX_CONFIG_DIR = $configDirA
        CCX_AGENT_DIR = $agentDir
        CCX_SUBAGENT_EFFORT = 'high'
        Path = $stubPath
    }

    $installResult = Invoke-PowerShellFile -Path $realInstall -Environment $installEnvironment -Arguments @(
        '-NoPath', '-NoService', '-WithAgent'
    )

    Assert-OutputContainsLine $installResult.Output 'Claudex installed.'
    Assert-OutputContainsLine $installResult.Output '  User PATH: skipped (-NoPath)'
    Assert-OutputContainsLine $installResult.Output '  Scheduled Task: skipped (-NoService)'
    if ($installResult.Output.IndexOf('Using existing proxy', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Expected install.ps1 to reuse the stubbed proxy on PATH, not download one:`n$($installResult.Output)"
    }
    Assert-OutputDoesNotContain $installResult.Output 'Downloading'

    $launcherCmdTarget = Join-Path $installDir 'ccx.cmd'
    $launcherPsTarget = Join-Path $installDir 'lib\ccx.ps1'
    $agentTarget = Join-Path $agentDir 'claudex-worker.md'
    $configTargetA = Join-Path $configDirA 'config'

    Assert-True (Test-Path -LiteralPath $launcherCmdTarget -PathType Leaf) "install.ps1 should have written $launcherCmdTarget"
    Assert-True (Test-Path -LiteralPath $launcherPsTarget -PathType Leaf) "install.ps1 should have written $launcherPsTarget"
    Assert-True (Test-Path -LiteralPath $agentTarget -PathType Leaf) "install.ps1 -WithAgent should have written $agentTarget"
    Assert-True (Test-Path -LiteralPath $configTargetA -PathType Leaf) "install.ps1 should have written $configTargetA"

    # The user's real PATH must be untouched by an install.ps1 run that
    # requested -NoPath.
    Assert-Equal $beforeUserPath ([Environment]::GetEnvironmentVariable('Path', 'User')) 'Real User PATH must be unchanged after -NoPath install'

    # =========================================================================
    # Test B: the real scripts/doctor.ps1 -NoService, run directly against
    # the artifacts Test A produced.
    # =========================================================================
    $doctorEnvironment = Merge-Environment @{
        CCX_CONFIG_DIR = $configDirA
        CCX_AGENT_DIR = $agentDir
        CCX_PROXY_URL = $unusedProxyUrl
        Path = "$stubDir;$installDir;$env:Path"
    }

    $doctorResult = Invoke-PowerShellFile -Path $realDoctor -Environment $doctorEnvironment -Arguments @('-NoService')

    Assert-True ($doctorResult.Output -match 'PASS(\s+)Claude Code:') 'doctor.ps1 should find the stubbed claude on PATH'
    Assert-True ($doctorResult.Output -match 'PASS(\s+)Proxy:') 'doctor.ps1 should find the stubbed claude-code-proxy on PATH'
    Assert-True ($doctorResult.Output -match 'PASS(\s+)Codex OAuth is configured') 'doctor.ps1 should read the stubbed healthy codex auth status'
    Assert-True ($doctorResult.Output -match 'INFO(\s+)Proxy health:.*expected with -NoService') 'doctor.ps1 -NoService should not fail the unreachable proxy health check'
    Assert-True ($doctorResult.Output -match 'PASS(\s+)Launcher:') 'doctor.ps1 should find the installed ccx launcher on PATH'
    Assert-OutputContainsLine $doctorResult.Output 'Claudex is ready. No live model request was made.'
    if ($doctorResult.Output -match '(?m)^FAIL\s') {
        throw "doctor.ps1 reported unexpected FAIL lines:`n$($doctorResult.Output)"
    }

    # =========================================================================
    # Test C: the real scripts/setup.ps1 WITHOUT -ConfigOnly, exercising its
    # install.ps1 delegation and final doctor.ps1 verification end to end.
    # Because setup.ps1 has no way to pass -NoPath through to install.ps1,
    # setup.ps1 and doctor.ps1 are copied byte-for-byte into a scratch "repo"
    # whose scripts/install.ps1 is a recording stub instead of the real
    # installer. This exercises the exact delegation/flag-threading/final-
    # verification behavior the task is about, without ever letting the real
    # PATH-mutating install.ps1 run outside of -ConfigOnly.
    # =========================================================================
    Copy-Item -LiteralPath $realSetup -Destination (Join-Path $tempRepoScripts 'setup.ps1')
    Copy-Item -LiteralPath $realDoctor -Destination (Join-Path $tempRepoScripts 'doctor.ps1')

    $recordingInstallStub = @'
[CmdletBinding()]
param(
    [switch]$WithAgent,
    [switch]$Login,
    [switch]$NoService,
    [switch]$NoPath,
    [Alias('h')][switch]$Help
)

$record = [PSCustomObject]@{
    WithAgent = $WithAgent.IsPresent
    Login = $Login.IsPresent
    NoService = $NoService.IsPresent
    NoPath = $NoPath.IsPresent
    ConfigFile = $env:CCX_CONFIG_FILE
    ConfigDir = $env:CCX_CONFIG_DIR
    SubagentEffort = $env:CCX_SUBAGENT_EFFORT
}
$record | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:CCX_TEST_INSTALL_RECORD -Encoding UTF8
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $tempRepoScripts 'install.ps1'), $recordingInstallStub)

    $setupEnvironment = Merge-Environment @{
        CCX_CONFIG_DIR = $configDirC
        CCX_AGENT_DIR = $agentDir
        CCX_TEST_INSTALL_RECORD = $recordFile
        CCX_PROXY_URL = $unusedProxyUrl
        Path = "$stubDir;$installDir;$env:Path"
    }

    $setupResult = Invoke-PowerShellFile -Path (Join-Path $tempRepoScripts 'setup.ps1') -Environment $setupEnvironment -Arguments @(
        '-NoLogin', '-NoService', '-NoPath', '-WithAgent', '-Yes'
    )

    Assert-OutputContainsLine $setupResult.Output 'Final verification:'
    Assert-OutputContainsLine $setupResult.Output 'Claudex is ready. No live model request was made.'
    if ($setupResult.Output -match '(?m)^FAIL\s') {
        throw "The relocated setup.ps1's final doctor.ps1 call reported unexpected FAIL lines:`n$($setupResult.Output)"
    }

    Assert-True (Test-Path -LiteralPath $recordFile -PathType Leaf) 'The recording install.ps1 stub should have written a record file'
    $record = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json
    $configTargetC = Join-Path $configDirC 'config'

    Assert-Equal 'True' ([string]$record.WithAgent) '-WithAgent should have reached install.ps1'
    Assert-Equal 'False' ([string]$record.Login) '-NoLogin should have kept Login unset on install.ps1'
    Assert-Equal 'True' ([string]$record.NoService) '-NoService should have reached install.ps1'
    Assert-Equal 'True' ([string]$record.NoPath) '-NoPath should have reached install.ps1'
    Assert-Equal ([IO.Path]::GetFullPath($configTargetC)) ([IO.Path]::GetFullPath([string]$record.ConfigFile)) 'CCX_CONFIG_FILE passed to install.ps1 should match the config setup.ps1 just wrote'
    Assert-Equal ([IO.Path]::GetFullPath($configDirC)) ([IO.Path]::GetFullPath([string]$record.ConfigDir)) 'CCX_CONFIG_DIR passed to install.ps1 should match the resolved config directory'
    Assert-Equal 'high' ([string]$record.SubagentEffort) 'CCX_SUBAGENT_EFFORT passed to install.ps1 should match the (default) selected sub-agent effort'

    Assert-True (Test-Path -LiteralPath $configTargetC -PathType Leaf) 'setup.ps1 should have written its own config before delegating to install.ps1'

    # =========================================================================
    # Test D: unit-test install.ps1's Scheduled-Task ownership check
    # (Test-ManagedProxyTask) directly, with fabricated task objects. No real
    # Scheduled Task is ever created, registered, started, or deleted.
    # =========================================================================
    $installTokens = $null
    $installParseErrors = $null
    $installAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $realInstall, [ref]$installTokens, [ref]$installParseErrors
    )
    if ($installParseErrors.Count -gt 0) {
        throw "scripts/install.ps1 failed to parse:`n$($installParseErrors | Out-String)"
    }

    $functionAsts = $installAst.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )
    $getProxyTaskScriptAst = @($functionAsts | Where-Object { $_.Name -eq 'Get-ProxyTaskScript' })
    $testManagedProxyTaskAst = @($functionAsts | Where-Object { $_.Name -eq 'Test-ManagedProxyTask' })
    Assert-True ($getProxyTaskScriptAst.Count -eq 1) 'Expected exactly one Get-ProxyTaskScript function definition in install.ps1'
    Assert-True ($testManagedProxyTaskAst.Count -eq 1) 'Expected exactly one Test-ManagedProxyTask function definition in install.ps1'

    . ([ScriptBlock]::Create($getProxyTaskScriptAst[0].Extent.Text))
    . ([ScriptBlock]::Create($testManagedProxyTaskAst[0].Extent.Text))

    # Matches install.ps1's own $script:taskMarker literal exactly.
    $script:taskMarker = 'Managed by https://github.com/migueltorrezd/claudex'

    $fakeProxyPath = Join-Path $testRoot 'fake-proxy\claude-code-proxy.exe'
    $otherProxyPath = Join-Path $testRoot 'other-proxy\claude-code-proxy.exe'
    $fakePort = '18765'

    function New-FakeTask {
        param(
            [Parameter(Mandatory = $true)][string]$Command,
            [string]$TaskPath = '\',
            [string]$Description = "$($script:taskMarker); loopback proxy for the current user.",
            [string]$Execute = 'powershell.exe'
        )

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
        return [PSCustomObject]@{
            TaskPath = $TaskPath
            Description = $Description
            Actions = @([PSCustomObject]@{
                Execute = $Execute
                Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
            })
        }
    }

    # Positive: identical shape and an encoded command that matches exactly
    # what Get-ProxyTaskScript would render for this proxy path/port.
    $managedCommand = Get-ProxyTaskScript -ProxyPath $fakeProxyPath -Port $fakePort
    $managedTask = New-FakeTask -Command $managedCommand
    Assert-True (Test-ManagedProxyTask -Task $managedTask -ProxyPath $fakeProxyPath) 'A task with the marker, expected shape, and matching encoded command should be recognized as managed'

    # Negative: same shape, same marker, but the encoded command was rendered
    # for a *different* proxy binary. This is the actual ownership property:
    # a task pointing at another executable must not be treated as ours.
    $otherCommand = Get-ProxyTaskScript -ProxyPath $otherProxyPath -Port $fakePort
    $otherProxyTask = New-FakeTask -Command $otherCommand
    Assert-True (-not (Test-ManagedProxyTask -Task $otherProxyTask -ProxyPath $fakeProxyPath)) 'A task whose encoded command targets a different proxy path must not be recognized as managed'

    # Negative: correct command, but not rooted at \ (TaskPath mismatch).
    $wrongPathTask = New-FakeTask -Command $managedCommand -TaskPath '\Some\Sub\Folder\'
    Assert-True (-not (Test-ManagedProxyTask -Task $wrongPathTask -ProxyPath $fakeProxyPath)) 'A task outside the root TaskPath must not be recognized as managed'

    # Negative: correct command, but the description is missing the marker.
    $unmarkedTask = New-FakeTask -Command $managedCommand -Description 'Some unrelated scheduled task.'
    Assert-True (-not (Test-ManagedProxyTask -Task $unmarkedTask -ProxyPath $fakeProxyPath)) 'A task without the managed marker in its description must not be recognized as managed'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Confirm no real system state was mutated by anything above.
# ---------------------------------------------------------------------------
Assert-Equal $beforeUserPath ([Environment]::GetEnvironmentVariable('Path', 'User')) 'Real User PATH must be unchanged after the whole suite'
Assert-Equal $beforeMachinePath ([Environment]::GetEnvironmentVariable('Path', 'Machine')) 'Real Machine PATH must be unchanged after the whole suite'
Assert-Equal ([string]$beforeTaskCount) ([string](Get-RealClaudexProxyTaskCount)) 'The real Claudex Proxy Scheduled Task count must be unchanged after the whole suite'
Assert-Equal ([string]$beforeAppDataClaudex) ([string](Get-RealAppDataClaudexState)) 'Whether %APPDATA%\Claudex exists must be unchanged after the whole suite'

Write-Output 'All install/doctor/setup delegation tests passed.'
