//
//  RemotePortScanCommand.swift
//  rootshell
//
//  The one-shot shell step that lists a remote host's listening TCP ports.
//  Runs over the connection the pane already holds (RemoteExecProbe), never
//  in the user's interactive shell, and is framed with a nonce so truncation
//  is distinguishable from an empty answer.
//
//  Only sockets opened by a process started inside this connection are listed.
//  A host normally listens on dozens of ports (databases, brew services, other
//  sessions' dev servers); listing all of them buries the ones this pane
//  started and makes every scan expensive to render. Ownership comes from
//  process ancestry: the probe walks up from itself to the per-connection
//  `sshd`, and keeps listeners that sit under the same one. Herdr marks panes
//  with an environment variable it injects; ancestry needs no cooperation from
//  the remote shell, so it also covers shells rootshell did not start.
//
//  When the tree cannot be read — `netstat` prints no pids, or a multiplexer
//  moves the shell out of the session — the answer carries `M all` and the
//  scan keeps the previous behaviour instead of silently hiding every port.
//

import Foundation

nonisolated enum RemotePortScanCommand {
    /// Builds `sh -c` plus the nonce that frames its answer.
    /// - Parameter pathPrefix: shell prologue that widens `PATH`; an exec
    ///   channel does not inherit the interactive shell's PATH, and `lsof`
    ///   lives in `/usr/sbin` on macOS.
    static func command(pathPrefix: String = "", filterOwnership: Bool = true) -> (command: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))
        let script = script(nonce: nonce, pathPrefix: pathPrefix, filterOwnership: filterOwnership)
        return (LoginShellCommand.runInPOSIXShell(script), nonce)
    }

    /// The inner script, before it is wrapped for `sh -c`. Exposed so tests
    /// can syntax-check what the remote shell actually parses.
    /// - Parameter filterOwnership: when false the whole host is listed, for
    ///   transports whose shell leaves the SSH session (mosh detaches its
    ///   server, so no ancestry ties a port back to this connection).
    static func script(nonce: String, pathPrefix: String = "", filterOwnership: Bool = true) -> String {
        var script = pathPrefix
        script += "printf '::RSPORTS_\(nonce)::\\n'\n"
        script += listing
        script += "\n"
        if filterOwnership {
            script += ownership
        } else {
            script += "printf 'M all\\n%s\\n' \"$_rslist\""
        }
        script += "\nprintf '::END_\(nonce)::\\n'\nexit 0"
        return script
    }

    /// One `L <pid> <address>` line per listening socket, or `N` when the host
    /// has none of the three tools.
    private static let listing = """
    # Linux: `ss` is fast and is present on every modern distribution. `-p` is
    # what limits the answer to the user processes without root; sockets
    # owned by root or other users carry no `pid=` field and are dropped here.
    if command -v ss >/dev/null 2>&1; then
        _rslist=$(ss -ltnp 2>/dev/null | awk 'NR > 1 && NF >= 4 {
            if (match($0, /pid=[0-9]+/)) {
                print "L", substr($0, RSTART + 4, RLENGTH - 4), $4
            }
        }')
    elif command -v lsof >/dev/null 2>&1; then
        # macOS has no `ss`. `-Fpcn` emits pid, command, and the socket name on
        # separate lines; the awk state machine pairs them.
        _rslist=$(lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '
            /^p/ { pid = substr($0, 2) }
            /^n/ { print "L", pid, substr($0, 2) }')
    elif command -v netstat >/dev/null 2>&1; then
        # BusyBox / older hosts; no pids, so ownership cannot be resolved.
        _rslist=$(netstat -ltn 2>/dev/null | awk 'NR > 2 && NF >= 4 { print "L", "-", $4 }')
    else
        echo N
    fi
    """

    /// Filters `_rslist` down to sockets started inside this connection, and
    /// says which rule it applied: `M conn` when the tree was read, `M all`
    /// when it was not.
    private static let ownership = """
    if [ -n "$_rslist" ]; then
        _rstab=$(ps -A -o pid=,ppid=,tty=,comm= 2>/dev/null)
        {
            printf '%s\\n' "$_rstab"
            printf '%s\\n' '--RSLISTEN--'
            printf '%s\\n' "$_rslist"
        } | awk -v me="$$" '
            $0 == "--RSLISTEN--" { phase = 1; next }
            phase == 0 {
                pid = $1; parent = $2; tty = $3
                $1 = ""; $2 = ""; $3 = ""
                pp[pid] = parent
                tty_of[pid] = tty
                comm[pid] = substr($0, 4)
                next
            }
            { count += 1; lp[count] = $2; la[count] = $3 }
            END {
                # A pid-less listing cannot be attributed; keep it whole.
                for (i = 1; i <= count; i++) {
                    if (lp[i] !~ /^[0-9]+$/) { all = 1 }
                }
                # The per-connection sshd is the nearest ancestor pair of sshd
                # processes above this probe; every session sharing the TCP
                # connection (the pane shell included) sits under it.
                cur = me
                root = ""
                for (i = 0; i < 64; i++) {
                    if (!(cur in pp)) break
                    parent = pp[cur]
                    if (parent == "" || parent == 0) break
                    if (comm[cur] ~ /sshd/ && comm[parent] ~ /sshd/) {
                        root = parent
                        break
                    }
                    cur = parent
                }
                # tmux, screen, herdr and mosh move the pane shell into a
                # detached server, so a port started in that pane is not under
                # this sshd and ancestry would hide it. If a multiplexer runs
                # under this connection, keep the unfiltered answer instead of
                # showing an empty list.
                detached = 0
                for (p in pp) {
                    cur = p
                    for (j = 0; j < 64; j++) {
                        if (cur == root) { break }
                        if (!(cur in pp)) { cur = ""; break }
                        parent = pp[cur]
                        if (parent == "" || parent == 0) { cur = ""; break }
                        cur = parent
                    }
                    if (cur != root) continue
                    if (comm[p] ~ /tmux|screen|herdr|mosh/) { detached = 1; break }
                }
                if (all || root == "" || detached) {
                    print "M all"
                    for (i = 1; i <= count; i++) print "L", lp[i], la[i]
                    exit
                }
                print "M conn"
                for (i = 1; i <= count; i++) {
                    cur = lp[i]
                    owned = 0
                    for (j = 0; j < 64; j++) {
                        if (cur == root) { owned = 1; break }
                        if (!(cur in pp)) break
                        parent = pp[cur]
                        if (parent == "" || parent == 0) break
                        cur = parent
                    }
                    if (owned) print "L", lp[i], la[i]
                }
            }'
    else
        printf '%s\\n' "$_rslist"
    fi
    """
}
