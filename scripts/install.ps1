<#
.SYNOPSIS
Installs Claudex for the current Windows user.

.DESCRIPTION
Validates Claude Code, installs a checksum-verified Windows release of
raine/claude-code-proxy when no proxy is available, preserves existing
configuration, installs the managed ccx launchers, adds the install directory
to the User PATH, and optionally installs the managed worker and registers a
per-user logon Scheduled Task.

OAuth remains with claude-code-proxy. This script never reads or writes token
files and never makes a model request.

.PARAMETER WithAgent
Installs or updates the optional managed claudex-worker agent.

.PARAMETER Login
Starts interactive Codex OAuth if authentication is not healthy.

.PARAMETER NoService
Does not register or start the Claudex Proxy logon Scheduled Task.

.PARAMETER NoPath
Does not add the Claudex install directory to the User PATH.

.PARAMETER Help
Shows detailed installer help and exits without changing anything.

.EXAMPLE
.\scripts\install.ps1 -WithAgent

.EXAMPLE
.\scripts\install.ps1 -WithAgent -Login

.EXAMPLE
.\scripts\install.ps1 -NoService
#>
[CmdletBinding()]
param(
    [switch]$WithAgent,
    [switch]$Login,
    [switch]$NoService,
    [switch]$NoPath,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:launcherMarker = '# Managed by https://github.com/migueltorrezd/claudex'
$script:cmdMarker = 'REM Managed by https://github.com/migueltorrezd/claudex'
$script:agentMarker = '<!-- Managed by https://github.com/migueltorrezd/claudex -->'
$script:taskMarker = 'Managed by https://github.com/migueltorrezd/claudex'
$script:taskName = 'Claudex Proxy'

function Stop-Install {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 1
    )

    $exception = New-Object System.Exception $Message
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Get-ExternalCommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($command in @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -eq 'Application' -or $command.CommandType -eq 'ExternalScript') {
            foreach ($candidate in @($command.Path, $command.Source, $command.Definition)) {
                if ($candidate) {
                    return [string]$candidate
                }
            }
        }
    }

    return ''
}

function Assert-ManagedTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        Stop-Install "install: refusing to overwrite existing non-file ${Kind}: $Target"
    }

    $contents = [IO.File]::ReadAllText($Target)
    if ($contents.IndexOf($Marker, [StringComparison]::Ordinal) -lt 0) {
        Stop-Install "install: refusing to overwrite existing unmanaged ${Kind}: $Target`ninstall: review it, move it, or select another target directory."
    }
}

