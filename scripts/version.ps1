# Shared dependency-version checks for Claudex PowerShell scripts.
Set-StrictMode -Version 2.0

$script:CcxMinimumClaudeVersion = '2.1.217'
$script:CcxMinimumProxyVersion = '0.1.17'

function Get-CcxSemanticVersion {
    param([AllowNull()][string]$Text)

    if (-not $Text) {
        return ''
    }

    $match = [regex]::Match($Text, '(?<![0-9])(?<Version>[0-9]+\.[0-9]+\.[0-9]+)(?![0-9])')
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups['Version'].Value
}

function Test-CcxVersionAtLeast {
    param(
        [AllowNull()][string]$Version,
        [Parameter(Mandatory = $true)][string]$Minimum
    )

    $actualVersion = Get-CcxSemanticVersion $Version
    $minimumVersion = Get-CcxSemanticVersion $Minimum
    if (-not $actualVersion -or -not $minimumVersion) {
        return $false
    }

    $actualParts = @($actualVersion.Split('.') | ForEach-Object { [int]$_ })
    $minimumParts = @($minimumVersion.Split('.') | ForEach-Object { [int]$_ })
    for ($index = 0; $index -lt 3; $index++) {
        if ($actualParts[$index] -gt $minimumParts[$index]) {
            return $true
        }
        if ($actualParts[$index] -lt $minimumParts[$index]) {
            return $false
        }
    }
    return $true
}

function Get-CcxCommandVersion {
    param([Parameter(Mandatory = $true)][string]$CommandPath)

    try {
        $output = @(& $CommandPath --version 2>$null)
        if ($output.Count -gt 0) {
            return Get-CcxSemanticVersion ([string]$output[0])
        }
    }
    catch {
        return ''
    }
    return ''
}
