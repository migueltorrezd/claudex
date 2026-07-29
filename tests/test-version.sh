#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/version.sh
source "$repo_root/scripts/version.sh"

test "$CCX_MINIMUM_CLAUDE_VERSION" = '2.1.217'
test "$CCX_MINIMUM_PROXY_VERSION" = '0.1.17'

version_at_least 0.1.26 0.1.17
version_at_least v2.1.220 2.1.217
version_at_least 2.1.217 2.1.217
version_at_least 3.0.0 2.99.99
version_at_least 2.2.0-beta.1 2.1.999

if version_at_least 0.1.16 0.1.17; then
  printf 'test: older proxy version passed minimum check\n' >&2
  exit 1
fi

if version_at_least 2.1.216 2.1.217; then
  printf 'test: older Claude Code version passed minimum check\n' >&2
  exit 1
fi

if version_at_least invalid 2.1.203; then
  printf 'test: invalid version passed minimum check\n' >&2
  exit 1
fi

printf 'All version tests passed.\n'
