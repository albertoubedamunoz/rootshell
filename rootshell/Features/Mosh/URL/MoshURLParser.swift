//
//  MoshURLParser.swift
//  rootshell
//
//  Parses mosh:// URL schemes into connection components
//

import Foundation

/// Parsed components from a Mosh URL
struct MoshURLComponents: Sendable {
    let host: String
    let port: Int  // SSH port (for server spawn)
    let username: String?

    init(host: String, port: Int, username: String?) {
        self.host = host
        self.port = port
        self.username = username
    }

    init(_ ssh: SSHURLComponents) {
        self.init(host: ssh.host, port: ssh.port, username: ssh.username)
    }

    /// Display string for UI (e.g., "roam user@host")
    var displayString: String {
        "roam " + sshComponents.displayString
    }

    /// Converts to SSHURLComponents for reuse with SSH infrastructure
    var sshComponents: SSHURLComponents {
        SSHURLComponents(host: host, port: port, username: username)
    }
}

/// Parser for Mosh URL schemes; same grammar as `SSHURLParser` with the `mosh` scheme.
///
/// Note: The port in mosh:// URLs refers to the SSH port used for
/// spawning mosh-server, not the UDP port (which mosh-server chooses).
enum MoshURLParser {

    /// Parse a Mosh URL into components
    /// - Parameter url: The URL to parse (must have `mosh` scheme)
    /// - Returns: Parsed components, or nil if URL is invalid
    static func parse(_ url: URL) -> MoshURLComponents? {
        SSHURLParser.parse(url, scheme: "mosh").map(MoshURLComponents.init)
    }
}
