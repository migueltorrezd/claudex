#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_dir="${CCX_INSTALL_DIR:-$HOME/.local/bin}"
launcher_target="$install_dir/ccx"
agent_dir="${CCX_AGENT_DIR:-$HOME/.claude/agents}"
agent_target="$agent_dir/claudex-worker.md"
config_dir="${CCX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claudex}"
config_target="$config_dir/config"
config_source="${CCX_CONFIG_SOURCE:-$repo_root/config/claudex.conf.example}"
with_agent=0
run_login=0
skip_service=0

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Options:
  --with-agent   Install the optional high-effort custom sub-agent
  --login        Start interactive Codex OAuth if authentication is missing
  --no-service   Do not start the Homebrew background service
  -h, --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-agent) with_agent=1 ;;
    --login) run_login=1 ;;
    --no-service) skip_service=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin|Linux) ;;
  *)
    printf 'install: automated setup supports macOS and Linux only.\n' >&2
    printf 'install: see the upstream Windows instructions linked from README.md.\n' >&2
    exit 1
    ;;
esac

for command_name in brew curl install; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'install: required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

if ! command -v claude >/dev/null 2>&1; then
  printf 'install: Claude Code is missing. Install it from https://code.claude.com/docs/en/setup\n' >&2
  exit 1
fi

if ! command -v claude-code-proxy >/dev/null 2>&1; then
  printf 'Installing raine/claude-code-proxy with Homebrew...\n'
  brew install raine/claude-code-proxy/claude-code-proxy
fi

if ! claude-code-proxy codex auth status >/dev/null 2>&1; then
  if [[ "$run_login" -eq 1 ]]; then
    claude-code-proxy codex auth login
  else
    printf '\nCodex OAuth needs interactive approval. Run:\n\n'
    printf '  claude-code-proxy codex auth login\n\n'
    printf 'Then rerun this installer. No token needs to be copied into Claudex.\n'
    exit 2
  fi
fi

if [[ "$skip_service" -eq 0 ]]; then
  brew services start claude-code-proxy >/dev/null 2>&1 || \
    brew services start raine/claude-code-proxy/claude-code-proxy >/dev/null
fi

mkdir -p "$config_dir"
if [[ ! -e "$config_target" ]]; then
  install -m 0644 "$config_source" "$config_target"
else
  printf 'Preserving existing config: %s\n' "$config_target"
fi

mkdir -p "$install_dir"
if [[ -e "$launcher_target" ]] && ! cmp -s "$repo_root/bin/ccx" "$launcher_target"; then
  if ! grep -qF '# Managed by https://github.com/migueltorrezd/claudex' "$launcher_target"; then
    printf 'install: refusing to overwrite existing unmanaged launcher: %s\n' "$launcher_target" >&2
    printf 'install: review it, move it, or set CCX_INSTALL_DIR to another directory.\n' >&2
    exit 1
  fi
fi
install -m 0755 "$repo_root/bin/ccx" "$launcher_target"

if [[ "$with_agent" -eq 1 ]]; then
  subagent_effort="${CCX_SUBAGENT_EFFORT:-}"
  if [[ -z "$subagent_effort" && -f "$config_target" ]]; then
    while IFS='=' read -r config_key config_value; do
      if [[ "$config_key" == 'CCX_SUBAGENT_EFFORT' ]]; then
        subagent_effort="${config_value%$'\r'}"
      fi
    done < "$config_target"
  fi
  subagent_effort="${subagent_effort:-high}"
  case "$subagent_effort" in
    low|medium|high|xhigh|max) ;;
    *)
      printf 'install: unsupported sub-agent effort: %s\n' "$subagent_effort" >&2
      exit 1
      ;;
  esac

  mkdir -p "$(dirname "$agent_target")"
  rendered_agent="$(mktemp "${TMPDIR:-/tmp}/claudex-agent.XXXXXX")"
  trap 'rm -f "$rendered_agent"' EXIT
  sed "s/^effort: .*/effort: $subagent_effort/" "$repo_root/examples/agents/claudex-worker.md" > "$rendered_agent"

  if [[ -e "$agent_target" ]] && ! cmp -s "$rendered_agent" "$agent_target"; then
    if ! grep -qF '<!-- Managed by https://github.com/migueltorrezd/claudex -->' "$agent_target"; then
      printf 'install: refusing to overwrite existing unmanaged agent: %s\n' "$agent_target" >&2
      exit 1
    fi
  fi
  install -m 0644 "$rendered_agent" "$agent_target"
  rm -f "$rendered_agent"
  trap - EXIT
fi

printf '\nClaudex installed.\n'
printf '  Launcher: %s\n' "$launcher_target"
printf '  Config:   %s\n' "$config_target"
if [[ "$with_agent" -eq 1 ]]; then
  printf '  Agent:    %s\n' "$agent_target"
fi
printf '\nRun: %s models\n' "$launcher_target"
printf 'Then: %s\n' "$repo_root/scripts/doctor.sh"
