#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  install|upgrade)
    exit 0
    ;;
  ruby)
    shift
    exec ruby "$@"
    ;;
  services)
    case "${2:-}" in
      start|restart)
        exit 0
        ;;
    esac
    ;;
esac

printf 'stub-brew: unsupported command\n' >&2
exit 2
