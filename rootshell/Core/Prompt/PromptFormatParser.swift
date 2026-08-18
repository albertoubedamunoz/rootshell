#if !targetEnvironment(macCatalyst)
//
//  PromptFormatParser.swift
//  rootshell
//
//  Recursive descent parser for Starship-compatible format strings.
//  Parses $variable references, [text](style) styled groups, and literal text.
//

import Foundation

// MARK: - AST Types

enum FormatNode: Sendable {
    case literal(String)
    case styledGroup(children: [FormatNode], style: PromptStyleSpec)
    case variable(String)
}

struct PromptStyleSpec: Sendable {
    var fg: ColorSpec?
    var bg: ColorSpec?
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var dimmed: Bool = false

    static let empty = PromptStyleSpec()
}

enum ColorSpec: Sendable, Equatable {
    case hex(String)       // "#f38ba8"
    case named(String)     // "red", "bright-blue"
    case palette(String)   // palette color name
}

// MARK: - Parser Errors

enum FormatParserError: LocalizedError, Sendable {
    case unmatchedBracket(Int)
    case unmatchedParen(Int)
    case emptyVariable(Int)

    var errorDescription: String? {
        switch self {
        case .unmatchedBracket(let pos):
            return "Unmatched '[' at position \(pos)"
        case .unmatchedParen(let pos):
            return "Unmatched '(' at position \(pos)"
        case .emptyVariable(let pos):
            return "Empty variable name at position \(pos)"
        }
    }
}

// MARK: - Parser

struct PromptFormatParser {

    /// Parse a format string into a tree of FormatNode
    static func parse(_ format: String) throws -> [FormatNode] {
        var scanner = FormatScanner(format)
        return try parseNodes(&scanner, until: nil)
    }

    private static func parseNodes(_ scanner: inout FormatScanner, until terminator: Character?) throws -> [FormatNode] {
        var nodes: [FormatNode] = []
        var literalBuffer = ""

        while let ch = scanner.peek() {
            // Stop at terminator
            if let term = terminator, ch == term {
                break
            }

            switch ch {
            case "$":
                // Flush literal
                if !literalBuffer.isEmpty {
                    nodes.append(.literal(literalBuffer))
                    literalBuffer = ""
                }
                // Parse variable
                scanner.advance()  // consume $
                let varName = scanner.consumeWhile { $0.isLetter || $0 == "_" || $0.isNumber }
                if varName.isEmpty {
                    // Bare $ — treat as literal
                    literalBuffer.append("$")
                } else {
                    nodes.append(.variable(varName))
                }

            case "[":
                // Flush literal
                if !literalBuffer.isEmpty {
                    nodes.append(.literal(literalBuffer))
                    literalBuffer = ""
                }
                let startPos = scanner.position
                scanner.advance()  // consume [

                // Parse children until ]
                let children = try parseNodes(&scanner, until: "]")
                guard scanner.peek() == "]" else {
                    throw FormatParserError.unmatchedBracket(startPos)
                }
                scanner.advance()  // consume ]

                // Check for (style) after ]
                if scanner.peek() == "(" {
                    scanner.advance()  // consume (
                    let styleStr = scanner.consumeWhile { $0 != ")" }
                    guard scanner.peek() == ")" else {
                        throw FormatParserError.unmatchedParen(startPos)
                    }
                    scanner.advance()  // consume )
                    let style = parseStyleSpec(styleStr)
                    nodes.append(.styledGroup(children: children, style: style))
                } else {
                    // No style — just treat brackets as literal wrapping
                    nodes.append(.literal("["))
                    nodes.append(contentsOf: children)
                    nodes.append(.literal("]"))
                }

            case "\\":
                // Escape sequences
                scanner.advance()  // consume backslash
                if let next = scanner.peek() {
                    switch next {
                    case "n":
                        literalBuffer.append("\r\n")
                        scanner.advance()
                    case "r":
                        literalBuffer.append("\r")
                        scanner.advance()
                    case "t":
                        literalBuffer.append("\t")
                        scanner.advance()
                    case "\\":
                        literalBuffer.append("\\")
                        scanner.advance()
                    case "[", "]", "$":
                        literalBuffer.append(next)
                        scanner.advance()
                    default:
                        literalBuffer.append("\\")
                    }
                } else {
                    literalBuffer.append("\\")
                }

            default:
                literalBuffer.append(ch)
                scanner.advance()
            }
        }

        if !literalBuffer.isEmpty {
            nodes.append(.literal(literalBuffer))
        }

        return nodes
    }

    // MARK: - Style Parsing

    /// Parse a style string like "bold fg:#hex bg:#hex" or "fg:red bg:palette_name"
    static func parseStyleSpec(_ style: String) -> PromptStyleSpec {
        var spec = PromptStyleSpec()
        let tokens = style.split(separator: " ").map(String.init)

        for token in tokens {
            let lower = token.lowercased()

            if lower == "bold" {
                spec.bold = true
            } else if lower == "italic" {
                spec.italic = true
            } else if lower == "underline" {
                spec.underline = true
            } else if lower == "dimmed" || lower == "dim" {
                spec.dimmed = true
            } else if lower.hasPrefix("fg:") {
                let colorStr = String(token.dropFirst(3))
                spec.fg = parseColorSpec(colorStr)
            } else if lower.hasPrefix("bg:") {
                let colorStr = String(token.dropFirst(3))
                spec.bg = parseColorSpec(colorStr)
            }
        }

        return spec
    }

    /// Parse a color spec from a string.
    /// All non-hex colors are classified as `.palette` — the evaluator's resolver
    /// checks the active palette first, then falls back to ANSI named colors.
    /// This ensures palette definitions of "red", "green", etc. override ANSI defaults.
    static func parseColorSpec(_ str: String) -> ColorSpec {
        if str.hasPrefix("#") && (str.count == 7 || str.count == 4) {
            return .hex(str)
        }

        return .palette(str)
    }
}

// MARK: - Scanner

private struct FormatScanner {
    private let chars: [Character]
    private(set) var position: Int = 0

    init(_ string: String) {
        self.chars = Array(string)
    }

    func peek() -> Character? {
        guard position < chars.count else { return nil }
        return chars[position]
    }

    mutating func advance() {
        position += 1
    }

    mutating func consumeWhile(_ predicate: (Character) -> Bool) -> String {
        var result = ""
        while position < chars.count && predicate(chars[position]) {
            result.append(chars[position])
            position += 1
        }
        return result
    }
}

#endif
