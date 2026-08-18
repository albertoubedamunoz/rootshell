//
//  TSSHCommandParser.swift
//  rootshell
//
//  Parses trzsz command-line arguments into TrzszConfig for internal Trzsz client integration
//

import Foundation
import os.log

/// Parser for trzsz command-line arguments
/// Accepts same flags as SSH plus Trzsz-specific options: --quic, --kcp, --server
@MainActor
struct TrzszCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TrzszCommandParser")

    /// Result of parsing a trzsz command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(TrzszConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(PartialTrzszConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare trzsz, -h, or --help)
        case help
    }

    /// Partial config when password is needed
    struct PartialTrzszConfig: Sendable {
        var sshPartialConfig: SSHCommandParser.PartialSSHConfig
        var transportMode: TrzszConfig.TransportMode
        var serverPath: String?

        /// Convert to full TrzszConfig with password
        func toTrzszConfig(password: String) -> TrzszConfig {
            let sshConfig = sshPartialConfig.toSSHConfig(password: password)
            return TrzszConfig(
                sshConfig: sshConfig,
                transportMode: transportMode,
                serverPath: serverPath
            )
        }
    }

    /// Parse a trzsz command string into configuration
    /// - Parameter command: Full command string (e.g., "trzsz --quic user@host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "trzsz" or "tssh"
        let commandName = tokens[0].lowercased()
        guard commandName == "trzsz" || commandName == "tssh" else {
            return .error("Not a trzsz command")
        }

        // Check for help request: bare command, -h, or --help
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help") {
            return .help
        }

        // Extract Trzsz-specific flags before delegating to SSH parser
        var transportMode: TrzszConfig.TransportMode = .auto
        var serverPath: String?
        var filteredTokens: [String] = [tokens[0]]

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token == "--quic" {
                transportMode = .quic
            } else if token == "--kcp" {
                transportMode = .kcp
            } else if token.hasPrefix("--server=") {
                // --server=path
                serverPath = String(token.dropFirst("--server=".count))
            } else if token == "--server" {
                // --server path
                i += 1
                guard i < tokens.count else {
                    return .error("Missing argument after --server")
                }
                serverPath = tokens[i]
            } else {
                // Pass through to SSH parser
                filteredTokens.append(token)
            }

            i += 1
        }

        // Normalize command name to "ssh" for SSHCommandParser
        filteredTokens[0] = "ssh"
        let normalizedCommand = filteredTokens.joined(separator: " ")

        // Delegate to SSH parser
        let sshResult = SSHCommandParser.parse(command: normalizedCommand)

        switch sshResult {
        case .success(let sshConfig):
            // Wrap SSH config in Trzsz config
            let trzszConfig = TrzszConfig(
                sshConfig: sshConfig,
                transportMode: transportMode,
                serverPath: serverPath
            )
            return .success(trzszConfig)

        case .needsPassword(let partialSSHConfig):
            // Need password - return partial Trzsz config
            let partialTrzsz = PartialTrzszConfig(
                sshPartialConfig: partialSSHConfig,
                transportMode: transportMode,
                serverPath: serverPath
            )
            return .needsPassword(partialTrzsz)

        case .help:
            // SSH parser returned help - we handle trzsz help ourselves
            return .help

        case .error(let message):
            return .error(message)
        }
    }

    // MARK: - Private Helpers

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
}
