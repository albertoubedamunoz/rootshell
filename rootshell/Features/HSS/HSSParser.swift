//
//  HSSParser.swift
//  rootshell
//
//  Main HSS parser that coordinates config loading, matching, and expansion
//

import Foundation
import Yams
import os.log

/// Helper to extract detailed error info from Yams
private func describeYamlError(_ error: Error) -> String {
    // Try to get more detail from YamlError
    if let yamlError = error as? YamlError {
        switch yamlError {
        case .no:
            return "No YAML error"
        case .memory:
            return "YAML memory allocation error"
        case .composer(let context, let problem, let mark, _):
            var msg = "YAML composer error at line \(mark.line)"
            if let ctx = context {
                msg += " (\(ctx.description))"
            }
            msg += ": \(problem)"
            return msg
        case .scanner(let context, let problem, let mark, _):
            var msg = "YAML scanner error at line \(mark.line)"
            if let ctx = context {
                msg += " (\(ctx.description))"
            }
            msg += ": \(problem)"
            return msg
        case .parser(let context, let problem, let mark, _):
            var msg = "YAML parser error at line \(mark.line)"
            if let ctx = context {
                msg += " (\(ctx.description))"
            }
            msg += ": \(problem)"
            return msg
        case .reader(let problem, let offset, _, _):
            var msg = "YAML reader error: \(problem)"
            if let off = offset {
                msg += " at offset \(off)"
            }
            return msg
        case .writer(let problem):
            return "YAML writer error: \(problem)"
        case .emitter(let problem):
            return "YAML emitter error: \(problem)"
        case .representer(let problem):
            return "YAML representer error: \(problem)"
        case .dataCouldNotBeDecoded(encoding: let enc):
            return "YAML encoding error: could not decode as \(enc)"
        case .duplicatedKeysInMapping(let duplicates, let context):
            return "YAML duplicate keys error: \(duplicates.joined(separator: ", ")) at \(context.description)"
        }
    }
    return error.localizedDescription
}

