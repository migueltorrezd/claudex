#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/version.sh
source "$repo_root/scripts/version.sh"

failures=0
config_file="${CCX_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claudex/config}"
config_proxy_url=''
config_proxy_transport=''
config_shim_url=''
config_subagent_guards=''
config_max_concurrent_subagents=''
config_max_subagents_per_session=''
config_max_subagent_spawn_depth=''
config_max_retries=''
config_api_timeout_ms=''

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

if [[ -f "$config_file" ]]; then
  while IFS='=' read -r config_key config_value || [[ -n "$config_key" ]]; do
    config_key="$(trim "${config_key%$'\r'}")"
    config_value="$(trim "${config_value%$'\r'}")"
    case "$config_key" in
      CCX_PROXY_URL) config_proxy_url="$config_value" ;;
      CCX_PROXY_TRANSPORT) config_proxy_transport="$config_value" ;;
      CCX_SHIM_URL) config_shim_url="$config_value" ;;
      CCX_SUBAGENT_GUARDS) config_subagent_guards="$config_value" ;;
      CCX_MAX_CONCURRENT_SUBAGENTS) config_max_concurrent_subagents="$config_value" ;;
      CCX_MAX_SUBAGENTS_PER_SESSION) config_max_subagents_per_session="$config_value" ;;
      CCX_MAX_SUBAGENT_SPAWN_DEPTH) config_max_subagent_spawn_depth="$config_value" ;;
      CCX_MAX_RETRIES) config_max_retries="$config_value" ;;
      CCX_API_TIMEOUT_MS) config_api_timeout_ms="$config_value" ;;
    esac
  done < "$config_file"
fi

if command -v claude >/dev/null 2>&1; then
  claude_version_line="$(claude --version 2>/dev/null | head -1)"
  claude_version="$(printf '%s\n' "$claude_version_line" | awk '{print $1}')"
  if version_at_least "$claude_version" "$CCX_MINIMUM_CLAUDE_VERSION"; then
    pass "Claude Code: $claude_version_line"
  else
    fail "Claude Code is too old: ${claude_version:-unknown}; need $CCX_MINIMUM_CLAUDE_VERSION or newer"
  fi
else
  fail 'Claude Code is not on PATH'
fi

if command -v claude-code-proxy >/dev/null 2>&1; then
  proxy_version_line="$(claude-code-proxy --version 2>/dev/null | head -1)"
  proxy_version="$(printf '%s\n' "$proxy_version_line" | awk '{print $NF}')"
  if version_at_least "$proxy_version" "$CCX_MINIMUM_PROXY_VERSION"; then
    pass "Proxy: $proxy_version_line"
  else
    fail "Proxy is too old: ${proxy_version:-unknown}; need $CCX_MINIMUM_PROXY_VERSION or newer"
  fi
else
  fail 'claude-code-proxy is not on PATH'
fi

if command -v claude-code-proxy >/dev/null 2>&1 && claude-code-proxy codex auth status >/dev/null 2>&1; then
  pass 'Codex OAuth is configured'
else
  fail 'Codex OAuth is missing or expired'
fi

proxy_url="${CCX_PROXY_URL:-${config_proxy_url:-http://127.0.0.1:18765}}"
proxy_transport="${CCX_PROXY_TRANSPORT:-${config_proxy_transport:-http}}"
shim_url="${CCX_SHIM_URL:-${config_shim_url:-}}"
proxy_healthy=0
if curl --silent --fail --max-time 2 "$proxy_url/healthz" >/dev/null 2>&1; then
  pass "Proxy health: $proxy_url/healthz"
  proxy_healthy=1
else
  fail "Proxy health: $proxy_url/healthz"
fi

if [[ -n "$shim_url" ]]; then
  if curl --silent --fail --max-time 2 "$shim_url/healthz" >/dev/null 2>&1; then
    pass "Retry shim health: $shim_url/healthz"
  else
    fail "Retry shim health: $shim_url/healthz"
  fi
else
  info 'Retry shim is not configured'
fi

case "$proxy_transport" in
  http|websocket|auto)
    if [[ -n "${CCP_CONFIG_DIR:-}" ]]; then
      proxy_config_dir="$CCP_CONFIG_DIR"
    elif [[ "$(uname -s)" == 'Darwin' ]]; then
      proxy_config_dir="$HOME/.config/claude-code-proxy"
    else
      proxy_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-code-proxy"
    fi
    proxy_config_path="$proxy_config_dir/config.json"
    if command -v brew >/dev/null 2>&1; then
      configured_transport="$(brew ruby "$repo_root/scripts/configure-proxy-transport.rb" "$proxy_config_path" 2>/dev/null || true)"
      if [[ "$configured_transport" == "$proxy_transport" ]]; then
        pass "Proxy Codex transport: $configured_transport"
      else
        fail "Proxy Codex transport: configured=${configured_transport:-unreadable}, expected=$proxy_transport"
      fi
    else
      info "Proxy Codex transport requested for on-demand starts: $proxy_transport"
    fi
    ;;
  *)
    fail "Unsupported proxy Codex transport: $proxy_transport"
    ;;
esac

resolved_subagent_guards="${CCX_SUBAGENT_GUARDS:-${config_subagent_guards:-1}}"
resolved_max_concurrent_subagents="${CCX_MAX_CONCURRENT_SUBAGENTS:-${config_max_concurrent_subagents:-3}}"
resolved_max_subagents_per_session="${CCX_MAX_SUBAGENTS_PER_SESSION:-${config_max_subagents_per_session:-12}}"
resolved_max_subagent_spawn_depth="${CCX_MAX_SUBAGENT_SPAWN_DEPTH:-${config_max_subagent_spawn_depth:-1}}"
resolved_max_retries="${CCX_MAX_RETRIES:-${config_max_retries:-3}}"
resolved_api_timeout_ms="${CCX_API_TIMEOUT_MS:-${config_api_timeout_ms:-300000}}"
info "Subagent guards: $resolved_subagent_guards"
info "Subagent limits: concurrent=$resolved_max_concurrent_subagents session=$resolved_max_subagents_per_session depth=$resolved_max_subagent_spawn_depth"
info "Request bounds: retries=$resolved_max_retries timeout=${resolved_api_timeout_ms}ms"

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
