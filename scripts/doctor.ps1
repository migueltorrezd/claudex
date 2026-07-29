# PowerShell 5.1 diagnostics for Claudex. This script never makes a live model request.
[CmdletBinding()]
param(
    # A stopped/absent background proxy service is an expected, supported
    # configuration in -NoService mode. When set, the proxy-health check
    # below does not count as a failure solely because the proxy is
    # unreachable; every other check still runs and still counts. Codex
    # OAuth status is a local token-file check ("claude-code-proxy codex
    # auth status") that does not require a running proxy, so it is never
    # exempted by -NoService.
    [switch]$NoService
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'version.ps1')

$script:failures = 0

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Output "PASS  $Message"
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Output "FAIL  $Message"
    $script:failures++
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Output "INFO  $Message"
}

function Get-ExternalCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($command in @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -eq 'Application' -or $command.CommandType -eq 'ExternalScript') {
            foreach ($path in @($command.Path, $command.Source, $command.Definition)) {
                if ($null -ne $path -and [string]$path -ne '') {
                    return [string]$path
                }
            }
        }
    }

    return ''
}

function Get-VersionLine {
    param([Parameter(Mandatory = $true)][string]$CommandPath)

    try {
        $output = @(& $CommandPath --version 2>$null)
        if ($output.Count -gt 0) {
            return [string]$output[0]
        }
    }
    catch {
        # Command discovery succeeded; keep the version detail empty, as doctor.sh does.
    }

    return ''
}

function Test-CodexAuth {
    param([Parameter(Mandatory = $true)][string]$ProxyPath)

    try {
        $global:LASTEXITCODE = 0
        & $ProxyPath codex auth status *> $null
        $commandSucceeded = $?
        $exitCode = $LASTEXITCODE
        return ($commandSucceeded -and ($null -eq $exitCode -or $exitCode -eq 0))
    }
    catch {
        return $false
    }
}

function Test-ProxyHealth {
    param(
        [Parameter(Mandatory = $true)][string]$HealthUrl,
        [int]$TimeoutSeconds = 2
    )

    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Get-CcxConfigFilePath {
    # Mirrors the canonical precedence used by bin/ccx.ps1 (Get-ConfigFile)
    # and scripts/setup.ps1 (Invoke-Setup config target resolution):
    # CCX_CONFIG_FILE -> CCX_CONFIG_DIR\config -> XDG_CONFIG_HOME\claudex\config
    # -> %APPDATA%\Claudex\config.
    if ($env:CCX_CONFIG_FILE) {
        return $env:CCX_CONFIG_FILE
    }

    if ($env:CCX_CONFIG_DIR) {
        return (Join-Path $env:CCX_CONFIG_DIR 'config')
    }

    if ($env:XDG_CONFIG_HOME) {
        return (Join-Path $env:XDG_CONFIG_HOME 'claudex\config')
    }

    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }
    return (Join-Path $appData 'Claudex\config')
}

function Get-CcxConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$WantedKey
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return ''
    }

    # Parse plain key=value text without executing or dot-sourcing it, same
    # as scripts/setup.ps1's Get-ConfigValue and bin/ccx.ps1's config loader.
    $value = ''
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        if ($key -ceq $WantedKey) {
            $value = $line.Substring($separator + 1).Trim()
        }
    }

    return $value
}

$claudePath = Get-ExternalCommandPath 'claude'
if ($claudePath) {
    $claudeVersion = Get-CcxCommandVersion $claudePath
    if (Test-CcxVersionAtLeast $claudeVersion $script:CcxMinimumClaudeVersion) {
        Write-Pass "Claude Code: $claudeVersion"
    }
    else {
        Write-Fail "Claude Code $($script:CcxMinimumClaudeVersion) or newer is required; found $(if ($claudeVersion) { $claudeVersion } else { 'unknown' })"
    }
}
else {
    Write-Fail 'Claude Code is not on PATH'
}

$proxyPath = Get-ExternalCommandPath 'claude-code-proxy'
if ($proxyPath) {
    $proxyVersion = Get-CcxCommandVersion $proxyPath
    if (Test-CcxVersionAtLeast $proxyVersion $script:CcxMinimumProxyVersion) {
        Write-Pass "Proxy: $proxyVersion"
    }
    else {
        Write-Fail "claude-code-proxy $($script:CcxMinimumProxyVersion) or newer is required; found $(if ($proxyVersion) { $proxyVersion } else { 'unknown' })"
    }
}
else {
    Write-Fail 'claude-code-proxy is not on PATH'
}

