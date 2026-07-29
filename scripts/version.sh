#!/usr/bin/env bash

# Shared semantic-version helpers for install.sh and doctor.sh.
# Supports numeric major.minor.patch versions with an optional leading "v".

# Consumed by scripts that source this helper.
# shellcheck disable=SC2034
CCX_MINIMUM_CLAUDE_VERSION='2.1.217'
# shellcheck disable=SC2034
CCX_MINIMUM_PROXY_VERSION='0.1.17'

normalize_version() {
  local version="$1"
  version="${version#v}"
  version="${version%%[-+]*}"
  printf '%s' "$version"
}

version_at_least() {
  local current required
  local current_major current_minor current_patch
  local required_major required_minor required_patch

  current="$(normalize_version "$1")"
  required="$(normalize_version "$2")"

  IFS='.' read -r current_major current_minor current_patch <<EOF
$current
EOF
  IFS='.' read -r required_major required_minor required_patch <<EOF
$required
EOF

  current_major="${current_major:-0}"
  current_minor="${current_minor:-0}"
  current_patch="${current_patch:-0}"
  required_major="${required_major:-0}"
  required_minor="${required_minor:-0}"
  required_patch="${required_patch:-0}"

  case "$current_major.$current_minor.$current_patch.$required_major.$required_minor.$required_patch" in
    *[!0-9.]*)
      return 2
      ;;
  esac

  if (( 10#$current_major != 10#$required_major )); then
    (( 10#$current_major > 10#$required_major ))
    return
  fi
  if (( 10#$current_minor != 10#$required_minor )); then
    (( 10#$current_minor > 10#$required_minor ))
    return
  fi
  (( 10#$current_patch >= 10#$required_patch ))
}
