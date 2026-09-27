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
grep -q '^COMPACT_WINDOW=272000$' <<<"$normal_output"
grep -q '^MAX_CONCURRENT_SUBAGENTS=3$' <<<"$normal_output"
grep -q '^MAX_SUBAGENTS_PER_SESSION=12$' <<<"$normal_output"
grep -q '^MAX_SUBAGENT_SPAWN_DEPTH=1$' <<<"$normal_output"
grep -q '^MAX_RETRIES=3$' <<<"$normal_output"
grep -q '^API_TIMEOUT_MS=300000$' <<<"$normal_output"

for astra_alias in astra gpt-6-astra 'gpt-6-astra[1m]'; do
  astra_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" "$astra_alias" -p test)"
  grep -q '^MODEL=gpt-6-astra$' <<<"$astra_output"
  grep -q '^ARG=medium$' <<<"$astra_output"
  grep -q '^COMPACT_WINDOW=272000$' <<<"$astra_output"
  if grep -q '^ARG=astra$' <<<"$astra_output"; then
    printf 'test: Astra selector leaked into Claude arguments\n' >&2
    exit 1
  fi
done
astra_override="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra --effort high -p test)"
grep -q '^ARG=high$' <<<"$astra_override"
if grep -q '^ARG=medium$' <<<"$astra_override"; then exit 1; fi

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
  'astra-fast:gpt-6-astra-fast'
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

astra_bg_output="$(CCX_BG_MODEL=astra CCX_BG_EFFORT=low CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" bg -p test)"
grep -q '^MODEL=gpt-6-astra$' <<<"$astra_bg_output"
grep -q '^ARG=low$' <<<"$astra_bg_output"
astra_main_output="$(CCX_MODEL=astra CCX_MAIN_EFFORT=high CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" -p test)"
grep -q '^ARG=high$' <<<"$astra_main_output"

# Recognition metadata must preserve wire IDs and caller settings.
catalog_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra -p test)"
grep -q '^MODEL=gpt-6-astra$' <<<"$catalog_output"
grep -q '"model":"gpt-6-astra","label":"GPT-6 Astra (OpenAI subscription)","behavesAs":"claude-opus-4-6"' <<<"$catalog_output"
for settings_style in split equals; do
  if [[ "$settings_style" == split ]]; then
    settings_arguments=(--settings '{"permissions":{"defaultMode":"plan"}}')
  else
    settings_arguments=('--settings={"permissions":{"defaultMode":"plan"}}')
  fi
  explicit_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra "${settings_arguments[@]}" -p test)"
  grep -q '"permissions":{"defaultMode":"plan"}' <<<"$explicit_output"
  grep -q 'behavesAs' <<<"$explicit_output"
done
sol_catalog_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" sol -p test)"
if grep -q 'behavesAs' <<<"$sol_catalog_output"; then
  printf 'test: Astra profile leaked into another model lane\n' >&2
  exit 1
fi

settings_file="$test_config_dir/custom settings.json"
cat > "$settings_file" <<'JSON'
{"env":{"TEST_VALUE":"literal $(ignored) and café"},"permissions":{"allow":["Read"],"defaultMode":"plan"},"modelPicker":{"replaceBuiltInOptions":true,"options":[{"model":"other-model","label":"Keep me"},{"model":"gpt-6-astra","label":"My Astra","behavesAs":"claude-opus-4-8"}]}}
JSON
original_settings="$(cat "$settings_file")"
file_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra --settings "$settings_file" -p test)"
merged_json="$(sed -n 's/^ARG=\({.*\)$/\1/p' <<<"$file_output")"
printf '%s' "$merged_json" | jq -e '
  .permissions.allow == ["Read"] and .permissions.defaultMode == "plan"
  and .env.TEST_VALUE == "literal $(ignored) and café"
  and .modelPicker.replaceBuiltInOptions == true
  and (.modelPicker.options | length) == 3
  and .modelPicker.options[0].label == "Keep me"
  and .modelPicker.options[1].label == "My Astra"
  and .modelPicker.options[1].behavesAs == "claude-opus-4-8"
  and .modelPicker.options[2].model == "gpt-6-astra-fast"
' >/dev/null
test "$(cat "$settings_file")" = "$original_settings"
for invalid_settings in '{secret' '[]' '{"modelPicker":null}' '{"modelPicker":{"options":{}}}' '{} {}' "$test_config_dir/missing.json"; do
  if CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra --settings "$invalid_settings" -p test >"$test_config_dir/invalid.out" 2>"$test_config_dir/invalid.err"; then
    printf 'test: malformed settings were accepted\n' >&2; exit 1
  fi
  test ! -s "$test_config_dir/invalid.out"
  if grep -q 'secret' "$test_config_dir/invalid.err"; then exit 1; fi
done
last_output="$(CCX_REAL_CLAUDE="$stub" CCX_SKIP_HEALTH_CHECK=1 "$launcher" astra --settings '{"env":{"FIRST":"discard"}}' --settings='{"env":{"LAST":"keep"}}' -p test)"
grep -q '"LAST":"keep"' <<<"$last_output"
if grep -q FIRST <<<"$last_output"; then exit 1; fi

printf 'All ccx launcher tests passed.\n'
