<#
.SYNOPSIS
Runs the interactive Claudex setup wizard for Windows.

.DESCRIPTION
Collects model and effort preferences, writes the per-user Claudex
configuration, optionally delegates installation to install.ps1, and runs
final verification through doctor.ps1. The configuration contains preferences
only; OAuth credentials are never written to it.

.PARAMETER MainModel
Root model alias for normal ccx sessions.

.PARAMETER MainEffort
Root effort: low, medium, high, xhigh, max, or ultracode.

.PARAMETER BgModel
Model alias used by the ccx bg lane.

.PARAMETER BgEffort
Effort used by the ccx bg lane.

.PARAMETER UtilityModel
Model alias for titles, token counts, and utility requests.

.PARAMETER SubagentEffort
Effort for the optional custom worker.

.PARAMETER WithAgent
Installs the custom worker.

.PARAMETER WithoutAgent
Does not install the custom worker.

.PARAMETER Login
Runs browser OAuth during installation if authentication is missing.

.PARAMETER NoLogin
Does not start browser OAuth.

.PARAMETER StartService
Registers and starts the per-user proxy Scheduled Task.

.PARAMETER NoService
Does not register or start the per-user proxy Scheduled Task.

.PARAMETER NoPath
Does not add the Claudex install directory to the User PATH.

.PARAMETER ConfigOnly
Writes configuration without installing anything or running diagnostics.

.PARAMETER Yes
Uses current/default values for unspecified choices and skips final confirmation.

.PARAMETER Help
Shows detailed setup help and exits without changing anything.

.EXAMPLE
.\scripts\setup.ps1

Opens the interactive setup wizard.

.EXAMPLE
.\scripts\setup.ps1 -MainModel sol -MainEffort xhigh -WithAgent -Yes

Applies explicit choices noninteractively and delegates to the installer.

.EXAMPLE
.\scripts\setup.ps1 -ConfigOnly -Yes

Writes the current/default configuration without installing anything.
#>
[CmdletBinding()]
param(
    [string]$MainModel = '',
    [string]$MainEffort = '',
    [string]$BgModel = '',
    [string]$BgEffort = '',
    [string]$UtilityModel = '',
    [string]$SubagentEffort = '',
    [switch]$WithAgent,
    [switch]$WithoutAgent,
    [switch]$Login,
    [switch]$NoLogin,
    [switch]$StartService,
    [switch]$NoService,
    [switch]$NoPath,
    [switch]$ConfigOnly,
    [Alias('y')][switch]$Yes,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
$script:renderedConfig = ''

function Stop-Setup {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 1
    )

    $exception = New-Object System.Exception $Message
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Write-SetupLine {
    param([string]$Message = '')

    [Console]::WriteLine($Message)
}

function Read-SetupLine {
    try {
        return [Console]::ReadLine()
    }
    catch {
        return $Host.UI.ReadLine()
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fallback
    )

    $value = $Fallback
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $value
    }

    # Parse plain key=value text without executing or dot-sourcing it.
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $candidateKey = $line.Substring(0, $separator)
        if ($candidateKey -ceq $Key) {
            $value = $line.Substring($separator + 1).TrimEnd("`r")
        }
    }

    return $value
}

