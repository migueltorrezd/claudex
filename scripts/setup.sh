#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${CCX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claudex}"
config_target="$config_dir/config"

main_model=''
main_effort=''
bg_model=''
bg_effort=''
utility_model=''
subagent_effort=''
install_agent=''
run_login=''
start_service=''
assume_yes=0
config_only=0

usage() {
  cat <<'EOF'
Usage: ./scripts/setup.sh [options]

Without options, setup.sh opens an interactive questionnaire.

Options:
  --main-model MODEL          Root model alias
  --main-effort EFFORT       Root effort: low, medium, high, xhigh, max, or ultracode
  --bg-model MODEL            Model used by the ccx bg lane
  --bg-effort EFFORT         Effort used by the ccx bg lane
  --utility-model MODEL       Model for titles, token counts, and utility requests
  --subagent-effort EFFORT   Effort for the optional custom worker
  --with-agent               Install the custom worker
  --without-agent            Do not install the custom worker
  --login                    Run browser OAuth if authentication is missing
  --no-login                 Do not start browser OAuth
  --start-service            Start the Homebrew background service
  --no-service               Do not start the Homebrew background service
  --config-only              Write configuration without installing anything
  -y, --yes                  Accept the summary without a final prompt
  -h, --help                 Show this help

Model aliases:
  sol, sol-fast, terra, terra-fast, luna, luna-fast, 5.5, 5.5-fast,
  5.4, 5.4-fast, mini, mini-fast, 5.3, 5.3-fast, spark, spark-fast,
  5.2, 5.2-fast
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    printf 'setup: %s requires a value\n' "$1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-model) require_value "$@"; main_model="$2"; shift ;;
    --main-effort) require_value "$@"; main_effort="$2"; shift ;;
    --bg-model) require_value "$@"; bg_model="$2"; shift ;;
    --bg-effort) require_value "$@"; bg_effort="$2"; shift ;;
    --utility-model) require_value "$@"; utility_model="$2"; shift ;;
    --subagent-effort) require_value "$@"; subagent_effort="$2"; shift ;;
    --with-agent) install_agent='yes' ;;
    --without-agent) install_agent='no' ;;
    --login) run_login='yes' ;;
    --no-login) run_login='no' ;;
    --start-service) start_service='yes' ;;
    --no-service) start_service='no' ;;
    --config-only) config_only=1 ;;
    -y|--yes) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'setup: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

read_config_value() {
  local wanted_key="$1"
  local fallback="$2"
  local key value
  CONFIG_VALUE="$fallback"
  if [[ ! -f "$config_target" ]]; then
    return
  fi
  # `|| [[ -n ... ]]` keeps the final line even without a trailing newline.
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    if [[ "$key" == "$wanted_key" ]]; then
      CONFIG_VALUE="${value%$'\r'}"
    fi
  done < "$config_target"
}

read_config_value CCX_MODEL sol
default_main_model="$CONFIG_VALUE"
read_config_value CCX_MAIN_EFFORT xhigh
default_main_effort="$CONFIG_VALUE"
read_config_value CCX_BG_MODEL sol
default_bg_model="$CONFIG_VALUE"
read_config_value CCX_BG_EFFORT medium
default_bg_effort="$CONFIG_VALUE"
read_config_value CCX_SMALL_FAST_MODEL 'gpt-5.6-sol[1m]'
default_utility_wire="$CONFIG_VALUE"
read_config_value CCX_SUBAGENT_EFFORT high
default_subagent_effort="$CONFIG_VALUE"
read_config_value CCX_CONTEXT_WINDOW ''
preserved_context_window="$CONFIG_VALUE"
read_config_value CCX_PROXY_URL 'http://127.0.0.1:18765'
preserved_proxy_url="$CONFIG_VALUE"
read_config_value CCX_PROXY_TRANSPORT http
preserved_proxy_transport="$CONFIG_VALUE"
read_config_value CCX_SHIM_URL ''
preserved_shim_url="$CONFIG_VALUE"
read_config_value CCX_SUBAGENT_GUARDS 1
preserved_subagent_guards="$CONFIG_VALUE"
read_config_value CCX_MAX_CONCURRENT_SUBAGENTS 3
preserved_max_concurrent_subagents="$CONFIG_VALUE"
read_config_value CCX_MAX_SUBAGENTS_PER_SESSION 12
preserved_max_subagents_per_session="$CONFIG_VALUE"
read_config_value CCX_MAX_SUBAGENT_SPAWN_DEPTH 1
preserved_max_subagent_spawn_depth="$CONFIG_VALUE"
read_config_value CCX_MAX_RETRIES 3
preserved_max_retries="$CONFIG_VALUE"
read_config_value CCX_API_TIMEOUT_MS 300000
preserved_api_timeout_ms="$CONFIG_VALUE"

