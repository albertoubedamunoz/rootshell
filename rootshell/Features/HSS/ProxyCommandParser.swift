//
//  ProxyCommandParser.swift
//  rootshell
//
//  Parses SSH strings and ProxyCommand to extract connection details
//

import Foundation
import os.log

/// Parsed jump host details from ProxyCommand
struct ParsedJumpHost {
    var host: String
    var port: Int = 22
    var username: String?
}

/// Parser for SSH command strings and ProxyCommand extraction
struct HSSSSHParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HSSSSHParser")

    /// Parse an expanded HSS string into connection details
    /// Handles formats like:
    /// - "ssh user@host"
    /// - "ssh -p 2222 user@host"
    /// - "ssh -oProxyCommand=\"ssh -W %h:%p jump@bastion\" user@target"
    /// - "user@host" (simple format)
    static func parse(_ sshString: String) -> HSSResolution? {
        var input = sshString.trimmingCharacters(in: .whitespaces)

        // Strip leading "ssh " if present
        if input.lowercased().hasPrefix("ssh ") {
            input = String(input.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }

        var resolution = HSSResolution(host: "", rawExpansion: sshString)

        // Extract ProxyCommand if present
        if let proxyResult = extractProxyCommand(from: input) {
            if let jumpHost = ProxyCommandParser.parse(proxyResult.proxyCommand) {
                resolution.jumpHost = jumpHost.host
                resolution.jumpPort = jumpHost.port
                resolution.jumpUsername = jumpHost.username
            }
            input = proxyResult.remaining
        }

        // Parse remaining options and target
        let (options, target) = parseSSHOptions(input)

        // Apply options
        if let port = options["-p"] {
            resolution.port = Int(port) ?? 22
        }
        if let user = options["-l"] {
            resolution.username = user
        }

        // Parse target (user@host or just host)
        if let parsed = parseUserAtHost(target) {
            resolution.host = parsed.host
            if parsed.port != 22 {
                resolution.port = parsed.port
            }
            if resolution.username == nil {
                resolution.username = parsed.username
            }
        } else {
            resolution.host = target
        }

        // Validate we have at least a host
        guard !resolution.host.isEmpty else {
            logger.warning("Failed to parse host from: \(sshString)")
            return nil
        }

        logger.info("Parsed HSS: host=\(resolution.host), port=\(resolution.port), user=\(resolution.username ?? ""), jump=\(resolution.jumpHost ?? "")")
        return resolution
    }

    /// Extract ProxyCommand from SSH options
    private static func extractProxyCommand(from input: String) -> (proxyCommand: String, remaining: String)? {
        // Pattern 1: -oProxyCommand="..."
        if let range = input.range(of: #"-oProxyCommand="#, options: .caseInsensitive) {
            let afterOption = input[range.upperBound...]

            // Find the quoted command
            if afterOption.hasPrefix("\"") {
                let commandStart = afterOption.index(after: afterOption.startIndex)
                if let endQuote = afterOption[commandStart...].firstIndex(of: "\"") {
                    let command = String(afterOption[commandStart..<endQuote])
                    let remaining = String(input[..<range.lowerBound]) + String(afterOption[afterOption.index(after: endQuote)...])
                    return (command, remaining.trimmingCharacters(in: .whitespaces))
                }
            } else if afterOption.hasPrefix("'") {
                let commandStart = afterOption.index(after: afterOption.startIndex)
                if let endQuote = afterOption[commandStart...].firstIndex(of: "'") {
                    let command = String(afterOption[commandStart..<endQuote])
                    let remaining = String(input[..<range.lowerBound]) + String(afterOption[afterOption.index(after: endQuote)...])
                    return (command, remaining.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // Pattern 2: -o ProxyCommand="..."
        if let range = input.range(of: #"-o\s+ProxyCommand="#, options: [.caseInsensitive, .regularExpression]) {
            let afterOption = input[range.upperBound...]

            if afterOption.hasPrefix("\"") {
                let commandStart = afterOption.index(after: afterOption.startIndex)
                if let endQuote = afterOption[commandStart...].firstIndex(of: "\"") {
                    let command = String(afterOption[commandStart..<endQuote])
                    let remaining = String(input[..<range.lowerBound]) + String(afterOption[afterOption.index(after: endQuote)...])
                    return (command, remaining.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        return nil
    }

    /// Parse SSH command-line options
    private static func parseSSHOptions(_ input: String) -> (options: [String: String], target: String) {
        var options: [String: String] = [:]
        var target = ""

        // Simple tokenization (doesn't handle all edge cases but covers common ones)
        let tokens = tokenize(input)
        var i = 0

        while i < tokens.count {
            let token = tokens[i]

            if token == "-p" && i + 1 < tokens.count {
                options["-p"] = tokens[i + 1]
                i += 2
            } else if token == "-l" && i + 1 < tokens.count {
                options["-l"] = tokens[i + 1]
                i += 2
            } else if token.hasPrefix("-") {
                // Skip other options
                i += 1
                // Skip option argument if it doesn't start with -
                if i < tokens.count && !tokens[i].hasPrefix("-") {
                    i += 1
                }
            } else {
                // This should be the target
                target = token
                i += 1
            }
        }

        return (options, target)
    }

    /// Simple tokenization respecting quotes
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in input {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else {
                switch char {
                case "\"", "'":
                    inQuote = true
                    quoteChar = char
                case " ", "\t":
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(char)
                }
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Parse user@host:port format
    private static func parseUserAtHost(_ input: String) -> (username: String?, host: String, port: Int)? {
        var username: String? = nil
        var host = input
        var port = 22

        // Extract user@ (split on LAST @ so usernames containing @ survive)
        if let atIndex = host.lastIndex(of: "@") {
            username = String(host[..<atIndex])
            host = String(host[host.index(after: atIndex)...])
        }

        // Extract :port
        if let colonIndex = host.lastIndex(of: ":") {
            let portString = String(host[host.index(after: colonIndex)...])
            if let parsedPort = Int(portString) {
                port = parsedPort
                host = String(host[..<colonIndex])
            }
        }

        guard !host.isEmpty else { return nil }
        return (username, host, port)
    }
}

/// Parser for ProxyCommand strings to extract jump host
struct ProxyCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ProxyCommandParser")

    /// Parse ProxyCommand to extract jump host details
    /// Supported formats:
    /// - "ssh -W %h:%p user@jumphost"
    /// - "ssh -W %h:%p -p 2222 user@jumphost"
    /// - "ssh -W %h:%p jumphost -l user"
    static func parse(_ proxyCommand: String) -> ParsedJumpHost? {
        var input = proxyCommand.trimmingCharacters(in: .whitespaces)

        // Must start with ssh
        guard input.lowercased().hasPrefix("ssh ") else {
            logger.warning("ProxyCommand doesn't start with 'ssh': \(proxyCommand)")
            return nil
        }
        input = String(input.dropFirst(4)).trimmingCharacters(in: .whitespaces)

        // Must contain -W %h:%p (the tunnel directive)
        guard input.contains("-W") && input.contains("%h:%p") else {
            logger.warning("ProxyCommand missing '-W %%h:%%p': \(proxyCommand)")
            return nil
        }

        // Remove the -W %h:%p part
        input = input.replacingOccurrences(of: "-W %h:%p", with: "")
            .replacingOccurrences(of: "-W%h:%p", with: "")
            .trimmingCharacters(in: .whitespaces)

        var jumpHost = ParsedJumpHost(host: "")

        // Parse remaining tokens
        let tokens = tokenize(input)
        var i = 0

        while i < tokens.count {
            let token = tokens[i]

            // Stop at shell subcommand syntax $(...)
            if token.hasPrefix("$(") || token.hasPrefix("`") {
                break
            }

            if token == "-p" && i + 1 < tokens.count {
                jumpHost.port = Int(tokens[i + 1]) ?? 22
                i += 2
            } else if token == "-l" && i + 1 < tokens.count {
                jumpHost.username = tokens[i + 1]
                i += 2
            } else if token.hasPrefix("-") {
                // Skip other options
                i += 1
            } else {
                // This should be the jump host (user@host or just host)
                // Take the FIRST non-option token and stop.
                // Split on LAST @ so usernames containing @ (e.g. AD-style user@domain) survive.
                if let atIndex = token.lastIndex(of: "@") {
                    jumpHost.username = String(token[..<atIndex])
                    jumpHost.host = String(token[token.index(after: atIndex)...])
                } else {
                    jumpHost.host = token
                }
                // Found the jump host, stop parsing
                break
            }
        }

        guard !jumpHost.host.isEmpty else {
            logger.warning("Failed to extract jump host from: \(proxyCommand)")
            return nil
        }

        logger.info("Parsed ProxyCommand: jump=\(jumpHost.host):\(jumpHost.port), user=\(jumpHost.username ?? "")")
        return jumpHost
    }

    /// Simple tokenization
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in input {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else {
                switch char {
                case "\"", "'":
                    inQuote = true
                    quoteChar = char
                case " ", "\t":
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(char)
                }
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
