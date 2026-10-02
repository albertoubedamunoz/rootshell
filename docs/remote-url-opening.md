# Open links from remote programs

Rootshell can open HTTP and HTTPS links requested by a program running in the focused terminal, using the browser on the connected Mac, iPad, or iPhone. This supports browser-launching tools such as Codex on a headless SSH host.

Enable **Open Links from Programs** in Settings → Terminal. It is off by default. The configuration key is `open-links-from-programs`.

Install the helper on the remote host from a checkout containing this feature:

```sh
install -m 755 scripts/rootshell-open "$HOME/bin/rootshell-open"
export BROWSER="$HOME/bin/rootshell-open"
```

Start a new Codex process with that environment. A normal link click now requests the device's browser. To limit this behavior to Codex:

```sh
BROWSER="$HOME/bin/rootshell-open" codex
```

The helper writes to `/dev/tty`, because browser-launching libraries can discard a subprocess's standard output. It takes exactly one HTTP(S) URL; URLs exceeding its bounded payload size are rejected.

## tmux

For ordinary tmux sessions over SSH, enable passthrough:

```sh
tmux set -g allow-passthrough on
```

The helper detects `$TMUX` and wraps its request in tmux's DCS passthrough encoding. This helper targets a direct connection or one ordinary tmux layer. Rootshell's parser also accepts a second passthrough layer when an emitter wraps it explicitly.

Native tmux control-mode panes (`tmux -CC`) are not supported by this Swift-side handler: their decoded output goes directly to Ghostty. Mosh screen synchronization also does not preserve this request. Use ordinary SSH/tmux for this feature; native pane support needs a Ghostty-level protocol hook.

## Request protocol

The sequence is `ESC ] 777;rootshell;open-url;<base64> BEL`, with UTF-8 URL bytes encoded using standard base64 without line breaks. `ESC \\` (ST) can replace BEL. Encoding the URL prevents embedded control characters or semicolons from changing the request framing.

Rootshell observes live session output without modifying the bytes sent to Ghostty. It handles requests split across transport chunks and bounds buffered control strings to 16 KiB. Unrelated OSC, DCS, APC, PM, and SOS sequences do not trigger URL requests. Saved scrollback and local redraws are not observed.

Only HTTP(S) URLs with a nonempty host and no credentials, whitespace, or control characters are accepted. Requests are dropped when the app is backgrounded or when the terminal is hidden or unfocused. Opening is limited to one request per second per terminal; suppressed requests are not queued. The remote helper does not receive an acknowledgement, so a successful exit means the request was written, not that the browser opened.

Browser-based authentication may also launch through this handler. Opening a URL does not forward a remote localhost callback port; use the tool's remote/device authentication flow when required.
