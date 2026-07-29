#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/claudex-setup-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

config_dir="$tmp_dir/config"

CCX_CONFIG_DIR="$config_dir" "$repo_root/scripts/setup.sh" \
  --main-model terra \
  --main-effort high \
  --bg-model sol \
  --bg-effort medium \
  --utility-model mini \
  --subagent-effort xhigh \
  --with-agent \
  --no-login \
  --no-service \
  --config-only \
  --yes

config_file="$config_dir/config"
grep -q '^CCX_MODEL=terra$' "$config_file"
grep -q '^CCX_MAIN_EFFORT=high$' "$config_file"
grep -q '^CCX_BG_MODEL=sol$' "$config_file"
grep -q '^CCX_BG_EFFORT=medium$' "$config_file"
grep -q '^CCX_SMALL_FAST_MODEL=gpt-5.4-mini\[1m\]$' "$config_file"
grep -q '^CCX_SUBAGENT_EFFORT=xhigh$' "$config_file"
grep -q '^CCX_SUBAGENT_GUARDS=1$' "$config_file"
grep -q '^CCX_MAX_CONCURRENT_SUBAGENTS=3$' "$config_file"
grep -q '^CCX_MAX_SUBAGENTS_PER_SESSION=12$' "$config_file"
grep -q '^CCX_MAX_SUBAGENT_SPAWN_DEPTH=1$' "$config_file"
grep -q '^CCX_MAX_RETRIES=3$' "$config_file"
grep -q '^CCX_API_TIMEOUT_MS=300000$' "$config_file"
grep -q '^CCX_PROXY_TRANSPORT=http$' "$config_file"

configured_output="$(
  CCX_CONFIG_FILE="$config_file" \
  CCX_REAL_CLAUDE="$repo_root/tests/stub-claude.sh" \
  CCX_SKIP_HEALTH_CHECK=1 \
    "$repo_root/bin/ccx" -p test
)"
grep -q '^MODEL=gpt-5.6-terra\[1m\]$' <<<"$configured_output"
grep -q '^SMALL_FAST=gpt-5.4-mini\[1m\]$' <<<"$configured_output"
grep -q '^ARG=high$' <<<"$configured_output"

sed \
  -e 's#^CCX_PROXY_URL=.*#CCX_PROXY_URL=http://127.0.0.1:18766#' \
  -e 's#^CCX_PROXY_TRANSPORT=.*#CCX_PROXY_TRANSPORT=auto#' \
  -e 's#^CCX_MAX_CONCURRENT_SUBAGENTS=.*#CCX_MAX_CONCURRENT_SUBAGENTS=2#' \
  -e 's#^CCX_MAX_SUBAGENTS_PER_SESSION=.*#CCX_MAX_SUBAGENTS_PER_SESSION=10#' \
  -e 's#^CCX_MAX_RETRIES=.*#CCX_MAX_RETRIES=2#' \
  -e 's#^CCX_API_TIMEOUT_MS=.*#CCX_API_TIMEOUT_MS=240000#' \
  "$config_file" > "$config_file.custom"
mv "$config_file.custom" "$config_file"
printf 'CCX_CONTEXT_WINDOW=200000\n' >> "$config_file"
printf 'CCX_SHIM_URL=http://127.0.0.1:18767\n' >> "$config_file"

CCX_CONFIG_DIR="$config_dir" "$repo_root/scripts/setup.sh" \
  --main-model luna \
  --main-effort xhigh \
  --bg-model sol \
  --bg-effort medium \
  --utility-model sol \
  --subagent-effort high \
  --without-agent \
  --no-login \
  --no-service \
  --config-only \
  --yes >/dev/null

grep -q '^CCX_MODEL=luna$' "$config_file"
grep -q '^CCX_PROXY_URL=http://127.0.0.1:18766$' "$config_file"
grep -q '^CCX_PROXY_TRANSPORT=auto$' "$config_file"
grep -q '^CCX_SHIM_URL=http://127.0.0.1:18767$' "$config_file"
grep -q '^CCX_CONTEXT_WINDOW=200000$' "$config_file"
grep -q '^CCX_MAX_CONCURRENT_SUBAGENTS=2$' "$config_file"
grep -q '^CCX_MAX_SUBAGENTS_PER_SESSION=10$' "$config_file"
grep -q '^CCX_MAX_SUBAGENT_SPAWN_DEPTH=1$' "$config_file"
grep -q '^CCX_MAX_RETRIES=2$' "$config_file"
grep -q '^CCX_API_TIMEOUT_MS=240000$' "$config_file"
backup_count="$(find "$config_dir" -maxdepth 1 -name 'config.backup-*' | wc -l | tr -d ' ')"
test "$backup_count" -eq 1

before_hash="$(cksum "$config_file")"
if CCX_CONFIG_DIR="$config_dir" "$repo_root/scripts/setup.sh" \
  --main-effort impossible --config-only --yes >/dev/null 2>&1; then
  printf 'test: invalid effort unexpectedly succeeded\n' >&2
  exit 1
fi
after_hash="$(cksum "$config_file")"
test "$before_hash" = "$after_hash"

printf 'All setup wizard tests passed.\n'
