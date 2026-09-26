//
//  DictationVocabulary.swift
//  rootshell
//
//  Vocabulary boost terms: the user's list plus identifiers read from the
//  visible terminal, each with the spoken forms that should map to it.
//

import Foundation

nonisolated enum DictationVocabulary {
    struct Entry: Equatable, Hashable, Sendable {
        var term: String
        var aliases: [String]
    }

    /// Parses `term: alias, alias`.
    static func parse(_ line: String) -> Entry? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let term = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !term.isEmpty else { return nil }
        let aliases = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return Entry(term: term, aliases: aliases)
    }

    static func line(for entry: Entry) -> String {
        entry.aliases.isEmpty ? entry.term : "\(entry.term): \(entry.aliases.joined(separator: ", "))"
    }

    /// Identifiers on screen that plain speech would never spell right:
    /// camelCase, snake_case, kebab-case and file names. Most recent first.
    static func screenTerms(from text: String, limit: Int = 40) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        let tokens = text.split { !($0.isLetter || $0.isNumber || "_-.".contains($0)) }
        for token in tokens.reversed() {
            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            guard word.count >= 4, word.count <= 40, word.first?.isLetter == true,
                  let aliases = spokenForms(of: word), seen.insert(word.lowercased()).inserted else { continue }
            result.append(Entry(term: word, aliases: aliases))
            if result.count == limit { break }
        }
        return result
    }

    /// How an identifier is said aloud, or nil when it is an ordinary word.
    static func spokenForms(of word: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for char in word {
            if char == "." {
                if !current.isEmpty { parts.append(current); current = "" }
                parts.append("dot")
            } else if char == "_" || char == "-" {
                if !current.isEmpty { parts.append(current); current = "" }
            } else if char.isUppercase, let prev = previous, prev.isLowercase || prev.isNumber {
                parts.append(current); current = String(char)
            } else {
                current.append(char)
            }
            previous = char
        }
        if !current.isEmpty { parts.append(current) }
        let words = parts.map { $0.lowercased() }.filter { !$0.isEmpty }
        // A single plain word gains nothing from boosting.
        guard words.count > 1, words.contains(where: { $0.count > 1 }) else { return nil }
        return [words.joined(separator: " ")]
    }
}
