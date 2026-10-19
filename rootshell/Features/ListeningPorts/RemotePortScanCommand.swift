//
//  RemotePortScanCommand.swift
//  rootshell
//
//  The one-shot shell step that lists a remote host's listening TCP ports.
//  Runs over the connection the pane already holds (RemoteExecProbe), never
//  in the user's interactive shell, and is framed with a nonce so truncation
//  is distinguishable from an empty answer.
//

import Foundation

nonisolated enum RemotePortScanCommand {
    /// Builds `sh -c` plus the nonce that frames its answer.
    /// - Parameter pathPrefix: shell prologue that widens `PATH`; an exec
    ///   channel does not inherit the interactive shell's PATH, and `lsof`
    ///   lives in `/usr/sbin` on macOS.
    static func command(pathPrefix: String = "") -> (command: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))
        return (LoginShellCommand.runInPOSIXShell(script(nonce: nonce, pathPrefix: pathPrefix)), nonce)
    }

    /// The inner script, before it is wrapped for `sh -c`. Exposed so tests
    /// can syntax-check what the remote shell actually parses.
    static func script(nonce: String, pathPrefix: String = "") -> String {
        var script = pathPrefix
        script += "printf '::RSPORTS_\(nonce)::\\n'; "
        // Linux: `ss` is fast and is present on every modern distribution.
        // `-p` is what limits the answer to this user's processes without
        // root; sockets owned by root or other users carry no `pid=` field
        // and are dropped by the awk step.
        script += "if command -v ss >/dev/null 2>&1; then "
        script += "ss -ltnp 2>/dev/null | awk 'NR > 1 && NF >= 4 {"
        script += " if (match($0, /pid=[0-9]+/)) {"
        script += " print \"L\", substr($0, RSTART + 4, RLENGTH - 4), $4"
        script += " } }'; "
        // macOS has no `ss`. `-Fpcn` emits pid, command, and the socket name
        // on separate lines; the awk state machine pairs them.
        script += "elif command -v lsof >/dev/null 2>&1; then "
        script += "lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '"
        script += "/^p/ { pid = substr($0, 2) } "
        script += "/^n/ { print \"L\", pid, substr($0, 2) }'; "
        // BusyBox / older hosts.
        script += "elif command -v netstat >/dev/null 2>&1; then "
        script += "netstat -ltn 2>/dev/null | awk 'NR > 2 && NF >= 4 { print \"L\", \"-\", $4 }'; "
        script += "else echo N; fi; "
        script += "printf '::END_\(nonce)::\\n'; "
        script += "exit 0"
        return script
    }
}