$configFilePath = Get-CcxConfigFilePath
$configProxyUrl = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_PROXY_URL'
if ($env:CCX_PROXY_URL) {
    $proxyUrl = $env:CCX_PROXY_URL
}
elseif ($configProxyUrl) {
    $proxyUrl = $configProxyUrl
}
else {
    $proxyUrl = 'http://127.0.0.1:18765'
}
$proxyTransport = if ($env:CCX_PROXY_TRANSPORT) {
    $env:CCX_PROXY_TRANSPORT
}
else {
    $configuredTransport = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_PROXY_TRANSPORT'
    if ($configuredTransport) { $configuredTransport } else { 'http' }
}
$subagentGuards = if ($env:CCX_SUBAGENT_GUARDS) {
    $env:CCX_SUBAGENT_GUARDS
}
else {
    $configuredGuards = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_SUBAGENT_GUARDS'
    if ($configuredGuards) { $configuredGuards } else { '1' }
}
$maxConcurrentSubagents = $env:CCX_MAX_CONCURRENT_SUBAGENTS
if (-not $maxConcurrentSubagents) {
    $maxConcurrentSubagents = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_MAX_CONCURRENT_SUBAGENTS'
}
if (-not $maxConcurrentSubagents) { $maxConcurrentSubagents = '3' }
$maxSubagentsPerSession = $env:CCX_MAX_SUBAGENTS_PER_SESSION
if (-not $maxSubagentsPerSession) {
    $maxSubagentsPerSession = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_MAX_SUBAGENTS_PER_SESSION'
}
if (-not $maxSubagentsPerSession) { $maxSubagentsPerSession = '12' }
$maxSubagentSpawnDepth = $env:CCX_MAX_SUBAGENT_SPAWN_DEPTH
if (-not $maxSubagentSpawnDepth) {
    $maxSubagentSpawnDepth = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_MAX_SUBAGENT_SPAWN_DEPTH'
}
if (-not $maxSubagentSpawnDepth) { $maxSubagentSpawnDepth = '1' }
$maxRetries = $env:CCX_MAX_RETRIES
if (-not $maxRetries) {
    $maxRetries = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_MAX_RETRIES'
}
if (-not $maxRetries) { $maxRetries = '3' }
$apiTimeoutMs = $env:CCX_API_TIMEOUT_MS
if (-not $apiTimeoutMs) {
    $apiTimeoutMs = Get-CcxConfigValue -ConfigPath $configFilePath -WantedKey 'CCX_API_TIMEOUT_MS'
}
if (-not $apiTimeoutMs) { $apiTimeoutMs = '300000' }

if ($proxyTransport -cnotin @('http', 'websocket', 'auto')) {
    Write-Fail "Proxy transport is invalid: $proxyTransport"
}
else {
    Write-Info "Proxy Codex transport: $proxyTransport"
}
if ($subagentGuards -cnotin @('0', '1')) {
    Write-Fail "Subagent guard toggle is invalid: $subagentGuards"
}
else {
    Write-Info "Subagent guards: $subagentGuards; concurrent=$maxConcurrentSubagents; total=$maxSubagentsPerSession; depth=$maxSubagentSpawnDepth"
}
foreach ($limit in @(
    @{ Name = 'CCX_MAX_CONCURRENT_SUBAGENTS'; Value = $maxConcurrentSubagents },
    @{ Name = 'CCX_MAX_SUBAGENTS_PER_SESSION'; Value = $maxSubagentsPerSession },
    @{ Name = 'CCX_MAX_SUBAGENT_SPAWN_DEPTH'; Value = $maxSubagentSpawnDepth },
    @{ Name = 'CCX_MAX_RETRIES'; Value = $maxRetries },
    @{ Name = 'CCX_API_TIMEOUT_MS'; Value = $apiTimeoutMs }
)) {
    $limitName = [string]$limit['Name']
    $limitValue = [string]$limit['Value']
    if ($limitValue -notmatch '^[1-9][0-9]*$') {
        Write-Fail "$limitName must be a positive integer; found $limitValue"
    }
}
Write-Info "Request limits: retries=$maxRetries; timeout=${apiTimeoutMs}ms"
$healthUrl = "$($proxyUrl.TrimEnd('/'))/healthz"
$proxyHealthy = Test-ProxyHealth -HealthUrl $healthUrl

