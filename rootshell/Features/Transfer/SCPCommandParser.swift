//
//  SCPCommandParser.swift
//  rootshell
//
//  Parses SCP command-line arguments for internal SCP client integration
//

import Foundation
import os.log

/// Parsed SCP command with all options and file specifications
struct SCPParsedCommand: Sendable {
    /// Transfer direction
    enum Direction: Sendable {
        case upload    // local -> remote
        case download  // remote -> local
    }

    /// A file specification (local or remote)
    enum FileSpec: Sendable, Equatable {
        case local(path: String)
        case remote(user: String?, host: String, path: String)

        var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }

        var path: String {
            switch self {
            case .local(let path): return path
            case .remote(_, _, let path): return path
            }
        }
    }

    var direction: Direction
    var sources: [FileSpec]
    var destination: FileSpec

    // Connection parameters (extracted from remote spec)
    var host: String
    var port: Int
    var username: String

    // Options
    var recursive: Bool = false           // -r
    var preserveTimestamps: Bool = false  // -p
    var quiet: Bool = false               // -q
    var verbose: Bool = false             // -v
    var compress: Bool = false            // -C
    var bandwidthLimit: Int?              // -l (KB/s)
    var identityFile: String?             // -i
    var jumpHost: String?                 // -J
    var sshOptions: [String: String] = [:] // -o options
}

