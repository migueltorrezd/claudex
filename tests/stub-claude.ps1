$ErrorActionPreference = 'Stop'

function Get-EnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrEmpty($value)) {
        return 'unset'
    }

    return $value
}

Write-Output "MODEL=$(Get-EnvironmentValue 'ANTHROPIC_MODEL')"
Write-Output "SMALL_FAST=$(Get-EnvironmentValue 'ANTHROPIC_SMALL_FAST_MODEL')"
Write-Output "EFFORT_ENV=$(Get-EnvironmentValue 'CLAUDE_CODE_EFFORT_LEVEL')"
Write-Output "BASE_URL=$(Get-EnvironmentValue 'ANTHROPIC_BASE_URL')"
Write-Output "COMPACT_WINDOW=$(Get-EnvironmentValue 'CLAUDE_CODE_AUTO_COMPACT_WINDOW')"
Write-Output "MAX_CONCURRENT_SUBAGENTS=$(Get-EnvironmentValue 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS')"
Write-Output "MAX_SUBAGENTS_PER_SESSION=$(Get-EnvironmentValue 'CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION')"
Write-Output "MAX_SUBAGENT_SPAWN_DEPTH=$(Get-EnvironmentValue 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')"
Write-Output "MAX_RETRIES=$(Get-EnvironmentValue 'CLAUDE_CODE_MAX_RETRIES')"
Write-Output "API_TIMEOUT_MS=$(Get-EnvironmentValue 'API_TIMEOUT_MS')"
foreach ($argument in $args) {
    Write-Output "ARG=$argument"
}
