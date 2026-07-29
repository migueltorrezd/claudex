#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '--version' ]]; then
  printf '%s (Claude Code)\\n' "${CLAUDE_STUB_VERSION:-2.1.220}"
  exit 0
fi

printf 'MODEL=%s\n' "${ANTHROPIC_MODEL:-unset}"
printf 'SMALL_FAST=%s\n' "${ANTHROPIC_SMALL_FAST_MODEL:-unset}"
printf 'EFFORT_ENV=%s\n' "${CLAUDE_CODE_EFFORT_LEVEL:-unset}"
printf 'BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-unset}"
printf 'COMPACT_WINDOW=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-unset}"
printf 'MAX_CONCURRENT_SUBAGENTS=%s\n' "${CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS:-unset}"
printf 'MAX_SUBAGENTS_PER_SESSION=%s\n' "${CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION:-unset}"
printf 'MAX_SUBAGENT_SPAWN_DEPTH=%s\n' "${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-unset}"
printf 'MAX_RETRIES=%s\n' "${CLAUDE_CODE_MAX_RETRIES:-unset}"
printf 'API_TIMEOUT_MS=%s\n' "${API_TIMEOUT_MS:-unset}"
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument"
done