function Write-ManagedBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if (Test-Path -LiteralPath $Target) {
        if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
            Stop-Install "install: refusing to overwrite existing non-file ${Kind}: $Target"
        }

        try {
            $stream = [IO.File]::Open($Target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch {
            Stop-Install "install: could not lock existing ${Kind} for a safe managed update: $Target"
        }

        try {
            $existingBytes = New-Object byte[] $stream.Length
            $offset = 0
            while ($offset -lt $existingBytes.Length) {
                $read = $stream.Read($existingBytes, $offset, $existingBytes.Length - $offset)
                if ($read -eq 0) {
                    break
                }
                $offset += $read
            }
            $contents = [Text.Encoding]::UTF8.GetString($existingBytes, 0, $offset)
            if ($contents.IndexOf($Marker, [StringComparison]::Ordinal) -lt 0) {
                Stop-Install "install: refusing to overwrite existing unmanaged ${Kind}: $Target`ninstall: review it, move it, or select another target directory."
            }

            $stream.Position = 0
            $stream.SetLength(0)
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }
        return
    }

    try {
        $stream = [IO.File]::Open($Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch {
        Stop-Install "install: ${Kind} target appeared during installation; refusing to overwrite it: $Target"
    }

    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $targetPath = [IO.Path]::GetFullPath($Target)
    if ($sourcePath -ieq $targetPath) {
        return
    }

    Write-ManagedBytes `
        -Target $Target `
        -Bytes ([IO.File]::ReadAllBytes($Source)) `
        -Marker $Marker `
        -Kind $Kind
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $value = ''
    # Configuration is parsed only as plain key=value text; it is never executed.
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $candidateKey = $line.Substring(0, $separator).Trim()
        if ($candidateKey -ceq $Key) {
            $value = $line.Substring($separator + 1).Trim()
        }
    }

    return $value
}

function Get-NormalizedPathEntry {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    $candidate = $Path.Trim().Trim('"')
    if (-not $candidate) {
        return ''
    }

    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    try {
        $candidate = [IO.Path]::GetFullPath($candidate)
    }
    catch {
        # Keep an unusual PATH entry comparable without rewriting it.
    }

    return $candidate.TrimEnd([char[]]@('\', '/'))
}

function Test-PathListContains {
    param(
        [AllowNull()][string]$PathList,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $wanted = Get-NormalizedPathEntry $Directory
    foreach ($entry in @([string]$PathList -split ';')) {
        if ((Get-NormalizedPathEntry $entry) -ieq $wanted) {
            return $true
        }
    }

    return $false
}

function Add-InstallDirectoryToPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $added = $false
    if (-not (Test-PathListContains $userPath $Directory)) {
        if ([string]::IsNullOrEmpty($userPath)) {
            $newUserPath = $Directory
        }
        elseif ($userPath.EndsWith(';')) {
            $newUserPath = $userPath + $Directory
        }
        else {
            $newUserPath = $userPath + ';' + $Directory
        }

        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        $added = $true
    }

    if (-not (Test-PathListContains $env:Path $Directory)) {
        if ([string]::IsNullOrEmpty($env:Path)) {
            $env:Path = $Directory
        }
        else {
            $env:Path = $env:Path + ';' + $Directory
        }
    }

    return $added
}

function Get-CcxCommandBeforeDirectory {
    param(
        [AllowNull()][string]$PathList,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $wanted = Get-NormalizedPathEntry $Directory
    foreach ($entry in @([string]$PathList -split ';')) {
        $normalized = Get-NormalizedPathEntry $entry
        if (-not $normalized) {
            continue
        }
        if ($normalized -ieq $wanted) {
            return ''
        }

        foreach ($name in @('ccx.exe', 'ccx.com', 'ccx.cmd', 'ccx.bat', 'ccx.ps1', 'ccx')) {
            $candidate = Join-Path $normalized $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    return ''
}

function Get-ProxyArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($architecture) {
        '^(AMD64|x86_64)$' { return 'amd64' }
        '^(ARM64|AARCH64)$' { return 'arm64' }
        default {
            Stop-Install "install: unsupported Windows architecture '$architecture' (expected amd64 or arm64)"
        }
    }
}

function Install-VerifiedProxyRelease {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $architecture = Get-ProxyArchitecture
    $assetBase = "claude-code-proxy-windows-$architecture"
    $archiveName = "$assetBase.zip"
    $checksumName = "$assetBase.sha256"
    $apiUrl = 'https://api.github.com/repos/raine/claude-code-proxy/releases/latest'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'Claudex-Windows-Installer'
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('claudex-proxy-' + [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $tempRoot $archiveName
    $checksumPath = Join-Path $tempRoot $checksumName
    $extractPath = Join-Path $tempRoot 'extract'
    $stagedTarget = Join-Path $InstallDirectory ('.claude-code-proxy.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        New-Item -ItemType Directory -Path $extractPath | Out-Null

        Write-Host 'Locating the latest raine/claude-code-proxy release...'
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
        if (-not $release -or -not $release.tag_name -or -not $release.assets) {
            Stop-Install 'install: GitHub returned an incomplete latest-release response'
        }

        $archiveAssets = @($release.assets | Where-Object { $_.name -ceq $archiveName })
        $checksumAssets = @($release.assets | Where-Object { $_.name -ceq $checksumName })
        if ($archiveAssets.Count -ne 1 -or $checksumAssets.Count -ne 1) {
            Stop-Install "install: release $($release.tag_name) does not contain exactly one $archiveName and $checksumName"
        }

        $archiveUri = [Uri][string]$archiveAssets[0].browser_download_url
        $checksumUri = [Uri][string]$checksumAssets[0].browser_download_url
        $expectedPrefix = 'https://github.com/raine/claude-code-proxy/releases/download/'
        if (-not $archiveUri.AbsoluteUri.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $checksumUri.AbsoluteUri.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Install 'install: refusing unexpected release asset URL outside raine/claude-code-proxy'
        }

        Write-Host "Downloading checksum-verified proxy release $($release.tag_name) for $architecture..."
        Invoke-WebRequest -Uri $checksumUri.AbsoluteUri -Headers $headers -OutFile $checksumPath -UseBasicParsing
        Invoke-WebRequest -Uri $archiveUri.AbsoluteUri -Headers $headers -OutFile $archivePath -UseBasicParsing

        $checksumText = [IO.File]::ReadAllText($checksumPath)
        $checksumMatches = [regex]::Matches(
            $checksumText,
            '(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])'
        )
        $publishedHashes = @(
            $checksumMatches |
                ForEach-Object { $_.Value.ToUpperInvariant() } |
                Select-Object -Unique
        )
        if ($publishedHashes.Count -ne 1) {
            Stop-Install "install: $checksumName must contain exactly one SHA256 value"
        }

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne $publishedHashes[0]) {
            Stop-Install "install: SHA256 verification failed for $archiveName"
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        $proxyExecutables = @(
            [IO.Directory]::GetFiles(
                $extractPath,
                'claude-code-proxy.exe',
                [IO.SearchOption]::AllDirectories
            )
        )
        if ($proxyExecutables.Count -ne 1) {
            Stop-Install "install: verified archive must contain exactly one claude-code-proxy.exe"
        }

        Copy-Item -LiteralPath $proxyExecutables[0] -Destination $stagedTarget
        if (Test-Path -LiteralPath $Target) {
            Stop-Install "install: proxy target appeared during installation; refusing to overwrite it: $Target"
        }
        Move-Item -LiteralPath $stagedTarget -Destination $Target

        return [PSCustomObject]@{
            Path = $Target
            Tag = [string]$release.tag_name
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
        if (Test-Path -LiteralPath $stagedTarget -PathType Leaf) {
            Remove-Item -LiteralPath $stagedTarget -Force
        }
        if (Test-Path -LiteralPath $tempRoot -PathType Container) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Invoke-ProxyCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$SuppressOutput
    )

    try {
        $global:LASTEXITCODE = $null
        if ($SuppressOutput.IsPresent) {
            & $ProxyPath @Arguments *> $null
        }
        else {
            & $ProxyPath @Arguments | Out-Host
        }
        $commandSucceeded = $?

        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) {
            if ($commandSucceeded) {
                return 0
            }
            return 1
        }
        return [int]$exitCode
    }
    catch {
        return 1
    }
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
        Stop-Install "install: PowerShell host is unavailable: $hostPath"
    }
    return $hostPath
}

function Get-LoopbackProxyEndpoint {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        Stop-Install "install: invalid CCX_PROXY_URL '$Url'"
    }
    if ($uri.Scheme -cne 'http' -or $uri.Host -notin @('127.0.0.1', 'localhost', '::1')) {
        Stop-Install 'install: CCX_PROXY_URL must use http on the local loopback interface'
    }

    return [PSCustomObject]@{
        Url = $Url.TrimEnd('/')
        Port = [string]$uri.Port
    }
}

function Test-ProxyHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 2
    )

    try {
        $response = Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))/healthz" -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Get-ProxyTaskScript {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyPath,
        [Parameter(Mandatory = $true)][string]$Port
    )

    $escapedProxyPath = $ProxyPath.Replace("'", "''")
    return "`$env:CCP_BIND_ADDRESS='127.0.0.1'; `$env:PORT='$Port'; & '$escapedProxyPath' serve --port $Port --no-monitor"
}

function Get-ProxyTaskActionSpec {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyPath,
        [Parameter(Mandatory = $true)][string]$Port
    )

    $command = Get-ProxyTaskScript -ProxyPath $ProxyPath -Port $Port
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return [PSCustomObject]@{
        Execute = Get-PowerShellHostPath
        Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    }
}

