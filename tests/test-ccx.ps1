$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $repoRoot 'bin\ccx.ps1'
$cmdLauncher = Join-Path $repoRoot 'bin\ccx.cmd'
$stub = Join-Path $PSScriptRoot 'stub-claude.ps1'
$customConfig = Join-Path $PSScriptRoot 'fixtures\custom.conf'
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$missingConfig = Join-Path ([IO.Path]::GetTempPath()) ("ccx-missing-$PID-$([Guid]::NewGuid().ToString('N')).conf")

$cleanEnvironmentNames = @(
    'CCX_CONFIG_FILE', 'CCX_CONFIG_DIR', 'CCX_MODEL', 'CCX_MAIN_EFFORT',
    'CCX_BG_MODEL', 'CCX_BG_EFFORT', 'CCX_BACKGROUND_MODEL',
    'CCX_BACKGROUND_EFFORT', 'CCX_SMALL_FAST_MODEL', 'CCX_CONTEXT_WINDOW',
    'CCX_PROXY_URL', 'CCX_PROXY_TRANSPORT', 'CCX_SHIM_URL', 'CCX_REAL_CLAUDE',
    'CCX_SKIP_HEALTH_CHECK', 'CCX_SUBAGENT_GUARDS',
    'CCX_MAX_CONCURRENT_SUBAGENTS', 'CCX_MAX_SUBAGENTS_PER_SESSION',
    'CCX_MAX_SUBAGENT_SPAWN_DEPTH', 'CCX_MAX_RETRIES', 'CCX_API_TIMEOUT_MS',
    'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS',
    'CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION', 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH',
    'CLAUDE_CODE_MAX_RETRIES', 'API_TIMEOUT_MS'
)

function New-TestEnvironment {
    $environment = @{}
    foreach ($name in $cleanEnvironmentNames) {
        $environment[$name] = $null
    }

    $environment['CCX_CONFIG_FILE'] = $missingConfig
    $environment['CCX_REAL_CLAUDE'] = $stub
    $environment['CCX_SKIP_HEALTH_CHECK'] = '1'
    return $environment
}

function Merge-Environment {
    param(
        [hashtable]$Base,
        [hashtable]$Overrides = @{}
    )

    $merged = @{}
    foreach ($key in $Base.Keys) {
        $merged[$key] = $Base[$key]
    }
    foreach ($key in $Overrides.Keys) {
        $merged[$key] = $Overrides[$key]
    }
    return $merged
}

function Set-TestEnvironment {
    param([hashtable]$Environment)

    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $Environment[$key], 'Process')
    }
    return $previous
}

function Restore-TestEnvironment {
    param([hashtable]$Previous)

    foreach ($key in $Previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $Previous[$key], 'Process')
    }
}

function Invoke-Ccx {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $previous = Set-TestEnvironment $Environment
    try {
        $output = & $powerShellExe -NoProfile -File $launcher @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        if (-not $AllowFailure) {
            throw
        }
        $output = $_ | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        Restore-TestEnvironment $previous
    }

    if ($null -eq $exitCode) {
        $exitCode = 1
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "ccx exited with code ${exitCode}:`n$output"
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = [int]$exitCode
    }
}

function Invoke-CcxCmd {
    param([Parameter(Mandatory = $true)][hashtable]$Environment)

    $previous = Set-TestEnvironment $Environment
    try {
        $commandLine = '"{0}" -p "hello world"' -f $cmdLauncher
        $output = & $env:ComSpec /d /c $commandLine 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        Restore-TestEnvironment $previous
    }

    if ($null -eq $exitCode -or $exitCode -ne 0) {
        throw "ccx.cmd exited with code ${exitCode}:`n$output"
    }

    return $output
}

function Assert-ContainsLine {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (($Output -split "`r?`n") -cnotcontains $Line) {
        throw "Expected output line '$Line' was not present:`n$Output"
    }
}

