#!/usr/bin/env bash
set -euo pipefail

printf 'MODEL=%s\n' "${ANTHROPIC_MODEL:-unset}"
printf 'SMALL_FAST=%s\n' "${ANTHROPIC_SMALL_FAST_MODEL:-unset}"
printf 'EFFORT_ENV=%s\n' "${CLAUDE_CODE_EFFORT_LEVEL:-unset}"
printf 'BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-unset}"
printf 'COMPACT_WINDOW=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-unset}"
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument"
done
