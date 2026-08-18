#if !CHINA_BUILD
//
//  SimpleMarkdownParser.swift
//  rootshell
//
//  Simple block-based markdown parser for AI agent chat rendering.
//  Parses markdown into blocks (headers, code blocks, tables, paragraphs) for SwiftUI rendering.
//

import Foundation

/// Simple block-based markdown parser
/// Identifies headers, code blocks, tables, and paragraphs in a single pass
enum SimpleMarkdownParser {

    /// A parsed markdown block
    struct Block: Identifiable {
        let id: String
        let content: Content

        enum Content {
            case header(level: Int, text: String)
            case codeBlock(language: String?, code: String)
            case table(headers: [String], rows: [[String]])
            case paragraph(text: String)
        }
    }

    /// Parse markdown text into blocks
    /// - Parameter markdown: Raw markdown text
    /// - Returns: Array of parsed blocks
    nonisolated static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var blockCounter = 0

        func nextId(from startIndex: Int) -> String {
            blockCounter += 1
            return "block-\(startIndex)-\(blockCounter)"
        }

        while index < lines.count {
            let line = lines[index]

            // Check for code block start
            if line.hasPrefix("```") {
                let blockStart = index
                let languageStr = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = languageStr.isEmpty ? nil : languageStr
                var codeLines: [String] = []
                index += 1

                // Collect code block content until closing ```
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }

                // Skip closing ``` if present
                if index < lines.count {
                    index += 1
                }

                let code = codeLines.joined(separator: "\n")
                if !code.isEmpty {
                    blocks.append(Block(
                        id: nextId(from: blockStart),
                        content: .codeBlock(language: language, code: code)
                    ))
                }
                continue
            }

            // Check for header (# at start of line)
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                let level = match.1.count
                let text = String(match.2)
                blocks.append(Block(id: nextId(from: index), content: .header(level: level, text: text)))
                index += 1
                continue
            }

            // Check for markdown table start
            // A table starts with a line containing | and is followed by a separator line
            if isTableRow(line), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let blockStart = index
                var tableLines: [String] = []

                // Collect all consecutive table lines
                while index < lines.count && isTableRow(lines[index]) {
                    tableLines.append(lines[index])
                    index += 1
                }

                if let table = parseTable(tableLines) {
                    blocks.append(Block(id: nextId(from: blockStart), content: .table(headers: table.headers, rows: table.rows)))
                }
                continue
            }

            // Accumulate paragraph lines until we hit a header, code block, or table
            var paragraphLines: [String] = []
            let paragraphStart = index
            while index < lines.count {
                let pLine = lines[index]

                // Stop if we hit a code block or header
                if pLine.hasPrefix("```") {
                    break
                }
                if pLine.firstMatch(of: /^#{1,6}\s+/) != nil {
                    break
                }
                // Stop if we hit a table
                if isTableRow(pLine), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                    break
                }

                paragraphLines.append(pLine)
                index += 1
            }

            // Create paragraph block if non-empty
            let paragraphText = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraphText.isEmpty {
                blocks.append(Block(id: nextId(from: paragraphStart), content: .paragraph(text: paragraphText)))
            }
        }

        return blocks
    }

    // MARK: - Table Detection

    /// Check if a line looks like a table row (contains | characters)
    nonisolated private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Must contain at least one | and have some content
        return trimmed.contains("|") && trimmed.count > 1
    }

    /// Check if a line is a table separator (|---|---|)
    nonisolated private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Separator contains |, -, and optionally : for alignment
        // Pattern: |---| or |:--| or |--:| or |:-:|
        guard trimmed.contains("|") && trimmed.contains("-") else { return false }

        // Check that it's mostly dashes, pipes, colons, and spaces
        let allowedChars = CharacterSet(charactersIn: "|-: ")
        return trimmed.unicodeScalars.allSatisfy { allowedChars.contains($0) }
    }

    /// Parse table lines into headers and rows
    nonisolated private static func parseTable(_ lines: [String]) -> (headers: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }

        // First line is header
        let headers = parseTableRow(lines[0])
        guard !headers.isEmpty else { return nil }

        // Second line should be separator - skip it
        // Remaining lines are data rows
        var rows: [[String]] = []
        for i in 2..<lines.count {
            let row = parseTableRow(lines[i])
            if !row.isEmpty {
                rows.append(row)
            }
        }

        return (headers: headers, rows: rows)
    }

    /// Parse a single table row into cells
    nonisolated private static func parseTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Split by | and trim each cell
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }

        // If line starts/ends with |, we'll have empty strings at start/end
        for part in parts {
            // Skip empty parts from leading/trailing pipes
            if !part.isEmpty {
                cells.append(part)
            }
        }

        return cells
    }
}
#endif
