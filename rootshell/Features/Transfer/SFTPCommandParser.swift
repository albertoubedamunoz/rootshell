//
//  SFTPCommandParser.swift
//  rootshell
//
//  Parses SFTP command-line arguments for internal SFTP client integration
//

import Foundation
import os.log

/// Parser for SFTP command-line arguments
/// Supports: -P (port), -i (identity), -J (jump host), -o (options)
@MainActor
struct SFTPCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SFTPCommandParser")

    /// Result of parsing an SFTP command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(SSHConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(SSHCommandParser.PartialSSHConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare sftp, -h, or --help)
        case help
    }

    /// Parse an SFTP command string into configuration
    /// - Parameter command: Full command string (e.g., "sftp user@host" or "sftp -P 2222 host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "sftp"
        guard tokens[0].lowercased() == "sftp" else {
            return .error("Not an sftp command")
        }

        // Check for help request: bare "sftp", "sftp -h", or "sftp --help"
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help") {
            return .help
        }

        var port = 22
        var identityFile: String?
        var jumpHostString: String?
        var sshOptions: [String: String] = [:]
        var targetArg: String?

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token.hasPrefix("-") && !token.hasPrefix("--") {
                switch token {
                case "-P":
                    // Port (uppercase P like scp)
                    i += 1
                    guard i < tokens.count, let p = Int(tokens[i]), p > 0, p <= 65535 else {
                        return .error("Invalid port number")
                    }
                    port = p

                case "-p":
                    // Also accept lowercase p for convenience
                    i += 1
                    guard i < tokens.count, let p = Int(tokens[i]), p > 0, p <= 65535 else {
                        return .error("Invalid port number")
                    }
                    port = p

                case "-i":
                    // Identity file
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing identity file after -i")
                    }
                    identityFile = tokens[i]

                case "-J":
                    // Jump host
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing jump host after -J")
                    }
                    jumpHostString = tokens[i]

                case "-o":
                    // SSH option
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing option after -o")
                    }
                    if let (key, value) = parseOption(tokens[i]) {
                        sshOptions[key] = value
                    }

                default:
                    // Ignore unknown flags
                    break
                }
            } else {
                // Non-flag argument - should be the target [user@]host
                if targetArg == nil {
                    targetArg = token
                }
                // Ignore additional non-flag arguments
            }

            i += 1
        }

        // Apply -o options that we recognize
        if let optPort = sshOptions["Port"], let p = Int(optPort) {
            port = p
        }
        if let optJump = sshOptions["ProxyJump"] {
            jumpHostString = optJump
        }
        if let optIdentity = sshOptions["IdentityFile"] {
            identityFile = optIdentity
        }

        // Parse the target
        guard let target = targetArg, !target.isEmpty else {
            return .error("Missing destination host")
        }

        let (username, host) = parseTarget(target)
        guard let finalHost = host, !finalHost.isEmpty else {
            return .error("Invalid destination")
        }

        // Default username to current user if not specified
        let finalUsername = username ?? UserPreferences.effectiveUsername

        logger.info("Parsed SFTP: \(finalUsername)@\(finalHost):\(port), identity=\(identityFile ?? "none"), jump=\(jumpHostString ?? "none")")

        // Build SSHConfig using the same key lookup logic as SSH/SCP commands
        return buildSSHConfig(
            host: finalHost,
            port: port,
            username: finalUsername,
            identityFile: identityFile,
            jumpHostString: jumpHostString,
            sshOptions: sshOptions
        )
    }

    // MARK: - Private Helpers

    /// Build SSHConfig from parsed parameters, with key store integration
    private static func buildSSHConfig(
        host: String,
        port: Int,
        username: String,
        identityFile: String?,
        jumpHostString: String?,
        sshOptions: [String: String]
    ) -> ParseResult {
        // Build jump host config if specified
        var jumpHostConfig: SSHConfig.JumpHostConfig?
        if let jumpStr = jumpHostString {
            let (jumpUser, jumpHost) = parseTarget(jumpStr)
            let finalJumpUser = jumpUser ?? username
            guard let finalJumpHost = jumpHost, !finalJumpHost.isEmpty else {
                return .error("Invalid jump host")
            }

            // Parse port from jump host if present (user@host:port format)
            let (parsedJumpHost, jumpPort) = parseHostPort(finalJumpHost)

            // For jump host auth, try to find a matching key
            let jumpKeyID = findMatchingKey(for: finalJumpUser, host: parsedJumpHost, identityHint: nil)

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if let keyID = jumpKeyID {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            jumpHostConfig = SSHConfig.JumpHostConfig(
                host: parsedJumpHost,
                port: jumpPort ?? 22,
                username: finalJumpUser,
                authMethod: jumpKeyID != nil ? .key(jumpKeyID!) : .password(""),
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )
        }

        // Agent config - disabled for SFTP transfers (can be enabled later if needed)
        let agentConfig: SSHAgentConfig = .disabled

        // Check connection history for cached IP
        let historyEntry = findHistoryEntry(username: username, host: host, port: port)
        let cachedIP = historyEntry?.cachedIP

        // Check if "none" authentication was explicitly requested (Tailscale/WireGuard)
        if let preferredAuth = sshOptions["PreferredAuthentications"]?.lowercased(),
           preferredAuth == "none" {
            logger.info("Using 'none' authentication (PreferredAuthentications=none)")
            let config = SSHConfig(
                host: host,
                port: port,
                username: username,
                authMethod: .none,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig
            )
            return .success(config)
        }

        // Try to find a matching key
        var keyID: UUID?

        // First try explicit identity file
        if let identity = identityFile {
            keyID = findKeyByIdentityPath(identity)
        }

        // If no explicit key, try to find from history
        if keyID == nil {
            keyID = findMatchingKey(for: username, host: host, identityHint: identityFile)
        }

        // If we found a key, return success
        if let foundKeyID = keyID {
            let config = SSHConfig(
                host: host,
                port: port,
                username: username,
                keyID: foundKeyID,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig
            )
            return .success(config)
        }

        // Check if we have a saved password for this connection
        if SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username) {
            logger.info("Found saved password for \(username)@\(host):\(port)")
            let config = SSHConfig(
                host: host,
                port: port,
                username: username,
                authMethod: .savedPassword,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig
            )
            return .success(config)
        }

        // Fall back to default keys if set and no saved password found
        if let primaryKeyID = SSHKeyManager.shared.primaryDefaultKeyID {
            // Build fallback keys list from remaining defaults
            let allDefaults = SSHKeyManager.shared.defaultKeyIDs
            let fallbackIDs = Array(allDefaults.dropFirst())

            logger.info("Using default key for \(username)@\(host): \(primaryKeyID) (+ \(fallbackIDs.count) fallbacks)")
            let config = SSHConfig(
                host: host,
                port: port,
                username: username,
                keyID: primaryKeyID,
                fallbackKeyIDs: fallbackIDs.isEmpty ? nil : fallbackIDs,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig
            )
            return .success(config)
        }

        // Need password - return partial config
        let partial = SSHCommandParser.PartialSSHConfig(
            host: host,
            port: port,
            username: username,
            jumpHost: jumpHostConfig,
            agentConfig: agentConfig,
            portForwardConfig: .none,
            cachedIP: cachedIP
        )

        return .needsPassword(partial)
    }

    /// Tokenize command string, respecting quotes
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

    /// Parse -o option string (key=value)
    private static func parseOption(_ option: String) -> (String, String)? {
        if let eqIndex = option.firstIndex(of: "=") {
            let key = String(option[..<eqIndex])
            let value = String(option[option.index(after: eqIndex)...])
            return (key, value)
        }
        return nil
    }

    /// Parse [user@]host target string (splits on LAST @ so usernames containing @ survive)
    private static func parseTarget(_ target: String) -> (username: String?, host: String?) {
        if let atIndex = target.lastIndex(of: "@") {
            let user = String(target[..<atIndex])
            let host = String(target[target.index(after: atIndex)...])
            return (user.isEmpty ? nil : user, host.isEmpty ? nil : host)
        }
        return (nil, target)
    }

    /// Parse host[:port] string
    private static func parseHostPort(_ hostPort: String) -> (host: String, port: Int?) {
        // Handle IPv6 format: [host]:port
        if hostPort.hasPrefix("[") {
            if let closeIndex = hostPort.firstIndex(of: "]") {
                let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeIndex])
                let afterClose = hostPort.index(after: closeIndex)
                if afterClose < hostPort.endIndex && hostPort[afterClose] == ":" {
                    let portStr = String(hostPort[hostPort.index(after: afterClose)...])
                    if let port = Int(portStr), port > 0, port <= 65535 {
                        return (host, port)
                    }
                }
                return (host, nil)
            }
        }

        // Regular host:port
        if let colonIndex = hostPort.lastIndex(of: ":") {
            let portStr = String(hostPort[hostPort.index(after: colonIndex)...])
            if let port = Int(portStr), port > 0, port <= 65535 {
                let host = String(hostPort[..<colonIndex])
                return (host, port)
            }
        }

        return (hostPort, nil)
    }

    // MARK: - Key Store Integration (mirrors SSHCommandParser/SCPCommandParser)

    /// Find an SSH key by identity file path
    private static func findKeyByIdentityPath(_ path: String) -> UUID? {
        // Extract filename from path
        let filename = (path as NSString).lastPathComponent
        // Remove common extensions
        let baseName = filename
            .replacingOccurrences(of: ".pub", with: "")
            .replacingOccurrences(of: ".pem", with: "")

        let keys = SSHKeyManager.shared.savedKeys

        // Try exact match first
        if let key = keys.first(where: { $0.name.lowercased() == baseName.lowercased() }) {
            logger.info("Found exact key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try prefix match
        if let key = keys.first(where: { $0.name.lowercased().hasPrefix(baseName.lowercased()) }) {
            logger.info("Found prefix key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try contains match
        if let key = keys.first(where: { $0.name.lowercased().contains(baseName.lowercased()) }) {
            logger.info("Found partial key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        logger.info("No key match found for identity '\(baseName)'")
        return nil
    }

    /// Find a matching key from connection history (does NOT fall back to default key)
    /// The caller should check saved passwords before falling back to default key
    private static func findMatchingKey(for username: String, host: String, identityHint: String?) -> UUID? {
        let historyManager = SSHConnectionHistoryManager.shared
        let keyManager = SSHKeyManager.shared

        // Check connection history for this host - only return key if history shows key auth was used
        for entry in historyManager.entries {
            if entry.host.lowercased() == host.lowercased() &&
               entry.username.lowercased() == username.lowercased() {
                if case .key(let keyID, let fingerprint) = entry.authType {
                    // Verify key still exists (use resolveKey for cross-device support)
                    if keyManager.resolveKey(id: keyID, fingerprint: fingerprint) != nil {
                        logger.info("Found key from history for \(username)@\(host): \(keyID)")
                        return keyID
                    }
                }
            }
        }

        // Don't fall back to default key here - let the caller check saved passwords first.
        // The default key will be used only if there's no matching history entry and no saved password.
        return nil
    }

    /// Find a connection history entry for the given target
    private static func findHistoryEntry(username: String, host: String, port: Int) -> SSHConnectionHistoryEntry? {
        let historyManager = SSHConnectionHistoryManager.shared

        return historyManager.entries.first { entry in
            entry.host.lowercased() == host.lowercased() &&
            entry.username.lowercased() == username.lowercased() &&
            entry.port == port
        }
    }
}
