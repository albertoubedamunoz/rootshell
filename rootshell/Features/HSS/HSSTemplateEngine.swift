//
//  HSSTemplateEngine.swift
//  rootshell
//
//  Template interpolation engine for HSS
//  Parses and evaluates #{...} expressions in template strings
//

import Foundation
import Yams

/// Context for evaluating HSS template expressions
struct HSSEvaluationContext {
    let config: HSSConfig
    let matchResult: HSSMatchResult?
    let documentsDirectory: URL
    let recursionDepth: Int

    static let maxRecursionDepth = 10

    func withIncrementedDepth() throws -> HSSEvaluationContext {
        let newDepth = recursionDepth + 1
        guard newDepth <= Self.maxRecursionDepth else {
            throw HSSError.recursionLimitExceeded(depth: newDepth)
        }
        return HSSEvaluationContext(
            config: config,
            matchResult: matchResult,
            documentsDirectory: documentsDirectory,
            recursionDepth: newDepth
        )
    }
}

/// Parses and evaluates HSS template strings
class HSSTemplateEngine {

    // Cache for external file contents
    private var externalFileCache: [String: Any] = [:]

    // MARK: - Public API

    /// Evaluate a template string with the given context
    func evaluate(template: String, context: HSSEvaluationContext) throws -> String {
        let tokens = tokenize(template)
        var result = ""

        for token in tokens {
            switch token {
            case .text(let text):
                result += text
            case .interpolation(let expression):
                let value = try evaluateExpression(expression, context: context)
                result += value
            }
        }

        return result
    }

    /// Clear the external file cache
    func clearCache() {
        externalFileCache.removeAll()
    }

    // MARK: - Token Types

    private enum Token {
        case text(String)
        case interpolation(String)  // Content inside #{...}
    }

    // MARK: - Tokenization

    /// Split template into text and interpolation tokens
    private func tokenize(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var index = template.startIndex

        while index < template.endIndex {
            // Look for next # character
            guard let hashIndex = template[index...].firstIndex(of: "#") else {
                // No more # characters, add remaining text
                tokens.append(.text(String(template[index...])))
                break
            }

            // Add text before the #
            if hashIndex > index {
                tokens.append(.text(String(template[index..<hashIndex])))
            }

            let afterHash = template.index(after: hashIndex)
            guard afterHash < template.endIndex else {
                // # at end of string
                tokens.append(.text("#"))
                break
            }

            let nextChar = template[afterHash]

            if nextChar == "{" {
                // #{...} interpolation
                let exprStart = template.index(after: afterHash)
                if let closingOffset = findMatchingBrace(in: String(template[exprStart...])) {
                    let exprEnd = template.index(exprStart, offsetBy: closingOffset)
                    let expression = String(template[exprStart..<exprEnd])
                    tokens.append(.interpolation(expression))
                    index = template.index(after: exprEnd)
                } else {
                    // No matching brace, treat as text
                    tokens.append(.text(String(template[hashIndex...])))
                    break
                }
            } else if nextChar == "$" {
                // #$N shorthand for capture groups
                var numEnd = template.index(after: afterHash)
                while numEnd < template.endIndex && template[numEnd].isNumber {
                    numEnd = template.index(after: numEnd)
                }

                if numEnd > template.index(after: afterHash) {
                    // We have digits after #$
                    let numStart = template.index(after: afterHash)
                    let expression = "$" + String(template[numStart..<numEnd])
                    tokens.append(.interpolation(expression))
                    index = numEnd
                } else {
                    // Just #$ with no number, treat as text
                    tokens.append(.text("#$"))
                    index = template.index(after: afterHash)
                }
            } else {
                // Just a # followed by something else, treat as text
                tokens.append(.text("#"))
                index = afterHash
            }
        }

        return tokens
    }

