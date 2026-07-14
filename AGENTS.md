# Agent installation protocol

Your task in this repository is to install and verify Claudex without exposing credentials or breaking the user's existing Claude Code or Codex setup.

1. Read `README.md` and `SECURITY.md` completely before changing the machine.
2. Confirm the OS is macOS or Linux, and check for `git`, `brew`, `claude`, and `curl`.
3. Run `./scripts/install.sh --with-agent` from the repository root.
4. If `claude-code-proxy codex auth status` is not healthy, stop and ask the user to complete `claude-code-proxy codex auth login` in an interactive terminal. Never read, print, copy, summarize, or commit OAuth credentials or token files.
5. Rerun `./scripts/install.sh --with-agent`, then run `./scripts/doctor.sh`.
6. Run `bash tests/test-ccx.sh`. This test uses a stub and does not make a model request.
7. Do not run a live model smoke test without the user's permission because it consumes subscription quota.
8. Report the installed proxy version, OAuth status, service state, health endpoint, launcher path, default model, root effort, background-lane effort, and custom-agent effort. Do not report account IDs or tokens.

Safety constraints:

- Keep the proxy bound to `127.0.0.1`.
- Do not overwrite an unknown `~/.local/bin/ccx` or `~/.claude/agents/claudex-worker.md`. The installer may update only files carrying this repository's managed marker; it must stop and report every other conflict.
- Do not alter `~/.claude/settings.json`, native `claude`, native `codex`, hooks, plugins, MCP configuration, or unrelated agent definitions.
- Do not set `ENABLE_TOOL_SEARCH=false`, `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`, `CLAUDE_CODE_SUBAGENT_MODEL`, or `CLAUDE_CODE_EFFORT_LEVEL` globally.
- Use only the upstream proxy's documented OAuth commands.
- Preserve user files and unrelated repository changes.
