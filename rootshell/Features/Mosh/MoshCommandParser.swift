//
//  MoshCommandParser.swift
//  rootshell
//
//  Parses mosh/roam command-line arguments into MoshConfig for internal Mosh client integration
//

import Foundation
import os.log

/// Parser for mosh/roam command-line arguments
/// Accepts same flags as SSH plus Mosh-specific options: --predict, --predict-overwrite, --server
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
        var predictOverwrite: Bool
        var serverPath: String?

        /// Convert to full MoshConfig with password
        func toMoshConfig(password: String) -> MoshConfig {
            let sshConfig = sshPartialConfig.toSSHConfig(password: password)
            return MoshConfig(
                sshConfig: sshConfig,
                predictionMode: predictionMode,
                predictOverwrite: predictOverwrite,
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
        let commandName = tokens[0].text.lowercased()
        guard commandName == "mosh" || commandName == "roam" else {
            return .error("Not a mosh/roam command")
        }

        // Check for help request: bare command, -h, or --help
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1].text == "-h" || tokens[1].text == "--help") {
            return .help
        }

        // Extract Mosh-specific flags before delegating to SSH parser
        // Read default prediction mode from UserDefaults, falling back to .adaptive
        var predictionMode = SettingsStore.shared.value(Settings.Roam.predictionMode)
        var predictOverwrite = MoshConfig.defaultPredictOverwrite
        var serverPath: String?
        var filteredParts: [String] = ["ssh"]

        var i = 1
        while i < tokens.count {
            let token = tokens[i].text

            if token == "--predict-overwrite" {
                predictOverwrite = true
            } else if token == "--no-predict-overwrite" {
                predictOverwrite = false
            } else if token.hasPrefix("--predict=") {
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
                let modeStr = tokens[i].text.lowercased()
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
                serverPath = tokens[i].text
            } else if Self.sshFlagsWithArgument.contains(token) {
                // Preserve SSH options and their values while looking for the destination.
                // SSHCommandParser remains responsible for validating a missing/invalid value.
                filteredParts.append(String(command[tokens[i].range]))
                i += 1
                if i < tokens.count {
                    filteredParts.append(String(command[tokens[i].range]))
                }
            } else if token.hasPrefix("-") {
                // Boolean or unknown SSH option. SSHCommandParser applies its normal handling.
                filteredParts.append(String(command[tokens[i].range]))
            } else {
                // First positional token is the destination. Preserve it and the complete
                // remote-command suffix verbatim, and never interpret nested Mosh flags.
                filteredParts.append(String(command[tokens[i].range.lowerBound...]))
                break
            }

            i += 1
        }

        let normalizedCommand = filteredParts.joined(separator: " ")

        // Delegate to SSH parser
        let sshResult = SSHCommandParser.parse(command: normalizedCommand)

        switch sshResult {
        case .success(let sshConfig):
            // Wrap SSH config in Mosh config
            let moshConfig = MoshConfig(
                sshConfig: sshConfig,
                predictionMode: predictionMode,
                predictOverwrite: predictOverwrite,
                serverPath: serverPath
            )
            return .success(moshConfig)

        case .needsPassword(let partialSSHConfig):
            // Need password - return partial Mosh config
            let partialMosh = PartialMoshConfig(
                sshPartialConfig: partialSSHConfig,
                predictionMode: predictionMode,
                predictOverwrite: predictOverwrite,
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

    /// SSH options that consume the next token before the destination.
    /// Keep this aligned with SSHCommandParser's option switch.
    private static let sshFlagsWithArgument: Set<String> = ["-L", "-R", "-p", "-l", "-J", "-i", "-o"]

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    /// Tokenize command string, respecting quotes and preserving source ranges.
    private static func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuote: Character?
        var tokenStart: String.Index?

        var index = command.startIndex
        while index < command.endIndex {
            let char = command[index]
            if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                if tokenStart == nil {
                    tokenStart = index
                }
                inQuote = char
            } else if char.isWhitespace {
                if let start = tokenStart {
                    tokens.append(Token(text: current, range: start..<index))
                    current = ""
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil {
                    tokenStart = index
                }
                current.append(char)
            }

            index = command.index(after: index)
        }

        if let tokenStart {
            tokens.append(Token(text: current, range: tokenStart..<command.endIndex))
        }

        return tokens
    }
}
