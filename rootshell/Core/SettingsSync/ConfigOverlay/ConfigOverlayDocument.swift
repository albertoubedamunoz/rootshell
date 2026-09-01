//
//  ConfigOverlayDocument.swift
//  rootshell
//
//  Line-level model of one config file for comment-preserving edits: replace
//  a key's effective line(s), comment a key out, or append a new key.
//

import Foundation

nonisolated struct ConfigOverlayDocument {
    private(set) var lines: [String]
    let lineEnding: String
    let hadTrailingNewline: Bool

    init(text: String) {
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        hadTrailingNewline = text.hasSuffix("\n")
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var split = body.components(separatedBy: lineEnding)
        if hadTrailingNewline, split.last == "" { split.removeLast() }
        lines = split
    }

    var text: String {
        lines.joined(separator: lineEnding) + (hadTrailingNewline || !lines.isEmpty ? lineEnding : "")
    }

    /// 1-based line numbers of uncommented entries for `configKey`, in order.
    func lineNumbers(for configKey: String) -> [Int] {
        var out: [Int] = []
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if key == configKey { out.append(index + 1) }
        }
        return out
    }

    /// Replace the key's effective occurrence with `values` (one line each).
    /// Scalars use the last occurrence; lists use the first contiguous block.
    /// Other occurrences are removed. Appends when the key is absent.
    mutating func set(configKey: String, values: [String]) {
        let numbers = lineNumbers(for: configKey)
        let newLines = values.map { ConfigOverlayCodec.line(configKey: configKey, value: $0) }
        guard let first = numbers.first else {
            append(newLines)
            return
        }
        let block: ClosedRange<Int>
        if values.count > 1 || numbers.count > 1, isContiguous(numbers) {
            block = first...numbers.last!
        } else if values.count <= 1 {
            let last = numbers.last!
            block = last...last
        } else {
            block = first...first
        }
        let others = numbers.filter { !block.contains($0) }
        // Replace the block, then delete stray duplicates from the bottom up.
        lines.replaceSubrange((block.lowerBound - 1)..<block.upperBound, with: newLines)
        let shift = newLines.count - block.count
        for number in others.sorted(by: >) {
            let index = number > block.upperBound ? number - 1 + shift : number - 1
            if lines.indices.contains(index) { lines.remove(at: index) }
        }
    }

    /// Turn every uncommented occurrence into a comment.
    mutating func commentOut(configKey: String) {
        for number in lineNumbers(for: configKey) {
            lines[number - 1] = "# " + lines[number - 1]
        }
    }

    private mutating func append(_ newLines: [String]) {
        if let last = lines.last, !last.isEmpty { lines.append("") }
        if !lines.contains(where: { $0.hasPrefix("# Added by rootshell Settings") }) {
            lines.append("# Added by rootshell Settings")
        }
        lines.append(contentsOf: newLines)
    }

    private func isContiguous(_ numbers: [Int]) -> Bool {
        guard let first = numbers.first, let last = numbers.last else { return true }
        return last - first + 1 == numbers.count
    }
}
