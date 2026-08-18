#if !targetEnvironment(macCatalyst)
//
//  TOMLParser.swift
//  rootshell
//
//  Minimal TOML subset parser for .promptrc.toml configuration files.
//  Handles key-value pairs, [table] headers, comments, basic/literal strings,
//  multi-line strings, booleans, and integers.
//

import Foundation

enum TOMLParserError: LocalizedError, Sendable {
    case unexpectedCharacter(Character, line: Int)
    case unterminatedString(line: Int)
    case invalidEscape(String, line: Int)
    case invalidValue(String, line: Int)
    case duplicateKey(String, line: Int)
    case invalidTableHeader(line: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedCharacter(let ch, let line):
            return "Unexpected character '\(ch)' on line \(line)"
        case .unterminatedString(let line):
            return "Unterminated string on line \(line)"
        case .invalidEscape(let seq, let line):
            return "Invalid escape sequence '\(seq)' on line \(line)"
        case .invalidValue(let value, let line):
            return "Invalid value '\(value)' on line \(line)"
        case .duplicateKey(let key, let line):
            return "Duplicate key '\(key)' on line \(line)"
        case .invalidTableHeader(let line):
            return "Invalid table header on line \(line)"
        }
    }
}

struct TOMLParser {

    /// Parse a TOML string into a nested dictionary
    static func parse(_ input: String) throws -> [String: Any] {
        var root: [String: Any] = [:]
        var currentTable: [String] = []  // Key path of current table
        let lines = input.components(separatedBy: .newlines)
        var lineIndex = 0

        while lineIndex < lines.count {
            let lineNumber = lineIndex + 1
            let rawLine = lines[lineIndex]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") {
                lineIndex += 1
                continue
            }

            // Table header: [table] or [table.subtable]
            if line.hasPrefix("[") && !line.hasPrefix("[[") {
                let header = try parseTableHeader(line, lineNumber: lineNumber)
                currentTable = header
                // Ensure the table path exists
                ensureTablePath(&root, path: header)
                lineIndex += 1
                continue
            }

            // Key-value pair
            guard let equalsIndex = findEqualsSign(in: line) else {
                lineIndex += 1
                continue
            }

            let key = String(line[line.startIndex..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                lineIndex += 1
                continue
            }

            // Check for multi-line strings
            let (value, linesConsumed) = try parseValue(rawValue, lines: lines, startLine: lineIndex)
            lineIndex += linesConsumed

            // Set value in the appropriate table
            try setValue(&root, path: currentTable, key: key, value: value, lineNumber: lineNumber)
        }

        return root
    }

    // MARK: - Table Header Parsing

    private static func parseTableHeader(_ line: String, lineNumber: Int) throws -> [String] {
        // Strip [ and ], ignoring inline comments
        guard line.hasPrefix("[") else {
            throw TOMLParserError.invalidTableHeader(line: lineNumber)
        }

        // Find closing ]
        guard let closeBracket = line.firstIndex(of: "]") else {
            throw TOMLParserError.invalidTableHeader(line: lineNumber)
        }

        let headerContent = String(line[line.index(after: line.startIndex)..<closeBracket])
            .trimmingCharacters(in: .whitespaces)

        guard !headerContent.isEmpty else {
            throw TOMLParserError.invalidTableHeader(line: lineNumber)
        }

        // Split by dots for nested tables
        let parts = headerContent.split(separator: ".").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }

        guard parts.allSatisfy({ !$0.isEmpty }) else {
            throw TOMLParserError.invalidTableHeader(line: lineNumber)
        }

