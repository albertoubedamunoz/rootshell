//
//  PathCompletion.swift
//  rootshell
//
//  Pure path arithmetic for the Open in Folder palette: what the typed text
//  means, how candidates rank, and what Tab writes back.
//

import Foundation

nonisolated enum PathCompletion {
    struct Split: Equatable, Sendable {
        /// The directory whose children are candidates. Absolute, `~user`, or
        /// (when no cwd is known) `~`-relative.
        let directory: String
        /// The partial last component to filter by.
        let prefix: String
    }

    enum MatchRank: Int, Comparable, Sendable {
        case subsequence = 1
        case substring
        case prefix
        case exact

        static func < (lhs: MatchRank, rhs: MatchRank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: Path arithmetic

    /// Lexical normalization: collapses `//`, resolves `.` and `..`, strips a
    /// trailing slash. Absolute paths clamp at `/`; relative ones keep leading
    /// `..`; a `~user` anchor is treated like a root. Never touches the filesystem.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let absolute = path.hasPrefix("/")
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var anchor: String?
        if !absolute, let first = components.first, first.hasPrefix("~") {
            anchor = first
            components.removeFirst()
        }
        var out: [String] = []
        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                if let last = out.last, last != ".." {
                    out.removeLast()
                } else if !absolute && anchor == nil {
                    out.append("..")
                }
            default:
                out.append(component)
            }
        }
        if absolute { return "/" + out.joined(separator: "/") }
        if let anchor { return out.isEmpty ? anchor : anchor + "/" + out.joined(separator: "/") }
        return out.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" || normalized.isEmpty { return normalized }
        guard let slash = normalized.lastIndex(of: "/") else {
            return normalized.hasPrefix("~") ? normalized : ""
        }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    /// Only a bare `~` or a `~/` prefix expands; `~user` is left for the shell.
    static func expandTilde(_ text: String, home: String) -> String {
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home + String(text.dropFirst()) }
        return text
    }

    /// Whether the text names a directory outright rather than a partial entry.
    static func endsWithSeparator(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if text.hasSuffix("/") || text == "~" || text == "." || text == ".." { return true }
        let last = text.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? text
        if last == "." || last == ".." { return true }
        return text.hasPrefix("~") && !text.contains("/")
    }

    /// Splits typed text into the directory to list and the prefix to filter.
    static func split(_ text: String, cwd: String, home: String) -> Split {
        if text.isEmpty { return Split(directory: normalize(cwd), prefix: "") }
        let expanded = expandTilde(text, home: home)
        let resolved: String
        if expanded.hasPrefix("/") || expanded.hasPrefix("~") {
            resolved = expanded
        } else {
            resolved = join(cwd, expanded)
        }
        if endsWithSeparator(text) {
            return Split(directory: normalize(resolved), prefix: "")
        }
        guard let slash = resolved.lastIndex(of: "/") else {
            return Split(directory: normalize(cwd), prefix: resolved)
        }
        let prefix = String(resolved[resolved.index(after: slash)...])
        let directory = String(resolved[..<slash])
        return Split(directory: directory.isEmpty ? "/" : normalize(directory), prefix: prefix)
    }

    /// `~`-abbreviated form for display.
    static func displayPath(_ absolute: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return absolute }
        if absolute == home { return "~" }
        if absolute.hasPrefix(home + "/") { return "~" + absolute.dropFirst(home.count) }
        return absolute
    }

    // MARK: Ranking

    static func rank(_ prefix: String, against name: String) -> MatchRank? {
        if prefix.isEmpty { return .prefix }
        let needle = prefix.lowercased()
        let haystack = name.lowercased()
        if haystack == needle { return .exact }
        if haystack.hasPrefix(needle) { return .prefix }
        if haystack.contains(needle) { return .substring }
        guard needle.count >= 2 else { return nil }
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let candidate = iterator.next() {
                if candidate == character { found = true; break }
            }
            if !found { return nil }
        }
        return .subsequence
    }

    /// Matching names, best first; dotfolders sink unless the prefix asks for them.
    static func rankedFolders(_ names: [String], prefix: String) -> [String] {
        let wantsDot = prefix.hasPrefix(".")
        let scored: [(name: String, rank: MatchRank, dotPenalty: Bool)] = names.compactMap { name in
            guard let rank = rank(prefix, against: name) else { return nil }
            return (name, rank, name.hasPrefix(".") && !wantsDot)
        }
        return scored.sorted { lhs, rhs in
            if lhs.dotPenalty != rhs.dotPenalty { return !lhs.dotPenalty }
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.name)
    }

    // MARK: Completion

    /// The field text after accepting `name` under `directory`, keeping the
    /// user's `~`, absolute, or cwd-relative style. Always ends with `/`.
    static func completedText(directory: String, name: String, originalText: String, cwd: String, home: String) -> String {
        let full = normalize(join(directory, name))
        if directory.hasPrefix("~") && !directory.hasPrefix("~/") { return full + "/" }
        if originalText.hasPrefix("~") { return displayPath(full, home: home) + "/" }
        if originalText.hasPrefix("/") { return full + "/" }
        let base = normalize(cwd)
        if !base.isEmpty, base != "/", full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1)) + "/"
        }
        return full + "/"
    }
}
