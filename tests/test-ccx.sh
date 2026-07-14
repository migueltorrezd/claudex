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

configured_bg_output="$(CCX_CONFIG_FILE="$custom_config" CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg -p test)"
grep -q '^MODEL=gpt-5.6-luna\[1m\]$' <<<"$configured_bg_output"
grep -q '^ARG=low$' <<<"$configured_bg_output"

config_output="$(CCX_CONFIG_FILE="$custom_config" "$launcher" config)"
grep -q '^Main model: terra$' <<<"$config_output"
grep -q '^Background effort: low$' <<<"$config_output"

printf 'All ccx launcher tests passed.\n'
