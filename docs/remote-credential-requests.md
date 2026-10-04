# Credential requests from remote programs

A program on a host connected over SSH or tssh can ask Rootshell for a password or token. Rootshell shows a sheet with the host, the requesting command, and the prompt. Fill the field from your password manager with AutoFill (for example 1Password, which unlocks with Face ID or Touch ID), tap **Send**, and the value goes back to the program that asked. Typical uses are `sudo` passwords, unlocking the GNOME keyring, and tokens for CLIs such as `gh`.

The request travels over a forwarded Unix socket, the same way GPG agent forwarding does, not over terminal output. Other programs cannot fake a request by printing escape sequences, and the reply reaches only the helper that asked.

## Enable it

Turn on **Credential Requests** in the connection's Advanced settings or in the profile editor. It is off by default and is not available for Mosh, which cannot forward a socket.

Install the helper on the remote host from a checkout containing this feature:

```sh
install -m 755 scripts/rootshell-askpass "$HOME/bin/"
```

The helper needs `perl`, `socat`, or an `nc` that supports `-U`. Most Linux distributions and macOS include `perl`.

## Examples

```sh
# sudo
SUDO_ASKPASS="$HOME/bin/rootshell-askpass" sudo -A apt upgrade

# GNOME keyring on a headless login
rootshell-askpass "Keyring password" | gnome-keyring-daemon --unlock

# A token for one command
GH_TOKEN=$(rootshell-askpass "GitHub token") gh pr list
```

The first argument is the prompt shown in the sheet; it defaults to `Password:`. The value is printed to standard output followed by a newline. The helper exits 1 when the request is cancelled, times out, or cannot reach Rootshell, and prints the reason to standard error.

## How the helper finds Rootshell

When the setting is on, Rootshell creates `~/.rootshell` (mode 0700) on connect and forwards a socket named `askpass-<pane>.sock` inside it. The pane token also reaches the remote as `LC_ROOTSHELL_PANE`. The helper tries, in order:

1. `$ROOTSHELL_ASKPASS_SOCK`, if set.
2. `~/.rootshell/askpass-$LC_ROOTSHELL_PANE.sock`.
3. The newest socket in `~/.rootshell` that accepts a connection. This covers tmux panes and reattached tssh sessions whose environment carries an older pane token.

Set `ROOTSHELL_ASKPASS_DIR` to look in a directory other than `~/.rootshell`.

## Security

- Any process running as your remote user (or as root) can **ask**. Nothing is sent unless you fill the field and tap **Send** for that request.
- The command shown in the sheet is reported by the server and can be spoofed by the requesting process. Treat it as a hint, and cancel requests you did not expect.
- Rootshell does not store, log, or cache the value. Each request needs its own approval.
- Only one request per connection is shown at a time; others are refused with `busy`. An unanswered request is cancelled after two minutes, and its sheet closes as soon as the helper exits or the connection ends.

## Troubleshooting

If the helper reports that no connection is available:

- Check that the setting is on for this connection and that you reconnected after enabling it.
- Check that sshd allows Unix-socket forwarding. `AllowStreamLocalForwarding` must be `yes` or `remote` (the default is `yes`).
- Check that `~/.rootshell/askpass-*.sock` exists while the connection is open.

## Request protocol

One request per connection on the socket:

```
ROOTSHELL-ASKPASS 1
PROMPT <text>
COMMAND <text>
END
```

Rootshell replies `OK`, a newline, and the value, or `ERR <reason>` followed by a newline, where the reason is `canceled`, `busy`, `timeout`, or `protocol`, and then closes the connection. The client must keep its write side open until the reply arrives. Requests are limited to 8 KiB, and control and bidirectional formatting characters are removed before display.