        return parts
    }

    // MARK: - Value Parsing

    private static func parseValue(_ raw: String, lines: [String], startLine: Int) throws -> (Any, Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Strip inline comments (not inside strings)
        let valueStr = stripInlineComment(trimmed)

        // Multi-line basic string: """
        if valueStr.hasPrefix("\"\"\"") {
            return try parseMultiLineBasicString(lines: lines, startLine: startLine)
        }

        // Multi-line literal string: '''
        if valueStr.hasPrefix("'''") {
            return try parseMultiLineLiteralString(lines: lines, startLine: startLine)
        }

        // Basic string: "..."
        if valueStr.hasPrefix("\"") {
            let str = try parseBasicString(valueStr, lineNumber: startLine + 1)
            return (str, 1)
        }

        // Literal string: '...'
        if valueStr.hasPrefix("'") {
            let str = try parseLiteralString(valueStr, lineNumber: startLine + 1)
            return (str, 1)
        }

        // Boolean
        if valueStr == "true" { return (true, 1) }
        if valueStr == "false" { return (false, 1) }

        // Integer
        if let intVal = Int(valueStr) {
            return (intVal, 1)
        }

        // Float
        if let floatVal = Double(valueStr), valueStr.contains(".") {
            return (floatVal, 1)
        }

        // Treat as bare string (unquoted value)
        return (valueStr, 1)
    }

    private static func parseBasicString(_ raw: String, lineNumber: Int) throws -> String {
        guard raw.hasPrefix("\"") else {
            throw TOMLParserError.invalidValue(raw, line: lineNumber)
        }

        var result = ""
        var idx = raw.index(after: raw.startIndex)
        var escaped = false

        while idx < raw.endIndex {
            let ch = raw[idx]

            if escaped {
                switch ch {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default:
                    throw TOMLParserError.invalidEscape("\\\(ch)", line: lineNumber)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return result
            } else {
                result.append(ch)
            }

            idx = raw.index(after: idx)
        }

        throw TOMLParserError.unterminatedString(line: lineNumber)
    }

    private static func parseLiteralString(_ raw: String, lineNumber: Int) throws -> String {
        guard raw.hasPrefix("'") else {
            throw TOMLParserError.invalidValue(raw, line: lineNumber)
        }

        // Find closing single quote
        if let closeIdx = raw.dropFirst().firstIndex(of: "'") {
            return String(raw[raw.index(after: raw.startIndex)..<closeIdx])
        }

        throw TOMLParserError.unterminatedString(line: lineNumber)
    }

    private static func parseMultiLineBasicString(lines: [String], startLine: Int) throws -> (String, Int) {
        // Find the opening """ on the start line
        let firstLine = lines[startLine]
        guard let tripleIdx = firstLine.range(of: "\"\"\"") else {
            throw TOMLParserError.unterminatedString(line: startLine + 1)
        }

        // Content after opening """ on the same line
        let contentStart = String(firstLine[tripleIdx.upperBound...])

        // If the opening line also has closing """, it's a single-line multi-line string
        if let closeRange = contentStart.range(of: "\"\"\"") {
            let content = String(contentStart[contentStart.startIndex..<closeRange.lowerBound])
            return (content, 1)
        }

        var result = ""
        // Skip leading newline after opening """
        if contentStart.trimmingCharacters(in: .whitespaces).isEmpty {
            // Opening """ is alone on the line — skip its trailing content
        } else {
            result += contentStart
        }

        var lineIdx = startLine + 1
        while lineIdx < lines.count {
            let line = lines[lineIdx]
            if let closeRange = line.range(of: "\"\"\"") {
                let beforeClose = String(line[line.startIndex..<closeRange.lowerBound])
                if !result.isEmpty { result += "\n" }
                result += beforeClose
                return (result, lineIdx - startLine + 1)
            }
            if !result.isEmpty { result += "\n" }
            result += line
            lineIdx += 1
        }

        throw TOMLParserError.unterminatedString(line: startLine + 1)
    }

    private static func parseMultiLineLiteralString(lines: [String], startLine: Int) throws -> (String, Int) {
        let firstLine = lines[startLine]
        guard let tripleIdx = firstLine.range(of: "'''") else {
            throw TOMLParserError.unterminatedString(line: startLine + 1)
        }

        let contentStart = String(firstLine[tripleIdx.upperBound...])

        if let closeRange = contentStart.range(of: "'''") {
            let content = String(contentStart[contentStart.startIndex..<closeRange.lowerBound])
            return (content, 1)
        }

        var result = ""
        if contentStart.trimmingCharacters(in: .whitespaces).isEmpty {
            // Skip trailing content on opening line
        } else {
            result += contentStart
        }

        var lineIdx = startLine + 1
        while lineIdx < lines.count {
            let line = lines[lineIdx]
            if let closeRange = line.range(of: "'''") {
                let beforeClose = String(line[line.startIndex..<closeRange.lowerBound])
                if !result.isEmpty { result += "\n" }
                result += beforeClose
                return (result, lineIdx - startLine + 1)
            }
            if !result.isEmpty { result += "\n" }
            result += line
            lineIdx += 1
        }

        throw TOMLParserError.unterminatedString(line: startLine + 1)
    }

    // MARK: - Helpers

    /// Find the first `=` that's not inside a string
    private static func findEqualsSign(in line: String) -> String.Index? {
        var inString = false
        var stringChar: Character = "\""

        for idx in line.indices {
            let ch = line[idx]
            if inString {
                if ch == stringChar { inString = false }
            } else {
                if ch == "\"" || ch == "'" {
                    inString = true
                    stringChar = ch
                } else if ch == "=" {
                    return idx
                } else if ch == "#" {
                    return nil  // Comment before any =
                }
            }
        }
        return nil
    }

    /// Strip inline comment from a value string (respecting quoted strings)
    private static func stripInlineComment(_ value: String) -> String {
        var inString = false
        var stringChar: Character = "\""

        for idx in value.indices {
            let ch = value[idx]
            if inString {
                if ch == stringChar { inString = false }
            } else {
                if ch == "\"" || ch == "'" {
                    inString = true
                    stringChar = ch
                } else if ch == "#" {
                    return String(value[value.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return value
    }

    /// Ensure a nested table path exists in the root dictionary
    private static func ensureTablePath(_ root: inout [String: Any], path: [String]) {
        guard !path.isEmpty else { return }

        var current = root
        var rebuiltPath: [[String: Any]] = []

        for component in path {
            if let existing = current[component] as? [String: Any] {
                rebuiltPath.append(existing)
                current = existing
            } else {
                let newTable: [String: Any] = [:]
                current[component] = newTable
                rebuiltPath.append(newTable)
                current = newTable
            }
        }

        // Rebuild from leaf to root
        var table: [String: Any] = rebuiltPath.last ?? [:]
        for i in stride(from: path.count - 2, through: 0, by: -1) {
            var parent = rebuiltPath[i]
            parent[path[i + 1]] = table
            table = parent
        }

        if let firstKey = path.first {
            root[firstKey] = path.count == 1 ? table : table[path[1]] != nil ? table : rebuiltPath.first ?? [:]
        }

        // Simpler approach: just ensure path exists
        setNestedTable(&root, path: path)
    }

    private static func setNestedTable(_ root: inout [String: Any], path: [String]) {
        guard let first = path.first else { return }

        if path.count == 1 {
            if root[first] == nil {
                root[first] = [String: Any]()
            }
        } else {
            var child = (root[first] as? [String: Any]) ?? [:]
            setNestedTable(&child, path: Array(path.dropFirst()))
            root[first] = child
        }
    }

    /// Set a value at a specific path + key in the root dictionary
    private static func setValue(_ root: inout [String: Any], path: [String], key: String, value: Any, lineNumber: Int) throws {
        if path.isEmpty {
            root[key] = value
        } else {
            var current = root
            var tables: [[String: Any]] = [current]

            for component in path {
                let child = (current[component] as? [String: Any]) ?? [:]
                tables.append(child)
                current = child
            }

            // Set the value in the leaf table
            var leaf = tables.last!
            leaf[key] = value

            // Rebuild path from leaf to root
            for i in stride(from: path.count - 1, through: 0, by: -1) {
                var parent = tables[i]
                parent[path[i]] = leaf
                leaf = parent
            }

            root = leaf
        }
    }
}

#endif
