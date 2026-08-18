#if !CHINA_BUILD
//
//  ThinkingParser.swift
//  rootshell
//
//  Utility for parsing chain-of-thought reasoning tags from model output
//

import Foundation

/// Parser for extracting thinking/reasoning content from model responses
struct ThinkingParser {
    /// Result of parsing a model response
    struct ParsedResponse: Sendable {
        let text: String
        let thinking: String?
    }

    /// Extract thinking content and clean text from model output
    /// Handles: <think>...</think>, <thinking>...</thinking>, and incomplete <think>... blocks
    /// - Parameter text: Raw model output text
    /// - Returns: Cleaned text and extracted thinking content
    nonisolated static func parse(_ text: String) -> ParsedResponse {
        var thinkingParts: [String] = []
        var cleanText = text

        // First extract complete blocks: <think>content</think> or <thinking>content</thinking>
        let completePattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#
        if let completeRegex = try? NSRegularExpression(pattern: completePattern, options: [.caseInsensitive]) {
            let matches = completeRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let thinkingRange = Range(match.range(at: 1), in: text) {
                    let content = String(text[thinkingRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        thinkingParts.append(content)
                    }
                }
            }
            cleanText = completeRegex.stringByReplacingMatches(
                in: cleanText,
                range: NSRange(cleanText.startIndex..., in: cleanText),
                withTemplate: ""
            )
        }

        // Then extract incomplete blocks: <think> or <thinking> without closing tag
        // This handles cases where </think> was stripped by another parser
        let incompletePattern = #"<think(?:ing)?>([\s\S]*)$"#
        if let incompleteRegex = try? NSRegularExpression(pattern: incompletePattern, options: [.caseInsensitive]) {
            let matches = incompleteRegex.matches(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText))
            for match in matches {
                if let thinkingRange = Range(match.range(at: 1), in: cleanText) {
                    let content = String(cleanText[thinkingRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        thinkingParts.append(content)
                    }
                }
            }
            cleanText = incompleteRegex.stringByReplacingMatches(
                in: cleanText,
                range: NSRange(cleanText.startIndex..., in: cleanText),
                withTemplate: ""
            )
        }

        // Handle orphaned closing tags: </think> without opening tag
        // Some models emit a stray closing tag when thinking is interleaved.
        let orphanedClosePattern = #"</think(?:ing)?>"#
        if let orphanedCloseRegex = try? NSRegularExpression(pattern: orphanedClosePattern, options: [.caseInsensitive]) {
            let cleanRange = NSRange(cleanText.startIndex..., in: cleanText)
            if let match = orphanedCloseRegex.firstMatch(in: cleanText, range: cleanRange),
               let matchRange = Range(match.range, in: cleanText),
               thinkingParts.isEmpty {
                let content = String(cleanText[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    thinkingParts.append(content)
                }
                cleanText = String(cleanText[matchRange.upperBound...])
            }
            cleanText = orphanedCloseRegex.stringByReplacingMatches(
                in: cleanText,
                range: NSRange(cleanText.startIndex..., in: cleanText),
                withTemplate: ""
            )
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Combine multiple thinking blocks if present
        let combinedThinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")

        return ParsedResponse(text: cleanText, thinking: combinedThinking)
    }

    /// Result of parsing streaming content
    struct StreamingParseResult: Sendable {
        let displayText: String
        let thinkingText: String?
    }

    /// Parse for streaming display - extracts thinking content and returns clean display text
    /// Handles both complete and incomplete thinking blocks during streaming
    /// - Parameter text: Raw streaming text
    /// - Returns: Clean display text and extracted thinking content
    nonisolated static func parseForStreaming(_ text: String) -> StreamingParseResult {
        var thinkingParts: [String] = []
        var displayText = text

        // First extract and remove complete blocks: <think>...</think> or <thinking>...</thinking>
        let completePattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#
        if let completeRegex = try? NSRegularExpression(pattern: completePattern, options: [.caseInsensitive]) {
            let matches = completeRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let thinkingRange = Range(match.range(at: 1), in: text) {
                    let content = String(text[thinkingRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        thinkingParts.append(content)
                    }
                }
            }
            displayText = completeRegex.stringByReplacingMatches(
                in: displayText,
                range: NSRange(displayText.startIndex..., in: displayText),
                withTemplate: ""
            )
        }

        // Then extract and remove incomplete blocks: <think> or <thinking> without closing tag
        // Pattern matches opening tag and everything after it to end of string
        let incompletePattern = #"<think(?:ing)?>([\s\S]*)$"#
        if let incompleteRegex = try? NSRegularExpression(pattern: incompletePattern, options: [.caseInsensitive]) {
            let matches = incompleteRegex.matches(in: displayText, range: NSRange(displayText.startIndex..., in: displayText))
            for match in matches {
                if let thinkingRange = Range(match.range(at: 1), in: displayText) {
                    let content = String(displayText[thinkingRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        thinkingParts.append(content)
                    }
                }
            }
            displayText = incompleteRegex.stringByReplacingMatches(
                in: displayText,
                range: NSRange(displayText.startIndex..., in: displayText),
                withTemplate: ""
            )
        }

        // Handle orphaned closing tags: </think> without opening tag
        let orphanedClosePattern = #"</think(?:ing)?>"#
        if let orphanedCloseRegex = try? NSRegularExpression(pattern: orphanedClosePattern, options: [.caseInsensitive]) {
            let displayRange = NSRange(displayText.startIndex..., in: displayText)
            if let match = orphanedCloseRegex.firstMatch(in: displayText, range: displayRange),
               let matchRange = Range(match.range, in: displayText),
               thinkingParts.isEmpty {
                let content = String(displayText[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    thinkingParts.append(content)
                }
                displayText = String(displayText[matchRange.upperBound...])
            }
            displayText = orphanedCloseRegex.stringByReplacingMatches(
                in: displayText,
                range: NSRange(displayText.startIndex..., in: displayText),
                withTemplate: ""
            )
        }

        let combinedThinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")
        return StreamingParseResult(
            displayText: displayText.trimmingCharacters(in: .whitespacesAndNewlines),
            thinkingText: combinedThinking
        )
    }
}
#endif