function Get-UtilityAliasFromWireModel {
    param([Parameter(Mandatory = $true)][string]$Model)

    switch -CaseSensitive ($Model) {
        'gpt-5.6-sol[1m]' { return 'sol' }
        'gpt-5.6-sol' { return 'sol' }
        'gpt-5.6-sol-fast[1m]' { return 'sol-fast' }
        'gpt-5.6-sol-fast' { return 'sol-fast' }
        'gpt-5.6-terra[1m]' { return 'terra' }
        'gpt-5.6-terra' { return 'terra' }
        'gpt-5.6-terra-fast[1m]' { return 'terra-fast' }
        'gpt-5.6-terra-fast' { return 'terra-fast' }
        'gpt-5.6-luna[1m]' { return 'luna' }
        'gpt-5.6-luna' { return 'luna' }
        'gpt-5.6-luna-fast[1m]' { return 'luna-fast' }
        'gpt-5.6-luna-fast' { return 'luna-fast' }
        'gpt-5.5[1m]' { return '5.5' }
        'gpt-5.5' { return '5.5' }
        'gpt-5.5-fast[1m]' { return '5.5-fast' }
        'gpt-5.5-fast' { return '5.5-fast' }
        'gpt-5.4[1m]' { return '5.4' }
        'gpt-5.4' { return '5.4' }
        'gpt-5.4-fast[1m]' { return '5.4-fast' }
        'gpt-5.4-fast' { return '5.4-fast' }
        'gpt-5.4-mini[1m]' { return 'mini' }
        'gpt-5.4-mini' { return 'mini' }
        'gpt-5.4-mini-fast[1m]' { return 'mini-fast' }
        'gpt-5.4-mini-fast' { return 'mini-fast' }
        'gpt-5.3-codex[1m]' { return '5.3' }
        'gpt-5.3-codex' { return '5.3' }
        'gpt-5.3-codex-fast[1m]' { return '5.3-fast' }
        'gpt-5.3-codex-fast' { return '5.3-fast' }
        'gpt-5.3-codex-spark' { return 'spark' }
        'gpt-5.3-codex-spark-fast' { return 'spark-fast' }
        'gpt-5.2[1m]' { return '5.2' }
        'gpt-5.2' { return '5.2' }
        'gpt-5.2-fast[1m]' { return '5.2-fast' }
        'gpt-5.2-fast' { return '5.2-fast' }
        default { return 'sol' }
    }
}

function Get-WireModelFromAlias {
    param([Parameter(Mandatory = $true)][string]$Alias)

    switch -CaseSensitive ($Alias) {
        'sol' { return 'gpt-5.6-sol[1m]' }
        'sol-fast' { return 'gpt-5.6-sol-fast[1m]' }
        'terra' { return 'gpt-5.6-terra[1m]' }
        'terra-fast' { return 'gpt-5.6-terra-fast[1m]' }
        'luna' { return 'gpt-5.6-luna[1m]' }
        'luna-fast' { return 'gpt-5.6-luna-fast[1m]' }
        '5.5' { return 'gpt-5.5[1m]' }
        '5.5-fast' { return 'gpt-5.5-fast[1m]' }
        '5.4' { return 'gpt-5.4[1m]' }
        '5.4-fast' { return 'gpt-5.4-fast[1m]' }
        'mini' { return 'gpt-5.4-mini[1m]' }
        'mini-fast' { return 'gpt-5.4-mini-fast[1m]' }
        '5.3' { return 'gpt-5.3-codex[1m]' }
        '5.3-fast' { return 'gpt-5.3-codex-fast[1m]' }
        'spark' { return 'gpt-5.3-codex-spark' }
        'spark-fast' { return 'gpt-5.3-codex-spark-fast' }
        '5.2' { return 'gpt-5.2[1m]' }
        '5.2-fast' { return 'gpt-5.2-fast[1m]' }
        default { return $null }
    }
}

function Assert-Model {
    param([Parameter(Mandatory = $true)][string]$Model)

    if (-not (Get-WireModelFromAlias $Model)) {
        Stop-Setup "setup: unsupported model alias: $Model" 2
    }
}

function Assert-SessionEffort {
    param([Parameter(Mandatory = $true)][string]$Effort)

    if (-not (@('low', 'medium', 'high', 'xhigh', 'max', 'ultracode') -ccontains $Effort)) {
        Stop-Setup "setup: unsupported session effort: $Effort" 2
    }
}

function Assert-SubagentEffort {
    param([Parameter(Mandatory = $true)][string]$Effort)

    if (-not (@('low', 'medium', 'high', 'xhigh', 'max') -ccontains $Effort)) {
        Stop-Setup "setup: unsupported custom sub-agent effort: $Effort" 2
    }
}

function Assert-Toggle {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Value -cnotin @('0', '1')) {
        Stop-Setup "setup: $Name must be 0 or 1: $Value" 2
    }
}

