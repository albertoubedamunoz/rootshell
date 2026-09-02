//
//  GhosttyConfigParser.swift
//  rootshell
//
//  Pure parser for the Ghostty config file format. Strips comments, trims
//  `key = value`, unwraps quotes, and yields entries in source order so
//  repeatable keys (font-family, font-feature, palette, keybind) are preserved.
//
//  Format reference: comments start with `#`, values are `key = value` with
//  optional whitespace around `=`, quoted values keep their interior, blank
//  lines are skipped. Includes (`config-file = path`) are parsed as ordinary
//  entries — the importer resolves them.
//

import Foundation

nonisolated enum GhosttyConfigParser {
    static func parse(_ contents: String, sourceFile: URL) -> [ParsedConfigEntry] {
        var entries: [ParsedConfigEntry] = []

        // Strip UTF-8 BOM if present (Ghostty does the same).
        var body = contents
        if body.hasPrefix("\u{FEFF}") {
            body.removeFirst()
        }

        let rawLines = body.components(separatedBy: .newlines)
        for (idx, raw) in rawLines.enumerated() {
            let lineNumber = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[trimmed.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let rawValue = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)

            guard !key.isEmpty else { continue }

            entries.append(
                ParsedConfigEntry(
                    key: key,
                    value: value,
                    sourceFile: sourceFile,
                    lineNumber: lineNumber
                )
            )
        }

        return entries
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
