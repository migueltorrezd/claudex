# Managed by https://github.com/migueltorrezd/claudex
# PowerShell 5.1 launcher for Claude Code through claude-code-proxy.
$ErrorActionPreference = 'Stop'

function Stop-Ccx {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 1
    )

    $exception = New-Object System.Exception $Message
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Get-FirstNonEmpty {
    param([object[]]$Values)

    foreach ($value in $Values) {
        if ($null -ne $value -and [string]$value -ne '') {
            return [string]$value
        }
    }

    return ''
}

function Get-ConfigFile {
    if ($env:CCX_CONFIG_FILE) {
        return $env:CCX_CONFIG_FILE
    }

    if ($env:CCX_CONFIG_DIR) {
        return (Join-Path $env:CCX_CONFIG_DIR 'config')
    }

    if ($env:XDG_CONFIG_HOME) {
        return (Join-Path $env:XDG_CONFIG_HOME 'claudex\config')
    }

    $appData = Get-FirstNonEmpty @($env:APPDATA, [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData))
    return (Join-Path $appData 'claudex\config')
}

function Get-ExternalCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($command in @(Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -eq 'Application' -or $command.CommandType -eq 'ExternalScript') {
            $path = Get-FirstNonEmpty @($command.Path, $command.Source, $command.Definition)
            if ($path) {
                return $path
            }
        }
    }

    return ''
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            for ($index = 0; $index -lt (($backslashes * 2) + 1); $index++) {
                [void]$builder.Append('\')
            }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        for ($index = 0; $index -lt $backslashes; $index++) {
            [void]$builder.Append('\')
        }
        $backslashes = 0
        [void]$builder.Append($character)
    }

    for ($index = 0; $index -lt ($backslashes * 2); $index++) {
        [void]$builder.Append('\')
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-PowerShellHostPath {
    try {
        $currentHost = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($currentHost -and (Test-Path -LiteralPath $currentHost -PathType Leaf)) {
            return $currentHost
        }
    }
    catch {
        # Fall through to the edition-specific executable name.
    }

    $hostName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $hostPath = Join-Path $PSHOME $hostName
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        Stop-Ccx "ccx: PowerShell host is unavailable: $hostPath"
    }
    return $hostPath
}

function New-CcxProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [switch]$CaptureOutput,
        [switch]$Hidden
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -ceq '.ps1') {
        $executable = Get-PowerShellHostPath
        $processArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
        $argumentLine = (($processArguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
    }
    elseif ($extension -ceq '.cmd' -or $extension -ceq '.bat') {
        $executable = Get-FirstNonEmpty @($env:ComSpec, (Join-Path $env:SystemRoot 'System32\cmd.exe'))
        $commandLine = ((@($Path) + $Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
        $argumentLine = '/d /s /c "' + $commandLine + '"'
    }
    else {
        $executable = $Path
        $argumentLine = (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $CaptureOutput.IsPresent
    $startInfo.RedirectStandardError = $CaptureOutput.IsPresent
    $startInfo.CreateNoWindow = $Hidden.IsPresent
    if ($Hidden.IsPresent) {
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    }

    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            $startInfo.EnvironmentVariables.Remove([string]$key)
        }
        else {
            $startInfo.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
        }
    }

    return $startInfo
}

function Invoke-CcxProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [switch]$CaptureOutput,
        [switch]$Hidden,
        [switch]$NoWait
    )

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-CcxProcessStartInfo `
        -Path $Path `
        -Arguments $Arguments `
        -Environment $Environment `
        -CaptureOutput:$CaptureOutput `
        -Hidden:$Hidden
    try {
        if (-not $process.Start()) {
            Stop-Ccx "ccx: failed to start $Path"
        }
        if ($NoWait.IsPresent) {
            return [PSCustomObject]@{ ExitCode = $null; StandardOutput = ''; StandardError = '' }
        }

        if ($CaptureOutput.IsPresent) {
            $standardOutput = $process.StandardOutput.ReadToEnd()
            $standardError = $process.StandardError.ReadToEnd()
        }
        else {
            $standardOutput = ''
            $standardError = ''
        }
        $process.WaitForExit()
        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            StandardOutput = $standardOutput
            StandardError = $standardError
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-LoopbackProxyEndpoint {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        Stop-Ccx "ccx: invalid CCX_PROXY_URL '$Url'"
    }
    if ($uri.Scheme -cne 'http') {
        Stop-Ccx "ccx: CCX_PROXY_URL must use http on the local loopback interface"
    }
    if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1')) {
        Stop-Ccx "ccx: refusing to auto-start an unauthenticated proxy for non-loopback URL '$Url'"
    }

    return [PSCustomObject]@{
        BindAddress = '127.0.0.1'
        Port = [string]$uri.Port
    }
}

function Test-ProxyHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 1
    )

    try {
        $response = Invoke-WebRequest -Uri "$Url/healthz" -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Start-Proxy {
    $proxyBin = Get-ExternalCommandPath 'claude-code-proxy'
    if ($proxyBin) {
        $endpoint = Get-LoopbackProxyEndpoint $script:proxyUrl
        try {
            Invoke-CcxProcess `
                -Path $proxyBin `
                -Arguments @('serve', '--port', $endpoint.Port, '--no-monitor') `
                -Environment @{
                    CCP_BIND_ADDRESS = $endpoint.BindAddress
                    PORT = $endpoint.Port
                } `
                -Hidden `
                -NoWait | Out-Null
        }
        catch {
            # The health-check loop below reports the actionable error.
        }
    }

    for ($attempt = 1; $attempt -le 50; $attempt++) {
        if (Test-ProxyHealth -Url $script:proxyUrl) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Show-Models {
@'
Usage: ccx [model|bg] [claude arguments]

Models:
  sol       GPT-5.6 Sol (default)
  sol-fast  GPT-5.6 Sol, priority service tier
  terra     GPT-5.6 Terra
  luna      GPT-5.6 Luna
  5.5       GPT-5.5
  5.4       GPT-5.4
  mini      GPT-5.4 Mini
  5.3       GPT-5.3 Codex
  spark     GPT-5.3 Codex Spark
  5.2       GPT-5.2

Modes:
  bg        Configured background lane (default: GPT-5.6 Sol, medium)

Examples:
  ccx
  ccx terra
  ccx bg
  ccx bg --bg "Run tests and fix failures"
  ccx --effort high -p "Review this repository"

Environment:
  CCX_CONFIG_FILE        Config path (default: %APPDATA%\claudex\config)
  CCX_MODEL              Default main-model alias or ID (default: sol)
  CCX_MAIN_EFFORT        Normal root-session effort (default: xhigh)
  CCX_BG_MODEL           Model for ccx bg (default: sol)
  CCX_BG_EFFORT          Root effort for ccx bg (default: medium)
  CCX_SMALL_FAST_MODEL   Utility/background-request model
  CCX_CONTEXT_WINDOW     Auto-compaction boundary (default: per model; 272000, spark 128000)
  CCX_PROXY_URL          Local proxy URL (default: http://127.0.0.1:18765)
  CCX_SHIM_URL           Optional retry-shim URL fronting the proxy (see scripts/ccx-retry-shim.py)
  CCX_REAL_CLAUDE        Claude Code executable
'@
}

function Show-Config {
    $mainModel = Get-FirstNonEmpty @($env:CCX_MODEL, $script:configModel, 'sol')
    $mainEffort = Get-FirstNonEmpty @($env:CCX_MAIN_EFFORT, $script:configMainEffort, 'xhigh')
    $backgroundModel = Get-FirstNonEmpty @($env:CCX_BG_MODEL, $script:configBgModel, 'sol')
    $backgroundEffort = Get-FirstNonEmpty @($env:CCX_BG_EFFORT, $env:CCX_BACKGROUND_EFFORT, $script:configBgEffort, 'medium')
    $contextWindow = Get-FirstNonEmpty @($env:CCX_CONTEXT_WINDOW, $script:configContextWindow, 'per-model default (272000; spark 128000)')
    $retryShim = Get-FirstNonEmpty @($script:shimUrl, 'not configured')

@"
Config file: $script:configFile
Main model: $mainModel
Main effort: $mainEffort
Background model: $backgroundModel
Background effort: $backgroundEffort
Utility model: $script:backgroundModel
Context window: $contextWindow
Proxy URL: $script:proxyUrl
Retry shim URL: $retryShim
"@
}

function Test-Effort {
    param([Parameter(Mandatory = $true)][string]$Effort)

    if ($Effort -cnotin @('low', 'medium', 'high', 'xhigh', 'max')) {
        Stop-Ccx "ccx: unsupported effort '$Effort' (expected low, medium, high, xhigh, or max)"
    }
}

function Resolve-Model {
    param([Parameter(Mandatory = $true)][string]$Model)

    # Most lanes are 272k-class. Spark is 128k, so Claude Code must compact
    # sooner instead of letting long sessions hit an upstream context error.
    switch -CaseSensitive ($Model) {
        'sol' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol[1m]'; Name = 'GPT-5.6 Sol'; ContextWindow = '272000' } }
        'gpt-5.6-sol' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol[1m]'; Name = 'GPT-5.6 Sol'; ContextWindow = '272000' } }
        'gpt-5.6-sol[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol[1m]'; Name = 'GPT-5.6 Sol'; ContextWindow = '272000' } }
        'sol-fast' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol-fast[1m]'; Name = 'GPT-5.6 Sol Fast'; ContextWindow = '272000' } }
        'gpt-5.6-sol-fast' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol-fast[1m]'; Name = 'GPT-5.6 Sol Fast'; ContextWindow = '272000' } }
        'gpt-5.6-sol-fast[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.6-sol-fast[1m]'; Name = 'GPT-5.6 Sol Fast'; ContextWindow = '272000' } }
        'terra' { return [PSCustomObject]@{ Selected = 'gpt-5.6-terra[1m]'; Name = 'GPT-5.6 Terra'; ContextWindow = '272000' } }
        'gpt-5.6-terra' { return [PSCustomObject]@{ Selected = 'gpt-5.6-terra[1m]'; Name = 'GPT-5.6 Terra'; ContextWindow = '272000' } }
        'gpt-5.6-terra[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.6-terra[1m]'; Name = 'GPT-5.6 Terra'; ContextWindow = '272000' } }
        'luna' { return [PSCustomObject]@{ Selected = 'gpt-5.6-luna[1m]'; Name = 'GPT-5.6 Luna'; ContextWindow = '272000' } }
        'gpt-5.6-luna' { return [PSCustomObject]@{ Selected = 'gpt-5.6-luna[1m]'; Name = 'GPT-5.6 Luna'; ContextWindow = '272000' } }
        'gpt-5.6-luna[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.6-luna[1m]'; Name = 'GPT-5.6 Luna'; ContextWindow = '272000' } }
        '5.5' { return [PSCustomObject]@{ Selected = 'gpt-5.5[1m]'; Name = 'GPT-5.5'; ContextWindow = '272000' } }
        'gpt-5.5' { return [PSCustomObject]@{ Selected = 'gpt-5.5[1m]'; Name = 'GPT-5.5'; ContextWindow = '272000' } }
        'gpt-5.5[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.5[1m]'; Name = 'GPT-5.5'; ContextWindow = '272000' } }
        '5.4' { return [PSCustomObject]@{ Selected = 'gpt-5.4[1m]'; Name = 'GPT-5.4'; ContextWindow = '272000' } }
        'gpt-5.4' { return [PSCustomObject]@{ Selected = 'gpt-5.4[1m]'; Name = 'GPT-5.4'; ContextWindow = '272000' } }
        'gpt-5.4[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.4[1m]'; Name = 'GPT-5.4'; ContextWindow = '272000' } }
        'mini' { return [PSCustomObject]@{ Selected = 'gpt-5.4-mini[1m]'; Name = 'GPT-5.4 Mini'; ContextWindow = '272000' } }
        '5.4-mini' { return [PSCustomObject]@{ Selected = 'gpt-5.4-mini[1m]'; Name = 'GPT-5.4 Mini'; ContextWindow = '272000' } }
        'gpt-5.4-mini' { return [PSCustomObject]@{ Selected = 'gpt-5.4-mini[1m]'; Name = 'GPT-5.4 Mini'; ContextWindow = '272000' } }
        'gpt-5.4-mini[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.4-mini[1m]'; Name = 'GPT-5.4 Mini'; ContextWindow = '272000' } }
        '5.3' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex[1m]'; Name = 'GPT-5.3 Codex'; ContextWindow = '272000' } }
        'gpt-5.3-codex' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex[1m]'; Name = 'GPT-5.3 Codex'; ContextWindow = '272000' } }
        'gpt-5.3-codex[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex[1m]'; Name = 'GPT-5.3 Codex'; ContextWindow = '272000' } }
        'spark' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex-spark'; Name = 'GPT-5.3 Codex Spark'; ContextWindow = '128000' } }
        '5.3-spark' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex-spark'; Name = 'GPT-5.3 Codex Spark'; ContextWindow = '128000' } }
        'gpt-5.3-codex-spark' { return [PSCustomObject]@{ Selected = 'gpt-5.3-codex-spark'; Name = 'GPT-5.3 Codex Spark'; ContextWindow = '128000' } }
        '5.2' { return [PSCustomObject]@{ Selected = 'gpt-5.2[1m]'; Name = 'GPT-5.2'; ContextWindow = '272000' } }
        'gpt-5.2' { return [PSCustomObject]@{ Selected = 'gpt-5.2[1m]'; Name = 'GPT-5.2'; ContextWindow = '272000' } }
        'gpt-5.2[1m]' { return [PSCustomObject]@{ Selected = 'gpt-5.2[1m]'; Name = 'GPT-5.2'; ContextWindow = '272000' } }
        default { Stop-Ccx "ccx: unsupported model '$Model'" }
    }
}

