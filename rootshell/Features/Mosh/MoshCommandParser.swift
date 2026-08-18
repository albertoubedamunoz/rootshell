//
//  MoshCommandParser.swift
//  rootshell
//
//  Parses mosh/roam command-line arguments into MoshConfig for internal Mosh client integration
//

import Foundation
import os.log

/// Parser for mosh/roam command-line arguments
/// Accepts same flags as SSH plus Mosh-specific options: --predict, --server
@MainActor
struct MoshCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MoshCommandParser")

    /// Result of parsing a mosh/roam command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(MoshConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(PartialMoshConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare mosh/roam, -h, or --help)
        case help
    }

    /// Partial config when password is needed
    struct PartialMoshConfig: Sendable {
        var sshPartialConfig: SSHCommandParser.PartialSSHConfig
        var predictionMode: MoshConfig.PredictionMode
        var serverPath: String?

        /// Convert to full MoshConfig with password
        func toMoshConfig(password: String) -> MoshConfig {
            let sshConfig = sshPartialConfig.toSSHConfig(password: password)
            return MoshConfig(
                sshConfig: sshConfig,
                predictionMode: predictionMode,
                serverPath: serverPath
            )
        }
    }

    /// Parse a mosh/roam command string into configuration
    /// - Parameter command: Full command string (e.g., "roam -p 2222 user@host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "mosh" or "roam"
        let commandName = tokens[0].lowercased()
        guard commandName == "mosh" || commandName == "roam" else {
            return .error("Not a mosh/roam command")
        }

        // Check for help request: bare command, -h, or --help
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help") {
            return .help
        }

        // Extract Mosh-specific flags before delegating to SSH parser
        // Read default prediction mode from UserDefaults, falling back to .adaptive
        var predictionMode: MoshConfig.PredictionMode = {
            let rawValue = UserDefaults.standard.string(forKey: MoshConfig.defaultPredictionModeKey) ?? ""
            return MoshConfig.PredictionMode(rawValue: rawValue) ?? .adaptive
        }()
        var serverPath: String?
        var filteredTokens: [String] = [tokens[0]]

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token.hasPrefix("--predict=") {
                // --predict=mode
                let modeStr = String(token.dropFirst("--predict=".count)).lowercased()
                if let mode = parsePredictionMode(modeStr) {
                    predictionMode = mode
                } else {
                    return .error("Invalid prediction mode: \(modeStr). Use: always, adaptive, or never")
                }
            } else if token == "--predict" {
                // --predict mode
                i += 1
                guard i < tokens.count else {
                    return .error("Missing argument after --predict")
                }
                let modeStr = tokens[i].lowercased()
                if let mode = parsePredictionMode(modeStr) {
                    predictionMode = mode
                } else {
                    return .error("Invalid prediction mode: \(modeStr). Use: always, adaptive, or never")
                }
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
            // Wrap SSH config in Mosh config
            let moshConfig = MoshConfig(
                sshConfig: sshConfig,
                predictionMode: predictionMode,
                serverPath: serverPath
            )
            return .success(moshConfig)

        case .needsPassword(let partialSSHConfig):
            // Need password - return partial Mosh config
            let partialMosh = PartialMoshConfig(
                sshPartialConfig: partialSSHConfig,
                predictionMode: predictionMode,
                serverPath: serverPath
            )
            return .needsPassword(partialMosh)

        case .help:
            // SSH parser returned help - we handle mosh help ourselves
            return .help

        case .error(let message):
            return .error(message)
        }
    }

    // MARK: - Private Helpers

    /// Parse prediction mode string
    private static func parsePredictionMode(_ str: String) -> MoshConfig.PredictionMode? {
        switch str.lowercased() {
        case "always", "a":
            return .always
        case "adaptive", "auto":
            return .adaptive
        case "never", "n":
            return .never
        default:
            return nil
        }
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
}