utility_alias_from_wire() {
  case "$1" in
    'gpt-5.6-sol[1m]'|gpt-5.6-sol) UTILITY_ALIAS='sol' ;;
    'gpt-5.6-sol-fast[1m]'|gpt-5.6-sol-fast) UTILITY_ALIAS='sol-fast' ;;
    'gpt-5.6-terra[1m]'|gpt-5.6-terra) UTILITY_ALIAS='terra' ;;
    'gpt-5.6-terra-fast[1m]'|gpt-5.6-terra-fast) UTILITY_ALIAS='terra-fast' ;;
    'gpt-5.6-luna[1m]'|gpt-5.6-luna) UTILITY_ALIAS='luna' ;;
    'gpt-5.6-luna-fast[1m]'|gpt-5.6-luna-fast) UTILITY_ALIAS='luna-fast' ;;
    'gpt-5.5[1m]'|gpt-5.5) UTILITY_ALIAS='5.5' ;;
    'gpt-5.5-fast[1m]'|gpt-5.5-fast) UTILITY_ALIAS='5.5-fast' ;;
    'gpt-5.4[1m]'|gpt-5.4) UTILITY_ALIAS='5.4' ;;
    'gpt-5.4-fast[1m]'|gpt-5.4-fast) UTILITY_ALIAS='5.4-fast' ;;
    'gpt-5.4-mini[1m]'|gpt-5.4-mini) UTILITY_ALIAS='mini' ;;
    'gpt-5.4-mini-fast[1m]'|gpt-5.4-mini-fast) UTILITY_ALIAS='mini-fast' ;;
    'gpt-5.3-codex[1m]'|gpt-5.3-codex) UTILITY_ALIAS='5.3' ;;
    'gpt-5.3-codex-fast[1m]'|gpt-5.3-codex-fast) UTILITY_ALIAS='5.3-fast' ;;
    gpt-5.3-codex-spark) UTILITY_ALIAS='spark' ;;
    gpt-5.3-codex-spark-fast) UTILITY_ALIAS='spark-fast' ;;
    'gpt-5.2[1m]'|gpt-5.2) UTILITY_ALIAS='5.2' ;;
    'gpt-5.2-fast[1m]'|gpt-5.2-fast) UTILITY_ALIAS='5.2-fast' ;;
    *) UTILITY_ALIAS='sol' ;;
  esac
}

wire_model_from_alias() {
  case "$1" in
    sol) WIRE_MODEL='gpt-5.6-sol[1m]' ;;
    sol-fast) WIRE_MODEL='gpt-5.6-sol-fast[1m]' ;;
    terra) WIRE_MODEL='gpt-5.6-terra[1m]' ;;
    terra-fast) WIRE_MODEL='gpt-5.6-terra-fast[1m]' ;;
    luna) WIRE_MODEL='gpt-5.6-luna[1m]' ;;
    luna-fast) WIRE_MODEL='gpt-5.6-luna-fast[1m]' ;;
    5.5) WIRE_MODEL='gpt-5.5[1m]' ;;
    5.5-fast) WIRE_MODEL='gpt-5.5-fast[1m]' ;;
    5.4) WIRE_MODEL='gpt-5.4[1m]' ;;
    5.4-fast) WIRE_MODEL='gpt-5.4-fast[1m]' ;;
    mini) WIRE_MODEL='gpt-5.4-mini[1m]' ;;
    mini-fast) WIRE_MODEL='gpt-5.4-mini-fast[1m]' ;;
    5.3) WIRE_MODEL='gpt-5.3-codex[1m]' ;;
    5.3-fast) WIRE_MODEL='gpt-5.3-codex-fast[1m]' ;;
    spark) WIRE_MODEL='gpt-5.3-codex-spark' ;;
    spark-fast) WIRE_MODEL='gpt-5.3-codex-spark-fast' ;;
    5.2) WIRE_MODEL='gpt-5.2[1m]' ;;
    5.2-fast) WIRE_MODEL='gpt-5.2-fast[1m]' ;;
    *) return 1 ;;
  esac
}

