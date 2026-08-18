//
//  SSHCopyIDCommandParser.swift
//  rootshell
//
//  Parses ssh-copy-id command-line arguments for internal SSH key installation
//

import Foundation
import os.log

/// Parsed ssh-copy-id command with all options
struct SSHCopyIDParsedCommand: Sendable {
    /// Keys to install (resolved from -i flag or defaults)
    var keyIDs: [UUID]
    /// Force mode: skip duplicate check
    var force: Bool = false
    /// Dry run: preview what would be installed without making changes
    var dryRun: Bool = false
    /// Target authorized_keys path on remote server
    var targetPath: String = "~/.ssh/authorized_keys"
}

/// Parser for ssh-copy-id command-line arguments
/// Supports: -i (identity), -f (force), -n (dry run), -t (target path),
///           -p (port), -o (ssh option), [user@]hostname
@MainActor
struct SSHCopyIDCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHCopyIDCommandParser")

    /// Result of parsing an ssh-copy-id command
    enum ParseResult {
        /// Successfully parsed with complete config
        case success(SSHCopyIDParsedCommand, SSHConfig)
        /// Parsed but needs password
        case needsPassword(SSHCopyIDParsedCommand, SSHCommandParser.PartialSSHConfig)
        /// User requested help
        case help
        /// Parse error
        case error(String)
    }

    /// Parse an ssh-copy-id command string into configuration
    /// - Parameter command: Full command string (e.g., "ssh-copy-id -i mykey user@host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "ssh-copy-id"
        guard tokens[0].lowercased() == "ssh-copy-id" else {
            return .error("Not an ssh-copy-id command")
        }

        // Check for help request
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help" || tokens[1] == "-?") {
            return .help
        }

        var port = 22
        var username: String?
        var host: String?
        var identityFile: String?
        var force = false
        var dryRun = false
        var targetPath = "~/.ssh/authorized_keys"
        var sshOptions: [String: String] = [:]

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token.hasPrefix("-") {
                switch token {
                case "-f":
                    force = true

                case "-n":
                    dryRun = true

                case "-i":
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing identity after -i")
                    }
                    identityFile = tokens[i]

                case "-t":
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing target path after -t")
                    }
                    targetPath = tokens[i]

                case "-p":
                    i += 1
                    guard i < tokens.count, let p = Int(tokens[i]), p > 0, p <= 65535 else {
                        return .error("Invalid port number")
                    }
                    port = p

                case "-o":
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing option after -o")
                    }
                    if let eqIndex = tokens[i].firstIndex(of: "=") {
                        let key = String(tokens[i][..<eqIndex])
                        let value = String(tokens[i][tokens[i].index(after: eqIndex)...])
                        sshOptions[key] = value
                    }

                case "-h", "--help", "-?":
                    return .help

                default:
                    // Handle combined flags like -fn
                    if token.hasPrefix("-") && token.count > 2 && !token.hasPrefix("--") {
                        for char in token.dropFirst() {
                            switch char {
                            case "f": force = true
                            case "n": dryRun = true
                            default: break
                            }
                        }
                    }
                }
            } else {
                // Positional argument: [user@]host[:port]
                let parsed = parseDestination(token)
                if let u = parsed.username {
                    username = u
                }
                host = parsed.host
                if let p = parsed.port {
                    port = p
                }
            }

            i += 1
        }

        // Apply -o options. SSH option names are case-insensitive.
        let sshOption: (String) -> String? = { name in
            sshOptions.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if let optPort = sshOption("Port"), let p = Int(optPort) {
            port = p
        }
        if let optUser = sshOption("User") {
            username = optUser
        }

        // `-o IdentityFile=<key>` picks the key that authenticates the bootstrap
        // connection, mirroring OpenSSH ssh-copy-id passing -o through to ssh.
        // Distinct from -i, which chooses the key(s) to install.
        var authIdentityKeyID: UUID?
        if let identity = sshOption("IdentityFile") {
            guard let keyID = SSHCommandParser.findKeyByIdentityPath(identity) else {
                return .error("No key found matching IdentityFile '\(identity)'")
            }
            authIdentityKeyID = keyID
        }

        // Validate we have a host
        guard let finalHost = host, !finalHost.isEmpty else {
            return .error("Missing hostname")
        }

        let finalUsername = username ?? UserPreferences.effectiveUsername

        // Resolve key IDs
        let keyIDs: [UUID]
        if let identity = identityFile {
            // Match by identity name
            if let keyID = SSHCommandParser.findKeyByIdentityPath(identity) {
                keyIDs = [keyID]
            } else {
                return .error("No key found matching '\(identity)'")
            }
        } else {
            // Use all default keys
            let defaultIDs = SSHKeyManager.shared.defaultKeyIDs
            if defaultIDs.isEmpty {
                // Try all saved keys
                let allKeys = SSHKeyManager.shared.savedKeys
                if allKeys.isEmpty {
                    return .error("No SSH keys available. Generate or import a key in Settings > SSH Keys")
                }
                keyIDs = allKeys.map(\.id)
            } else {
                keyIDs = defaultIDs
            }
        }

        let parsedCommand = SSHCopyIDParsedCommand(
            keyIDs: keyIDs,
            force: force,
            dryRun: dryRun,
            targetPath: targetPath
        )

        logger.info("Parsed ssh-copy-id: \(finalUsername)@\(finalHost):\(port), keys=\(keyIDs.count), force=\(force), dryRun=\(dryRun)")

        // Check connection history for cached IP
        let historyEntry = SSHConnectionHistoryManager.shared.entries.first { entry in
            entry.host.lowercased() == finalHost.lowercased() &&
            entry.username.lowercased() == finalUsername.lowercased() &&
            entry.port == port
        }
        let cachedIP = historyEntry?.cachedIP

        // Resolve SSH auth independently from -i (which only controls keys to install).
        // Order: explicit -o IdentityFile, then host-specific evidence (connection
        // history, saved password), else prompt. A global default key is
        // deliberately not used as a silent fallback - ssh-copy-id targets servers
        // that have no key installed yet, so guessing one fails auth instead of
        // prompting. Use -o IdentityFile=<key> to bootstrap with a known key.
        var authKeyID: UUID? = authIdentityKeyID

        // Check history for previously-used auth key
        if authKeyID == nil {
            for entry in SSHConnectionHistoryManager.shared.entries {
                if entry.host.lowercased() == finalHost.lowercased() &&
                   entry.username.lowercased() == finalUsername.lowercased() {
                    if case .key(let keyID, let fingerprint) = entry.authType {
                        if SSHKeyManager.shared.resolveKey(id: keyID, fingerprint: fingerprint) != nil {
                            authKeyID = keyID
                            break
                        }
                    }
                }
            }
        }

        // Build SSHConfig for connection authentication
        if let foundKeyID = authKeyID {
            let config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                keyID: foundKeyID,
                cachedIP: cachedIP
            )
            return .success(parsedCommand, config)
        }

        // Check saved password
        if SSHPasswordManager.shared.hasPassword(host: finalHost, port: port, username: finalUsername) {
            let config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                authMethod: .savedPassword,
                cachedIP: cachedIP
            )
            return .success(parsedCommand, config)
        }

        // Need password
        let partial = SSHCommandParser.PartialSSHConfig(
            host: finalHost,
            port: port,
            username: finalUsername,
            jumpHost: nil,
            agentConfig: .disabled,
            portForwardConfig: .none,
            cachedIP: cachedIP
        )

        return .needsPassword(parsedCommand, partial)
    }

    // MARK: - Private Helpers

    /// Reuse SSHCommandParser's tokenizer pattern
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?

        for char in command {
            if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Parse [user@]host[:port] destination string
    private static func parseDestination(_ dest: String) -> (username: String?, host: String?, port: Int?) {
        var remaining = dest
        var username: String?
        var port: Int?

        // Extract user@ prefix (split on LAST @ so usernames containing @ survive)
        if let atIndex = remaining.lastIndex(of: "@") {
            username = String(remaining[..<atIndex])
            remaining = String(remaining[remaining.index(after: atIndex)...])
        }

        // Extract :port suffix
        if remaining.hasPrefix("[") {
            // IPv6: [host]:port
            if let closeIndex = remaining.firstIndex(of: "]") {
                let afterClose = remaining.index(after: closeIndex)
                if afterClose < remaining.endIndex && remaining[afterClose] == ":" {
                    let portStr = String(remaining[remaining.index(after: afterClose)...])
                    port = Int(portStr)
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                } else {
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                }
            }
        } else if let colonIndex = remaining.lastIndex(of: ":") {
            let portStr = String(remaining[remaining.index(after: colonIndex)...])
            if let p = Int(portStr), p > 0, p <= 65535 {
                port = p
                remaining = String(remaining[..<colonIndex])
            }
        }

        return (username, remaining.isEmpty ? nil : remaining, port)
    }
}

