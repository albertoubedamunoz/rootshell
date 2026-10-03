# Open links from remote programs

Rootshell can open HTTP and HTTPS links requested by a program running in the focused terminal, using the browser on the connected Mac, iPad, or iPhone. This supports browser-launching tools such as Codex on a headless SSH host.

Enable **Open Links from Programs** in Settings → Terminal. It is off by default. The configuration key is `open-links-from-programs`.

Install the helper on the remote host from a checkout containing this feature:

```sh
install -m 755 scripts/rootshell-open scripts/rootshell-open-clipboard "$HOME/bin/"
export BROWSER="$HOME/bin/rootshell-open"
```

Start a new Codex process with that environment. A normal link click now requests the device's browser. To limit this behavior to Codex:

```sh
BROWSER="$HOME/bin/rootshell-open" codex
```

The helper writes to `/dev/tty`, because browser-launching libraries can discard a subprocess's standard output. It takes exactly one HTTP(S) URL; URLs exceeding its bounded payload size are rejected.

There are two transports:

| Connection | `BROWSER` | Sequence |
| --- | --- | --- |
| SSH, tsshd, ordinary tmux | `rootshell-open` | iTerm2's `OSC 1337 ; OpenURL` |
| Mosh, native tmux (`tmux -CC`) | `rootshell-open-clipboard` | Reserved OSC 52 envelope |

The default mode uses iTerm2's existing sequence, so the helper also opens links when the remote session runs in iTerm2, and programs that already emit that sequence work in Rootshell without the helper.

## Ordinary tmux over SSH

For ordinary tmux sessions over SSH, enable passthrough:

```sh
tmux set -g allow-passthrough on
```

The helper detects `$TMUX` and wraps its request in tmux's DCS passthrough encoding. This helper targets a direct connection or one ordinary tmux layer. Rootshell's parser also accepts a second passthrough layer when an emitter wraps it explicitly.

## Native tmux and Mosh

Use the clipboard-state transport for native `tmux -CC` panes and Mosh. `rootshell-open-clipboard` runs `rootshell-open --clipboard`; it exists because Python's `webbrowser` module runs a `BROWSER` value without `%s` as a single executable path, so `BROWSER="rootshell-open --clipboard"` would fail there:

```sh
BROWSER="$HOME/bin/rootshell-open-clipboard" codex
```

This sends a reserved envelope using OSC 52's `c` selector. Native tmux delivers it to the pane's Ghostty clipboard callback, which associates the request with the correct terminal. Mosh 1.4 and newer preserve this clipboard state; no server patch or separate forwarding service is needed. Rootshell intercepts the reserved envelope before writing the device clipboard or clipboard history, including when the feature is disabled or the envelope is invalid.

The `--clipboard` mode also works over plain SSH. For ordinary tmux nested inside SSH or Mosh, allow application clipboard updates:

```sh
tmux set -g set-clipboard on
```

Unlike the default mode, `--clipboard` sends an unwrapped OSC 52 request even when `$TMUX` is set. It does not require `allow-passthrough` for native tmux. Ordinary tmux must forward the `c` clipboard selector (its `Ms` terminal capability); Mosh discards other selectors.

Mosh carries the most recent clipboard state rather than an event queue. Very rapid requests can be coalesced before reaching the device. Each helper invocation uses a random request ID so opening the same URL twice produces two different clipboard states. Rootshell discards URL state from initial, resumed, throttled, and background frames so it cannot open when a hidden tab later becomes visible. [Mosh's clipboard renderer](https://github.com/mobile-shell/mosh/blob/mosh-1.4.0/src/terminal/terminaldisplay.cc#L102-L112) describes the underlying state channel.

## Request protocol

The default sequence is [iTerm2's `OpenURL`](https://iterm2.com/documentation-escape-codes.html): `ESC ] 1337;OpenURL=:<base64> BEL`, with UTF-8 URL bytes encoded using standard base64 without line breaks. `ESC \\` (ST) can replace BEL. Rootshell ignores any arguments between `OpenURL=` and the colon. Encoding the URL prevents embedded control characters or semicolons from changing the request framing. Other OSC 1337 commands are ignored.

Rootshell observes live session output without modifying the bytes sent to Ghostty. It handles requests split across transport chunks and bounds buffered control strings to 16 KiB. Unrelated OSC, DCS, APC, PM, and SOS sequences do not trigger URL requests. Saved scrollback and local redraws are not observed.

In `--clipboard` mode, the decoded clipboard payload is `rootshell-open-url:v1:<Unix timestamp>:<32 lowercase hex request ID>:<URL>`. The entire UTF-8 envelope is base64-encoded in `ESC ] 52;c;<base64> BEL`. URL validation is identical in both modes. Envelopes expire after 60 seconds and allow up to five seconds of future clock skew; synchronize the remote host and device clocks. A bounded, device-only replay cache stores request IDs and expiry times, never URLs, and survives app restarts. Requests consumed while disabled, hidden, or backgrounded cannot open upon later replay. Reserved-envelope handling never changes ordinary clipboard updates or selection copies.

Only HTTP(S) URLs with a nonempty host and no credentials, whitespace, or control characters are accepted. Requests are dropped when the app is backgrounded, when the terminal is hidden or unfocused, when its window is inactive, and while output buffered in the background is being replayed. Opening is limited to one request per second per terminal; suppressed requests are not queued. The remote helper does not receive an acknowledgement, so a successful exit means the request was written, not that the browser opened.

Browser-based authentication may also launch through this handler. Opening a URL does not forward a remote localhost callback port; use the tool's remote/device authentication flow when required.