validate_model() {
  wire_model_from_alias "$1" || {
    printf 'setup: unsupported model alias: %s\n' "$1" >&2
    exit 2
  }
}

validate_session_effort() {
  case "$1" in
    low|medium|high|xhigh|max|ultracode) ;;
    *)
      printf 'setup: unsupported session effort: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

validate_subagent_effort() {
  case "$1" in
    low|medium|high|xhigh|max) ;;
    *)
      printf 'setup: unsupported custom sub-agent effort: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'setup: %s must be a positive integer: %s\n' "$name" "$value" >&2
    exit 2
  fi
}

case "$preserved_subagent_guards" in
  0|1) ;;
  *)
    printf 'setup: CCX_SUBAGENT_GUARDS must be 0 or 1: %s\n' "$preserved_subagent_guards" >&2
    exit 2
    ;;
esac
validate_positive_integer CCX_MAX_CONCURRENT_SUBAGENTS "$preserved_max_concurrent_subagents"
validate_positive_integer CCX_MAX_SUBAGENTS_PER_SESSION "$preserved_max_subagents_per_session"
validate_positive_integer CCX_MAX_SUBAGENT_SPAWN_DEPTH "$preserved_max_subagent_spawn_depth"
validate_positive_integer CCX_MAX_RETRIES "$preserved_max_retries"
validate_positive_integer CCX_API_TIMEOUT_MS "$preserved_api_timeout_ms"
case "$preserved_proxy_transport" in
  http|websocket|auto) ;;
  *)
    printf 'setup: CCX_PROXY_TRANSPORT must be http, websocket, or auto: %s\n' "$preserved_proxy_transport" >&2
    exit 2
    ;;
esac
if [[ -n "$preserved_context_window" ]]; then
  validate_positive_integer CCX_CONTEXT_WINDOW "$preserved_context_window"
fi