function Assert-DoesNotContainLine {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (($Output -split "`r?`n") -ccontains $Line) {
        throw "Unexpected output line '$Line' was present:`n$Output"
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if ($Expected -cne $Actual) {
        throw "Expected ${Because}: '$Expected' but got '$Actual'"
    }
}

$normalOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $normalOutput 'MODEL=gpt-5.6-sol[1m]'
Assert-ContainsLine $normalOutput 'SMALL_FAST=gpt-5.6-sol[1m]'
Assert-ContainsLine $normalOutput 'EFFORT_ENV=unset'
Assert-ContainsLine $normalOutput 'ARG=xhigh'
Assert-ContainsLine $normalOutput 'BASE_URL=http://127.0.0.1:18765'
Assert-ContainsLine $normalOutput 'COMPACT_WINDOW=272000'
Assert-ContainsLine $normalOutput 'MAX_CONCURRENT_SUBAGENTS=3'
Assert-ContainsLine $normalOutput 'MAX_SUBAGENTS_PER_SESSION=12'
Assert-ContainsLine $normalOutput 'MAX_SUBAGENT_SPAWN_DEPTH=1'
Assert-ContainsLine $normalOutput 'MAX_RETRIES=3'
Assert-ContainsLine $normalOutput 'API_TIMEOUT_MS=300000'

$sparkOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('spark', '-p', 'test')).Output
Assert-ContainsLine $sparkOutput 'MODEL=gpt-5.3-codex-spark'
Assert-ContainsLine $sparkOutput 'COMPACT_WINDOW=128000'

$bareIdOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('gpt-5.6-terra', '-p', 'test')).Output
Assert-ContainsLine $bareIdOutput 'MODEL=gpt-5.6-terra[1m]'
Assert-DoesNotContainLine $bareIdOutput 'ARG=gpt-5.6-terra'

$bogusResult = Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('gpt-bogus', '-p', 'test') -AllowFailure
if ($bogusResult.ExitCode -eq 0) {
    throw 'test: unsupported bare model ID was accepted'
}

$shimOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_SHIM_URL = 'http://127.0.0.1:59999' }) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $shimOutput 'BASE_URL=http://127.0.0.1:59999'

$noNewlineConfig = Join-Path ([IO.Path]::GetTempPath()) ("ccx-no-newline-$PID-$([Guid]::NewGuid().ToString('N')).conf")
[IO.File]::WriteAllText($noNewlineConfig, "# fixture without trailing newline`nCCX_MODEL=luna", (New-Object Text.UTF8Encoding($false)))
try {
    $noNewlineOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_CONFIG_FILE = $noNewlineConfig }) -Arguments @('-p', 'test')).Output
}
finally {
    Remove-Item -LiteralPath $noNewlineConfig -Force -ErrorAction SilentlyContinue
}
Assert-ContainsLine $noNewlineOutput 'MODEL=gpt-5.6-luna[1m]'

$backgroundOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('bg', '-p', 'test')).Output
Assert-ContainsLine $backgroundOutput 'MODEL=gpt-5.6-sol[1m]'
Assert-ContainsLine $backgroundOutput 'ARG=medium'

$overrideOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('bg', '--effort', 'high', '-p', 'test')).Output
Assert-DoesNotContainLine $overrideOutput 'ARG=medium'
Assert-ContainsLine $overrideOutput 'ARG=high'

$terraOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('terra', '-p', 'test')).Output
Assert-ContainsLine $terraOutput 'MODEL=gpt-5.6-terra[1m]'

