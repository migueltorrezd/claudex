# Security

## Localhost only

`claude-code-proxy` does not authenticate incoming clients. Claudex therefore defaults to `http://127.0.0.1:18765` and never changes the proxy bind address. The optional retry shim follows the same rule and binds only to `127.0.0.1:18767`.

The loopback bind is not a complete boundary: every process and every local user account on the machine can reach `127.0.0.1:18765` and spend your subscription quota through it, without any credential. On a single-user machine this adds little beyond what local code can already do with your files, but on shared machines treat the proxy as an open spigot for anyone with local access.

Do not expose port `18765` or `18767` to a LAN, VPN, container bridge, tunnel, or the public internet unless you add a firewall and an authenticating reverse proxy you understand and control.

## Credentials

- Authenticate only with `claude-code-proxy codex auth login` or `claude-code-proxy codex auth device`.
- Never copy OAuth access or refresh tokens into this repository, a shell alias, `.env`, an issue, or a support message.
- `ANTHROPIC_AUTH_TOKEN=unused` in `bin/ccx` is intentionally a dummy value for the loopback proxy. It is not your OpenAI or Anthropic credential.
- `~/.config/claudex/config` contains model and effort preferences only. The launcher parses an allowlist of keys and does not execute or `source` the file.
- On macOS, the upstream proxy stores the credential it manages in Keychain (`claude-code-proxy codex auth status` reports the storage backend). Other platforms use the upstream proxy's documented credential directory and file permissions.
- If the standalone Codex CLI is also installed, it keeps its own plaintext copy of the OAuth credential at `~/.codex/auth.json` (mode 0600). That file is outside Claudex's and the proxy's control: any process running as your user can read it, so treat it as a live credential even when the proxy side sits in Keychain.

## Trust boundary

This repository is a launcher and setup guide. The protocol translation and OAuth implementation live in the separate [`raine/claude-code-proxy`](https://github.com/raine/claude-code-proxy) project. Review that project and its releases before installing it.

## Reporting

If the problem is in the launcher or documentation, open an issue in this repository without logs that contain credentials or private prompts. If it reproduces with the upstream proxy directly, report it to the upstream project and follow its security policy.
