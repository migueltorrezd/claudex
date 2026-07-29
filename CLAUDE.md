# Agent installation protocol

Your task in this repository is to install and verify Claudex without exposing credentials or breaking the user's existing Claude Code or Codex setup.

1. Read `README.md` and `SECURITY.md` completely before changing the machine.
2. Confirm whether the OS is Windows, macOS, or Linux. On Windows, check for `git`, Windows PowerShell 5.1 or newer, and `claude`; on macOS/Linux, also check for `brew` and `curl`.
3. If the user has not supplied preferences, ask for the main model/effort, background model/effort, utility model, custom-agent effort, agent installation, OAuth, and service-start choices. Alternatively, invite the user to run `.\scripts\setup.ps1` on Windows or `./scripts/setup.sh` on macOS/Linux.
4. Apply explicit choices with `.\scripts\setup.ps1 -Yes` and the corresponding PowerShell switches on Windows, or `./scripts/setup.sh --yes` and the corresponding flags on macOS/Linux. For the tested defaults, use `.\scripts\install.ps1 -WithAgent` on Windows or `./scripts/install.sh --with-agent` on macOS/Linux.
5. If `claude-code-proxy codex auth status` is not healthy, stop and ask the user to complete `claude-code-proxy codex auth login` in an interactive terminal. Never read, print, copy, summarize, or commit OAuth credentials or token files.
6. Rerun the selected setup command, then run `.\scripts\doctor.ps1` on Windows or `./scripts/doctor.sh` on macOS/Linux.
7. On Windows, run `.\tests\test-ccx.ps1`, `.\tests\test-setup.ps1`, `.\tests\test-install.ps1`, and `.\tests\test-version.ps1`. On macOS/Linux, run `bash tests/test-ccx.sh`, `bash tests/test-setup.sh`, `bash tests/test-install.sh`, `bash tests/test-version.sh`, and `PYTHONDONTWRITEBYTECODE=1 python3 tests/test-retry-shim.py`. These tests use stubs and local sockets; they do not make a model request.
8. Do not run a live model smoke test without the user's permission because it consumes subscription quota.
9. Report the installed proxy version, Codex transport, OAuth status, service state, health endpoint, launcher path, config path, selected models, selected efforts, and custom-agent state. Do not report account IDs or tokens.

Safety constraints:

- Keep the proxy bound to `127.0.0.1`.
- Do not overwrite an unknown `~/.local/bin/ccx`, `%LOCALAPPDATA%\Claudex\bin\ccx.cmd`, `%LOCALAPPDATA%\Claudex\bin\lib\ccx.ps1`, or user `.claude\agents\claudex-worker.md`. The installer may update only files carrying this repository's managed marker; it must stop and report every other conflict.
- Do not alter `~/.claude/settings.json`, native `claude`, native `codex`, hooks, plugins, MCP configuration, or unrelated agent definitions.
- Do not set `ENABLE_TOOL_SEARCH=false`, `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`, `CLAUDE_CODE_SUBAGENT_MODEL`, or `CLAUDE_CODE_EFFORT_LEVEL` globally.
- Use only the upstream proxy's documented OAuth commands.
- Preserve user files and unrelated repository changes.