function Assert-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Value -notmatch '^[1-9][0-9]*$') {
        Stop-Setup "setup: $Name must be a positive integer: $Value" 2
    }
}

function Assert-ProxyTransport {
    param([Parameter(Mandatory = $true)][string]$Transport)

    if ($Transport -cnotin @('http', 'websocket', 'auto')) {
        Stop-Setup "setup: CCX_PROXY_TRANSPORT must be http, websocket, or auto: $Transport" 2
    }
}

function Select-SetupOption {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Recommended,
        [Parameter(Mandatory = $true)][string[]]$Options
    )

    while ($true) {
        Write-SetupLine
        Write-SetupLine $Label
        for ($index = 0; $index -lt $Options.Count; $index++) {
            $suffix = if ($Options[$index] -ceq $Recommended) { ' (recommended/current)' } else { '' }
            Write-SetupLine ('  {0}) {1}{2}' -f ($index + 1), $Options[$index], $suffix)
        }

        [Console]::Write("Choose [$Recommended]: ")
        $answer = Read-SetupLine
        if ([string]::IsNullOrEmpty($answer)) {
            return $Recommended
        }

        $selectedIndex = 0
        if ([int]::TryParse($answer, [ref]$selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le $Options.Count) {
                return $Options[$selectedIndex - 1]
            }
        }

        foreach ($option in $Options) {
            if ($answer -ceq $option) {
                return $option
            }
        }

        [Console]::Error.WriteLine('Please enter a listed number or value.')
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ValidateSet('yes', 'no')][string]$Recommended
    )

    $prompt = if ($Recommended -ceq 'yes') { 'Y/n' } else { 'y/N' }
    while ($true) {
        [Console]::Write("$Label [$prompt]: ")
        $answer = Read-SetupLine
        if ([string]::IsNullOrEmpty($answer)) {
            $answer = $Recommended
        }

        switch -CaseSensitive ($answer) {
            'y' { return 'yes' }
            'Y' { return 'yes' }
            'yes' { return 'yes' }
            'YES' { return 'yes' }
            'Yes' { return 'yes' }
            'n' { return 'no' }
            'N' { return 'no' }
            'no' { return 'no' }
            'NO' { return 'no' }
            'No' { return 'no' }
            default { [Console]::Error.WriteLine('Please answer yes or no.') }
        }
    }
}

function Test-FileContentsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$FirstPath,
        [Parameter(Mandatory = $true)][string]$SecondPath
    )

    $first = [IO.File]::ReadAllBytes($FirstPath)
    $second = [IO.File]::ReadAllBytes($SecondPath)
    if ($first.Length -ne $second.Length) {
        return $false
    }

    for ($index = 0; $index -lt $first.Length; $index++) {
        if ($first[$index] -ne $second[$index]) {
            return $false
        }
    }

    return $true
}

function Invoke-CheckedScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Parameters = @{}
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Setup "setup: required script not found: $Path"
    }

    $global:LASTEXITCODE = 0
    & $Path @Parameters
    $succeeded = $?
    $childExitCode = $LASTEXITCODE
    if (-not $succeeded -or ($null -ne $childExitCode -and $childExitCode -ne 0)) {
        if ($null -eq $childExitCode -or $childExitCode -eq 0) {
            $childExitCode = 1
        }
        Stop-Setup "setup: script failed: $Path" ([int]$childExitCode)
    }
}

