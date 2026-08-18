#if !CHINA_BUILD
//
//  TextToolCallParser.swift
//  rootshell
//
//  Parser for extracting tool calls from text-based delimiter formats
//  Handles: <|tool_call_begin|> ... <|tool_call_end|> format
//

import Foundation

/// Parser for text-based tool call formats using delimiter markers
/// Handles formats like: <|tool_call_begin|> functions.name:index <|tool_call_argument_begin|> {...} <|tool_call_end|>
struct TextToolCallParser {
    /// Result of parsing a model response for text-based tool calls
    struct ParseResult: Sendable {
        let toolCalls: [AIToolCall]
        let remainingText: String  // Text with markers removed
    }

    // MARK: - Cached Regex Patterns (compiled once at startup)

    /// Matches complete tool call blocks with function name and arguments
    nonisolated private static let blockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<\|tool_call_begin\|>\s*(?:functions\.)?([a-zA-Z_][a-zA-Z0-9_]*)(?::\d+)?\s*<\|tool_call_argument_begin\|>\s*([\s\S]*?)\s*<\|tool_call_end\|>"#)
    }()

    /// Matches complete blocks for streaming removal
    nonisolated private static let completeBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<\|tool_call_begin\|>[\s\S]*?<\|tool_call_end\|>"#)
    }()

    /// Matches incomplete blocks (no closing marker yet)
    nonisolated private static let incompleteBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<\|tool_call_begin\|>[\s\S]*$"#)
    }()

    /// Matches partial markers being streamed in
    nonisolated private static let partialMarkerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<\|tool_call[^>]*$"#)
    }()

    /// Matches <|tool_calls_section_end|> marker (some models emit this after tool calls)
    nonisolated private static let toolCallsSectionEndRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<\|tool_calls_section_end\|>"#)
    }()

    /// Extract tool calls from text-based delimiter format
    /// - Parameter text: Raw model output text
    /// - Returns: Extracted tool calls and remaining text for display
    static func parse(_ text: String) -> ParseResult {
        guard let blockRegex = blockRegex else {
            return ParseResult(toolCalls: [], remainingText: text)
        }

        var allToolCalls: [AIToolCall] = []
        var cleanText = text

        // Find all tool call blocks
        let blockMatches = blockRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for blockMatch in blockMatches {
            guard let nameRange = Range(blockMatch.range(at: 1), in: text),
                  let argsRange = Range(blockMatch.range(at: 2), in: text) else {
                continue
            }

            let toolName = String(text[nameRange])
            let arguments = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Generate a unique ID for this tool call
            let toolCallId = "text_\(UUID().uuidString.prefix(8))"

            // Log the parsed tool call for debugging
            #if DEBUG
            print("[TextToolCallParser] Parsed tool: \(toolName), args: \(arguments.prefix(100))")
            #endif

            allToolCalls.append(AIToolCall(
                id: toolCallId,
                name: toolName,
                arguments: arguments,
                isFromXMLParsing: true  // Treat as text-parsed for tool result handling
            ))
        }

        // Remove all tool call blocks from display text
        cleanText = blockRegex.stringByReplacingMatches(
            in: cleanText,
            range: NSRange(cleanText.startIndex..., in: cleanText),
            withTemplate: ""
        )

        // Remove <|tool_calls_section_end|> marker
        if let toolCallsSectionEndRegex = toolCallsSectionEndRegex {
            cleanText = toolCallsSectionEndRegex.stringByReplacingMatches(
                in: cleanText,
                range: NSRange(cleanText.startIndex..., in: cleanText),
                withTemplate: ""
            )
        }

        return ParseResult(toolCalls: allToolCalls, remainingText: cleanText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parse for streaming display - removes both complete and incomplete tool call blocks
    /// Use this during streaming when closing markers may not have arrived yet
    /// - Parameter text: Raw streaming text
    /// - Returns: Cleaned text with all tool call markers removed
    nonisolated static func parseForStreaming(_ text: String) -> String {
        var result = text

        // First remove complete blocks: <|tool_call_begin|>...<|tool_call_end|>
        if let completeBlockRegex = completeBlockRegex {
            result = completeBlockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Then remove incomplete blocks: <|tool_call_begin|> without closing marker
        if let incompleteBlockRegex = incompleteBlockRegex {
            result = incompleteBlockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Also handle partial markers that might be streaming in
        if let partialMarkerRegex = partialMarkerRegex {
            result = partialMarkerRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Remove <|tool_calls_section_end|> marker
        if let toolCallsSectionEndRegex = toolCallsSectionEndRegex {
            result = toolCallsSectionEndRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
