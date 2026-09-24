//
//  InitialDirectoryCommand.swift
//  rootshell
//

import Foundation

/// Wraps a remote session command so the shell starts in a chosen directory.
/// The outer login shell only ever parses `sh -c '…'`; the user's own command
/// still runs through `$SHELL -c`, exactly as sshd would have run it.
nonisolated enum InitialDirectoryCommand {
    /// Absolute and single-line: a newline cannot survive `sh -c` quoting.
    static func isSupportedDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
    }

    /// `cd` that falls back to the login directory with a visible notice.
    static func prologue(directory: String) -> String {
        let quoted = LoginShellCommand.singleQuoted(directory)
        return "cd \(quoted) 2>/dev/null || printf 'rootshell: cannot start in %s, using home\\n' \(quoted) >&2; "
    }

    /// SSH/tssh exec request. A nil command starts a login shell.
    static func execCommand(directory: String, wrapping command: String?) -> String {
        let tail: String
        if let command, !command.isEmpty {
            tail = "exec \"${SHELL:-/bin/sh}\" -c \(LoginShellCommand.singleQuoted(command))"
        } else {
            tail = "exec \"${SHELL:-/bin/sh}\" -l"
        }
        return LoginShellCommand.runInPOSIXShell(prologue(directory: directory) + tail)
    }

    /// The post-`--` command for mosh-server; the base is always a single
    /// simple command, so `exec` is safe.
    static func moshSessionCommand(directory: String, wrapping command: String) -> String {
        LoginShellCommand.runInPOSIXShell(prologue(directory: directory) + "exec " + command)
    }
}
