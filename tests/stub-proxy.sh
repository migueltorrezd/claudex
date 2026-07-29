#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version)
    printf 'claude-code-proxy %s\n' "${PROXY_STUB_VERSION:-0.1.26}"
    ;;
  codex)
    if [[ "${2:-}" == 'auth' && "${3:-}" == 'status' ]]; then
      printf 'authenticated\n'
    else
      printf 'stub-proxy: unsupported codex command\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'stub-proxy: unsupported command\n' >&2
    exit 2
    ;;
esac
