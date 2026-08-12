#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_root/bin/ccx"
stub="$repo_root/tests/stub-claude.sh"
test_config_dir="$(mktemp -d "${TMPDIR:-/tmp}/claudex-ccx-test.XXXXXX")"
trap 'rm -rf "$test_config_dir"' EXIT
export CCX_CONFIG_FILE="$test_config_dir/missing.conf"

normal_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^MODEL=gpt-5.6-sol\[1m\]$' <<<"$normal_output"
grep -q '^SMALL_FAST=gpt-5.6-sol\[1m\]$' <<<"$normal_output"
grep -q '^EFFORT_ENV=unset$' <<<"$normal_output"
grep -q '^ARG=xhigh$' <<<"$normal_output"
grep -q '^BASE_URL=http://127.0.0.1:18765$' <<<"$normal_output"
grep -q '^COMPACT_WINDOW=967000$' <<<"$normal_output"
grep -q '^MAX_CONCURRENT_SUBAGENTS=3$' <<<"$normal_output"
grep -q '^MAX_SUBAGENTS_PER_SESSION=12$' <<<"$normal_output"
grep -q '^MAX_SUBAGENT_SPAWN_DEPTH=1$' <<<"$normal_output"
grep -q '^MAX_RETRIES=3$' <<<"$normal_output"
grep -q '^API_TIMEOUT_MS=300000$' <<<"$normal_output"

spark_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" spark -p test)"
grep -q '^MODEL=gpt-5.3-codex-spark$' <<<"$spark_output"
grep -q '^COMPACT_WINDOW=128000$' <<<"$spark_output"

bare_id_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" gpt-5.6-terra -p test)"
grep -q '^MODEL=gpt-5.6-terra\[1m\]$' <<<"$bare_id_output"
if grep -q '^ARG=gpt-5.6-terra$' <<<"$bare_id_output"; then
  printf 'test: bare model ID leaked into claude arguments\n' >&2
  exit 1
fi

if CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" gpt-bogus -p test >/dev/null 2>&1; then
  printf 'test: unsupported bare model ID was accepted\n' >&2
  exit 1
fi

shim_output="$(CCX_SHIM_URL='http://127.0.0.1:59999' CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^BASE_URL=http://127.0.0.1:59999$' <<<"$shim_output"

no_newline_conf="$(mktemp)"
printf '# fixture without trailing newline\nCCX_MODEL=luna' > "$no_newline_conf"
no_newline_output="$(CCX_CONFIG_FILE="$no_newline_conf" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
rm -f "$no_newline_conf"
grep -q '^MODEL=gpt-5.6-luna\[1m\]$' <<<"$no_newline_output"

background_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg -p test)"
grep -q '^MODEL=gpt-5.6-sol\[1m\]$' <<<"$background_output"
grep -q '^ARG=medium$' <<<"$background_output"

override_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg --effort high -p test)"
if grep -q '^ARG=medium$' <<<"$override_output"; then
  printf 'test: explicit effort was not respected\n' >&2
  exit 1
fi
grep -q '^ARG=high$' <<<"$override_output"

terra_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" terra -p test)"
grep -q '^MODEL=gpt-5.6-terra\[1m\]$' <<<"$terra_output"

fast_aliases=(
  'sol-fast:gpt-5.6-sol-fast[1m]'
  'terra-fast:gpt-5.6-terra-fast[1m]'
  'luna-fast:gpt-5.6-luna-fast[1m]'
  '5.5-fast:gpt-5.5-fast[1m]'
  '5.4-fast:gpt-5.4-fast[1m]'
  'mini-fast:gpt-5.4-mini-fast[1m]'
  '5.3-fast:gpt-5.3-codex-fast[1m]'
  'spark-fast:gpt-5.3-codex-spark-fast'
  '5.2-fast:gpt-5.2-fast[1m]'
)
for alias_mapping in "${fast_aliases[@]}"; do
  alias_name="${alias_mapping%%:*}"
  expected_model="${alias_mapping#*:}"
  alias_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" "$alias_name" -p test)"
  grep -qF "MODEL=$expected_model" <<<"$alias_output"
done

ultracode_output="$(CCX_MAIN_EFFORT=ultracode CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^ARG=ultracode$' <<<"$ultracode_output"

solo_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" solo -p test)"
grep -q '^ARG=--disallowedTools$' <<<"$solo_output"
grep -q '^ARG=Agent$' <<<"$solo_output"

guard_override_output="$(
  CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=7 \
  CCX_REAL_CLAUDE="$stub" \
  CCX_SKIP_HEALTH_CHECK=1 \
    "$launcher" -p test
)"
grep -q '^MAX_CONCURRENT_SUBAGENTS=7$' <<<"$guard_override_output"

guards_disabled_output="$(
  env \
    -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS \
    -u CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION \
    -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH \
    -u CLAUDE_CODE_MAX_RETRIES \
    -u API_TIMEOUT_MS \
    CCX_SUBAGENT_GUARDS=0 \
    CCX_REAL_CLAUDE="$stub" \
    CCX_SKIP_HEALTH_CHECK=1 \
      "$launcher" -p test
)"
grep -q '^MAX_CONCURRENT_SUBAGENTS=unset$' <<<"$guards_disabled_output"
grep -q '^MAX_SUBAGENTS_PER_SESSION=unset$' <<<"$guards_disabled_output"
grep -q '^MAX_SUBAGENT_SPAWN_DEPTH=unset$' <<<"$guards_disabled_output"
grep -q '^MAX_RETRIES=unset$' <<<"$guards_disabled_output"
grep -q '^API_TIMEOUT_MS=unset$' <<<"$guards_disabled_output"

if CCX_MAX_CONCURRENT_SUBAGENTS=invalid CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test >/dev/null 2>&1; then
  printf 'test: invalid subagent concurrency cap was accepted\n' >&2
  exit 1
fi

custom_config="$repo_root/tests/fixtures/custom.conf"
configured_output="$(CCX_CONFIG_FILE="$custom_config" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^MODEL=gpt-5.6-terra\[1m\]$' <<<"$configured_output"
grep -q '^SMALL_FAST=gpt-5.4-mini\[1m\]$' <<<"$configured_output"
grep -q '^ARG=high$' <<<"$configured_output"
grep -q '^COMPACT_WINDOW=200000$' <<<"$configured_output"
grep -q '^MAX_CONCURRENT_SUBAGENTS=2$' <<<"$configured_output"
grep -q '^MAX_SUBAGENTS_PER_SESSION=9$' <<<"$configured_output"
grep -q '^MAX_SUBAGENT_SPAWN_DEPTH=1$' <<<"$configured_output"
grep -q '^MAX_RETRIES=2$' <<<"$configured_output"
grep -q '^API_TIMEOUT_MS=240000$' <<<"$configured_output"

configured_bg_output="$(CCX_CONFIG_FILE="$custom_config" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg -p test)"
grep -q '^MODEL=gpt-5.6-luna\[1m\]$' <<<"$configured_bg_output"
grep -q '^ARG=low$' <<<"$configured_bg_output"

config_output="$(CCX_CONFIG_FILE="$custom_config" "$launcher" config)"
grep -q '^Main model: terra$' <<<"$config_output"
grep -q '^Background effort: low$' <<<"$config_output"
grep -q '^Proxy Codex transport: auto$' <<<"$config_output"

if CCX_PROXY_TRANSPORT=invalid CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test >/dev/null 2>&1; then
  printf 'test: invalid proxy transport was accepted\n' >&2
  exit 1
fi

printf 'All ccx launcher tests passed.\n'