function Test-ManagedProxyTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$ProxyPath
    )

    if ([string]$Task.TaskPath -cne '\' -or
        ([string]$Task.Description).IndexOf($script:taskMarker, [StringComparison]::Ordinal) -lt 0) {
        return $false
    }

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) {
        return $false
    }
    if ([IO.Path]::GetFileName([string]$actions[0].Execute) -notin @('powershell.exe', 'pwsh.exe')) {
        return $false
    }

    $argumentText = [string]$actions[0].Arguments
    $encodedMatch = [regex]::Match(
        $argumentText,
        '(?i)(?:^|\s)-EncodedCommand\s+(?<Value>[A-Za-z0-9+/=]+)(?:\s|$)'
    )
    if (-not $encodedMatch.Success) {
        return $false
    }

    try {
        $command = [Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($encodedMatch.Groups['Value'].Value)
        )
    }
    catch {
        return $false
    }

    $portMatch = [regex]::Match($command, '\$env:PORT=''(?<Port>\d{1,5})''')
    if (-not $portMatch.Success) {
        return $false
    }
    $port = $portMatch.Groups['Port'].Value
    return ($command -ceq (Get-ProxyTaskScript -ProxyPath $ProxyPath -Port $port))
}

function Register-AndStartProxyTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyPath,
        [Parameter(Mandatory = $true)][string]$ProxyUrl
    )

    foreach ($commandName in @(
        'Get-ScheduledTask',
        'New-ScheduledTaskAction',
        'New-ScheduledTaskTrigger',
        'New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet',
        'New-ScheduledTask',
        'Register-ScheduledTask',
        'Start-ScheduledTask'
    )) {
        if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw "ScheduledTasks command is unavailable: $commandName"
        }
    }

    $endpoint = Get-LoopbackProxyEndpoint $ProxyUrl
    $actionSpec = Get-ProxyTaskActionSpec -ProxyPath $ProxyPath -Port $endpoint.Port
    $existingTasks = @(Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue)
    if ($existingTasks.Count -gt 1 -or
        ($existingTasks.Count -eq 1 -and -not (Test-ManagedProxyTask -Task $existingTasks[0] -ProxyPath $ProxyPath))) {
        $exception = New-Object System.Exception "install: refusing to overwrite existing unmanaged or unexpected Scheduled Task '$($script:taskName)'. If this task is safe to replace, remove it first with: Stop-ScheduledTask -TaskName '$($script:taskName)' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName '$($script:taskName)' -Confirm:`$false"
        $exception.Data['TaskConflict'] = $true
        throw $exception
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction `
        -Execute $actionSpec.Execute `
        -Argument $actionSpec.Arguments `
        -WorkingDirectory (Split-Path -Parent $ProxyPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "$($script:taskMarker); loopback proxy for the current user."

    Register-ScheduledTask -TaskName $script:taskName -InputObject $task -Force | Out-Null
    Start-ScheduledTask -TaskName $script:taskName

    for ($attempt = 1; $attempt -le 100; $attempt++) {
        if (Test-ProxyHealth -Url $endpoint.Url) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Scheduled Task started, but the proxy did not become healthy at $($endpoint.Url)/healthz"
}

function Invoke-Install {
    if ($Help.IsPresent) {
        Get-Help -Name $PSCommandPath -Detailed
        return
    }
    if ($env:OS -cne 'Windows_NT') {
        Stop-Install 'install: this installer supports Windows only'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5 -or
        ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        Stop-Install 'install: Windows PowerShell 5.1 or newer is required'
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $userProfile = $env:USERPROFILE
    if (-not $userProfile) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }

    if (-not $userProfile) {
        Stop-Install 'install: the user profile directory is unavailable; set CCX_AGENT_DIR explicitly'
    }
    if (-not $localAppData -and -not $env:CCX_INSTALL_DIR) {
        Stop-Install 'install: LOCALAPPDATA is unavailable; set CCX_INSTALL_DIR explicitly'
    }
    if (-not $appData -and -not $env:CCX_CONFIG_FILE -and -not $env:CCX_CONFIG_DIR -and -not $env:XDG_CONFIG_HOME) {
        Stop-Install 'install: APPDATA is unavailable; set CCX_CONFIG_FILE, CCX_CONFIG_DIR, or XDG_CONFIG_HOME explicitly'
    }

    if ($env:CCX_INSTALL_DIR) {
        $installDir = $env:CCX_INSTALL_DIR
    }
    else {
        $installDir = Join-Path $localAppData 'Claudex\bin'
    }
    if ($env:CCX_AGENT_DIR) {
        $agentDir = $env:CCX_AGENT_DIR
    }
    else {
        $agentDir = Join-Path $userProfile '.claude\agents'
    }
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
        $configDir = Join-Path $appData 'Claudex'
        $configTarget = Join-Path $configDir 'config'
    }
    if ($env:CCX_CONFIG_SOURCE) {
        $configSource = $env:CCX_CONFIG_SOURCE
    }
    else {
        $configSource = Join-Path $repoRoot 'config\claudex.conf.example'
    }

    $launcherPsSource = Join-Path $repoRoot 'bin\ccx.ps1'
    $launcherCmdSource = Join-Path $repoRoot 'bin\ccx.cmd'
    $agentSource = Join-Path $repoRoot 'examples\agents\claudex-worker.md'
    $launcherLibDir = Join-Path $installDir 'lib'
    $launcherPsTarget = Join-Path $launcherLibDir 'ccx.ps1'
    $launcherCmdTarget = Join-Path $installDir 'ccx.cmd'
    $proxyTarget = Join-Path $installDir 'claude-code-proxy.exe'
    $agentTarget = Join-Path $agentDir 'claudex-worker.md'

    foreach ($requiredFile in @($launcherPsSource, $launcherCmdSource, $configSource)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            Stop-Install "install: required source file not found: $requiredFile"
        }
    }
    if (-not (Get-ExternalCommandPath 'claude')) {
        Stop-Install 'install: Claude Code is missing. Install it from https://code.claude.com/docs/en/setup'
    }
    if (Test-Path -LiteralPath $configTarget) {
        if (-not (Test-Path -LiteralPath $configTarget -PathType Leaf)) {
            Stop-Install "install: configuration target exists but is not a file: $configTarget"
        }
    }
    if (Test-Path -LiteralPath $proxyTarget) {
        if (-not (Test-Path -LiteralPath $proxyTarget -PathType Leaf)) {
            Stop-Install "install: proxy target exists but is not a file: $proxyTarget"
        }
    }

    # Refuse all managed-file conflicts before downloading or changing user state.
    Assert-ManagedTarget $launcherPsTarget $script:launcherMarker 'launcher'
    Assert-ManagedTarget $launcherCmdTarget $script:cmdMarker 'launcher shim'

    $subagentEffort = ''
    $renderedAgent = ''
    if ($WithAgent.IsPresent) {
        if (-not (Test-Path -LiteralPath $agentSource -PathType Leaf)) {
            Stop-Install "install: required agent template not found: $agentSource"
        }
        if ($env:CCX_SUBAGENT_EFFORT) {
            $subagentEffort = $env:CCX_SUBAGENT_EFFORT
        }
        elseif (Test-Path -LiteralPath $configTarget -PathType Leaf) {
            $subagentEffort = Get-ConfigValue $configTarget 'CCX_SUBAGENT_EFFORT'
        }
        else {
            $subagentEffort = Get-ConfigValue $configSource 'CCX_SUBAGENT_EFFORT'
        }
        if (-not $subagentEffort) {
            $subagentEffort = 'high'
        }
        if (-not (@('low', 'medium', 'high', 'xhigh', 'max') -ccontains $subagentEffort)) {
            Stop-Install "install: unsupported sub-agent effort: $subagentEffort"
        }

        $agentTemplate = [IO.File]::ReadAllText($agentSource)
        $renderedAgent = [regex]::Replace(
            $agentTemplate,
            '(?m)^effort: .*$',
            "effort: $subagentEffort"
        )
        Assert-ManagedTarget $agentTarget $script:agentMarker 'agent'

        $agentSourcePath = [IO.Path]::GetFullPath($agentSource)
        $agentTargetPath = [IO.Path]::GetFullPath($agentTarget)
        if ($agentSourcePath -ieq $agentTargetPath -and
            $renderedAgent -cne $agentTemplate) {
            Stop-Install 'install: refusing to render the agent over its repository template; set CCX_AGENT_DIR to an install directory'
        }
    }

    foreach ($directory in @($installDir, $launcherLibDir)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    $proxyPath = ''
    $proxyRelease = ''
    if (Test-Path -LiteralPath $proxyTarget -PathType Leaf) {
        $proxyPath = $proxyTarget
        Write-Host "Using existing proxy: $proxyPath"
    }
    else {
        $proxyPath = Get-ExternalCommandPath 'claude-code-proxy'
        if ($proxyPath) {
            Write-Host "Using existing proxy: $proxyPath"
        }
        else {
            $installedProxy = Install-VerifiedProxyRelease $installDir $proxyTarget
            $proxyPath = $installedProxy.Path
            $proxyRelease = $installedProxy.Tag
            Write-Host "Installed verified proxy $proxyRelease to $proxyPath"
        }
    }

    $pathAdded = $false
    $pathState = 'skipped (-NoPath)'

    $authStatus = Invoke-ProxyCommand $proxyPath @('codex', 'auth', 'status') -SuppressOutput
    if ($authStatus -ne 0) {
        if ($Login.IsPresent) {
            Write-Host 'Codex OAuth needs interactive approval. Starting the upstream browser login...'
            $loginStatus = Invoke-ProxyCommand $proxyPath @('codex', 'auth', 'login')
            if ($loginStatus -ne 0) {
                Stop-Install 'install: Codex OAuth login did not complete successfully' 2
            }
            $authStatus = Invoke-ProxyCommand $proxyPath @('codex', 'auth', 'status') -SuppressOutput
            if ($authStatus -ne 0) {
                Stop-Install 'install: Codex OAuth is still not healthy; rerun claude-code-proxy codex auth login, then rerun this installer' 2
            }
        }
        else {
            [Console]::WriteLine('')
            [Console]::WriteLine('Codex OAuth needs interactive approval. Run:')
            [Console]::WriteLine('')
            [Console]::WriteLine('  claude-code-proxy codex auth login')
            [Console]::WriteLine('')
            [Console]::WriteLine('Then rerun this installer. No token needs to be copied into Claudex.')
            Stop-Install 'install: authentication is required' 2
        }
    }


    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    # Use an exclusive atomic create so a config file that appears between the
    # existence check and the write (TOCTOU) is never silently overwritten;
    # if creation loses that race, the existing config is preserved untouched.
    $configBytes = [IO.File]::ReadAllBytes($configSource)
    $configStream = $null
    try {
        $configStream = [IO.File]::Open($configTarget, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        $configStream = $null
    }
    if ($configStream) {
        try {
            $configStream.Write($configBytes, 0, $configBytes.Length)
            $configStream.Flush()
        }
        finally {
            $configStream.Dispose()
        }
    }
    else {
        Write-Host "Preserving existing config: $configTarget"
    }

    Copy-ManagedFile `
        -Source $launcherPsSource `
        -Target $launcherPsTarget `
        -Marker $script:launcherMarker `
        -Kind 'PowerShell launcher'
    Copy-ManagedFile `
        -Source $launcherCmdSource `
        -Target $launcherCmdTarget `
        -Marker $script:cmdMarker `
        -Kind 'launcher shim'

    if ($WithAgent.IsPresent) {
        if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) {
            New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
        }

        $agentSourcePath = [IO.Path]::GetFullPath($agentSource)
        $agentTargetPath = [IO.Path]::GetFullPath($agentTarget)
        if ($agentSourcePath -ine $agentTargetPath) {
            $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
            Write-ManagedBytes `
                -Target $agentTarget `
                -Bytes ($utf8WithoutBom.GetBytes($renderedAgent)) `
                -Marker $script:agentMarker `
                -Kind 'agent'
        }
    }

    if (-not $NoPath.IsPresent) {
        $pathAdded = Add-InstallDirectoryToPath $installDir
        $pathState = if ($pathAdded) { "added $installDir" } else { "already contains $installDir" }

        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $effectivePath = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
        $shadowingCommand = Get-CcxCommandBeforeDirectory -PathList $effectivePath -Directory $installDir
        if ($shadowingCommand) {
            [Console]::Error.WriteLine("install: warning: '$shadowingCommand' appears before the Claudex directory on a new terminal's PATH.")
            [Console]::Error.WriteLine("install: bare 'ccx' may resolve to that command; reorder PATH or invoke '$launcherCmdTarget' explicitly.")
        }
    }

    $proxyUrl = $env:CCX_PROXY_URL
    if (-not $proxyUrl) {
        $proxyUrl = Get-ConfigValue $configTarget 'CCX_PROXY_URL'
    }
    if (-not $proxyUrl) {
        $proxyUrl = 'http://127.0.0.1:18765'
    }

    $taskState = 'skipped (-NoService)'
    if (-not $NoService.IsPresent) {
        try {
            Register-AndStartProxyTask -ProxyPath $proxyPath -ProxyUrl $proxyUrl
            $taskState = 'registered, started, and healthy'
        }
        catch {
            if ($_.Exception.Data['TaskConflict']) {
                throw
            }
            $taskState = 'not started (see warning)'
            [Console]::Error.WriteLine("install: warning: could not register/start the per-user '$($script:taskName)' task: $($_.Exception.Message)")
            [Console]::Error.WriteLine('install: continuing; ccx can start the proxy on demand, or rerun with -NoService.')
        }
    }

    [Console]::WriteLine('')
    [Console]::WriteLine('Claudex installed.')
    [Console]::WriteLine("  Launcher: $launcherCmdTarget")
    [Console]::WriteLine("  PowerShell launcher: $launcherPsTarget")
    [Console]::WriteLine("  Proxy:    $proxyPath")
    if ($proxyRelease) {
        [Console]::WriteLine("  Release:  $proxyRelease (SHA256 verified)")
    }
    [Console]::WriteLine("  Config:   $configTarget")
    if ($WithAgent.IsPresent) {
        [Console]::WriteLine("  Agent:    $agentTarget ($subagentEffort effort)")
    }
    [Console]::WriteLine("  User PATH: $pathState")
    [Console]::WriteLine("  Scheduled Task: $taskState")
    [Console]::WriteLine('')
    [Console]::WriteLine('Open a new terminal, then run: ccx models')
    [Console]::WriteLine("Then: $(Join-Path $repoRoot 'scripts\doctor.ps1')")
}

$exitCode = 0
try {
    Invoke-Install
}
catch {
    $message = $_.Exception.Message
    if (-not $message.StartsWith('install:', [StringComparison]::OrdinalIgnoreCase)) {
        $message = "install: $message"
    }
    [Console]::Error.WriteLine($message)

    $storedExitCode = $_.Exception.Data['ExitCode']
    if ($null -ne $storedExitCode) {
        $exitCode = [int]$storedExitCode
    }
    else {
        $exitCode = 1
    }
}

exit $exitCode