# Every documented alias and canonical model ID routes to the intended model.
$modelCases = @(
    @{ Argument = 'sol'; ExpectedModel = 'gpt-5.6-sol[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'sol-fast'; ExpectedModel = 'gpt-5.6-sol-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'terra'; ExpectedModel = 'gpt-5.6-terra[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'terra-fast'; ExpectedModel = 'gpt-5.6-terra-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'luna'; ExpectedModel = 'gpt-5.6-luna[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'luna-fast'; ExpectedModel = 'gpt-5.6-luna-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.5'; ExpectedModel = 'gpt-5.5[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.5-fast'; ExpectedModel = 'gpt-5.5-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.4'; ExpectedModel = 'gpt-5.4[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.4-fast'; ExpectedModel = 'gpt-5.4-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'mini'; ExpectedModel = 'gpt-5.4-mini[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'mini-fast'; ExpectedModel = 'gpt-5.4-mini-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.3'; ExpectedModel = 'gpt-5.3-codex[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.3-fast'; ExpectedModel = 'gpt-5.3-codex-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'spark'; ExpectedModel = 'gpt-5.3-codex-spark'; ExpectedContext = '128000' },
    @{ Argument = 'spark-fast'; ExpectedModel = 'gpt-5.3-codex-spark-fast'; ExpectedContext = '128000' },
    @{ Argument = '5.2'; ExpectedModel = 'gpt-5.2[1m]'; ExpectedContext = '272000' },
    @{ Argument = '5.2-fast'; ExpectedModel = 'gpt-5.2-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-sol'; ExpectedModel = 'gpt-5.6-sol[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-sol-fast'; ExpectedModel = 'gpt-5.6-sol-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-terra'; ExpectedModel = 'gpt-5.6-terra[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-terra-fast'; ExpectedModel = 'gpt-5.6-terra-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-luna'; ExpectedModel = 'gpt-5.6-luna[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.6-luna-fast'; ExpectedModel = 'gpt-5.6-luna-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.5'; ExpectedModel = 'gpt-5.5[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.5-fast'; ExpectedModel = 'gpt-5.5-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.4'; ExpectedModel = 'gpt-5.4[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.4-fast'; ExpectedModel = 'gpt-5.4-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.4-mini'; ExpectedModel = 'gpt-5.4-mini[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.4-mini-fast'; ExpectedModel = 'gpt-5.4-mini-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.3-codex'; ExpectedModel = 'gpt-5.3-codex[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.3-codex-fast'; ExpectedModel = 'gpt-5.3-codex-fast[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.3-codex-spark'; ExpectedModel = 'gpt-5.3-codex-spark'; ExpectedContext = '128000' },
    @{ Argument = 'gpt-5.3-codex-spark-fast'; ExpectedModel = 'gpt-5.3-codex-spark-fast'; ExpectedContext = '128000' },
    @{ Argument = 'gpt-5.2'; ExpectedModel = 'gpt-5.2[1m]'; ExpectedContext = '272000' },
    @{ Argument = 'gpt-5.2-fast'; ExpectedModel = 'gpt-5.2-fast[1m]'; ExpectedContext = '272000' }
)
foreach ($modelCase in $modelCases) {
    $modelOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @($modelCase.Argument, '-p', 'test')).Output
    Assert-ContainsLine $modelOutput "MODEL=$($modelCase.ExpectedModel)"
    Assert-ContainsLine $modelOutput "COMPACT_WINDOW=$($modelCase.ExpectedContext)"
}

$modelOptionOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('--model', 'luna', '-p', 'test')).Output
Assert-ContainsLine $modelOptionOutput 'MODEL=gpt-5.6-luna[1m]'
$shortModelOptionOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('-m', '5.2', '-p', 'test')).Output
Assert-ContainsLine $shortModelOptionOutput 'MODEL=gpt-5.2[1m]'

$invalidEffortResult = Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_MAIN_EFFORT = 'unsupported' }) -Arguments @('-p', 'test') -AllowFailure
if ($invalidEffortResult.ExitCode -eq 0) {
    throw 'test: unsupported configured effort was accepted'
}

$ultracodeOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_MAIN_EFFORT = 'ultracode' }) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $ultracodeOutput 'ARG=ultracode'

$soloOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('solo', '-p', 'test')).Output
Assert-ContainsLine $soloOutput 'ARG=--disallowedTools'
Assert-ContainsLine $soloOutput 'ARG=Agent'

$guardOverrideOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
    CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = '7'
}) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $guardOverrideOutput 'MAX_CONCURRENT_SUBAGENTS=7'

$guardsDisabledOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
    CCX_SUBAGENT_GUARDS = '0'
}) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $guardsDisabledOutput 'MAX_CONCURRENT_SUBAGENTS=unset'
Assert-ContainsLine $guardsDisabledOutput 'MAX_SUBAGENTS_PER_SESSION=unset'
Assert-ContainsLine $guardsDisabledOutput 'MAX_SUBAGENT_SPAWN_DEPTH=unset'
Assert-ContainsLine $guardsDisabledOutput 'MAX_RETRIES=unset'
Assert-ContainsLine $guardsDisabledOutput 'API_TIMEOUT_MS=unset'

$invalidGuardResult = Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
    CCX_MAX_CONCURRENT_SUBAGENTS = 'invalid'
}) -Arguments @('-p', 'test') -AllowFailure
if ($invalidGuardResult.ExitCode -eq 0) {
    throw 'test: invalid subagent concurrency cap was accepted'
}

$configuredOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_CONFIG_FILE = $customConfig }) -Arguments @('-p', 'test')).Output
Assert-ContainsLine $configuredOutput 'MODEL=gpt-5.6-terra[1m]'
Assert-ContainsLine $configuredOutput 'SMALL_FAST=gpt-5.4-mini[1m]'
Assert-ContainsLine $configuredOutput 'ARG=high'
Assert-ContainsLine $configuredOutput 'COMPACT_WINDOW=200000'
Assert-ContainsLine $configuredOutput 'MAX_CONCURRENT_SUBAGENTS=2'
Assert-ContainsLine $configuredOutput 'MAX_SUBAGENTS_PER_SESSION=9'
Assert-ContainsLine $configuredOutput 'MAX_SUBAGENT_SPAWN_DEPTH=1'
Assert-ContainsLine $configuredOutput 'MAX_RETRIES=2'
Assert-ContainsLine $configuredOutput 'API_TIMEOUT_MS=240000'

$configuredBgOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_CONFIG_FILE = $customConfig }) -Arguments @('bg', '-p', 'test')).Output
Assert-ContainsLine $configuredBgOutput 'MODEL=gpt-5.6-luna[1m]'
Assert-ContainsLine $configuredBgOutput 'ARG=low'

$configOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_CONFIG_FILE = $customConfig }) -Arguments @('config')).Output
Assert-ContainsLine $configOutput 'Main model: terra'
Assert-ContainsLine $configOutput 'Background effort: low'
Assert-ContainsLine $configOutput 'Proxy Codex transport: auto'

$invalidTransportResult = Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
    CCX_PROXY_TRANSPORT = 'invalid'
}) -Arguments @('-p', 'test') -AllowFailure
if ($invalidTransportResult.ExitCode -eq 0) {
    throw 'test: invalid proxy transport was accepted'
}

# Windows-specific: a .ps1 target is dispatched directly, not through cmd.exe.
$ps1DispatchOutput = (Invoke-Ccx -Environment (New-TestEnvironment) -Arguments @('-p', 'ps1-dispatch')).Output
Assert-ContainsLine $ps1DispatchOutput 'ARG=ps1-dispatch'

# Windows-specific: the command shim preserves one quoted argument verbatim.
$cmdOutput = Invoke-CcxCmd -Environment (New-TestEnvironment)
Assert-ContainsLine $cmdOutput 'ARG=hello world'

# An explicit Claude Code effort must take precedence over a configured launcher effort.
$explicitEffortOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_MAIN_EFFORT = 'low' }) -Arguments @('--effort=max', '-p', 'test')).Output
Assert-DoesNotContainLine $explicitEffortOutput 'ARG=low'
Assert-ContainsLine $explicitEffortOutput 'ARG=--effort=max'

