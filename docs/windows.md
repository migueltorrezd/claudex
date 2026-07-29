# Windows

Claudex supports Windows 10/11 with **Windows PowerShell 5.1**. The launcher, configuration, and scheduled task are per-user: no administrator session is required. It does not modify your native `claude` or `codex` commands.

The proxy is always configured to stay on `127.0.0.1` (default port `18765`). Do not change it to a LAN or public bind address; the proxy does not authenticate incoming clients. Read the repository's [security guidance](../SECURITY.md) before changing any proxy networking setting.

## Requirements

- Windows 10 or Windows 11 with Windows PowerShell 5.1 (`$PSVersionTable.PSVersion`).
- [Git for Windows](https://git-scm.com/download/win).
- [Claude Code](https://code.claude.com/docs/en/setup) 2.1.217 or newer, available as `claude` on `PATH`.
- A ChatGPT plan with Codex access. Availability varies by account.
- Internet access to download the published `claude-code-proxy` Windows binary during installation.

Use an ordinary PowerShell window. The installer changes only user-scoped settings; do not run it elevated unless your own environment requires that.

## Clone and use the setup wizard

```powershell
Set-Location $HOME
git clone https://github.com/migueltorrezd/claudex.git
Set-Location .\claudex
.\scripts\setup.ps1
```

If your execution policy blocks local scripts, use a process-only bypass rather than changing the machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

The wizard shows the recommended/current value for each choice, displays a summary, and asks for confirmation before writing files. Its defaults are:

| Choice | Default |
|---|---|
| Main session | `sol` at `xhigh` effort |
| `ccx bg` lane | `sol` at `medium` effort |
| Utility requests | `sol` (`gpt-5.6-sol[1m]`) |
| Optional custom worker | `high` effort |
| Install custom worker | Yes |
| Start interactive OAuth when needed | Yes |
| Register/start the proxy at logon | Yes |

Every model lane has a normal and `-fast` alias: `sol`, `terra`, `luna`, `5.5`, `5.4`, `mini`, `5.3`, `spark`, and `5.2`, plus `sol-fast`, `terra-fast`, `luna-fast`, `5.5-fast`, `5.4-fast`, `mini-fast`, `5.3-fast`, `spark-fast`, and `5.2-fast`. Session effort values are `low`, `medium`, `high`, `xhigh`, `max`, and `ultracode`; the optional custom worker supports up to `max`.

For unattended use, pass explicit choices and `-Yes`. `-ConfigOnly` writes only the configuration. Run `Get-Help .\scripts\setup.ps1 -Detailed` for the complete parameter list. The corresponding choices are `-MainModel`, `-MainEffort`, `-BgModel`, `-BgEffort`, `-UtilityModel`, `-SubagentEffort`, `-WithAgent`/`-WithoutAgent`, `-Login`/`-NoLogin`, `-StartService`/`-NoService`, `-ConfigOnly`, and `-Yes`.

## Deterministic installation

For automation, use the installer with the tested defaults:

```powershell
.\scripts\install.ps1 -WithAgent
```

`install.ps1` accepts `-WithAgent`, `-Login`, `-NoService`, `-NoPath`, and `-Help`. Use `-NoPath` when you do not want the installer to touch your **User** `PATH` at all. It validates the supported Claude Code and proxy versions, downloads a checksum-verified upstream Windows proxy only if no proxy binary is already present (it does not update an existing binary), preserves an existing configuration, installs the `ccx` launcher, and optionally renders the managed worker. If authentication is missing, it stops with instructions unless `-Login` was supplied. OAuth is interactive; complete it in the browser and rerun the installer if necessary:

```powershell
claude-code-proxy codex auth login
.\scripts\install.ps1 -WithAgent
```

Do not copy an OAuth token into a script, a configuration file, or this repository.

## PATH and service behavior

The launcher is installed into the per-user location selected by `CCX_INSTALL_DIR` (by default, `%LOCALAPPDATA%\Claudex\bin`). The installer can add that directory to the **User** `PATH`; a new terminal is required before `ccx` resolves by name. It does not modify the Machine `PATH`.

Unless `-NoService` is selected, setup registers a per-user Scheduled Task named `Claudex Proxy` that starts `claude-code-proxy serve --no-monitor` at logon with the configured Codex transport. It is not a Windows service and does not require administrator rights. `ccx` checks `http://127.0.0.1:18765/healthz`; if the task did not start the proxy, it starts the proxy for the current user and waits briefly for the health check. The task and proxy keep the loopback-only bind address.

To inspect the task without changing it:

```powershell
Get-ScheduledTask -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue
Get-ScheduledTaskInfo -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue
```

## Configuration and overrides

The wizard configuration defaults to `%APPDATA%\Claudex\config`. Override its directory before running setup with `CCX_CONFIG_DIR`, or point the launcher at an individual file with `CCX_CONFIG_FILE`. The installer location and custom-agent directory can be changed with `CCX_INSTALL_DIR` and `CCX_AGENT_DIR`.

The configuration is plain `key=value` model preferences; it is not executed, and it must not contain credentials. Environment variables override values saved in the file, and an explicit `ccx` command-line model/effort choice overrides the saved default. Supported launcher overrides are:

| Variable | Default | Purpose |
|---|---:|---|
| `CCX_CONFIG_FILE` | `%APPDATA%\Claudex\config` | Persistent wizard configuration |
| `CCX_MODEL` | `sol` | Main model alias or supported ID |
| `CCX_MAIN_EFFORT` | `xhigh` | Normal root-session effort |
| `CCX_BG_MODEL` | `sol` | Model selected by `ccx bg` |
| `CCX_BG_EFFORT` | `medium` | Root-session effort for `ccx bg` |
| `CCX_SMALL_FAST_MODEL` | `gpt-5.6-sol[1m]` | Utility/background-request model |
| `CCX_CONTEXT_WINDOW` | Per-model | Auto-compaction boundary (`272000`; Spark `128000`) |
| `CCX_PROXY_URL` | `http://127.0.0.1:18765` | Local proxy URL |
| `CCX_PROXY_TRANSPORT` | `http` | Proxy-to-Codex transport: `http`, `websocket`, or `auto` |
| `CCX_SHIM_URL` | unset | Optional local retry-shim URL |
| `CCX_SUBAGENT_GUARDS` | `1` | Apply the bounded agent and request defaults below |
| `CCX_MAX_CONCURRENT_SUBAGENTS` | `3` | Maximum simultaneously active sub-agents |
| `CCX_MAX_SUBAGENTS_PER_SESSION` | `12` | Maximum sub-agents spawned in one session |
| `CCX_MAX_SUBAGENT_SPAWN_DEPTH` | `1` | Allow root delegation but prevent recursive fan-out |
| `CCX_MAX_RETRIES` | `3` | Claude Code request-retry ceiling |
| `CCX_API_TIMEOUT_MS` | `300000` | Claude Code per-request deadline in milliseconds |
| `CCX_REAL_CLAUDE` | first `claude` on `PATH` | Claude Code executable |

For example:

```powershell
$env:CCX_MODEL = 'terra'
$env:CCX_MAIN_EFFORT = 'high'
ccx
```

## Usage

Open a new PowerShell window after installation, then run:

```powershell
.\scripts\doctor.ps1
ccx models
ccx config
ccx
ccx bg
ccx solo -p 'Review this repository without delegating'
ccx terra
ccx --effort high -p 'Review this diff'
ccx bg --bg 'Run the test suite and fix failures'
```

`ccx bg` selects the configured background lane but does not detach on its own. Add Claude Code's `--bg` option when you want a managed background agent.

`ccx solo` (also `ccx no-agents`) removes the Agent tool for that session. The normal defaults allow three active sub-agents, twelve total spawns, and one spawn level; direct `CLAUDE_CODE_MAX_*` environment variables still take precedence when you intentionally need different limits.

## Diagnostics

`.\scripts\doctor.ps1` checks dependency versions, launcher configuration, OAuth status, Scheduled Task state, and the loopback health endpoint without making a model request. It does not print credentials.

Useful checks:

```powershell
Get-Command ccx, claude, claude-code-proxy -ErrorAction SilentlyContinue
ccx config
Invoke-WebRequest http://127.0.0.1:18765/healthz -UseBasicParsing
claude-code-proxy codex auth status
Get-ScheduledTaskInfo -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue
```

## Update

Update Claudex and rerun setup to preserve or revise your preferences:

```powershell
git pull --ff-only
.\scripts\setup.ps1
.\scripts\doctor.ps1
```

The installer updates only Claudex-managed launcher and worker files. It refuses to overwrite an unmanaged file at either target. Review upstream release notes before updating `claude-code-proxy`.

Run the deterministic Windows test suite after an update:

```powershell
.\tests\test-ccx.ps1
.\tests\test-setup.ps1
.\tests\test-install.ps1
.\tests\test-version.ps1
```

## Troubleshooting

- **`ccx` is not recognized:** Open a new PowerShell window. Check `[Environment]::GetEnvironmentVariable('Path', 'User')`; if the install directory is absent, add the `CCX_INSTALL_DIR` directory to User `PATH` manually, then restart the terminal.
- **PowerShell refuses to run a script:** use the process-only `-ExecutionPolicy Bypass` command shown above. Do not weaken the system-wide execution policy just for Claudex.
- **Health check fails:** run ` .\scripts\doctor.ps1`, inspect the `Claudex Proxy` task, and confirm that no other process is using port `18765`. Starting the task manually is safe: `Start-ScheduledTask -TaskName 'Claudex Proxy'`.
- **OAuth is missing or expired:** run `claude-code-proxy codex auth login` interactively, then rerun the selected setup command. Never paste tokens into config or logs.
- **Another launcher or worker already exists:** the installer intentionally refuses to overwrite files without its Claudex managed marker. Set `CCX_INSTALL_DIR` or `CCX_AGENT_DIR` to a separate location, or review and move the conflicting file yourself.
- **A model is unavailable:** choose a model your ChatGPT account supports. The proxy recognizing a model does not guarantee account access.

## Security

The proxy accepts unauthenticated local connections, so keep it on `127.0.0.1`; do not expose port `18765` through a firewall rule, port forward, VPN, container bridge, tunnel, or reverse proxy unless you add and operate authenticated protection yourself. A local `ANTHROPIC_AUTH_TOKEN=unused` value is a dummy compatibility value, not an OpenAI or Anthropic secret.

Use only `claude-code-proxy codex auth login` (or the upstream documented device flow) for OAuth. Do not read, print, copy, commit, or share OAuth credential files. The configuration has model and effort settings only. See [SECURITY.md](../SECURITY.md) for the full threat model and limitation details.

## Safe manual uninstall

Uninstalling is deliberately manual. First close active `ccx` sessions. Then inspect every target and delete only files and settings you recognize as Claudex-managed:

```powershell
Stop-ScheduledTask -TaskName 'Claudex Proxy' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'Claudex Proxy' -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\Claudex\bin\lib\ccx.ps1"
Remove-Item "$env:LOCALAPPDATA\Claudex\bin\ccx.cmd"
Remove-Item "$HOME\.claude\agents\claudex-worker.md"
Remove-Item "$env:APPDATA\Claudex\config"
```

Remove `%LOCALAPPDATA%\Claudex\bin` from the **User** `PATH` only if you added it for Claudex and it contains no other tools. Removing Claudex does not uninstall Claude Code, Codex, `claude-code-proxy`, or OAuth credentials. Remove the proxy or revoke its OAuth access using the upstream project's documented procedures if that is your intent.
