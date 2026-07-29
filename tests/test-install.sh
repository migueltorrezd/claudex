#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/claudex-install-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"
ln -s "$repo_root/tests/stub-claude.sh" "$stub_dir/claude"
ln -s "$repo_root/tests/stub-proxy.sh" "$stub_dir/claude-code-proxy"
ln -s "$repo_root/tests/stub-brew.sh" "$stub_dir/brew"

install_dir="$tmp_dir/install"
config_dir="$tmp_dir/config"
agent_dir="$tmp_dir/agents"
proxy_config_dir="$tmp_dir/proxy-config"

PATH="$stub_dir:$PATH" \
CCX_INSTALL_DIR="$install_dir" \
CCX_CONFIG_DIR="$config_dir" \
CCX_AGENT_DIR="$agent_dir" \
CCP_CONFIG_DIR="$proxy_config_dir" \
  "$repo_root/scripts/install.sh" --no-service >/dev/null

test -x "$install_dir/ccx"
cmp -s "$repo_root/bin/ccx" "$install_dir/ccx"
grep -q '^CCX_MAX_CONCURRENT_SUBAGENTS=3$' "$config_dir/config"
grep -q '^CCX_MAX_SUBAGENTS_PER_SESSION=12$' "$config_dir/config"
grep -q '^CCX_MAX_SUBAGENT_SPAWN_DEPTH=1$' "$config_dir/config"
grep -q '^CCX_PROXY_TRANSPORT=http$' "$config_dir/config"
grep -q '"transport": "http"' "$proxy_config_dir/config.json"

cat > "$proxy_config_dir/config.json" <<'EOF'
{
  "custom": "preserved",
  "codex": {
    "effort": "high",
    "transport": "websocket"
  }
}
EOF
PATH="$stub_dir:$PATH" \
CCX_INSTALL_DIR="$install_dir" \
CCX_CONFIG_DIR="$config_dir" \
CCX_AGENT_DIR="$agent_dir" \
CCP_CONFIG_DIR="$proxy_config_dir" \
  "$repo_root/scripts/install.sh" --no-service >/dev/null
ruby -rjson -e '
  config = JSON.parse(File.read(ARGV.fetch(0)))
  abort unless config["custom"] == "preserved"
  abort unless config.dig("codex", "effort") == "high"
  abort unless config.dig("codex", "transport") == "http"
' "$proxy_config_dir/config.json"

if PATH="$stub_dir:$PATH" \
  CLAUDE_STUB_VERSION=2.1.216 \
  CCX_INSTALL_DIR="$tmp_dir/old-claude-install" \
  CCX_CONFIG_DIR="$tmp_dir/old-claude-config" \
  CCP_CONFIG_DIR="$tmp_dir/old-claude-proxy-config" \
    "$repo_root/scripts/install.sh" --no-service >"$tmp_dir/old-claude.out" 2>&1; then
  printf 'test: installer accepted an unsupported Claude Code version\n' >&2
  exit 1
fi
grep -q 'Claude Code 2.1.217 or newer is required' "$tmp_dir/old-claude.out"

if PATH="$stub_dir:$PATH" \
  PROXY_STUB_VERSION=0.1.16 \
  CCX_INSTALL_DIR="$tmp_dir/old-proxy-install" \
  CCX_CONFIG_DIR="$tmp_dir/old-proxy-config" \
  CCP_CONFIG_DIR="$tmp_dir/old-proxy-proxy-config" \
    "$repo_root/scripts/install.sh" --no-service >"$tmp_dir/old-proxy.out" 2>&1; then
  printf 'test: installer accepted an unsupported proxy version\n' >&2
  exit 1
fi
grep -q 'claude-code-proxy 0.1.17 or newer is required' "$tmp_dir/old-proxy.out"

printf 'All installer tests passed.\n'