/// Main HSS parser that coordinates config loading, matching, and expansion
@MainActor
class HSSParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HSSParser")

    private var config: HSSConfig
    private var compiledPatterns: [(pattern: HSSPattern, regex: NSRegularExpression)] = []
    private let templateEngine: HSSTemplateEngine
    private let documentsDirectory: URL

    init() {
        self.config = HSSConfig()
        self.templateEngine = HSSTemplateEngine()

        // Get Documents directory for external file resolution
        self.documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Configuration Loading

    /// Load HSS config from a file URL
    func loadConfig(from url: URL) throws {
        Self.logger.info("Loading HSS config from: \(url.path)")

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw HSSError.configParseError(underlying: NSError(domain: "HSS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to decode file as UTF-8"]))
        }

        try loadConfigFromString(content)
    }

    /// Load HSS config from a YAML string
    func loadConfigFromString(_ yaml: String) throws {
        Self.logger.info("Parsing HSS YAML config")

        // Parse YAML with duplicate keys allowed (Ruby-style: last value wins)
        let parsed: Any
        do {
            guard let result = try Yams.load(yaml: yaml, allowDuplicateKeys: true) else {
                throw HSSError.invalidConfigStructure(reason: "Empty YAML content")
            }
            parsed = result
        } catch let error as HSSError {
            throw error
        } catch {
            // Wrap Yams parsing error with more context
            let detailedMessage = describeYamlError(error)
            Self.logger.error("Yams parsing error: \(detailedMessage)")
            throw HSSError.yamlParseError(detail: detailedMessage)
        }

        guard let dict = parsed as? [String: Any] else {
            throw HSSError.invalidConfigStructure(reason: "Root must be a dictionary, got \(type(of: parsed))")
        }

        // Parse patterns (be lenient with value types)
        var patterns: [HSSPattern] = []
        if let patternsArray = dict["patterns"] as? [[String: Any]] {
            for (index, patternDict) in patternsArray.enumerated() {
                // Get 'short' - required, convert to string if needed
                let short: String
                if let s = patternDict["short"] as? String {
                    short = s
                } else if let s = patternDict["short"] {
                    short = "\(s)"
                } else {
                    Self.logger.warning("Pattern at index \(index) missing 'short' key, skipping")
                    continue
                }

                // Get 'long' - required, convert to string if needed
                let long: String
                if let l = patternDict["long"] as? String {
                    long = l
                } else if let l = patternDict["long"] {
                    long = "\(l)"
                } else {
                    Self.logger.warning("Pattern at index \(index) missing 'long' key, skipping")
                    continue
                }

                // Get optional fields
                let note: String?
                if let n = patternDict["note"] as? String {
                    note = n
                } else if let n = patternDict["note"] {
                    note = "\(n)"
                } else {
                    note = nil
                }

                let example: String?
                if let e = patternDict["example"] as? String {
                    example = e
                } else if let e = patternDict["example"] {
                    example = "\(e)"
                } else {
                    example = nil
                }

                let pattern = HSSPattern(
                    note: note,
                    example: example,
                    short: short,
                    long: long
                )
                patterns.append(pattern)
            }
        }

        // Parse expansions (be lenient with value types)
        var expansions: [String: [String]]? = nil
        if let expansionsDict = dict["expansions"] as? [String: Any] {
            expansions = [:]
            for (key, value) in expansionsDict {
                if let stringArray = value as? [String] {
                    expansions?[key] = stringArray
                } else if let anyArray = value as? [Any] {
                    // Convert array elements to strings
                    expansions?[key] = anyArray.map { "\($0)" }
                } else if let singleValue = value as? String {
                    expansions?[key] = [singleValue]
                } else {
                    // Convert any other single value to string
                    expansions?[key] = ["\(value)"]
                }
            }
        }

        // Parse shortcuts (be lenient with value types)
        var shortcuts: [String: String]? = nil
        if let shortcutsDict = dict["shortcuts"] as? [String: Any] {
            shortcuts = [:]
            for (key, value) in shortcutsDict {
                // Convert any value type to string
                if let stringValue = value as? String {
                    shortcuts?[key] = stringValue
                } else if let intValue = value as? Int {
                    shortcuts?[key] = String(intValue)
                } else {
                    shortcuts?[key] = "\(value)"
                }
            }
        }

        // Create config
        config = HSSConfig()
        config.patterns = patterns
        config.expansions = expansions
        config.shortcuts = shortcuts

        // Compile patterns
        try compilePatterns()

        Self.logger.info("Loaded HSS config with \(patterns.count) patterns")
    }

    /// Pre-compile regex patterns for efficiency
    private func compilePatterns() throws {
        compiledPatterns = []

        for pattern in config.patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern.short, options: [])
                compiledPatterns.append((pattern, regex))
            } catch {
                throw HSSError.invalidRegex(pattern: pattern.short, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Pattern Matching

    /// Find the first matching pattern for the given input
    func match(input: String) -> HSSMatchResult? {
        let range = NSRange(input.startIndex..., in: input)

        for (pattern, regex) in compiledPatterns {
            if let match = regex.firstMatch(in: input, options: [], range: range) {
                // Verify it's a full match (pattern should cover entire input)
                if match.range.length == input.utf16.count {
                    return HSSMatchResult(pattern: pattern, match: match, input: input)
                }
            }
        }

        return nil
    }

    /// Check if an input string matches any HSS pattern
    func matches(_ input: String) -> Bool {
        match(input: input) != nil
    }

    // MARK: - Expansion

    /// Expand an input string using HSS patterns
    /// Returns the expanded string, or nil if no pattern matched
    func expand(_ input: String) throws -> String? {
        guard let matchResult = match(input: input) else {
            return nil
        }

        let context = HSSEvaluationContext(
            config: config,
            matchResult: matchResult,
            documentsDirectory: documentsDirectory,
            recursionDepth: 0
        )

        let expanded = try templateEngine.evaluate(
            template: matchResult.pattern.long,
            context: context
        )

        Self.logger.info("HSS expanded '\(input)' -> '\(expanded)'")
        return expanded
    }

    // MARK: - Accessors

    /// Get all patterns (for UI display)
    var patterns: [HSSPattern] {
        config.patterns
    }

    /// Get pattern count
    var patternCount: Int {
        config.patterns.count
    }

    /// Check if config is loaded
    var isLoaded: Bool {
        !config.patterns.isEmpty
    }

    /// Clear current config
    func clearConfig() {
        config = HSSConfig()
        compiledPatterns = []
        templateEngine.clearCache()
    }
}
