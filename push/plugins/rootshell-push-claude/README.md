# rootshell-push for Claude Code

Sends an end-to-end encrypted push notification to your paired rootshell
devices when Claude Code finishes a turn or is waiting on you (permission
prompts, idle, and questions via `AskUserQuestion`).

Hooks installed: `Stop`, `Notification`, and `PreToolUse` matched to
`AskUserQuestion`. All run in the background and never block or answer on
your behalf; the question hook only reports the first question text.

## Requirements

1. `rootshell-notify` on your PATH:

   ```sh
   curl -fsSL https://push.rootshell.com/install.sh | sh
   ```

2. At least one paired device: in rootshell open Settings > Notifications >
   Push Notifications > Pair a computer, then run `rootshell-notify pair`.

## Install the plugin

```
/plugin install rootshell-push
```

Or, without the plugin system, `rootshell-notify install claude-code` merges the
same hooks into `~/.claude/settings.json`.

## What is sent

Only a title ("Claude Code · project"), a short redacted summary of the last
assistant message (or the notification text), and routing hints so rootshell can
jump to the right pane. Everything is encrypted to your device before it leaves
this computer; the relay never sees plaintext.

See the [push README](../../README.md) and [PROTOCOL.md](../../PROTOCOL.md).
