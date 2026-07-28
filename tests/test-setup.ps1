$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$setup = Join-Path $repoRoot 'scripts\setup.ps1'
$launcher = Join-Path $repoRoot 'bin\ccx.ps1'
$stub = Join-Path $PSScriptRoot 'stub-claude.ps1'
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("claudex-setup-test-$PID-$([Guid]::NewGuid().ToString('N'))")
$configDir = Join-Path $testRoot 'config'
$configFile = Join-Path $configDir 'config'

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

function Assert-FileContainsLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (([IO.File]::ReadAllLines($Path)) -cnotcontains $Line) {
        throw "Expected config line '$Line' was not present in $Path"
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

# Every CCX_*/ANTHROPIC_* variable is cleared for each child process. This is
# a safety requirement, not a tidiness one: setup.ps1 resolves its config
# target as CCX_CONFIG_FILE -> CCX_CONFIG_DIR -> XDG_CONFIG_HOME\claudex ->
# %APPDATA%\Claudex, so an ambient CCX_CONFIG_FILE on the host running this
# suite would outrank the CCX_CONFIG_DIR set below and make the real
# setup.ps1 back up and rewrite the user's actual configuration file.
$ambientNamesToClear = @(
    'CCX_CONFIG_FILE', 'CCX_CONFIG_DIR', 'CCX_CONFIG_SOURCE', 'CCX_INSTALL_DIR',
    'CCX_AGENT_DIR', 'CCX_SUBAGENT_EFFORT', 'CCX_MODEL', 'CCX_MAIN_EFFORT',
    'CCX_BG_MODEL', 'CCX_BG_EFFORT', 'CCX_BACKGROUND_MODEL',
    'CCX_BACKGROUND_EFFORT', 'CCX_SMALL_FAST_MODEL', 'CCX_CONTEXT_WINDOW',
    'CCX_PROXY_URL', 'CCX_SHIM_URL', 'CCX_REAL_CLAUDE', 'CCX_SKIP_HEALTH_CHECK',
    'CLAUDE_CODE_EFFORT_LEVEL', 'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL',
    'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'XDG_CONFIG_HOME'
)

function New-CleanEnvironment {
    $environment = @{}
    foreach ($name in $ambientNamesToClear) {
        $environment[$name] = $null
    }
    return $environment
}

try {
    $setupEnvironment = New-CleanEnvironment
    $setupEnvironment['CCX_CONFIG_DIR'] = $configDir
    Invoke-PowerShellFile -Path $setup -Environment $setupEnvironment -Arguments @(
        '-MainModel', 'terra',
        '-MainEffort', 'high',
        '-BgModel', 'sol',
        '-BgEffort', 'medium',
        '-UtilityModel', 'mini',
        '-SubagentEffort', 'xhigh',
        '-WithAgent',
        '-NoLogin',
        '-NoService',
        '-ConfigOnly',
        '-Yes'
    ) | Out-Null

    Assert-FileContainsLine $configFile 'CCX_MODEL=terra'
    Assert-FileContainsLine $configFile 'CCX_MAIN_EFFORT=high'
    Assert-FileContainsLine $configFile 'CCX_BG_MODEL=sol'
    Assert-FileContainsLine $configFile 'CCX_BG_EFFORT=medium'
    Assert-FileContainsLine $configFile 'CCX_SMALL_FAST_MODEL=gpt-5.4-mini[1m]'
    Assert-FileContainsLine $configFile 'CCX_SUBAGENT_EFFORT=xhigh'
    Assert-FileContainsLine $configFile 'CCX_PROXY_URL=http://127.0.0.1:18765'

    $launcherEnvironment = @{}
    foreach ($name in @(
        'CCX_CONFIG_FILE', 'CCX_CONFIG_DIR', 'CCX_MODEL', 'CCX_MAIN_EFFORT',
        'CCX_BG_MODEL', 'CCX_BG_EFFORT', 'CCX_BACKGROUND_MODEL',
        'CCX_BACKGROUND_EFFORT', 'CCX_SMALL_FAST_MODEL', 'CCX_CONTEXT_WINDOW',
        'CCX_PROXY_URL', 'CCX_SHIM_URL', 'CCX_REAL_CLAUDE',
        'CCX_SKIP_HEALTH_CHECK', 'CLAUDE_CODE_EFFORT_LEVEL', 'ANTHROPIC_MODEL',
        'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_BASE_URL',
        'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
    )) {
        $launcherEnvironment[$name] = $null
    }
    $launcherEnvironment['CCX_CONFIG_FILE'] = $configFile
    $launcherEnvironment['CCX_REAL_CLAUDE'] = $stub
    $launcherEnvironment['CCX_SKIP_HEALTH_CHECK'] = '1'

    $launcherOutput = (Invoke-PowerShellFile -Path $launcher -Environment $launcherEnvironment -Arguments @('-p', 'test')).Output
    Assert-OutputContainsLine $launcherOutput 'MODEL=gpt-5.6-terra[1m]'
    Assert-OutputContainsLine $launcherOutput 'SMALL_FAST=gpt-5.4-mini[1m]'
    Assert-OutputContainsLine $launcherOutput 'ARG=high'

    Invoke-PowerShellFile -Path $setup -Environment $setupEnvironment -Arguments @(
        '-MainModel', 'luna',
        '-MainEffort', 'xhigh',
        '-BgModel', 'sol',
        '-BgEffort', 'medium',
        '-UtilityModel', 'sol',
        '-SubagentEffort', 'high',
        '-WithoutAgent',
        '-NoLogin',
        '-NoService',
        '-ConfigOnly',
        '-Yes'
    ) | Out-Null

    Assert-FileContainsLine $configFile 'CCX_MODEL=luna'
    $backupCount = @([IO.Directory]::GetFiles($configDir, 'config.backup-*')).Count
    if ($backupCount -ne 1) {
        throw "Expected exactly one config backup, found $backupCount"
    }

    $beforeInvalid = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
    $invalidResult = Invoke-PowerShellFile -Path $setup -Environment $setupEnvironment -Arguments @(
        '-MainEffort', 'impossible',
        '-ConfigOnly',
        '-Yes'
    ) -AllowFailure
    if ($invalidResult.ExitCode -eq 0) {
        throw 'Invalid effort unexpectedly succeeded'
    }

    $afterInvalid = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
    if ($beforeInvalid -cne $afterInvalid) {
        throw 'Invalid effort changed the existing configuration'
    }

    $backupCount = @([IO.Directory]::GetFiles($configDir, 'config.backup-*')).Count
    if ($backupCount -ne 1) {
        throw "Expected invalid input to leave one config backup, found $backupCount"
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All setup wizard tests passed.'
