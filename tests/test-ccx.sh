#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_root/bin/ccx"
stub="$repo_root/tests/stub-claude.sh"

normal_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^MODEL=gpt-5.6-sol\[1m\]$' <<<"$normal_output"
grep -q '^SMALL_FAST=gpt-5.6-sol\[1m\]$' <<<"$normal_output"
grep -q '^EFFORT_ENV=unset$' <<<"$normal_output"
grep -q '^ARG=xhigh$' <<<"$normal_output"
grep -q '^BASE_URL=http://127.0.0.1:18765$' <<<"$normal_output"
grep -q '^COMPACT_WINDOW=272000$' <<<"$normal_output"

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

custom_config="$repo_root/tests/fixtures/custom.conf"
configured_output="$(CCX_CONFIG_FILE="$custom_config" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^MODEL=gpt-5.6-terra\[1m\]$' <<<"$configured_output"
grep -q '^SMALL_FAST=gpt-5.4-mini\[1m\]$' <<<"$configured_output"
grep -q '^ARG=high$' <<<"$configured_output"
grep -q '^COMPACT_WINDOW=200000$' <<<"$configured_output"

configured_bg_output="$(CCX_CONFIG_FILE="$custom_config" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg -p test)"
grep -q '^MODEL=gpt-5.6-luna\[1m\]$' <<<"$configured_bg_output"
grep -q '^ARG=low$' <<<"$configured_bg_output"

config_output="$(CCX_CONFIG_FILE="$custom_config" "$launcher" config)"
grep -q '^Main model: terra$' <<<"$config_output"
grep -q '^Background effort: low$' <<<"$config_output"

printf 'All ccx launcher tests passed.\n'
