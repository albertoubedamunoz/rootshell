# herdr control mode

herdr control mode presents herdr's tabs and splits as native rootshell tabs and panes. You can navigate with the tab bar, sidebar, keyboard shortcuts, and Tab Exposé; manage workspaces and Git worktrees; and create, rename, rearrange, zoom, or close the corresponding tabs and panes from native controls. herdr's agent detection takes priority over rootshell's own detection, and agent notifications return to the matching pane.

**Requires rootshell 1.0.12-147 or newer and herdr 0.9.0 or newer on the host.** These are separate version requirements. rootshell validates the *running herdr server's* version, not just the CLI binary found in your shell. Unsupported or unrecognized server versions cannot be bypassed by switching to fallback mode.

## Connect

Enable **Control Mode** in the multiplexer session picker, choose **herdr (control)** as the auto-start option in a profile or connection, or use `--herdr-control` in Quick Connect. The integration supports SSH and tssh connections, plus local macOS sessions through rootshell's helper. Mosh does not provide the auxiliary channels needed for this control mode.

The gateway tab keeps your shell and connection controls available. Press Escape on the gateway to detach without stopping herdr; the gateway can also be hidden. With session persistence enabled, local macOS control-mode sessions can be restored when rootshell reopens. Connection Info shows the current mode and available server/session details.

For a tab with multiple panes, press **⌘⌥P** or choose **Choose Pane to Zoom** from the Terminal or pane menu. Type the displayed number or click a pane to focus and zoom it. With ten or more panes, type the whole padded label (`01`, `02`, …). Any other key cancels without reaching the terminal. When already zoomed, the picker shows the full split layout; canceling leaves the server's zoom unchanged. The shortcut can be changed or removed in Keyboard Shortcuts. The picker works in both fork and fallback modes and is unavailable while another client controls the tab or a pane move is pending.

## Regular herdr and the optional fork