choose_option() {
  local label="$1"
  local recommended="$2"
  shift 2
  local options=("$@")
  local answer option index

  while true; do
    printf '\n%s\n' "$label"
    index=1
    for option in "${options[@]}"; do
      if [[ "$option" == "$recommended" ]]; then
        printf '  %d) %s (recommended/current)\n' "$index" "$option"
      else
        printf '  %d) %s\n' "$index" "$option"
      fi
      index=$((index + 1))
    done
    printf 'Choose [%s]: ' "$recommended"
    IFS= read -r answer
    if [[ -z "$answer" ]]; then
      CHOICE="$recommended"
      return
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      index=$((10#$answer))
      if (( index >= 1 && index <= ${#options[@]} )); then
        CHOICE="${options[$((index - 1))]}"
        return
      fi
    fi
    for option in "${options[@]}"; do
      if [[ "$answer" == "$option" ]]; then
        CHOICE="$option"
        return
      fi
    done
    printf 'Please enter a listed number or value.\n' >&2
  done
}

ask_yes_no() {
  local label="$1"
  local recommended="$2"
  local answer prompt
  if [[ "$recommended" == 'yes' ]]; then prompt='Y/n'; else prompt='y/N'; fi
  while true; do
    printf '%s [%s]: ' "$label" "$prompt"
    IFS= read -r answer
    answer="${answer:-$recommended}"
    case "$answer" in
      y|Y|yes|YES|Yes) ANSWER='yes'; return ;;
      n|N|no|NO|No) ANSWER='no'; return ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

utility_alias_from_wire "$default_utility_wire"
default_utility_model="$UTILITY_ALIAS"

if [[ "$assume_yes" -eq 0 && ! -t 0 ]]; then
  printf 'setup: interactive mode needs a terminal. Use explicit options with --yes.\n' >&2
  exit 2
fi

printf 'Claudex setup wizard\n'
printf 'This stores model and effort preferences only. OAuth tokens never enter the config.\n'

if [[ -z "$main_model" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then main_model="$default_main_model"; else
    choose_option '1. Main model for normal ccx sessions' "$default_main_model" sol sol-fast terra terra-fast luna luna-fast 5.5 5.5-fast 5.4 5.4-fast mini mini-fast 5.3 5.3-fast spark spark-fast 5.2 5.2-fast
    main_model="$CHOICE"
  fi
fi

if [[ -z "$main_effort" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then main_effort="$default_main_effort"; else
    choose_option '2. Main-session reasoning effort' "$default_main_effort" low medium high xhigh max ultracode
    main_effort="$CHOICE"
  fi
fi

if [[ -z "$bg_model" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then bg_model="$default_bg_model"; else
    choose_option '3. Model for the ccx bg lane' "$default_bg_model" sol sol-fast terra terra-fast luna luna-fast 5.5 5.5-fast 5.4 5.4-fast mini mini-fast 5.3 5.3-fast spark spark-fast 5.2 5.2-fast
    bg_model="$CHOICE"
  fi
fi

if [[ -z "$bg_effort" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then bg_effort="$default_bg_effort"; else
    choose_option '4. Reasoning effort for the ccx bg lane' "$default_bg_effort" low medium high xhigh max ultracode
    bg_effort="$CHOICE"
  fi
fi

if [[ -z "$utility_model" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then utility_model="$default_utility_model"; else
    choose_option '5. Utility model for titles, token counts, and small background requests' "$default_utility_model" sol sol-fast terra terra-fast luna luna-fast 5.5 5.5-fast 5.4 5.4-fast mini mini-fast 5.3 5.3-fast spark spark-fast 5.2 5.2-fast
    utility_model="$CHOICE"
  fi
fi

if [[ -z "$subagent_effort" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then subagent_effort="$default_subagent_effort"; else
    choose_option '6. Effort for the optional custom sub-agent' "$default_subagent_effort" low medium high xhigh max
    subagent_effort="$CHOICE"
  fi
fi

if [[ -z "$install_agent" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then install_agent='yes'; else
    ask_yes_no '7. Install the custom background sub-agent?' yes
    install_agent="$ANSWER"
  fi
fi

if [[ -z "$run_login" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then run_login='yes'; else
    ask_yes_no '8. Open browser OAuth during installation if needed?' yes
    run_login="$ANSWER"
  fi
fi

if [[ -z "$start_service" ]]; then
  if [[ "$assume_yes" -eq 1 ]]; then start_service='yes'; else
    ask_yes_no '9. Start the proxy automatically as a background service?' yes
    start_service="$ANSWER"
  fi
fi

validate_model "$main_model"
validate_model "$bg_model"
validate_model "$utility_model"
validate_session_effort "$main_effort"
validate_session_effort "$bg_effort"
validate_subagent_effort "$subagent_effort"
wire_model_from_alias "$utility_model"
utility_wire_model="$WIRE_MODEL"

printf '\nConfiguration summary\n'
printf '  Main session:      %s / %s effort\n' "$main_model" "$main_effort"
printf '  Background lane:  %s / %s effort\n' "$bg_model" "$bg_effort"
printf '  Utility requests: %s\n' "$utility_model"
printf '  Custom sub-agent: %s (effort: %s)\n' "$install_agent" "$subagent_effort"
printf '  Browser OAuth:    %s, if needed\n' "$run_login"
printf '  Background service: %s\n' "$start_service"
printf '  Subagent guards:  %s (concurrent: %s, session: %s, depth: %s)\n' \
  "$preserved_subagent_guards" \
  "$preserved_max_concurrent_subagents" \
  "$preserved_max_subagents_per_session" \
  "$preserved_max_subagent_spawn_depth"
printf '  Request bounds:   %s retries, %sms timeout\n' \
  "$preserved_max_retries" \
  "$preserved_api_timeout_ms"
printf '  Proxy URL:        %s\n' "$preserved_proxy_url"
printf '  Proxy transport:  %s\n' "$preserved_proxy_transport"
printf '  Retry shim URL:   %s\n' "${preserved_shim_url:-not configured}"
printf '  Config path:      %s\n' "$config_target"

if [[ "$assume_yes" -eq 0 ]]; then
  ask_yes_no 'Apply this configuration?' yes
  if [[ "$ANSWER" != 'yes' ]]; then
    printf 'No changes made.\n'
    exit 0
  fi
fi

mkdir -p "$config_dir"
rendered_config="$(mktemp "$config_dir/.config.XXXXXX")"
trap 'rm -f "$rendered_config"' EXIT
cat > "$rendered_config" <<EOF
# Managed by https://github.com/migueltorrezd/claudex
# Generated by scripts/setup.sh. Do not put credentials in this file.
CCX_MODEL=$main_model
CCX_MAIN_EFFORT=$main_effort
CCX_BG_MODEL=$bg_model
CCX_BG_EFFORT=$bg_effort
CCX_SMALL_FAST_MODEL=$utility_wire_model
CCX_SUBAGENT_EFFORT=$subagent_effort
CCX_SUBAGENT_GUARDS=$preserved_subagent_guards
CCX_MAX_CONCURRENT_SUBAGENTS=$preserved_max_concurrent_subagents
CCX_MAX_SUBAGENTS_PER_SESSION=$preserved_max_subagents_per_session
CCX_MAX_SUBAGENT_SPAWN_DEPTH=$preserved_max_subagent_spawn_depth
CCX_MAX_RETRIES=$preserved_max_retries
CCX_API_TIMEOUT_MS=$preserved_api_timeout_ms
CCX_PROXY_URL=$preserved_proxy_url
CCX_PROXY_TRANSPORT=$preserved_proxy_transport
EOF
if [[ -n "$preserved_context_window" ]]; then
  printf 'CCX_CONTEXT_WINDOW=%s\n' "$preserved_context_window" >> "$rendered_config"
else
  cat >> "$rendered_config" <<'EOF'
# CCX_CONTEXT_WINDOW is intentionally unset: the launcher picks the correct
# per-model boundary (967000 for most lanes, 128000 for spark). Set it only
# to force a specific value for every model.
EOF
fi
if [[ -n "$preserved_shim_url" ]]; then
  printf 'CCX_SHIM_URL=%s\n' "$preserved_shim_url" >> "$rendered_config"
else
  cat >> "$rendered_config" <<'EOF'
# CCX_SHIM_URL is optional. When configured, setup preserves it across updates.
EOF
fi
chmod 0644 "$rendered_config"

if [[ -f "$config_target" ]] && ! cmp -s "$rendered_config" "$config_target"; then
  backup_path="$config_target.backup-$(date +%Y%m%d%H%M%S)-$$"
  cp -p "$config_target" "$backup_path"
  printf 'Backed up existing config to %s\n' "$backup_path"
fi
mv "$rendered_config" "$config_target"
trap - EXIT
printf 'Saved configuration to %s\n' "$config_target"

if [[ "$config_only" -eq 1 ]]; then
  printf 'Configuration-only mode complete.\n'
  exit 0
fi

install_args=()
if [[ "$install_agent" == 'yes' ]]; then install_args+=(--with-agent); fi
if [[ "$run_login" == 'yes' ]]; then install_args+=(--login); fi
if [[ "$start_service" == 'no' ]]; then install_args+=(--no-service); fi

CCX_CONFIG_DIR="$config_dir" \
CCX_SUBAGENT_EFFORT="$subagent_effort" \
  "$repo_root/scripts/install.sh" "${install_args[@]}"

printf '\nFinal verification:\n'
"$repo_root/scripts/doctor.sh"
