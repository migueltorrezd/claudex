# Security

## Localhost only

`claude-code-proxy` does not authenticate incoming clients. Claudex therefore defaults to `http://127.0.0.1:18765` and never changes the proxy bind address.

Do not expose port `18765` to a LAN, VPN, container bridge, tunnel, or the public internet unless you add a firewall and an authenticating reverse proxy you understand and control.

## Credentials

- Authenticate only with `claude-code-proxy codex auth login` or `claude-code-proxy codex auth device`.
- Never copy OAuth access or refresh tokens into this repository, a shell alias, `.env`, an issue, or a support message.
- `ANTHROPIC_AUTH_TOKEN=unused` in `bin/ccx` is intentionally a dummy value for the loopback proxy. It is not your OpenAI or Anthropic credential.
- `~/.config/claudex/config` contains model and effort preferences only. The launcher parses an allowlist of keys and does not execute or `source` the file.
- On macOS, the upstream proxy stores its own credentials in Keychain. Other platforms use the upstream proxy's documented credential directory and file permissions.

## Trust boundary

This repository is a launcher and setup guide. The protocol translation and OAuth implementation live in the separate [`raine/claude-code-proxy`](https://github.com/raine/claude-code-proxy) project. Review that project and its releases before installing it.

## Reporting

If the problem is in the launcher or documentation, open an issue in this repository without logs that contain credentials or private prompts. If it reproduces with the upstream proxy directly, report it to the upstream project and follow its security policy.