# Windows config-path precedence: file, directory, XDG, then APPDATA.
$configRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccx-config-precedence-$PID-$([Guid]::NewGuid().ToString('N'))")
$configDirectory = Join-Path $configRoot 'configured-dir'
$xdgDirectory = Join-Path $configRoot 'xdg'
$appDataDirectory = Join-Path $configRoot 'appdata'
New-Item -ItemType Directory -Path $configDirectory, (Join-Path $xdgDirectory 'claudex'), (Join-Path $appDataDirectory 'claudex') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $configDirectory 'config'), 'CCX_MODEL=luna')
[IO.File]::WriteAllText((Join-Path $xdgDirectory 'claudex\config'), 'CCX_MODEL=terra')
[IO.File]::WriteAllText((Join-Path $appDataDirectory 'claudex\config'), 'CCX_MODEL=5.4')
try {
    $configDirOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
        CCX_CONFIG_FILE = $null; CCX_CONFIG_DIR = $configDirectory; XDG_CONFIG_HOME = $xdgDirectory; APPDATA = $appDataDirectory
    }) -Arguments @('-p', 'test')).Output
    Assert-ContainsLine $configDirOutput 'MODEL=gpt-5.6-luna[1m]'

    $xdgOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
        CCX_CONFIG_FILE = $null; CCX_CONFIG_DIR = $null; XDG_CONFIG_HOME = $xdgDirectory; APPDATA = $appDataDirectory
    }) -Arguments @('-p', 'test')).Output
    Assert-ContainsLine $xdgOutput 'MODEL=gpt-5.6-terra[1m]'

    $appDataOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
        CCX_CONFIG_FILE = $null; CCX_CONFIG_DIR = $null; XDG_CONFIG_HOME = $null; APPDATA = $appDataDirectory
    }) -Arguments @('-p', 'test')).Output
    Assert-ContainsLine $appDataOutput 'MODEL=gpt-5.4[1m]'
}
finally {
    Remove-Item -LiteralPath $configRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Native argument marshalling edge cases: embedded double quotes, an
# empty-string argument, and arguments ending in a trailing backslash must
# reach the child process byte-for-byte. These call ConvertTo-NativeArgument
# / New-CcxProcessStartInfo / Invoke-CcxProcess directly (by dot-sourcing just
# the function definitions out of bin\ccx.ps1, stopping before its main
# execution block) instead of routing through Invoke-Ccx, because PowerShell
# 5.1's own native-argument relay used by Invoke-Ccx (`& powershell.exe
# @Arguments`) silently mangles embedded quotes and drops empty-string
# arguments before they ever reach the launcher -- a limitation of that outer
# hop, unrelated to the launcher helpers under test here.
$launcherRawText = [IO.File]::ReadAllText($launcher)
$mainBlockMatch = [regex]::Match($launcherRawText, '(?m)^try \{')
if (-not $mainBlockMatch.Success) {
    throw 'test: could not locate the launcher main execution block marker for function extraction'
}
$launcherFunctionsOnly = $launcherRawText.Substring(0, $mainBlockMatch.Index)
$launcherFunctionsFile = Join-Path ([IO.Path]::GetTempPath()) ("ccx-functions-$PID-$([Guid]::NewGuid().ToString('N')).ps1")
[IO.File]::WriteAllText($launcherFunctionsFile, $launcherFunctionsOnly)
try {
    . $launcherFunctionsFile
}
finally {
    Remove-Item -LiteralPath $launcherFunctionsFile -Force -ErrorAction SilentlyContinue
}

$nativeArgumentCases = @(
    'plain-anchor',
    'value with "embedded" and "double" quotes',
    '',
    'C:\no-space-trailing-backslash\',
    'C:\has space trailing backslash\'
)
$nativeArgumentResult = Invoke-CcxProcess -Path $stub -Arguments $nativeArgumentCases -CaptureOutput
Assert-Equal 0 $nativeArgumentResult.ExitCode 'native-argument stub exit code'
$nativeArgumentLines = @(($nativeArgumentResult.StandardOutput -split "`r?`n") | Where-Object { $_ -like 'ARG=*' })
if ($nativeArgumentLines.Count -ne $nativeArgumentCases.Count) {
    throw "Expected $($nativeArgumentCases.Count) ARG lines from the native-argument stub, got $($nativeArgumentLines.Count):`n$($nativeArgumentResult.StandardOutput)"
}
for ($index = 0; $index -lt $nativeArgumentCases.Count; $index++) {
    Assert-Equal "ARG=$($nativeArgumentCases[$index])" $nativeArgumentLines[$index] "native argument #$index round-trip"
}

# Windows-specific: a claude executable resolved to a path containing a space
# (both a directory and the file name itself) must still be quoted and
# invoked correctly by New-CcxProcessStartInfo/Invoke-CcxProcess.
$spacedStubRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccx spaced dir $PID $([Guid]::NewGuid().ToString('N'))")
$spacedStubDirectory = Join-Path $spacedStubRoot 'nested folder'
New-Item -ItemType Directory -Path $spacedStubDirectory -Force | Out-Null
$spacedStubPath = Join-Path $spacedStubDirectory 'stub claude.ps1'
Copy-Item -LiteralPath $stub -Destination $spacedStubPath -Force
try {
    $spacedStubOutput = (Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{ CCX_REAL_CLAUDE = $spacedStubPath }) -Arguments @('-p', 'test')).Output
    Assert-ContainsLine $spacedStubOutput 'MODEL=gpt-5.6-sol[1m]'
    Assert-ContainsLine $spacedStubOutput 'ARG=test'
}
finally {
    Remove-Item -LiteralPath $spacedStubRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# CCP_BIND_ADDRESS/PORT pinning: Start-Proxy must always launch
# claude-code-proxy bound to loopback on the port parsed from CCX_PROXY_URL,
# ignoring whatever ambient CCP_BIND_ADDRESS/PORT values happen to already be
# set in the environment. A stub claude-code-proxy.ps1 records the
# environment it actually received; its directory is added to PATH only for
# this single overridden test-process invocation (restored immediately after
# by Invoke-Ccx's existing Set-TestEnvironment/Restore-TestEnvironment pair).
$proxyStubDirectory = Join-Path ([IO.Path]::GetTempPath()) ("ccx-proxy-stub-$PID-$([Guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $proxyStubDirectory -Force | Out-Null
$proxyStubPath = Join-Path $proxyStubDirectory 'claude-code-proxy.ps1'
$proxyCaptureFile = Join-Path ([IO.Path]::GetTempPath()) ("ccx-proxy-capture-$PID-$([Guid]::NewGuid().ToString('N')).txt")
$proxyStubScript = @'
$ErrorActionPreference = 'Stop'
$lines = @()
$lines += "BIND=$($env:CCP_BIND_ADDRESS)"
$lines += "TRANSPORT=$($env:CCP_CODEX_TRANSPORT)"
$lines += "PORT=$($env:PORT)"
foreach ($argument in $args) {
    $lines += "ARG=$argument"
}
[IO.File]::WriteAllLines($env:CCX_TEST_PROXY_CAPTURE_FILE, $lines)
'@
[IO.File]::WriteAllText($proxyStubPath, $proxyStubScript)

try {
    $pinningResult = Invoke-Ccx -Environment (Merge-Environment (New-TestEnvironment) @{
        CCX_SKIP_HEALTH_CHECK = $null
        CCX_PROXY_URL = 'http://127.0.0.1:18744'
        CCX_SHIM_URL = $null
        CCX_TEST_PROXY_CAPTURE_FILE = $proxyCaptureFile
        CCP_BIND_ADDRESS = '0.0.0.0'
        PORT = '9999'
        PATH = "$proxyStubDirectory;$env:PATH"
    }) -Arguments @('-p', 'test') -AllowFailure

    if (-not (Test-Path -LiteralPath $proxyCaptureFile)) {
        throw "test: stub claude-code-proxy was never invoked (no capture file produced). Launcher output:`n$($pinningResult.Output)"
    }
    $proxyCaptureContent = [IO.File]::ReadAllText($proxyCaptureFile)
    Assert-ContainsLine $proxyCaptureContent 'BIND=127.0.0.1'
    Assert-ContainsLine $proxyCaptureContent 'TRANSPORT=http'
    Assert-ContainsLine $proxyCaptureContent 'PORT=18744'
}
finally {
    Remove-Item -LiteralPath $proxyStubDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $proxyCaptureFile -Force -ErrorAction SilentlyContinue
}

Write-Output 'All ccx launcher tests passed.'
exit 0
