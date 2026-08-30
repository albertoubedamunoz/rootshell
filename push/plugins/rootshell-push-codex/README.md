# rootshell-push for Codex

Sends an end-to-end encrypted push notification to your paired rootshell
devices when a Codex turn completes or Codex is waiting for your approval.

Hooks installed: `Stop` and `PermissionRequest`. The approval notification
carries the command (or tool name) Codex wants to run; the hook never
approves anything on your behalf.

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
