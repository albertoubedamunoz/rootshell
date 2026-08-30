# rootshell-push for Codex

Sends an end-to-end encrypted push notification to your paired rootshell
devices when a Codex turn completes.

Hook installed: `Stop`.

Codex's `PermissionRequest` hook fires before its reviewer decides whether the
user must act, so it is not a reliable blocker signal. When Codex is running in
a rootshell terminal, rootshell's on-device screen detector handles blocker
notifications while an approval prompt is actually visible.

## Requirements

1. `rootshell-notify` on your PATH:

   ```sh
   curl -fsSL https://push.rootshell.com/install.sh | sh
   ```

2. At least one paired device: in rootshell open Settings > Notifications >
   Push Notifications > Pair a computer, then run `rootshell-notify pair`.

## Install

Either install this plugin, or run `rootshell-notify install codex` to merge
the hook into `~/.codex/hooks.json`.

## Trust the hook

Codex requires you to trust new hooks: run `codex` then `/hooks`, review the
rootshell entry and mark it trusted. The installer never writes
`trusted_hash` or touches `config.toml` on your behalf.

## What is sent

Only a title ("Codex · project"), a short redacted summary of the last
assistant message, and routing hints so rootshell can jump to the right pane.
Everything is encrypted to your device before it leaves this computer; the
relay never sees plaintext.

See the [push README](../../README.md) and [PROTOCOL.md](../../PROTOCOL.md).