if ($proxyPath -and (Test-CodexAuth $proxyPath)) {
    Write-Pass 'Codex OAuth is configured'
}
else {
    # This is a local token-file check ("claude-code-proxy codex auth
    # status"); it does not require a running proxy, so -NoService does not
    # exempt it (unlike the proxy-health check below).
    Write-Fail 'Codex OAuth is missing or expired'
}

if ($proxyHealthy) {
    Write-Pass "Proxy health: $healthUrl"
}
elseif ($NoService.IsPresent) {
    Write-Info "Proxy health: $healthUrl (proxy is not running; expected with -NoService)"
}
else {
    Write-Fail "Proxy health: $healthUrl"
}

$launcherPath = Get-ExternalCommandPath 'ccx'
if ($launcherPath) {
    Write-Pass "Launcher: $launcherPath"

    $inspectionPath = $launcherPath
    if ([IO.Path]::GetExtension($launcherPath) -in @('.cmd', '.bat')) {
        $launcherDir = Split-Path -Parent $launcherPath
        $companionCandidates = @(
            [IO.Path]::ChangeExtension($launcherPath, '.ps1'),
            (Join-Path $launcherDir 'lib\ccx.ps1')
        )
        foreach ($companionScript in $companionCandidates) {
            if (Test-Path -LiteralPath $companionScript -PathType Leaf) {
                $inspectionPath = $companionScript
                break
            }
        }
    }

    $hasPersistentConfig = $false
    if (Test-Path -LiteralPath $inspectionPath -PathType Leaf) {
        try {
            $hasPersistentConfig = [bool](Select-String -LiteralPath $inspectionPath -SimpleMatch 'CCX_CONFIG_FILE' -Quiet -ErrorAction Stop)
        }
        catch {
            $hasPersistentConfig = $false
        }
    }

    if ($hasPersistentConfig) {
        try {
            foreach ($configLine in @(& $launcherPath config 2>$null)) {
                Write-Info ([string]$configLine)
            }
        }
        catch {
            # The launcher itself was found; its config output is supplemental.
        }
    }
    else {
        Write-Info 'Installed launcher predates persistent Claudex configuration'
    }
}
else {
    Write-Fail 'ccx is not on PATH; open a new terminal or add %LOCALAPPDATA%\Claudex\bin to User PATH'
}

$taskName = 'Claudex Proxy'
$scheduledTaskCommand = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
if ($null -eq $scheduledTaskCommand) {
    Write-Fail "Scheduled Task inspection is unavailable for '$taskName'"
}
else {
    $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        Write-Info "Scheduled Task '$taskName' was not found; a manually started proxy may still be healthy"
    }
    else {
        $taskState = [string]$tasks[0].State
        if ($taskState -eq 'Running') {
            Write-Pass "Scheduled Task '$taskName' is running"
        }
        elseif ($proxyHealthy) {
            Write-Info "Scheduled Task '$taskName' state: $taskState; another healthy service manager is active"
        }
        else {
            Write-Fail "Scheduled Task '$taskName' state: $taskState"
        }
    }
}

$agentDirectory = if ($env:CCX_AGENT_DIR) { $env:CCX_AGENT_DIR } else { Join-Path $HOME '.claude\agents' }
$agentFile = Join-Path $agentDirectory 'claudex-worker.md'
if (Test-Path -LiteralPath $agentFile -PathType Leaf) {
    $agentEffort = ''
    foreach ($line in [IO.File]::ReadLines($agentFile)) {
        if ($line -match '^effort:\s*(.*)$') {
            $agentEffort = $Matches[1].Trim()
            break
        }
    }

    if (-not $agentEffort) {
        $agentEffort = 'unknown'
    }
    Write-Pass "Custom claudex-worker effort: $agentEffort"
}
else {
    Write-Info 'Optional claudex-worker is not installed'
}

if ($script:failures -gt 0) {
    [Console]::Error.WriteLine("`nDoctor found $($script:failures) problem(s).")
    exit 1
}

Write-Output "`nClaudex is ready. No live model request was made."
# Explicit exit code: internal native-command invocations (e.g. the stub/real
# proxy binary's "codex auth status") can leave a nonzero $LASTEXITCODE even
# on a check that intentionally did not count as a failure (-NoService).
# Without this, the script's own exit code would inherit that stale value.
exit 0
