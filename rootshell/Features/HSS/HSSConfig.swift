//
//  HSSConfig.swift
//  rootshell
//
//  Data structures for HSS (Host Shorthand System) configuration
//

import Foundation

/// Root HSS configuration structure
struct HSSConfig: Codable {
    /// Pattern definitions for hostname expansion
    var patterns: [HSSPattern]

    /// Expansion mappings: full value -> [short forms]
    var expansions: [String: [String]]?

    /// Shortcut mappings: short -> full
    var shortcuts: [String: String]?

    init() {
        self.patterns = []
        self.expansions = nil
        self.shortcuts = nil
    }

    // MARK: - Expansion Helpers

    /// Look up an expansion by short form
    /// Returns the full value if found
    func expand(_ shortForm: String) -> String? {
        guard let expansions = expansions else { return nil }
        for (fullValue, shortForms) in expansions {
            if shortForms.contains(shortForm) {
                return fullValue
            }
        }
        return nil
    }

    /// Look up a shortcut by key
    func shortcut(_ key: String) -> String? {
        shortcuts?[key]
    }
}

/// A single HSS pattern definition
struct HSSPattern: Codable {
    /// Optional human-readable description
    let note: String?

    /// Example usage (for documentation)
    let example: String?

    /// Regex pattern to match against input
    let short: String

    /// Template string to expand when pattern matches
    /// Supports #{...} interpolation
    let long: String

    init(note: String? = nil, example: String? = nil, short: String, long: String) {
        self.note = note
        self.example = example
        self.short = short
        self.long = long
    }
}

/// Result of matching input against an HSS pattern
struct HSSMatchResult {
    /// The pattern that matched
    let pattern: HSSPattern

    /// The regex match result
    let match: NSTextCheckingResult

    /// The original input string
    let input: String

    /// Extract numbered capture group ($1, $2, etc.)
    /// Index 0 is the full match, 1+ are capture groups
    /// Returns nil only if the index is out of bounds (group doesn't exist in pattern)
    /// Returns empty string if the group exists but didn't participate in the match (optional group)
    func captureGroup(_ index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        // Optional groups that didn't match have NSNotFound - return empty string
        guard range.location != NSNotFound else { return "" }
        return (input as NSString).substring(with: range)
    }

    /// Extract named capture group
    /// Returns nil only if the named group doesn't exist
    /// Returns empty string if the group exists but didn't participate in the match
    func namedCapture(_ name: String) -> String? {
        let range = match.range(withName: name)
        // Optional groups that didn't match have NSNotFound - return empty string
        guard range.location != NSNotFound else { return "" }
        return (input as NSString).substring(with: range)
    }

    /// All numbered captures as a dictionary (1-indexed for template compatibility)
    var numberedCaptures: [Int: String] {
        var captures: [Int: String] = [:]
        for i in 0..<match.numberOfRanges {
            if let value = captureGroup(i) {
                captures[i] = value
            }
        }
        return captures
    }
}

/// Result of HSS resolution - parsed SSH connection details
struct HSSResolution {
    /// Target hostname
    var host: String

    /// Target port (default 22)
    var port: Int = 22

    /// Username for target
    var username: String?

    /// Jump host details if ProxyCommand detected
    var jumpHost: String?
    var jumpPort: Int = 22
    var jumpUsername: String?

    /// The raw expanded string from HSS
    var rawExpansion: String

    /// Whether a proxy/jump configuration was detected
    var hasJumpHost: Bool {
        jumpHost != nil
    }
}
