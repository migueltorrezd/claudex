#!/usr/bin/env bash
set -u

failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

if command -v claude >/dev/null 2>&1; then
  pass "Claude Code: $(claude --version 2>/dev/null | head -1)"
else
  fail 'Claude Code is not on PATH'
fi

if command -v claude-code-proxy >/dev/null 2>&1; then
  pass "Proxy: $(claude-code-proxy --version 2>/dev/null | head -1)"
else
  fail 'claude-code-proxy is not on PATH'
fi

if command -v claude-code-proxy >/dev/null 2>&1 && claude-code-proxy codex auth status >/dev/null 2>&1; then
  pass 'Codex OAuth is configured'
else
  fail 'Codex OAuth is missing or expired'
fi

proxy_url="${CCX_PROXY_URL:-http://127.0.0.1:18765}"
proxy_healthy=0
if curl --silent --fail --max-time 2 "$proxy_url/healthz" >/dev/null 2>&1; then
  pass "Proxy health: $proxy_url/healthz"
  proxy_healthy=1
else
  fail "Proxy health: $proxy_url/healthz"
fi

if command -v ccx >/dev/null 2>&1; then
  launcher_path="$(command -v ccx)"
  pass "Launcher: $launcher_path"
  if grep -qF 'CCX_CONFIG_FILE' "$launcher_path" 2>/dev/null; then
    while IFS= read -r config_line; do
      info "$config_line"
    done < <(ccx config 2>/dev/null)
  else
    info 'Installed launcher predates persistent Claudex configuration'
  fi
else
  fail 'ccx is not on PATH; add ~/.local/bin to PATH'
fi

if command -v brew >/dev/null 2>&1; then
  service_output="$(brew services list 2>/dev/null | awk '$1 == "claude-code-proxy" {print $2; exit}')"
  if [[ "$service_output" == 'started' ]]; then
    pass 'Homebrew service is started'
  elif [[ -n "$service_output" ]]; then
    if [[ "$proxy_healthy" -eq 1 ]]; then
      info "Homebrew service state: $service_output; another healthy service manager is active"
    else
      fail "Homebrew service state: $service_output"
    fi
  else
    info 'Homebrew service row not found; a manually started proxy may still be healthy'
  fi
fi

agent_file="${CCX_AGENT_DIR:-$HOME/.claude/agents}/claudex-worker.md"
if [[ -f "$agent_file" ]]; then
  agent_effort="$(awk -F': ' '$1 == "effort" {print $2; exit}' "$agent_file")"
  pass "Custom claudex-worker effort: ${agent_effort:-unknown}"
else
  info 'Optional claudex-worker is not installed'
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nDoctor found %d problem(s).\n' "$failures" >&2
  exit 1
fi

printf '\nClaudex is ready. No live model request was made.\n'