    /// Find the index of the matching closing brace
    private func findMatchingBrace(in text: String) -> Int? {
        var depth = 1
        var index = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"

        for char in text {
            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                default:
                    break
                }
            }
            prevChar = char
            index += 1
        }

        return nil
    }

    // MARK: - Expression Evaluation

    /// Evaluate an expression string
    private func evaluateExpression(_ expr: String, context: HSSEvaluationContext) throws -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)

        // 1. Check for rescue suffix: expr rescue "fallback"
        if let (mainExpr, fallback) = parseRescue(trimmed) {
            do {
                return try evaluateExpression(mainExpr, context: context)
            } catch {
                return fallback
            }
        }

        // 2. Check for "or" operator: expr || fallback (Ruby-style)
        if let (left, right) = splitByOrOperator(trimmed) {
            do {
                let leftValue = try evaluateExpression(left, context: context)
                if !leftValue.isEmpty {
                    return leftValue
                }
            } catch {
                // Left side failed, fall through to right side
            }
            return try evaluateExpression(right, context: context)
        }

        // 3. Check for concatenation: expr + expr
        if let parts = splitByConcatenation(trimmed) {
            var result = ""
            for part in parts {
                result += try evaluateExpression(part, context: context)
            }
            return result
        }

        // 4. Check for function calls
        if let (funcName, args) = parseFunctionCall(trimmed) {
            return try evaluateFunction(funcName, args: args, context: context)
        }

        // 5. Check for capture group references: $1, $2, etc.
        if trimmed.hasPrefix("$"), let index = Int(String(trimmed.dropFirst())) {
            guard let match = context.matchResult,
                  let value = match.captureGroup(index) else {
                throw HSSError.captureGroupNotFound(index: index)
            }
            return value
        }

        // 6. Check for named capture: x["name"]
        if let name = parseNamedCapture(trimmed) {
            guard let match = context.matchResult,
                  let value = match.namedCapture(name) else {
                throw HSSError.namedCaptureNotFound(name: name)
            }
            return value
        }

        // 7. Check for string literal
        if let literal = extractStringLiteral(trimmed) {
            return literal
        }

        // 8. Check for parenthesized expression: (expr)
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            // Verify it's a balanced grouping, not a function call
            let inner = String(trimmed.dropFirst().dropLast())
            if isBalancedParentheses(inner) {
                return try evaluateExpression(inner, context: context)
            }
        }

        // 9. Default to literal value (for simple variable references)
        return trimmed
    }

    // MARK: - Function Evaluation

    private func evaluateFunction(_ name: String, args: [String], context: HSSEvaluationContext) throws -> String {
        switch name {
        case "expand":
            guard args.count == 1 else {
                throw HSSError.invalidExpression(expression: "expand(\(args.joined(separator: ", ")))", reason: "expand() requires exactly 1 argument")
            }
            let key = try evaluateExpression(args[0], context: context)
            guard let value = context.config.expand(key) else {
                throw HSSError.expansionNotFound(key: key)
            }
            return value

        case "shortcut":
            guard args.count == 1 else {
                throw HSSError.invalidExpression(expression: "shortcut(\(args.joined(separator: ", ")))", reason: "shortcut() requires exactly 1 argument")
            }
            let key = try evaluateExpression(args[0], context: context)
            guard let value = context.config.shortcut(key) else {
                throw HSSError.shortcutNotFound(key: key)
            }
            // Recursively evaluate the shortcut value (it may contain #{...} expressions)
            let nestedContext = try context.withIncrementedDepth()
            return try evaluate(template: value, context: nestedContext)

        case "external":
            guard args.count == 2 else {
                throw HSSError.invalidExpression(expression: "external(\(args.joined(separator: ", ")))", reason: "external() requires exactly 2 arguments")
            }
            let path = try evaluateExpression(args[0], context: context)
            let key = try evaluateExpression(args[1], context: context)
            return try evaluateExternal(path: path, key: key, context: context)

        case "default":
            guard args.count == 2 else {
                throw HSSError.invalidExpression(expression: "default(\(args.joined(separator: ", ")))", reason: "default() requires exactly 2 arguments")
            }
            do {
                let value = try evaluateExpression(args[0], context: context)
                if !value.isEmpty {
                    return value
                }
            } catch {
                // Fall through to return fallback
            }
            return try evaluateExpression(args[1], context: context)

        default:
            throw HSSError.invalidExpression(expression: "\(name)(...)", reason: "Unknown function '\(name)'")
        }
    }

    // MARK: - External File Lookup

    private func evaluateExternal(path: String, key: String, context: HSSEvaluationContext) throws -> String {
        // Resolve path relative to Documents folder (iOS sandbox restriction)
        // Paths starting with ~ or / are mapped to Documents folder
        let resolvedPath: URL
        var relativePath = path

        if path.hasPrefix("~/") {
            // Strip ~/ and resolve from Documents (iOS equivalent of home)
            relativePath = String(path.dropFirst(2))
        } else if path.hasPrefix("~") {
            // Strip ~ and resolve from Documents
            relativePath = String(path.dropFirst())
        } else if path.hasPrefix("/") {
            // Absolute paths: use just the filename in Documents
            relativePath = (path as NSString).lastPathComponent
        }

        resolvedPath = context.documentsDirectory.appendingPathComponent(relativePath)

        // Load and cache the file
        let cacheKey = resolvedPath.path
        let yaml: Any

        if let cached = externalFileCache[cacheKey] {
            yaml = cached
        } else {
            guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
                throw HSSError.externalFileNotFound(path: path)
            }

            let content = try String(contentsOf: resolvedPath, encoding: .utf8)
            guard let parsed = try Yams.load(yaml: content) else {
                throw HSSError.configParseError(underlying: NSError(domain: "HSS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Empty YAML file"]))
            }
            yaml = parsed
            externalFileCache[cacheKey] = parsed
        }

        // Navigate to the key using dot notation
        let keyParts = key.split(separator: ".").map(String.init)
        var current: Any = yaml

        for part in keyParts {
            if let dict = current as? [String: Any], let next = dict[part] {
                current = next
            } else if let array = current as? [Any], let index = Int(part), index < array.count {
                current = array[index]
            } else {
                throw HSSError.externalKeyNotFound(path: path, key: key)
            }
        }

        // Convert result to string
        if let string = current as? String {
            return string
        } else if let number = current as? NSNumber {
            return number.stringValue
        } else if current is NSNull {
            // YAML null values should produce empty strings
            return ""
        } else {
            // For other types, convert to string but guard against "nil" output
            let described = String(describing: current)
            return described == "nil" ? "" : described
        }
    }

    // MARK: - Parsing Helpers

    /// Parse rescue expression: "expr rescue fallback"
    private func parseRescue(_ expr: String) -> (main: String, fallback: String)? {
        // Look for " rescue " at top level (not inside strings or parens)
        var depth = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"
        var i = expr.startIndex

        while i < expr.endIndex {
            let char = expr[i]

            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth -= 1
                default:
                    break
                }

                // Check for " rescue " at depth 0
                if depth == 0 {
                    let remaining = String(expr[i...])
                    if remaining.hasPrefix(" rescue ") {
                        let main = String(expr[..<i])
                        let fallbackStart = expr.index(i, offsetBy: 8) // " rescue ".count
                        let fallbackRaw = String(expr[fallbackStart...]).trimmingCharacters(in: .whitespaces)
                        // Handle "rescue nil" as empty string (Ruby-style nil fallback)
                        let fallback: String
                        if fallbackRaw == "nil" {
                            fallback = ""
                        } else {
                            fallback = extractStringLiteral(fallbackRaw) ?? fallbackRaw
                        }
                        return (main.trimmingCharacters(in: .whitespaces), fallback)
                    }
                }
            }

            prevChar = char
            i = expr.index(after: i)
        }

        return nil
    }

    /// Split by + operator at top level
    private func splitByConcatenation(_ expr: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"

        for char in expr {
            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
                current.append(char)
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                    current.append(char)
                case "(", "[", "{":
                    depth += 1
                    current.append(char)
                case ")", "]", "}":
                    depth -= 1
                    current.append(char)
                case "+":
                    if depth == 0 {
                        parts.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                    } else {
                        current.append(char)
                    }
                default:
                    current.append(char)
                }
            }
            prevChar = char
        }

        if !current.isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }

        // Only return if there was actually a split
        return parts.count > 1 ? parts : nil
    }

    /// Check if an expression has balanced parentheses (for grouping detection)
    private func isBalancedParentheses(_ expr: String) -> Bool {
        var depth = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"

        for char in expr {
            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth -= 1
                    if depth < 0 { return false }
                default:
                    break
                }
            }
            prevChar = char
        }

        return depth == 0
    }

    /// Split by || operator at top level (Ruby-style "or")
    /// Returns (left, right) if found, nil otherwise
    private func splitByOrOperator(_ expr: String) -> (left: String, right: String)? {
        var depth = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"
        var i = expr.startIndex

        while i < expr.endIndex {
            let char = expr[i]

            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth -= 1
                case "|":
                    // Check for || at depth 0
                    if depth == 0 {
                        let nextIndex = expr.index(after: i)
                        if nextIndex < expr.endIndex && expr[nextIndex] == "|" {
                            let left = String(expr[..<i]).trimmingCharacters(in: .whitespaces)
                            let rightStart = expr.index(after: nextIndex)
                            let right = String(expr[rightStart...]).trimmingCharacters(in: .whitespaces)
                            return (left, right)
                        }
                    }
                default:
                    break
                }
            }

            prevChar = char
            i = expr.index(after: i)
        }

        return nil
    }

    /// Parse function call: funcName(args)
    private func parseFunctionCall(_ expr: String) -> (name: String, args: [String])? {
        guard let parenStart = expr.firstIndex(of: "("),
              expr.hasSuffix(")") else {
            return nil
        }

        let funcName = String(expr[..<parenStart]).trimmingCharacters(in: .whitespaces)
        guard !funcName.isEmpty, funcName.allSatisfy({ $0.isLetter || $0 == "_" }) else {
            return nil
        }

        let argsStart = expr.index(after: parenStart)
        let argsEnd = expr.index(before: expr.endIndex)
        let argsString = String(expr[argsStart..<argsEnd])

        let args = splitFunctionArgs(argsString)
        return (funcName, args)
    }

    /// Split function arguments by comma at top level
    private func splitFunctionArgs(_ argsString: String) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var stringChar: Character = "\""
        var prevChar: Character = "\0"

        for char in argsString {
            if inString {
                if char == stringChar && prevChar != "\\" {
                    inString = false
                }
                current.append(char)
            } else {
                switch char {
                case "\"", "'":
                    inString = true
                    stringChar = char
                    current.append(char)
                case "(", "[", "{":
                    depth += 1
                    current.append(char)
                case ")", "]", "}":
                    depth -= 1
                    current.append(char)
                case ",":
                    if depth == 0 {
                        args.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                    } else {
                        current.append(char)
                    }
                default:
                    current.append(char)
                }
            }
            prevChar = char
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(current.trimmingCharacters(in: .whitespaces))
        }

        return args
    }

    /// Parse named capture: x["name"]
    private func parseNamedCapture(_ expr: String) -> String? {
        // Pattern: x["name"] or x['name']
        let pattern = #"^x\[["']([^"']+)["']\]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)),
              match.numberOfRanges > 1 else {
            return nil
        }

        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return (expr as NSString).substring(with: range)
    }

    /// Extract string literal value (removes quotes)
    private func extractStringLiteral(_ expr: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }
}