/// Parser for SCP command-line arguments
/// Supports: -r (recursive), -p (preserve), -q (quiet), -v (verbose), -C (compress),
///           -P (port), -i (identity), -J (jump host), -o (options), -l (limit)
@MainActor
struct SCPCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SCPCommandParser")

    /// Result of parsing an SCP command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(SCPParsedCommand, SSHConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(SCPParsedCommand, SSHCommandParser.PartialSSHConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare scp, -h, or --help)
        case help
    }

    /// Parse an SCP command string into configuration
    /// - Parameter command: Full command string (e.g., "scp -r file.txt user@host:/path/")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "scp"
        guard tokens[0].lowercased() == "scp" else {
            return .error("Not an scp command")
        }

        // Check for help request: bare "scp", "scp -h", or "scp --help"
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help") {
            return .help
        }

        var port = 22
        var identityFile: String?
        var jumpHostString: String?
        var recursive = false
        var preserveTimestamps = false
        var quiet = false
        var verbose = false
        var compress = false
        var bandwidthLimit: Int?
        var sshOptions: [String: String] = [:]
        var fileArgs: [String] = []

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token.hasPrefix("-") && !token.hasPrefix("--") {
                // Handle flags
                switch token {
                case "-r":
                    recursive = true

                case "-p":
                    preserveTimestamps = true

                case "-q":
                    quiet = true

                case "-v":
                    verbose = true

                case "-C":
                    compress = true

                case "-P":
                    // Port (note: scp uses uppercase P, unlike ssh's lowercase p)
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

                case "-l":
                    // Bandwidth limit
                    i += 1
                    guard i < tokens.count, let limit = Int(tokens[i]), limit > 0 else {
                        return .error("Invalid bandwidth limit")
                    }
                    bandwidthLimit = limit

                default:
                    // Handle combined flags like -rp, -rv, etc.
                    if token.count > 2 {
                        for char in token.dropFirst() {
                            switch char {
                            case "r": recursive = true
                            case "p": preserveTimestamps = true
                            case "q": quiet = true
                            case "v": verbose = true
                            case "C": compress = true
                            default: break // Ignore unknown flags
                            }
                        }
                    }
                    // Otherwise ignore unknown flags
                }
            } else {
                // Non-flag argument - file specification
                fileArgs.append(token)
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

        // Parse file specifications and determine direction
        return parseFileSpecs(
            fileArgs,
            port: port,
            identityFile: identityFile,
            jumpHostString: jumpHostString,
            recursive: recursive,
            preserveTimestamps: preserveTimestamps,
            quiet: quiet,
            verbose: verbose,
            compress: compress,
            bandwidthLimit: bandwidthLimit,
            sshOptions: sshOptions
        )
    }

    // MARK: - Private Helpers

    /// Parse file specifications to determine sources, destination, and direction
    private static func parseFileSpecs(
        _ args: [String],
        port: Int,
        identityFile: String?,
        jumpHostString: String?,
        recursive: Bool,
        preserveTimestamps: Bool,
        quiet: Bool,
        verbose: Bool,
        compress: Bool,
        bandwidthLimit: Int?,
        sshOptions: [String: String]
    ) -> ParseResult {
        guard args.count >= 2 else {
            return .error("scp requires source and destination")
        }

        // Last argument is destination, rest are sources
        let destArg = args.last!
        let sourceArgs = Array(args.dropLast())

        let destination = parseFileSpec(destArg)
        let sources = sourceArgs.map { parseFileSpec($0) }

        // Determine direction based on remote location
        let hasRemoteSource = sources.contains { $0.isRemote }
        let hasRemoteDest = destination.isRemote

        // Validate: exactly one side must be remote
        if hasRemoteSource && hasRemoteDest {
            return .error("Remote-to-remote copy not supported")
        }
        if !hasRemoteSource && !hasRemoteDest {
            return .error("At least one path must be remote ([user@]host:path)")
        }

        let direction: SCPParsedCommand.Direction
        let remoteSpec: SCPParsedCommand.FileSpec

        if hasRemoteDest {
            direction = .upload
            remoteSpec = destination
        } else {
            direction = .download
            // Get the first remote source for connection info
            remoteSpec = sources.first { $0.isRemote }!
        }

        // Extract connection info from remote spec
        guard case .remote(let user, let host, _) = remoteSpec else {
            return .error("Internal error: expected remote spec")
        }

        // Default username to current user if not specified
        let finalUsername = user ?? UserPreferences.effectiveUsername

        logger.info("Parsed SCP: \(direction == .upload ? "upload" : "download") \(finalUsername)@\(host):\(port), identity=\(identityFile ?? "none"), jump=\(jumpHostString ?? "none"), recursive=\(recursive)")

        // Build the parsed command
        var parsedCommand = SCPParsedCommand(
            direction: direction,
            sources: sources,
            destination: destination,
            host: host,
            port: port,
            username: finalUsername
        )
        parsedCommand.recursive = recursive
        parsedCommand.preserveTimestamps = preserveTimestamps
        parsedCommand.quiet = quiet
        parsedCommand.verbose = verbose
        parsedCommand.compress = compress
        parsedCommand.bandwidthLimit = bandwidthLimit
        parsedCommand.identityFile = identityFile
        parsedCommand.jumpHost = jumpHostString
        parsedCommand.sshOptions = sshOptions

        // Build SSHConfig using the same key lookup logic as SSH command
        return buildSSHConfig(parsedCommand: parsedCommand, jumpHostString: jumpHostString, identityFile: identityFile)
    }

    /// Build SSHConfig from parsed command, with key store integration
    private static func buildSSHConfig(
        parsedCommand: SCPParsedCommand,
        jumpHostString: String?,
        identityFile: String?
    ) -> ParseResult {
        let host = parsedCommand.host
        let port = parsedCommand.port
        let username = parsedCommand.username

        // Build jump host config if specified
        var jumpHostConfig: SSHConfig.JumpHostConfig?
        if let jumpStr = jumpHostString {
            let jumpParsed = parseDestination(jumpStr)
            let jumpUser = jumpParsed.username ?? username
            guard let jumpHost = jumpParsed.host, !jumpHost.isEmpty else {
                return .error("Invalid jump host")
            }
            // For jump host auth, try to find a matching key or fall back to password prompt
            let jumpKeyID = findMatchingKey(for: jumpUser, host: jumpHost, identityHint: nil)

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if let keyID = jumpKeyID {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            jumpHostConfig = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: jumpParsed.port ?? 22,
                username: jumpUser,
                authMethod: jumpKeyID != nil ? .key(jumpKeyID!) : .password(""),
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )
        }

        // Agent config - disabled for SCP transfers (no forwarding needed)
        let agentConfig: SSHAgentConfig = .disabled

        // Check connection history for cached IP
        let historyEntry = findHistoryEntry(username: username, host: host, port: port)
        let cachedIP = historyEntry?.cachedIP

        // Check if "none" authentication was explicitly requested (Tailscale/WireGuard)
        if let preferredAuth = parsedCommand.sshOptions["PreferredAuthentications"]?.lowercased(),
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
            return .success(parsedCommand, config)
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
            return .success(parsedCommand, config)
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
            return .success(parsedCommand, config)
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
            return .success(parsedCommand, config)
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

        return .needsPassword(parsedCommand, partial)
    }

    /// Tokenize command string, respecting quotes
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasContent = false   // Track tokens that were explicitly opened (e.g. empty "") so they aren't dropped.
        var inQuote: Character?
        var escaped = false

        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let char = chars[i]

            if escaped {
                // POSIX: outside quotes, `\X` → literal X. Inside double quotes,
                // `\X` only escapes $, `, ", \, newline — anything else preserves the
                // backslash literally with X. (Single quotes don't reach here.)
                if inQuote == "\"" {
                    switch char {
                    case "$", "`", "\"", "\\", "\n":
                        current.append(char)
                    default:
                        current.append("\\")
                        current.append(char)
                    }
                } else {
                    current.append(char)
                }
                hasContent = true
                escaped = false
                i += 1
                continue
            }

            if let quote = inQuote {
                if quote == "\"" && char == "\\" {
                    escaped = true
                } else if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
                i += 1
                continue
            }

            if char == "\\" {
                escaped = true
                i += 1
                continue
            }

            if char == "\"" || char == "'" {
                inQuote = char
                hasContent = true
                i += 1
                continue
            }

            if char.isWhitespace {
                if hasContent {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
                i += 1
                continue
            }

            current.append(char)
            hasContent = true
            i += 1
        }

        // Trailing backslash with no following char: treat as literal.
        if escaped {
            current.append("\\")
            hasContent = true
        }
        if hasContent {
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

    /// Parse a single file specification
    /// Returns FileSpec for local path or remote [user@]host:path
    private static func parseFileSpec(_ spec: String) -> SCPParsedCommand.FileSpec {
        // Check for remote: [user@]host:path
        // Be careful with: Windows paths like C:\foo and IPv6 like [::1]:path

        if spec.hasPrefix("[") {
            // IPv6 format: [host]:path
            if let closeBracket = spec.firstIndex(of: "]") {
                let afterBracket = spec.index(after: closeBracket)
                if afterBracket < spec.endIndex && spec[afterBracket] == ":" {
                    let host = String(spec[spec.index(after: spec.startIndex)..<closeBracket])
                    let path = String(spec[spec.index(after: afterBracket)...])
                    return .remote(user: nil, host: host, path: path.isEmpty ? "." : path)
                }
            }
        }

        // Check for user@host:path or host:path
        // Colon must appear and path must follow (to distinguish from host-only)
        if let colonIndex = spec.firstIndex(of: ":") {
            let beforeColon = String(spec[..<colonIndex])
            let afterColon = String(spec[spec.index(after: colonIndex)...])

            // Make sure beforeColon isn't empty and doesn't look like a Windows drive letter
            guard !beforeColon.isEmpty else {
                return .local(path: spec)
            }

            // Windows drive detection: single letter before colon
            if beforeColon.count == 1 && beforeColon.first!.isLetter {
                return .local(path: spec)
            }

            // Check for user@host — split on LAST @ so usernames containing @ survive
            if let atIndex = beforeColon.lastIndex(of: "@") {
                let user = String(beforeColon[..<atIndex])
                let host = String(beforeColon[beforeColon.index(after: atIndex)...])
                return .remote(user: user.isEmpty ? nil : user, host: host, path: afterColon.isEmpty ? "." : afterColon)
            } else {
                return .remote(user: nil, host: beforeColon, path: afterColon.isEmpty ? "." : afterColon)
            }
        }

        // Local path
        return .local(path: spec)
    }

    /// Parse [user@]host[:port] destination string (for jump hosts)
    private static func parseDestination(_ dest: String) -> (username: String?, host: String?, port: Int?) {
        var remaining = dest
        var username: String?
        var port: Int?

        // Extract user@ prefix (split on LAST @ so usernames containing @ survive)
        if let atIndex = remaining.lastIndex(of: "@") {
            username = String(remaining[..<atIndex])
            remaining = String(remaining[remaining.index(after: atIndex)...])
        }

        // Extract :port suffix (but be careful with IPv6 [host]:port)
        if remaining.hasPrefix("[") {
            // IPv6 format: [host]:port
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
            // Regular host:port - but only if what follows looks like a port number
            let portStr = String(remaining[remaining.index(after: colonIndex)...])
            if let p = Int(portStr), p > 0, p <= 65535 {
                port = p
                remaining = String(remaining[..<colonIndex])
            }
        }

        return (username, remaining.isEmpty ? nil : remaining, port)
    }

    // MARK: - Key Store Integration (mirrors SSHCommandParser)

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
