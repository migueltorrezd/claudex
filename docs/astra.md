# GPT-6 Astra support

Verified on Miguel's Mac on 2026-09-05. Use `ccx astra` for medium reasoning, or `ccx astra --effort high`. `ccx gpt-6-astra` is equivalent. The existing plain `ccx` and `ccx bg` model preferences remain unchanged.

## Upstream requirement

Release 0.1.35 does not contain Astra. Upstream commit `55bf0b5818b461e1860964809726f99d2fd52c10` adds `gpt-6-astra` to both the registry and Responses translation allowlist. The installed binary is an unmodified build of that pinned source using `cargo build --locked --release` with four build jobs. Rust was installed from Homebrew to build it.

Local build installation:

- `~/.local/share/claudex/proxy/55bf0b5818b461e1860964809726f99d2fd52c10/claude-code-proxy`
- The neighboring `build.json` records source revision, build command, and binary SHA-256.
- `~/.local/bin/claude-code-proxy` points to this build and precedes the unchanged Homebrew release binary.
- `~/Library/LaunchAgents/com.migle.claudex-proxy.plist` runs it on `127.0.0.1:18765`.
- `CCX_PROXY_SERVICE=com.migle.claudex-proxy` in `~/.config/claudex/config` makes the launcher recover this service instead of starting the old Homebrew release.
- The existing retry shim on `127.0.0.1:18767` forwards to the new service unchanged.

Both `homebrew.mxcl.claude-code-proxy` and `com.raine.claude-code-proxy` were disabled and unloaded after confirming no active connections. Their plists remain for recovery. Do not enable them alongside the managed service: all three target the same port. Native Claude/Codex configuration, OAuth credentials, hooks, plugins, and Feynman were not changed.

## Verification

The launcher's deterministic suite covers Astra aliases, explicit effort, safe compaction thresholds, and supported priority aliases. Upstream model-allowlist tests passed. Live subscription-backed tests returned `ASTRA_OK`, `ASTRA_INSTALLED_OK`, and `ASTRA_CHILD_OK`; the child test reported one spawned and completed worker, zero failed workers, and `gpt-6-astra` usage. Large fan-out was not stress-tested.

CCX now supplies a session-local `modelPicker` row with `behavesAs: "claude-opus-4-6"` for Astra and Astra Fast. Claude 2.1.261 uses that known client profile for prompt/capability/effort defaults while still sending `gpt-6-astra` (or its priority ID). This fixes `unrecognized_model` at its source; no stderr filtering, model fallback, native binary patch, or persistent Claude settings edit is involved. The conservative existing compaction boundary remains unchanged.

The result's `canonicalModel` may consequently read `claude-opus-4-6`: that is the compatibility profile, not an Anthropic inference call. Check the actual `modelUsage` key and CCX routing. Pricing, `provider: firstParty`, and context display metadata reflect Claude's client profile, not the actual Codex billing/capacity contract.

For `--settings JSON`, `--settings=JSON`, or a JSON settings-file path, CCX adds only missing Astra picker rows and fills missing compatibility fields. Existing permissions, environment values, other picker rows, labels, `replaceBuiltInOptions`, and explicit `behavesAs` choices remain intact. The source file is never modified. Repeated `--settings` follows Claude's last-value behavior. Malformed input fails before a model request, without printing its contents. macOS/Linux uses `jq` for this merge; Windows uses native PowerShell JSON handling.

The follow-up main probe returned `ASTRA_CATALOG_OK` with empty stderr. The child probe returned `ASTRA_CHILD_DIAGNOSTIC_OK`, completed one inherited Astra child, and emitted no unknown-model diagnostic. An unrelated connector-authentication warning remained visible, confirming that stderr is not suppressed. These probes used the existing Codex subscription path. Older Claude builds may not understand this metadata; the tested build is 2.1.261.

The root launcher defaults to a conservative 272,000-token compaction window (Spark: 128,000). Astra does not require a `[1m]` suffix. Explicit `CCX_CONTEXT_WINDOW` remains available for a verified larger allowance.

## Future updates and recovery

When an upstream release includes Astra, verify its live model catalogue and run the bounded main/child checks before replacing the pinned build. Prefer updating this managed service's executable deliberately; do not let `brew services restart` introduce a second listener. The setup wizard preserves `CCX_PROXY_SERVICE` on this Mac.

Recovery copies of the old launcher, preferences, and service plists are in Workspace `output/agent-instructions/2026-09-05-backups/`. To return to the released Homebrew proxy, first ensure no active requests, unload/disable the managed service, remove its `CCX_PROXY_SERVICE` preference, and enable/bootstrap only the Homebrew service. Use the backed-up launcher and select a model supported by that release. Keep the legacy `com.raine` service disabled. Obtain authorization before an intentional rollback that removes Astra access.

Source: [upstream Astra registration](https://github.com/raine/claude-code-proxy/commit/55bf0b5818b461e1860964809726f99d2fd52c10).

Client metadata reference: [Claude Code model picker](https://code.claude.com/docs/en/settings-reference#modelpicker). The installed 2.1.261 schema and recognition code were inspected to verify `behavesAs` support.