function Invoke-Setup {
    if ($Help.IsPresent) {
        Get-Help -Name $PSCommandPath -Detailed
        return
    }
    if ($WithAgent.IsPresent -and $WithoutAgent.IsPresent) {
        Stop-Setup 'setup: -WithAgent and -WithoutAgent cannot be used together' 2
    }
    if ($Login.IsPresent -and $NoLogin.IsPresent) {
        Stop-Setup 'setup: -Login and -NoLogin cannot be used together' 2
    }
    if ($StartService.IsPresent -and $NoService.IsPresent) {
        Stop-Setup 'setup: -StartService and -NoService cannot be used together' 2
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ($env:CCX_CONFIG_FILE) {
        $configTarget = [IO.Path]::GetFullPath($env:CCX_CONFIG_FILE)
        $configDir = Split-Path -Parent $configTarget
    }
    elseif ($env:CCX_CONFIG_DIR) {
        $configDir = $env:CCX_CONFIG_DIR
        $configTarget = Join-Path $configDir 'config'
    }
    elseif ($env:XDG_CONFIG_HOME) {
        $configDir = Join-Path $env:XDG_CONFIG_HOME 'claudex'
        $configTarget = Join-Path $configDir 'config'
    }
    else {
        $appData = $env:APPDATA
        if (-not $appData) {
            $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
        }
        if (-not $appData) {
            Stop-Setup 'setup: APPDATA is not available; set CCX_CONFIG_FILE, CCX_CONFIG_DIR, or XDG_CONFIG_HOME explicitly'
        }
        $configDir = Join-Path $appData 'Claudex'
        $configTarget = Join-Path $configDir 'config'
    }

    $defaultMainModel = Get-ConfigValue $configTarget 'CCX_MODEL' 'sol'
    $defaultMainEffort = Get-ConfigValue $configTarget 'CCX_MAIN_EFFORT' 'xhigh'
    $defaultBgModel = Get-ConfigValue $configTarget 'CCX_BG_MODEL' 'sol'
    $defaultBgEffort = Get-ConfigValue $configTarget 'CCX_BG_EFFORT' 'medium'
    $defaultUtilityWire = Get-ConfigValue $configTarget 'CCX_SMALL_FAST_MODEL' 'gpt-5.6-sol[1m]'
    $defaultSubagentEffort = Get-ConfigValue $configTarget 'CCX_SUBAGENT_EFFORT' 'high'
    $defaultUtilityModel = Get-UtilityAliasFromWireModel $defaultUtilityWire
    $preservedContextWindow = Get-ConfigValue $configTarget 'CCX_CONTEXT_WINDOW' ''
    $preservedProxyUrl = Get-ConfigValue $configTarget 'CCX_PROXY_URL' 'http://127.0.0.1:18765'
    $preservedProxyTransport = Get-ConfigValue $configTarget 'CCX_PROXY_TRANSPORT' 'http'
    $preservedShimUrl = Get-ConfigValue $configTarget 'CCX_SHIM_URL' ''
    $preservedSubagentGuards = Get-ConfigValue $configTarget 'CCX_SUBAGENT_GUARDS' '1'
    $preservedMaxConcurrentSubagents = Get-ConfigValue $configTarget 'CCX_MAX_CONCURRENT_SUBAGENTS' '3'
    $preservedMaxSubagentsPerSession = Get-ConfigValue $configTarget 'CCX_MAX_SUBAGENTS_PER_SESSION' '12'
    $preservedMaxSubagentSpawnDepth = Get-ConfigValue $configTarget 'CCX_MAX_SUBAGENT_SPAWN_DEPTH' '1'
    $preservedMaxRetries = Get-ConfigValue $configTarget 'CCX_MAX_RETRIES' '3'
    $preservedApiTimeoutMs = Get-ConfigValue $configTarget 'CCX_API_TIMEOUT_MS' '300000'

    Assert-Toggle 'CCX_SUBAGENT_GUARDS' $preservedSubagentGuards
    Assert-PositiveInteger 'CCX_MAX_CONCURRENT_SUBAGENTS' $preservedMaxConcurrentSubagents
    Assert-PositiveInteger 'CCX_MAX_SUBAGENTS_PER_SESSION' $preservedMaxSubagentsPerSession
    Assert-PositiveInteger 'CCX_MAX_SUBAGENT_SPAWN_DEPTH' $preservedMaxSubagentSpawnDepth
    Assert-PositiveInteger 'CCX_MAX_RETRIES' $preservedMaxRetries
    Assert-PositiveInteger 'CCX_API_TIMEOUT_MS' $preservedApiTimeoutMs
    Assert-ProxyTransport $preservedProxyTransport
    if ($preservedContextWindow) {
        Assert-PositiveInteger 'CCX_CONTEXT_WINDOW' $preservedContextWindow
    }

    if (-not $Yes.IsPresent) {
        try {
            if ([Console]::IsInputRedirected) {
                Stop-Setup 'setup: interactive mode needs a terminal. Use explicit options with -Yes.' 2
            }
        }
        catch [System.IO.IOException] {
            # Hosts without a conventional console can still provide Read-Host input.
        }
    }

    Write-SetupLine 'Claudex setup wizard'
    Write-SetupLine 'This stores model and effort preferences only. OAuth tokens never enter the config.'

    $selectedMainModel = $MainModel
    if (-not $selectedMainModel) {
        if ($Yes.IsPresent) {
            $selectedMainModel = $defaultMainModel
        }
        else {
            $selectedMainModel = Select-SetupOption '1. Main model for normal ccx sessions' $defaultMainModel @(
                'sol', 'sol-fast', 'terra', 'terra-fast', 'luna', 'luna-fast',
                '5.5', '5.5-fast', '5.4', '5.4-fast', 'mini', 'mini-fast',
                '5.3', '5.3-fast', 'spark', 'spark-fast', '5.2', '5.2-fast'
            )
        }
    }

    $selectedMainEffort = $MainEffort
    if (-not $selectedMainEffort) {
        if ($Yes.IsPresent) {
            $selectedMainEffort = $defaultMainEffort
        }
        else {
            $selectedMainEffort = Select-SetupOption '2. Main-session reasoning effort' $defaultMainEffort @(
                'low', 'medium', 'high', 'xhigh', 'max', 'ultracode'
            )
        }
    }

    $selectedBgModel = $BgModel
    if (-not $selectedBgModel) {
        if ($Yes.IsPresent) {
            $selectedBgModel = $defaultBgModel
        }
        else {
            $selectedBgModel = Select-SetupOption '3. Model for the ccx bg lane' $defaultBgModel @(
                'sol', 'sol-fast', 'terra', 'terra-fast', 'luna', 'luna-fast',
                '5.5', '5.5-fast', '5.4', '5.4-fast', 'mini', 'mini-fast',
                '5.3', '5.3-fast', 'spark', 'spark-fast', '5.2', '5.2-fast'
            )
        }
    }

    $selectedBgEffort = $BgEffort
    if (-not $selectedBgEffort) {
        if ($Yes.IsPresent) {
            $selectedBgEffort = $defaultBgEffort
        }
        else {
            $selectedBgEffort = Select-SetupOption '4. Reasoning effort for the ccx bg lane' $defaultBgEffort @(
                'low', 'medium', 'high', 'xhigh', 'max', 'ultracode'
            )
        }
    }

    $selectedUtilityModel = $UtilityModel
    if (-not $selectedUtilityModel) {
        if ($Yes.IsPresent) {
            $selectedUtilityModel = $defaultUtilityModel
        }
        else {
            $selectedUtilityModel = Select-SetupOption '5. Utility model for titles, token counts, and small background requests' $defaultUtilityModel @(
                'sol', 'sol-fast', 'terra', 'terra-fast', 'luna', 'luna-fast',
                '5.5', '5.5-fast', '5.4', '5.4-fast', 'mini', 'mini-fast',
                '5.3', '5.3-fast', 'spark', 'spark-fast', '5.2', '5.2-fast'
            )
        }
    }

    $selectedSubagentEffort = $SubagentEffort
    if (-not $selectedSubagentEffort) {
        if ($Yes.IsPresent) {
            $selectedSubagentEffort = $defaultSubagentEffort
        }
        else {
            $selectedSubagentEffort = Select-SetupOption '6. Effort for the optional custom sub-agent' $defaultSubagentEffort @(
                'low', 'medium', 'high', 'xhigh', 'max'
            )
        }
    }

    if ($WithAgent.IsPresent) {
        $installAgent = 'yes'
    }
    elseif ($WithoutAgent.IsPresent) {
        $installAgent = 'no'
    }
    elseif ($Yes.IsPresent) {
        $installAgent = 'yes'
    }
    else {
        $installAgent = Read-YesNo '7. Install the custom background sub-agent?' 'yes'
    }

    if ($Login.IsPresent) {
        $runLogin = 'yes'
    }
    elseif ($NoLogin.IsPresent) {
        $runLogin = 'no'
    }
    elseif ($Yes.IsPresent) {
        $runLogin = 'yes'
    }
    else {
        $runLogin = Read-YesNo '8. Open browser OAuth during installation if needed?' 'yes'
    }

    if ($StartService.IsPresent) {
        $startBackgroundService = 'yes'
    }
    elseif ($NoService.IsPresent) {
        $startBackgroundService = 'no'
    }
    elseif ($Yes.IsPresent) {
        $startBackgroundService = 'yes'
    }
    else {
        $startBackgroundService = Read-YesNo '9. Start the proxy automatically as a background service?' 'yes'
    }

    Assert-Model $selectedMainModel
    Assert-Model $selectedBgModel
    Assert-Model $selectedUtilityModel
    Assert-SessionEffort $selectedMainEffort
    Assert-SessionEffort $selectedBgEffort
    Assert-SubagentEffort $selectedSubagentEffort
    $utilityWireModel = Get-WireModelFromAlias $selectedUtilityModel

    Write-SetupLine
    Write-SetupLine 'Configuration summary'
    Write-SetupLine ("  Main session:      $selectedMainModel / $selectedMainEffort effort")
    Write-SetupLine ("  Background lane:  $selectedBgModel / $selectedBgEffort effort")
    Write-SetupLine ("  Utility requests: $selectedUtilityModel")
    Write-SetupLine ("  Custom sub-agent: $installAgent (effort: $selectedSubagentEffort)")
    Write-SetupLine ("  Browser OAuth:    $runLogin, if needed")
    Write-SetupLine ("  Background service: $startBackgroundService")
    Write-SetupLine ("  Guardrails:        enabled=$preservedSubagentGuards, concurrent=$preservedMaxConcurrentSubagents, total=$preservedMaxSubagentsPerSession, depth=$preservedMaxSubagentSpawnDepth")
    Write-SetupLine ("  Request limits:    retries=$preservedMaxRetries, timeout=${preservedApiTimeoutMs}ms")
    Write-SetupLine ("  Proxy:             $preservedProxyUrl ($preservedProxyTransport)")
    Write-SetupLine ("  Retry shim:        $(if ($preservedShimUrl) { $preservedShimUrl } else { 'not configured' })")
    Write-SetupLine ("  Config path:      $configTarget")

    if (-not $Yes.IsPresent) {
        $applyConfiguration = Read-YesNo 'Apply this configuration?' 'yes'
        if ($applyConfiguration -cne 'yes') {
            Write-SetupLine 'No changes made.'
            return
        }
    }

    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $script:renderedConfig = Join-Path $configDir ('.config.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $renderedText = @(
        '# Managed by https://github.com/migueltorrezd/claudex'
        '# Generated by scripts/setup.ps1. Do not put credentials in this file.'
        "CCX_MODEL=$selectedMainModel"
        "CCX_MAIN_EFFORT=$selectedMainEffort"
        "CCX_BG_MODEL=$selectedBgModel"
        "CCX_BG_EFFORT=$selectedBgEffort"
        "CCX_SMALL_FAST_MODEL=$utilityWireModel"
        "CCX_SUBAGENT_EFFORT=$selectedSubagentEffort"
        "CCX_SUBAGENT_GUARDS=$preservedSubagentGuards"
        "CCX_MAX_CONCURRENT_SUBAGENTS=$preservedMaxConcurrentSubagents"
        "CCX_MAX_SUBAGENTS_PER_SESSION=$preservedMaxSubagentsPerSession"
        "CCX_MAX_SUBAGENT_SPAWN_DEPTH=$preservedMaxSubagentSpawnDepth"
        "CCX_MAX_RETRIES=$preservedMaxRetries"
        "CCX_API_TIMEOUT_MS=$preservedApiTimeoutMs"
        "CCX_PROXY_URL=$preservedProxyUrl"
        "CCX_PROXY_TRANSPORT=$preservedProxyTransport"
    ) -join "`n"
    if ($preservedContextWindow) {
        $renderedText += "`nCCX_CONTEXT_WINDOW=$preservedContextWindow"
    }
    else {
        $renderedText += @'

# CCX_CONTEXT_WINDOW is intentionally unset: the launcher picks the correct
# per-model boundary (272000 for most lanes, 128000 for spark). Set it only
# to force a specific value for every model.
'@
    }
    if ($preservedShimUrl) {
        $renderedText += "`nCCX_SHIM_URL=$preservedShimUrl"
    }
    else {
        $renderedText += @'

# CCX_SHIM_URL is optional. When configured, setup preserves it across updates.
'@
    }
    $renderedText += "`n"
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($script:renderedConfig, $renderedText, $utf8WithoutBom)

    if (Test-Path -LiteralPath $configTarget -PathType Leaf) {
        if (-not (Test-FileContentsEqual $script:renderedConfig $configTarget)) {
            $backupPath = '{0}.backup-{1}-{2}' -f $configTarget, (Get-Date -Format 'yyyyMMddHHmmss'), $PID
            Copy-Item -LiteralPath $configTarget -Destination $backupPath
            Write-SetupLine "Backed up existing config to $backupPath"
        }
        Move-Item -LiteralPath $script:renderedConfig -Destination $configTarget -Force
    }
    else {
        [IO.File]::Move($script:renderedConfig, $configTarget)
    }
    $script:renderedConfig = ''
    Write-SetupLine "Saved configuration to $configTarget"

    if ($ConfigOnly.IsPresent) {
        Write-SetupLine 'Configuration-only mode complete.'
        return
    }

    $installParameters = @{}
    if ($installAgent -ceq 'yes') {
        $installParameters['WithAgent'] = $true
    }
    if ($runLogin -ceq 'yes') {
        $installParameters['Login'] = $true
    }
    if ($startBackgroundService -ceq 'no') {
        $installParameters['NoService'] = $true
    }
    if ($NoPath.IsPresent) {
        $installParameters['NoPath'] = $true
    }

    $previousConfigFile = $env:CCX_CONFIG_FILE
    $previousConfigDir = $env:CCX_CONFIG_DIR
    $previousSubagentEffort = $env:CCX_SUBAGENT_EFFORT
    try {
        $env:CCX_CONFIG_FILE = $configTarget
        $env:CCX_CONFIG_DIR = $configDir
        $env:CCX_SUBAGENT_EFFORT = $selectedSubagentEffort
        Invoke-CheckedScript (Join-Path $repoRoot 'scripts\install.ps1') $installParameters
    }
    finally {
        $env:CCX_CONFIG_FILE = $previousConfigFile
        $env:CCX_CONFIG_DIR = $previousConfigDir
        $env:CCX_SUBAGENT_EFFORT = $previousSubagentEffort
    }

    Write-SetupLine
    Write-SetupLine 'Final verification:'
    $doctorParameters = @{}
    if ($startBackgroundService -ceq 'no') {
        $doctorParameters['NoService'] = $true
    }
    Invoke-CheckedScript (Join-Path $repoRoot 'scripts\doctor.ps1') $doctorParameters
}

$exitCode = 0
try {
    Invoke-Setup
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $storedExitCode = $_.Exception.Data['ExitCode']
    if ($null -ne $storedExitCode) {
        $exitCode = [int]$storedExitCode
    }
    else {
        $exitCode = 1
    }
}
finally {
    if ($script:renderedConfig -and (Test-Path -LiteralPath $script:renderedConfig -PathType Leaf)) {
        Remove-Item -LiteralPath $script:renderedConfig -Force
    }
}

exit $exitCode
