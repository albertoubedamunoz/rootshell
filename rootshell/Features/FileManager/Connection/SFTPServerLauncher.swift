//
//  SFTPServerLauncher.swift
//  rootshell
//
//  The commands that start the remote sftp-server over an exec channel,
//  for transports with no SFTP subsystem (tssh) and for sudo mode.
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

    /// Prints the first sftp-server found on stdout; exits 127 when none exists.
    static func locateCommand() -> String {
        let paths = candidatePaths.map(shellQuote)
        return "sh -c " + shellQuote("""
        for p in \(paths.joined(separator: " ")) "$(command -v sftp-server 2>/dev/null)"; do \
        [ -n "$p" ] && [ -x "$p" ] && { printf '%s\\n' "$p"; exit 0; }; done; \
        exit \(notFoundExitStatus)
        """)
    }

    /// Marker sudo prints in place of its password prompt; `%p` expands to
    /// the account whose password it wants.
    static let sudoPromptMarker = "ROOTSHELL_SUDO_PROMPT:"

    /// Runs sftp-server directly under sudo, so rules naming only its path
    /// still match. `-S` puts prompts on stderr and reads answers from stdin;
    /// `-e -l INFO` makes the server announce its start on stderr.
    static func sudoCommand(serverPath: String) -> String {
        "env LC_ALL=C sudo -S -p " + shellQuote(sudoPromptMarker + "%p:")
            + " -- " + shellQuote(serverPath) + " -e -l INFO"
    }

    /// Single-quotes `value` for POSIX sh.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