try {
    $script:configFile = Get-ConfigFile
    $script:configModel = ''
    $script:configMainEffort = ''
    $script:configBgModel = ''
    $script:configBgEffort = ''
    $script:configSmallFastModel = ''
    $script:configContextWindow = ''
    $script:configProxyUrl = ''
    $script:configShimUrl = ''

    if (Test-Path -LiteralPath $script:configFile -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($script:configFile)) {
            $separator = $line.IndexOf('=')
            if ($separator -lt 0) {
                continue
            }

            $key = $line.Substring(0, $separator).Trim()
            $value = $line.Substring($separator + 1).Trim()
            switch -CaseSensitive ($key) {
                'CCX_MODEL' { $script:configModel = $value }
                'CCX_MAIN_EFFORT' { $script:configMainEffort = $value }
                'CCX_BG_MODEL' { $script:configBgModel = $value }
                'CCX_BG_EFFORT' { $script:configBgEffort = $value }
                'CCX_SMALL_FAST_MODEL' { $script:configSmallFastModel = $value }
                'CCX_CONTEXT_WINDOW' { $script:configContextWindow = $value }
                'CCX_PROXY_URL' { $script:configProxyUrl = $value }
                'CCX_SHIM_URL' { $script:configShimUrl = $value }
            }
        }
    }

    $script:proxyUrl = Get-FirstNonEmpty @($env:CCX_PROXY_URL, $script:configProxyUrl, 'http://127.0.0.1:18765')
    $script:shimUrl = Get-FirstNonEmpty @($env:CCX_SHIM_URL, $script:configShimUrl)
    $script:backgroundModel = Get-FirstNonEmpty @($env:CCX_SMALL_FAST_MODEL, $env:CCX_BACKGROUND_MODEL, $script:configSmallFastModel, 'gpt-5.6-sol[1m]')

    $requestedModel = Get-FirstNonEmpty @($env:CCX_MODEL, $script:configModel, 'sol')
    $selectedEffort = Get-FirstNonEmpty @($env:CCX_MAIN_EFFORT, $script:configMainEffort, 'xhigh')
    $forwardArguments = @($args)

    if ($forwardArguments.Count -gt 0) {
        $firstArgument = [string]$forwardArguments[0]
        if ($firstArgument -ceq 'models' -or $firstArgument -ceq '--models') {
            Show-Models
            exit 0
        }
        elseif ($firstArgument -ceq 'config' -or $firstArgument -ceq '--config') {
            Show-Config
            exit 0
        }
        elseif ($firstArgument -ceq '--model' -or $firstArgument -ceq '-m') {
            if ($forwardArguments.Count -lt 2) {
                Stop-Ccx "ccx: $firstArgument requires a model" 2
            }
            $requestedModel = [string]$forwardArguments[1]
            $forwardArguments = @($forwardArguments | Select-Object -Skip 2)
        }
        elseif ($firstArgument -ceq 'bg' -or $firstArgument -ceq 'background') {
            $requestedModel = Get-FirstNonEmpty @($env:CCX_BG_MODEL, $script:configBgModel, 'sol')
            $selectedEffort = Get-FirstNonEmpty @($env:CCX_BG_EFFORT, $env:CCX_BACKGROUND_EFFORT, $script:configBgEffort, 'medium')
            $forwardArguments = @($forwardArguments | Select-Object -Skip 1)
        }
        elseif ($firstArgument -cin @('sol', 'sol-fast', 'terra', 'luna', '5.5', '5.4', 'mini', '5.3', 'spark', '5.2')) {
            $requestedModel = $firstArgument
            $forwardArguments = @($forwardArguments | Select-Object -Skip 1)
        }
        elseif ($firstArgument -clike 'gpt-*' -or $firstArgument -clike '*[[]1m[]]*') {
            # A full model ID must select a known model or fail loudly, never
            # leak through to Claude Code as an unrelated argument.
            $requestedModel = $firstArgument
            $forwardArguments = @($forwardArguments | Select-Object -Skip 1)
        }
    }

    Test-Effort $selectedEffort
    $resolvedModel = Resolve-Model $requestedModel
    $contextWindow = Get-FirstNonEmpty @($env:CCX_CONTEXT_WINDOW, $script:configContextWindow, $resolvedModel.ContextWindow)

    $claudeBin = Get-FirstNonEmpty @($env:CCX_REAL_CLAUDE, (Get-ExternalCommandPath 'claude'))
    if (-not $claudeBin -or -not (Test-Path -LiteralPath $claudeBin -PathType Leaf)) {
        Stop-Ccx 'ccx: Claude Code is missing or not executable. Set CCX_REAL_CLAUDE or install Claude Code.'
    }

    $skipHealthCheck = ($env:CCX_SKIP_HEALTH_CHECK -eq '1')
    if (-not $skipHealthCheck) {
        if (-not (Test-ProxyHealth -Url $script:proxyUrl)) {
            if (-not (Start-Proxy)) {
                Stop-Ccx "ccx: proxy did not become healthy at $script:proxyUrl/healthz`nccx: run .\scripts\doctor.ps1 from the Claudex repository for diagnostics."
            }
        }

        # healthz only verifies the server. Verify Codex OAuth before Claude
        # Code starts a session that would otherwise fail all requests with 401.
        $proxyBin = Get-ExternalCommandPath 'claude-code-proxy'
        if ($proxyBin) {
            $authResult = Invoke-CcxProcess `
                -Path $proxyBin `
                -Arguments @('codex', 'auth', 'status') `
                -CaptureOutput
            $authOutput = $authResult.StandardOutput + $authResult.StandardError
            if ($authResult.ExitCode -ne 0) {
                Stop-Ccx "ccx: Codex authentication is broken:`n$authOutput`nccx: run: claude-code-proxy codex auth login"
            }
            if ($authOutput -match '(?i)expired') {
                Stop-Ccx 'ccx: Codex token is expired; run: claude-code-proxy codex auth login'
            }
        }
    }

    # A configured shim retries transient 401/5xx responses from the proxy.
    # If it is unavailable, keep the direct proxy route and warn instead.
    $baseUrl = $script:proxyUrl
    if ($script:shimUrl) {
        if ($skipHealthCheck -or (Test-ProxyHealth -Url $script:shimUrl -TimeoutSeconds 2)) {
            $baseUrl = $script:shimUrl
        }
        else {
            [Console]::Error.WriteLine("ccx: warning: retry shim $script:shimUrl is unavailable; using the proxy directly")
        }
    }

    $env:ANTHROPIC_BASE_URL = $baseUrl
    $env:ANTHROPIC_AUTH_TOKEN = 'unused'
    $env:ANTHROPIC_MODEL = $resolvedModel.Selected
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $script:backgroundModel
    $env:ANTHROPIC_SMALL_FAST_MODEL = $script:backgroundModel
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $resolvedModel.Selected
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = "$($resolvedModel.Name) (OpenAI subscription)"
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $contextWindow
    if (-not $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT) {
        $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
    }
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    $env:CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = '1'

    $hasEffortArgument = $false
    foreach ($argument in $forwardArguments) {
        if ($argument -ceq '--effort' -or $argument -clike '--effort=*') {
            $hasEffortArgument = $true
            break
        }
    }

    $claudeArguments = @('--model', $resolvedModel.Selected)
    if (-not $hasEffortArgument) {
        $claudeArguments += @('--effort', $selectedEffort)
    }
    $claudeArguments += $forwardArguments

    $claudeResult = Invoke-CcxProcess -Path $claudeBin -Arguments $claudeArguments
    exit ([int]$claudeResult.ExitCode)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = $_.Exception.Data['ExitCode']
    if ($null -eq $exitCode) {
        $exitCode = 1
    }
    exit ([int]$exitCode)
}
