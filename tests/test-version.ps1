$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\version.ps1')

$cases = @(
    @{ Actual = '2.1.217'; Minimum = '2.1.217'; Expected = $true },
    @{ Actual = '2.1.220 (Claude Code)'; Minimum = '2.1.217'; Expected = $true },
    @{ Actual = '2.2.0'; Minimum = '2.1.217'; Expected = $true },
    @{ Actual = '2.1.216'; Minimum = '2.1.217'; Expected = $false },
    @{ Actual = '1.99.999'; Minimum = '2.1.217'; Expected = $false },
    @{ Actual = 'claude-code-proxy 0.1.27'; Minimum = '0.1.17'; Expected = $true },
    @{ Actual = 'claude-code-proxy 0.1.16'; Minimum = '0.1.17'; Expected = $false },
    @{ Actual = 'not-a-version'; Minimum = '0.1.17'; Expected = $false },
    @{ Actual = ''; Minimum = '0.1.17'; Expected = $false }
)

foreach ($case in $cases) {
    $actualResult = Test-CcxVersionAtLeast $case.Actual $case.Minimum
    if ($actualResult -ne $case.Expected) {
        throw "Version comparison failed for '$($case.Actual)' >= '$($case.Minimum)': expected $($case.Expected), got $actualResult"
    }
}

if ((Get-CcxSemanticVersion 'prefix 12.34.56 suffix') -cne '12.34.56') {
    throw 'Semantic-version extraction failed'
}

Write-Output 'All PowerShell version tests passed.'
exit 0
