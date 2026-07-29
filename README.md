# Claudex

Run the Claude Code harness with GPT models from a ChatGPT subscription.

Claudex is a small, opinionated setup layer around [Claude Code](https://code.claude.com/docs/en/overview) and [Raine's `claude-code-proxy`](https://github.com/raine/claude-code-proxy). You keep Claude Code's interface, tools, skills, hooks, permissions, and agents while requests are translated to the Codex Responses backend.

> [!IMPORTANT]
> The translation layer is the work of [Raine (`@raine`)](https://github.com/raine) and the [`claude-code-proxy` contributors](https://github.com/raine/claude-code-proxy/graphs/contributors). Claudex only packages a launcher, tested defaults, and setup documentation. If this is useful, please star and support the upstream project.

## What you get

- `ccx`: a separate launcher, so normal `claude` and `codex` remain untouched.
- GPT-5.6 Sol by default, with shortcuts for the other models currently recognized by the proxy.
- Sol for Claude Code's small/background utility requests instead of silently falling back to a Haiku alias the proxy cannot route.
- Sol at medium effort for the dedicated `ccx bg` lane.
- An optional custom background sub-agent configured at high effort.
- An interactive wizard that asks which models and effort levels you want.
- Proxy health checks and automatic Homebrew service recovery.
- Bounded sub-agent fan-out, request retries, and request timeouts by default.
- A `ccx solo` escape hatch that disables the Agent tool for one session.
- No API key in the repository. Authentication is handled by the proxy's Codex OAuth flow.

```mermaid
flowchart LR
    U[You] --> C[Claude Code UI and tools]
    C --> X[ccx launcher]
    X --> P[claude-code-proxy on localhost]
    P --> O[Codex Responses backend]
    O --> G[GPT model from your ChatGPT plan]
```

## Requirements

- macOS or Linux with Homebrew, or Windows 10/11 with Windows PowerShell 5.1.
- [Claude Code](https://code.claude.com/docs/en/setup) 2.1.217 or newer. That is the first release supporting all three configurable sub-agent limits.
- [Homebrew](https://brew.sh/) installed.
- [`claude-code-proxy`](https://github.com/raine/claude-code-proxy) 0.1.17 or newer. The installer adds it when missing.
- A ChatGPT plan with Codex access. Model availability varies by account and can change.
- Git for cloning this repository.

For Windows PowerShell 5.1 installation, see the [Windows guide](docs/windows.md).

## Five-minute setup

```bash
git clone https://github.com/migueltorrezd/claudex.git
cd claudex
./scripts/setup.sh
```

On Windows PowerShell 5.1:

```powershell
git clone https://github.com/migueltorrezd/claudex.git
Set-Location .\claudex
.\scripts\setup.ps1
```

See the [Windows guide](docs/windows.md) for requirements, PATH, and logon-service details.

The wizard asks you to choose:

1. The main model and its reasoning effort.
2. The model and effort for the `ccx bg` lane.
3. The utility model used for titles, token counting, and small background requests.
4. The optional custom sub-agent's effort.
5. Whether to install that agent, complete OAuth, and start the background service.

Every question shows the recommended/current value. Before writing anything, the wizard displays a complete summary and asks for confirmation. Preferences are saved to `~/.config/claudex/config` (on Windows, `%APPDATA%\Claudex\config` by default, following the precedence `CCX_CONFIG_FILE` -> `CCX_CONFIG_DIR\config` -> `XDG_CONFIG_HOME\claudex\config` -> `%APPDATA%\Claudex\config`); an existing config is backed up before it changes. OAuth credentials are never stored there.

The tested defaults are:

- Main session: GPT-5.6 Sol at `xhigh` effort.
- Background lane: GPT-5.6 Sol at `medium` effort.
- Utility requests: GPT-5.6 Sol.
- Custom sub-agent: `high` effort.
- Proxy Codex transport: `http` for reliable large workflow fan-out.
- Sub-agent safety: at most 3 concurrent, 12 total per session, and one spawn level.
- Request safety: at most 3 Claude Code retries and a 5-minute request deadline.

If Codex OAuth is not configured yet and you decline browser login in the wizard, run:

```bash
claude-code-proxy codex auth login
./scripts/setup.sh
```

On Windows PowerShell 5.1:

```powershell
claude-code-proxy codex auth login
.\scripts\setup.ps1
```

The first command opens the official browser OAuth flow. On a headless machine, use:

```bash
claude-code-proxy codex auth device
```

(Windows: the same `claude-code-proxy codex auth device` command works from PowerShell.)

Then make sure `~/.local/bin` is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add that line to `~/.zshrc` or `~/.bashrc` if necessary.

On Windows, the installer can add its per-user launcher directory (`CCX_INSTALL_DIR`, default `%LOCALAPPDATA%\Claudex\bin`) to your **User** `PATH` automatically; see the [Windows guide](docs/windows.md#path-and-service-behavior) if you need to add it manually.

For non-default locations, set `CCX_INSTALL_DIR`, `CCX_AGENT_DIR`, or `CCX_CONFIG_DIR`.

For automation or an AI agent, keep the deterministic installer:

```bash
./scripts/install.sh --with-agent
```

On Windows PowerShell 5.1:

```powershell
.\scripts\install.ps1 -WithAgent
```

The wizard also accepts explicit non-interactive flags. Run `./scripts/setup.sh --help` for the full list (on Windows, `Get-Help .\scripts\setup.ps1 -Detailed`).

Verify the complete installation:

```bash
./scripts/doctor.sh
ccx models
ccx config
ccx
```

On Windows PowerShell 5.1:

```powershell
.\scripts\doctor.ps1
ccx models
ccx config
ccx
```

## Give this repository to an agent

Claude Code reads `CLAUDE.md`; Codex reads `AGENTS.md`. Both contain the same safe installation protocol.

You can tell either agent:

```text
Clone https://github.com/migueltorrezd/claudex, read its AGENTS.md or CLAUDE.md,
and install it. Do not read, print, copy, or commit OAuth credentials. If Codex
OAuth needs browser approval, stop and ask me to complete it. Run the doctor
script afterward and report the final model, effort, auth, service, and health state.
```

## Usage

```bash
ccx                         # GPT-5.6 Sol, xhigh root-session effort
ccx bg                      # GPT-5.6 Sol, medium root-session effort
ccx bg --bg "Refactor it"  # launch that lane as a real Claude background agent
ccx solo -p "Review this"   # run with the Agent tool disabled
ccx terra                   # GPT-5.6 Terra
ccx terra-fast              # GPT-5.6 Terra, priority service tier
ccx luna                    # GPT-5.6 Luna
ccx 5.5                     # GPT-5.5
ccx 5.4                     # GPT-5.4
ccx mini                    # GPT-5.4 Mini
ccx spark                   # GPT-5.3 Codex Spark
ccx models                  # show all launcher aliases
```

All remaining arguments pass through to Claude Code:

```bash
ccx -p "Explain this repository"
ccx --effort high -p "Review this diff"
ccx bg --bg "Run the test suite and fix failures"
```

`ccx bg` selects the Sol/medium lane. It does not detach by itself. Add Claude Code's own `--bg` flag when you want a managed background agent, as shown above.

### Configuration

The launcher supports these environment overrides:

| Variable | Default | Purpose |
|---|---:|---|
| `CCX_CONFIG_FILE` | `~/.config/claudex/config` | Persistent wizard configuration |
| `CCX_MODEL` | `sol` | Default main model alias or supported model ID |
| `CCX_MAIN_EFFORT` | `xhigh` | Normal root-session effort |
| `CCX_BG_MODEL` | `sol` | Model used by `ccx bg` |
| `CCX_BG_EFFORT` | `medium` | Root-session effort for `ccx bg` |
| `CCX_SMALL_FAST_MODEL` | `gpt-5.6-sol[1m]` | Claude utility/background-request model |
| `CCX_CONTEXT_WINDOW` | Per-model | Auto-compaction boundary (`272000`; Spark `128000`) |
| `CCX_PROXY_URL` | `http://127.0.0.1:18765` | Local proxy URL |
| `CCX_PROXY_TRANSPORT` | `http` | Proxy-to-Codex transport: `http`, `websocket`, or `auto` |
| `CCX_SHIM_URL` | unset | Optional bounded retry-shim URL |
| `CCX_SUBAGENT_GUARDS` | `1` | Apply the limits below; set `0` to opt out |
| `CCX_MAX_CONCURRENT_SUBAGENTS` | `3` | Maximum simultaneously active sub-agents |
| `CCX_MAX_SUBAGENTS_PER_SESSION` | `12` | Maximum sub-agents spawned in one session |
| `CCX_MAX_SUBAGENT_SPAWN_DEPTH` | `1` | Allow root delegation but prevent recursive fan-out |
| `CCX_MAX_RETRIES` | `3` | Claude Code request-retry ceiling |
| `CCX_API_TIMEOUT_MS` | `300000` | Claude Code per-request deadline in milliseconds |
| `CCX_REAL_CLAUDE` | first `claude` on `PATH` | Claude Code executable |

Example:

```bash
CCX_MODEL=terra CCX_MAIN_EFFORT=high ccx
```

Environment variables and explicit command-line arguments override the saved configuration. Run `ccx config` to see the resolved defaults.

## Effort and sub-agents

These are separate controls:

1. The root Claudex session uses `xhigh` by default.
2. The `ccx bg` root session uses `medium` by default.
3. Custom sub-agent definitions can set `effort: high` in their YAML frontmatter.
4. Every normal lane applies hard fan-out and request bounds before Claude Code starts.

Install the included example with `./scripts/install.sh --with-agent`, or copy [`examples/agents/claudex-worker.md`](examples/agents/claudex-worker.md) into `~/.claude/agents/`.

The setup wizard can select a different effort for this custom agent and safely renders that value during installation.

The launcher intentionally uses Claude Code's `--effort` session option instead of `CLAUDE_CODE_EFFORT_LEVEL`. The environment variable has higher precedence and would prevent a custom agent's `effort: high` frontmatter from overriding its parent session.

There is no `CLAUDE_CODE_SUBAGENT_EFFORT` variable. Built-in agents inherit the parent session's effort; editable custom agents can declare their own effort. The repository also does not force `CLAUDE_CODE_SUBAGENT_MODEL`, because that would override every agent's own model selection.

The default limits are intentionally conservative: three active sub-agents, twelve spawned across the session, and one delegation level. They prevent an audit or review prompt from recursively multiplying workers while preserving useful parallel work. Direct `CLAUDE_CODE_MAX_*` environment variables still take precedence when you deliberately need different limits. Claude Code exempts `ultracode` sessions from its concurrency cap, but the session-total and nesting limits still apply.

If a task should never delegate, use `ccx solo` (also available as `ccx no-agents`). It passes Claude Code's `--disallowedTools Agent` option for that session. This is also the quickest recovery lane after stopping a runaway session.

These limits govern sub-agents spawned through Claude Code's Agent tool. Dynamic workflows and agent teams have their own limits upstream; they are not silently presented here as protected by the same caps.

## Dynamic workflow scale

Claude Code dynamic workflows can schedule dozens or hundreds of agents, but the runtime executes at most 16 at once. “100 agents in one section” therefore means a 100-item queue feeding a 16-agent execution pool, not 100 simultaneous model requests.

On July 29, 2026, Claudex stress-tested one workflow phase that scheduled 100 Sol/high agents together on an 18-core, 48 GB Mac:

| Proxy transport | Runs | Valid agents | Agent failures | Measured peak active |
|---|---:|---:|---:|---:|
| Upstream default `websocket` | 1 | 80/100 | 20 transient WebSocket upgrade 403s | 16 |
| Claudex default `http` | 3 | 300/300 | 0 | 16 |

The verified maximum within the tested 1–100 range is therefore **100 scheduled agents in one phase, HTTP transport, 16 active at once**. Two one-turn HTTP runs took 34.3 and 32.2 seconds inside the workflow and used about 1.34 million agent tokens each. A third sustained run made every agent perform a real `Read` plus structured return: all 100 completed their two tool calls, used 1.41 million tokens, and finished in 62.5 seconds. Treat that as a measured ceiling for this machine and account, not a universal service guarantee.

For a generated workflow to aim above the normal medium guideline, choose `unrestricted` under **Dynamic workflow size** in `/config`, or add `"workflowSizeGuideline": "unrestricted"` to the relevant Claude Code settings file. This is planning advice, not a runtime cap. Claude Code still enforces 16 concurrent and 1,000 total agents per run.

Keep scaling in the workflow script: fan out a phase with `pipeline()`, collect its results, then start the next phase. Do not make workflow agents recursively spawn more agents; nested delegation was not reliable in this test environment and obscures the runtime’s queue.

The setup scripts record `CCX_PROXY_TRANSPORT=http`. On macOS/Linux, the installer safely merges `codex.transport` into the upstream proxy’s `config.json` without discarding unrelated fields. On Windows, both the Scheduled Task and on-demand launcher pass the selected transport directly to the proxy process. A proxy restart is required before a changed transport takes effect.

## Why this is more than an alias

An alias that only runs `claude --model gpt-5.6-sol` does not create the connection. Claude Code still needs:

- a running Anthropic-compatible proxy;
- Codex OAuth stored by that proxy;
- `ANTHROPIC_BASE_URL` and a local dummy auth value;
- a concrete model for Claude Code's small/background requests;
- a correct compaction boundary;
- hard limits on sub-agent fan-out and request duration;
- protection from non-streaming retries that can duplicate tool calls.

The launcher handles those pieces while leaving native Claude Code untouched.

It deliberately does **not** set:

- `ENABLE_TOOL_SEARCH=false`, because loading every MCP tool definition up front can waste context;
- `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3`, because that is a throttle, not a quality improvement;
- `CLAUDE_CODE_SUBAGENT_MODEL`, because it overrides per-agent model choices.

## Reliability: fan-out guards, timeouts, and retry shim

Four failure modes matter in practice, and the launcher now defends against all four.

**Recursive or excessive agent fan-out.** A broad prompt can trigger several sub-agents at once, and current Claude Code builds allow nested delegation by default. Claudex caps concurrency, total spawns, and nesting. The caps are enforced by Claude Code itself, while `ccx solo` removes the Agent tool entirely when delegation is inappropriate.

**Requests that never settle.** Claude Code's default request timeout and retry count are generous enough that a disconnected fleet can appear to spin for a long time. Claudex lowers them to a five-minute per-request deadline and three retries. The optional shim separately bounds connection, response-header, streaming-idle, write, and queue waits; closes upstream work when the client disconnects; and accepts at most eight simultaneous connections by default.

**Dead token at launch.** The proxy's `/healthz` endpoint only proves the HTTP server is up; it says nothing about the Codex OAuth token. Before handing off to Claude Code, `ccx` runs `claude-code-proxy codex auth status` and refuses to start a session that would only produce 401 errors, telling you to run `claude-code-proxy codex auth login` instead.

**Transient 401s under parallel load.** During token refresh the proxy can briefly answer some requests with `401 Authentication failed` while others succeed. Claude Code treats 401 as terminal for a subagent, so a single flapped request can kill that worker. `scripts/ccx-retry-shim.py` is a small standard-library-only proxy that sits in front of `claude-code-proxy` and retries an explicit 401 exactly once by default.

**WebSocket upgrade saturation during very large workflow bursts.** The upstream WebSocket default produced 20 terminal 403 upgrade failures in a 100-agent phase even though OAuth remained healthy. HTTP transport completed three maximum-size runs without a failure, so Claudex persists `codex.transport=http` in the proxy configuration.

The shim deliberately does not retry 5xx or transport failures by default because Claude Code already retries them. Retrying at both layers multiplies traffic precisely when a worker fleet is unhealthy. Advanced users can change the shim's retry statuses and limits through its documented `CCX_SHIM_*` environment variables.

To use the shim, run it as a service listening on a free local port (default `18767`) and set `CCX_SHIM_URL` in `~/.config/claudex/config` (on Windows, `%APPDATA%\Claudex\config` by default):

```
CCX_SHIM_URL=http://127.0.0.1:18767
```

On macOS a minimal launchd agent works well (`RunAtLoad` + `KeepAlive`, `ProgramArguments = [/usr/bin/python3, /path/to/ccx-retry-shim.py]`); on Linux use a systemd user unit. On Windows, a per-user Scheduled Task running at logon works the same way `scripts/install.ps1` registers one for the proxy itself (see [Windows guide](docs/windows.md#path-and-service-behavior) for the `Register-ScheduledTask` pattern); point its action at whatever interpreter runs `scripts/ccx-retry-shim.py` on your machine. The launcher health-checks the shim and falls back to the proxy directly, with a warning, when the shim is down. `/healthz` requests pass through the shim, so one check validates the whole chain.

The shim is optional. The sub-agent caps, Claude Code retry limit, and request timeout work without it.

## Models

At the time of writing, the upstream proxy recognizes these Codex model IDs:

- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`
- `gpt-5.5`
- `gpt-5.4`
- `gpt-5.4-mini`
- `gpt-5.3-codex`
- `gpt-5.3-codex-spark`
- `gpt-5.2`

Each lane also has the upstream `-fast` priority-service variant, exposed as aliases such as `sol-fast`, `terra-fast`, `mini-fast`, and `spark-fast`.

Recognition by the proxy does not guarantee access on your ChatGPT account. Unsupported account/model combinations are returned by the upstream service as an error. Treat the [upstream model list](https://github.com/raine/claude-code-proxy#4-point-claude-code-at-it) as canonical because this list will age.

The `[1m]` suffix used by the launcher is a local Claude Code compaction hint. The proxy strips it before the upstream request. It does not magically increase your account's real context limit.

## Tests

The suite is deterministic and uses a stub Claude executable plus local sockets. It never reads OAuth credentials or makes a model request.

```bash
bash tests/test-ccx.sh
bash tests/test-setup.sh
bash tests/test-install.sh
bash tests/test-version.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-retry-shim.py
```

On Windows PowerShell 5.1:

```powershell
.\tests\test-ccx.ps1
.\tests\test-setup.ps1
.\tests\test-install.ps1
.\tests\test-version.ps1
```

The retry-shim tests reproduce the relevant failure shapes: bounded 401 recovery, no duplicate 5xx retry layer, stalled headers, stalled streams, client cancellation, and connection saturation. CI runs the platform-appropriate suite on Linux, macOS, and Windows.

## Updating and uninstalling

Update the proxy:

```bash
brew update
brew upgrade claude-code-proxy
brew services restart claude-code-proxy
./scripts/doctor.sh
```

Update Claudex:

```bash
git pull --ff-only
./scripts/setup.sh
```

Uninstall only the Claudex launcher and optional example agent:

```bash
rm "$HOME/.local/bin/ccx"
rm "$HOME/.claude/agents/claudex-worker.md"
```

Those commands are intentionally not automated. Review each path before deleting it. Removing Claudex does not remove Claude Code, Codex, the proxy, or OAuth credentials.

## Security and limitations

Read [`SECURITY.md`](SECURITY.md) before changing the bind address.

- The proxy is third-party software and is not affiliated with Anthropic or OpenAI.
- It uses a compatibility bridge to the Codex backend. Upstream behavior, account eligibility, terms, quotas, and model names can change.
- The local proxy has no incoming client authentication. Keep it bound to `127.0.0.1` unless you add your own firewall and authenticated reverse proxy.
- ChatGPT subscription usage is still subject to plan limits. This is not unlimited or guaranteed access.
- Features that depend on Anthropic-hosted services may not work through a custom base URL. See the upstream project's limitations for the current list.

## Credits

Claudex would not exist without [`raine/claude-code-proxy`](https://github.com/raine/claude-code-proxy), created and maintained by [Raine](https://github.com/raine) with help from [its contributors](https://github.com/raine/claude-code-proxy/graphs/contributors). The proxy performs the hard protocol translation, OAuth handling, streaming conversion, tool-call mapping, and service integration.

Please direct proxy bugs and compatibility questions to the upstream repository after checking that the issue reproduces without this launcher. See [`CREDITS.md`](CREDITS.md) for the full attribution.

## License

The original files in this repository are released under the [MIT License](LICENSE). `claude-code-proxy` is a separate MIT-licensed project owned by its respective contributors.