[Regular upstream herdr](https://github.com/herdrdev/herdr) is supported. When the host has no rootshell terminal control stream, rootshell automatically uses **fallback mode**, which still provides most native control-mode functionality.

The optional [rootshell herdr fork](https://github.com/kitknox/herdr) adds a terminal control stream for native rendering and richer coordination between clients. It is experimental: it tracks upstream closely, but may introduce breaking changes. We hope upstream herdr will adopt these additional control-mode changes; fallback mode continues to support regular herdr if they are not included.

| Behavior | Regular herdr / fallback | rootshell fork / full control mode |
| --- | --- | --- |
| Native tabs, splits, workspace/worktree controls, and agent status | Supported, subject to the host's available API methods | Supported |
| Terminal rendering | herdr sends rendered surfaces; rootshell presents their panes in native splits | herdr sends terminal snapshots and raw output; rootshell's terminal engine renders each pane |
| Selection and scrolling | Native text selection, scroll indicators, and automatic scrolling while selecting through the upstream endpoint; viewport/history remains server-owned | Native local scrollback with fully pixel-smooth scrolling |
| Global scrollback search | Does not provide the fork's local scrollback search | Supported over scrollback available to rootshell |
| Updates | Live endpoint frames and metadata, supplemented by snapshots/API calls as needed | Terminal output and topology/agent events over a persistent control stream |
| Several devices viewing one tab | Follows upstream client/viewport behavior; does not provide the fork's explicit shared-attach and geometry-ownership contract | Shared viewing when stream protocol 2 and the required capabilities are advertised; older forks may allow only one control client per tab |

Fallback is not simply a screenshot poller: the normal upstream endpoint keeps frames and input live and supports semantic selection and scrolling. A secondary PTY compatibility path exists for compatible servers without that endpoint, with fewer endpoint features.

Shared viewing does not give every client a separately sized copy of the same terminal. One client controls a tab's geometry; other viewers follow that layout. The **Take Control** and **Fit to This Window** actions allow an explicit change of owner. On older single-owner forks, taking control can displace the previous attach.

**Detach Other Clients** (⇧⌘X by default) takes every tab in the session at once, and any pane another client holds. herdr has no method to close another client's connection, and shared viewing is deliberate, so unlike tmux's `detach-client -a` this does not empty the session: other clients keep viewing, but nothing else decides how the session is laid out. Every tab is claimed at once, including the tabs this window is not currently showing: those are claimed at the size they will have here, so they are laid out for this device the moment you switch to them.

On every platform, opening or returning to the app, or selecting a terminal tab, automatically fits the selected tab to this device and returns its visible panes to live output. No typing is needed. Other clients stay attached. Each activation claims once; a later handoff to another client does not start a contest for control. Scrolling or selecting text cancels a pending return to live output for that pane.

Activation follows the window the user is actually in. On iPhone, iPad, and visionOS it ends when the app is backgrounded. On the Mac, where windows stay on screen, it ends when the window is no longer the focused one in the frontmost app, and returning to that window activates it again. Only the focused window claims, so several rootshell windows on one session do not size the same tab against each other. A Mac keeps its text selection across activation; a device clears the stale highlight left by the replay.

## Install the optional fork

Run this on the **macOS or Linux host running herdr**, which may be a remote SSH/tssh host or your local Mac:

```sh
curl -fsSL https://github.com/kitknox/herdr/releases/download/rootshell-channel/install.sh | sh
```

The installer supports arm64/aarch64 and x86_64 hosts with a bash or zsh login account. It downloads the rootshell channel's tagged binary, verifies its published SHA-256 checksum, and installs it at:

```text
~/.local/opt/herdr-rootshell/bin/herdr
```

It leaves package-manager installations intact and prepends the fork directory to PATH using this marked line:

```sh
export PATH="$HOME/.local/opt/herdr-rootshell/bin:$PATH" # rootshell-herdr
```

For zsh, the line goes in `${ZDOTDIR:-$HOME}/.zshrc`. For bash, it goes in `~/.bashrc` and the login profile: `~/.bash_profile` if it exists, otherwise `~/.bash_login` or `~/.profile` if present, otherwise a new `~/.bash_profile`.

rootshell also gives `~/.local/opt/herdr-rootshell/bin` first priority when launching herdr on the host, including for saved local sessions. Removing the shell's PATH entry alone does not switch rootshell back to upstream; remove the fork binary as described below.

Open a new shell and check the selected binary:

```sh
type -a herdr
command -v herdr
herdr --version
```

**Installing a binary does not upgrade an already running server. Save your work before restarting: stopping a server terminates its pane processes.** Detach from rootshell control mode, and use a shell outside herdr to stop and restart only the intended session. For the default session:

```sh
herdr server stop
herdr
```

For a named session, replace `NAME` with its name and use that name for both commands:

```sh
herdr --session NAME server stop
herdr --session NAME
```

Use the same socket/configuration overrides if your setup has custom ones. Detach from the ordinary herdr client and reconnect in rootshell with control mode enabled. Turn off **Force herdr Fallback Mode** in Debug settings if it is enabled. Check Connection Info for the running server's version and capabilities. Future fork upgrades can use `herdr update` while the fork is selected.

## Return to regular upstream herdr

Switching back requires removing the preferred fork binary, selecting the upstream binary, and restarting the intended server with it. Your existing upstream installation can stay in place.

1. **Save work, detach, and stop the intended fork server from outside herdr.** Use `herdr server stop` for the default session or `herdr --session NAME server stop` for a named session, preserving any custom socket/configuration overrides. This terminates that server's pane processes; detaching alone does not stop them.

2. **Remove the rootshell fork binary on the host running herdr.** rootshell prioritizes this location even without the shell startup PATH entry:

   ```sh
   rm "$HOME/.local/opt/herdr-rootshell/bin/herdr"
   ```

3. **Remove the marked PATH entry from your shell startup files.** Remove the line ending in `# rootshell-herdr` shown above. For zsh, check `${ZDOTDIR:-$HOME}/.zshrc`. For bash, check `~/.bashrc` and the login profile modified by the installer (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`). Preserve unrelated PATH settings. If you installed the fork manually, also undo your corresponding alias, symlink, or PATH override.

4. **Start a fresh login environment and verify resolution.** Close the old shell and open a fresh terminal or SSH login, then run `type -a herdr`, `command -v herdr`, and `herdr --version`. The selected executable must be your upstream installation, not `~/.local/opt/herdr-rootshell/bin/herdr`. Merely sourcing an edited startup file does not remove a PATH entry already in the environment. If a parent process still passes down the old PATH, remove that fork directory from its environment or restart the parent terminal application before continuing. Also update any custom launch command that explicitly names the fork.

5. **Install or update upstream if needed.** It must be at least 0.9.0 for rootshell control mode. Use your original package manager, or the [official upstream installer](https://github.com/herdrdev/herdr#install):

   ```sh
   curl -fsSL https://herdr.dev/install.sh | sh
   ```

   Verify resolution again afterward. Installing upstream alone does not override a fork directory earlier on PATH.

6. **Start the session with the verified upstream binary.** Run `herdr` or `herdr --session NAME` as appropriate. Reconnect in rootshell with control mode enabled; when upstream lacks the fork's control stream, rootshell automatically selects fallback. For local sessions restored with an old executable path, detach and discover/attach the session again. Check Connection Info to confirm the server and mode.

7. **Keep your session data.** The empty fork directory may remain, but its `bin/herdr` binary must be removed. Do not delete herdr configuration, saved session data, or worktrees as part of switching binaries. Because the fork is experimental, compatibility of fork-specific persisted state across a downgrade is not guaranteed; restarting does not preserve the original pane processes.

**Force herdr Fallback Mode** only changes how rootshell connects. It does not uninstall the fork, select an upstream binary, or replace the running server.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| herdr not found | Verify herdr is available to the host's login shell, not only through an interactive alias. Check `command -v herdr` and the profile's custom command. |
| A new CLI is installed, but rootshell reports an old server | Save work and restart the intended server/session with the selected binary. Check Connection Info; `herdr --version` alone only checks the CLI. |
| The fork still uses fallback | Check PATH and the running server, disable **Force herdr Fallback Mode**, and detach/reconnect. |
| Full mode works, but shared viewing does not | Older forks may advertise stream protocol 1 or lack the required shared-viewing features. Check Connection Info and upgrade the fork if needed. |
| A pane is paused after another client takes control | On a single-owner server, use **Take Control** when you want ownership back. rootshell does not repeatedly evict the other client automatically. |
| An individual fallback management action is unavailable | Availability depends on upstream's advertised methods. Some compatibility API calls require `python3` or `nc` with Unix-socket support on the host. |

## Protocol details

This is a practical description of the client implemented in rootshell, not a separate frozen protocol specification. The linked source types define the exact fields and optional behavior.

### Transport and negotiation

The fork's `herdr control` command bridges the host's herdr socket API over stdin/stdout. rootshell runs it through an auxiliary exec channel on the existing SSH or tssh connection, or through a helper-spawned local process on macOS. The gateway terminal remains separate. The bridge respects the chosen session and, for discovered local attachments, their executable and socket identity.

rootshell sets `HERDR_CONTROL_CLIENT=rootshell/<app-version>` and `HERDR_CONTROL_PROTOCOL=2` in the bridge environment. The first output line is the response to `control.open`, containing `connection_id`, `boot_id`, the running server's `version`, base `protocol`, optional negotiated `control_protocol`, and `capabilities`.

These numbers have different meanings:

- `version` is the herdr release, validated against the 0.9.0 minimum. A recognized fork suffix is accepted using its base release.
- `protocol` is the server's base API protocol identifier, not the terminal-stream version.
- `capabilities.terminal_control_stream` advertises the terminal control stream. rootshell supports protocol 1 and prefers protocol 2; `control_protocol` reports negotiation on newer servers.
- `capabilities.control_features` gates individual additions. Shared viewing requires stream protocol 2 or later **and** `shared_attach`, `geometry_ownership`, and `geometry_controller`. The version number alone does not enable it.

See [launch and environment selection](../rootshell/Features/SSH/Config/SSHConfig.swift), [channel transport](../rootshell/Features/Herdr/Transport/HerdrChannelFactory.swift), and [capability checks](../rootshell/Features/Herdr/HerdrServerCapabilities.swift).

### JSON messages and terminal data

The control stream carries one JSON object per newline. Requests have `id`, `method`, and `params`; responses match that ID and contain `result` or `error`. Pushed terminal records use `type`; subscribed events use `event` and `data`. Responses and pushed messages share the stream, so clients must demultiplex them while preserving pushed-record order.

For example, after obtaining a terminal ID from `session.snapshot`, a client can attach without requesting a takeover. The IDs below are illustrative; each code-block line is one wire message.

```json
{"id":"r1","method":"terminal.attach","params":{"target":"terminal-1","answer_queries":"client","history_limit_bytes":1048576,"takeover":false}}
{"id":"r1","result":{"attach_id":"1-0","terminal_id":"terminal-1","pane_id":"pane-1"}}
```

Input bytes are base64-encoded (`bHMK` is `ls` followed by a newline):

```json
{"id":"r2","method":"terminal.input","params":{"attach_id":"1-0","bytes":"bHMK"}}
```

A pushed output record likewise carries base64 bytes, alongside its attach ID and sequence number:

```json
{"type":"terminal.output","attach_id":"1-0","seq":42,"bytes":"aGVsbG8NCg=="}
```

An error response uses the request ID, for example when another client owns the terminal on a single-owner server:

```json
{"id":"r1","error":{"code":"terminal_attached","message":"Terminal is already attached"}}
```

`terminal.snapshot` records carry a sequence number, primary/alternate screen content, ANSI terminal state, cursor state, dimensions, and a truncation flag. Snapshot text/state fields are JSON strings containing VT data; they are not the base64 `bytes` field used by live output. rootshell rebuilds the local terminal from the snapshot and then applies live output. Initial history is bounded by `history_limit_bytes` (1 MiB by default in rootshell), so native search cannot recover history never supplied to or retained by the client.

See the [wire types and record decoder](../rootshell/Features/Herdr/HerdrControlProtocol.swift), [JSON channel](../rootshell/Features/Herdr/HerdrControlChannel.swift), and [snapshot/output rendering](../rootshell/Features/Herdr/HerdrPaneSession.swift).

### Events, ownership, and recovery

rootshell subscribes with `events.subscribe` and obtains initial topology from `session.snapshot`. Workspace, tab, pane, and agent events update the native interface. Terminal data is routed by attach ID, while `tab.layout` records supply pane geometry. Layout changes hold output until the native surfaces use the corresponding grid.

Each raw layout invalidates the previous parser-size confirmation, including a handoff that returns to the same dimensions. Probes start after the layout's surface-size requests cross the Ghostty API queue; replies outstanding from an earlier layout cannot release the new layout's output. Superseded layouts and timed-out waits recover through snapshots.

Mounted panes participate in parser confirmation before `terminal.attach` completes, because initial attach itself waits for the parser grid. This avoids a circular wait during cold restoration.

The host fork applies PTY geometry immediately and sends one additional `SIGWINCH` after 250 ms without another resize. New resizes replace the pending notification, and server handoff cancels it. This lets a program recover from a missed initial resize event, including queued changes that return to the original dimensions. The notification does not change ownership, alter the grid, or insert terminal input. This recovery requires the updated host server as well as the app's layout handling.

On capable servers, `tab.set_geometry` can store a client's desired size with `claim:false`; `tab.claim_geometry` explicitly takes geometry ownership. Layouts and geometry-change events identify the owner. Shared terminal viewing and terminal-query authority are separate: `terminal.authority` identifies which attach answers terminal queries. With the `auto_input` feature, automatic terminal replies use `terminal.input` with `auto:true`, so the server can forward only the authority's replies without treating them as user interaction.

rootshell applies query-authority changes at their position in the terminal parser's output stream. Replies to earlier queries can still finish during the server's handoff grace period, while later queries are answered only by the new authority. Layout waits and snapshot recovery preserve this boundary, preventing both clients from answering the same cursor-position query during a resize.

Focus reports, including those generated while replaying a snapshot, are automatic reports and never claim geometry. Routine size updates use `claim:false`; the server applies them only while that client owns the tab. Activation and explicit fit/take-control actions send one claiming size request, so a delayed resize or retry cannot undo a newer client's handoff.

Stream protocol 1 has no stored size: every `tab.set_geometry` there takes the tab. Such a client sends one only for the tab it is showing, in the focused window, so an idle or backgrounded device cannot resize a tab out from under whoever is using it.

`control.close` is also sent when the app terminates. The bridge runs inside the gateway's session, and a persistent (attachable) session keeps its processes running after the app goes away; without that close, the server keeps counting the departed client as a viewer that can hold a tab's geometry.

`terminal.gap` reports dropped terminal output. rootshell invalidates that attach's output stream and requests a fresh `terminal.snapshot` before resuming rendering. `events.gap` triggers a topology refresh. Reconnection establishes a new stream, subscriptions, and snapshot; a changed `boot_id` identifies a restarted server and causes server-dependent state to be rebuilt.

`terminal.detach` releases an attach, and `control.close` releases the control connection. They do not stop the herdr server. A pushed `terminal.detached` with reason `closed` removes/refreshes the pane; reason `takeover` pauses the displaced attach for explicit user action instead of automatically taking it back.

See [pane attachment and recovery](../rootshell/Features/Herdr/HerdrController+Panes.swift) and [ownership handling](../rootshell/Features/Herdr/HerdrController+Ownership.swift).

### Upstream fallback protocol

When the fork stream is unavailable, rootshell validates a snapshot from `herdr api snapshot` and uses upstream's `remote-client-bridge` for endpoint generation 1 when advertised. This is a separate protocol from the fork's newline JSON stream.

Endpoint messages use a four-byte little-endian length prefix around bincode 2 standard encoding. The `endpoint.hello.v1` control message carries JSON negotiation data inside that binary envelope. rootshell requests the frozen `shell.snapshot.v1`, `shell.surface.v1`, `shell.input.semantic.v1`, and `shell.blob.v1` codecs. The client currently caps endpoint frames at 32 MiB.

The endpoint sends server-rendered surfaces and metadata, and accepts semantic pane input, selection, scrolling, and resize operations. Its command lane runs one operation at a time while input and frames stay live. rootshell checks advertised methods before sending optional commands and supplements endpoint metadata with CLI snapshots as needed, rather than launching a CLI command for each scroll tick.

For compatible servers without the endpoint, the secondary path uses per-pane PTY attaches. Some management operations can use a one-shot JSON request to the resolved Unix socket through `python3` or Unix-socket-capable `nc`. Neither compatibility path bypasses the minimum server version.

See the [endpoint wire codec](../rootshell/Features/Herdr/HerdrEndpointWire.swift), [endpoint channel](../rootshell/Features/Herdr/HerdrEndpointChannel.swift), and [fallback controller](../rootshell/Features/Herdr/HerdrController+Legacy.swift).
