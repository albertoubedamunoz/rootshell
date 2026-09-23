//
//  SFTPServerLauncher.swift
//  rootshell
//
//  The command that starts the remote sftp-server over an exec channel,
//  for transports with no SFTP subsystem (tssh).
//

import Foundation

nonisolated enum SFTPServerLauncher {
    /// Where the common distributions install OpenSSH's sftp-server.
    static let candidatePaths = [
        "/usr/lib/openssh/sftp-server",      // Debian, Ubuntu
        "/usr/libexec/openssh/sftp-server",  // RHEL, Fedora
        "/usr/libexec/sftp-server",          // macOS, BSD
        "/usr/lib/ssh/sftp-server",          // Arch
        "/usr/lib/sftp-server",              // Alpine
    ]

    /// Exit status the command uses when no server binary exists.
    static let notFoundExitStatus = 127

    /// Execs the first sftp-server found; otherwise prints a marker to stderr
    /// and exits 127 without writing to stdout.
    static func command(preferredPath: String? = nil) -> String {
        let paths = ([preferredPath].compactMap { $0 } + candidatePaths).map(shellQuote)
        return "sh -c " + shellQuote("""
        for p in \(paths.joined(separator: " ")) "$(command -v sftp-server 2>/dev/null)"; do \
        [ -n "$p" ] && [ -x "$p" ] && exec "$p"; done; \
        echo 'rootshell: sftp-server not found' >&2; exit \(notFoundExitStatus)
        """)
    }

    /// Single-quotes `value` for POSIX sh.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
