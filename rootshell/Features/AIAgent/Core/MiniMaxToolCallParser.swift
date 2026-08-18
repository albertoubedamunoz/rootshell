#if !CHINA_BUILD
//
//  MiniMaxToolCallParser.swift
//  rootshell
//
//  Parser for extracting tool calls from MiniMax's XML format
//

import Foundation

/// Parser for MiniMax's XML-based tool call format
/// Handles: <minimax:tool_call><invoke name="..."><parameter name="...">value</parameter></invoke></minimax:tool_call>
struct MiniMaxToolCallParser {
    /// Result of parsing a model response for MiniMax tool calls
    struct ParseResult: Sendable {
        let toolCalls: [AIToolCall]
        let remainingText: String  // Text with XML tags removed
    }

    // MARK: - Cached Regex Patterns (compiled once at startup)

    /// Matches complete tool call blocks: <minimax:tool_call>...</minimax:tool_call>
    nonisolated private static let blockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<minimax:tool_call>([\s\S]*?)</minimax:tool_call>"#)
    }()

    /// Matches complete blocks for streaming removal
    nonisolated private static let completeBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<minimax:tool_call>[\s\S]*?</minimax:tool_call>"#)
    }()

    /// Matches incomplete blocks (no closing tag yet)
    nonisolated private static let incompleteBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<minimax:tool_call>[\s\S]*$"#)
    }()

    /// Matches <invoke name="...">...</invoke> elements
    nonisolated private static let invokeRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<invoke\s+name="([^"]+)"[^>]*>([\s\S]*?)</invoke>"#)
    }()

    /// Matches <parameter name="...">...</parameter> elements
    nonisolated private static let paramRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<parameter\s+name="([^"]+)"[^>]*>([\s\S]*?)</parameter>"#)
    }()

    /// Extract tool calls from MiniMax XML format
    /// - Parameter text: Raw model output text
    /// - Returns: Extracted tool calls and remaining text for display
    nonisolated static func parse(_ text: String) -> ParseResult {
        guard let blockRegex = blockRegex else {
            return ParseResult(toolCalls: [], remainingText: text)
        }

        var allToolCalls: [AIToolCall] = []
        var cleanText = text

        // Find all tool call blocks
        let blockMatches = blockRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for blockMatch in blockMatches {
            if let blockContentRange = Range(blockMatch.range(at: 1), in: text) {
                let blockContent = String(text[blockContentRange])
                let toolCalls = parseInvocations(blockContent)
                allToolCalls.append(contentsOf: toolCalls)
            }
        }

        // Remove all tool call blocks from display text
        cleanText = blockRegex.stringByReplacingMatches(
            in: cleanText,
            range: NSRange(cleanText.startIndex..., in: cleanText),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return ParseResult(toolCalls: allToolCalls, remainingText: cleanText)
    }

    /// Parse individual <invoke> elements within a tool_call block
    nonisolated private static func parseInvocations(_ blockContent: String) -> [AIToolCall] {
        guard let invokeRegex = invokeRegex else {
            return []
        }

        var toolCalls: [AIToolCall] = []
        let matches = invokeRegex.matches(in: blockContent, range: NSRange(blockContent.startIndex..., in: blockContent))

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: blockContent),
                  let paramsRange = Range(match.range(at: 2), in: blockContent) else {
                continue
            }

            let toolName = String(blockContent[nameRange])
            let paramsContent = String(blockContent[paramsRange])
            let arguments = parseParameters(paramsContent)

            // Generate a unique ID for this tool call
            let toolCallId = "minimax_\(UUID().uuidString.prefix(8))"

            toolCalls.append(AIToolCall(
                id: toolCallId,
                name: toolName,
                arguments: arguments,
                isFromXMLParsing: true
            ))
        }

        return toolCalls
    }

    /// Parse <parameter> elements and convert to JSON string
    nonisolated private static func parseParameters(_ content: String) -> String {
        guard let paramRegex = paramRegex else {
            return "{}"
        }

        var params: [String: Any] = [:]
        let matches = paramRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: content),
                  let valueRange = Range(match.range(at: 2), in: content) else {
                continue
            }

            let paramName = String(content[nameRange])
            let paramValue = String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to parse as JSON value (for arrays, objects, booleans, numbers)
            if let data = paramValue.data(using: .utf8),
               let jsonValue = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                params[paramName] = jsonValue
            } else {
                // Treat as string
                params[paramName] = paramValue
            }
        }

        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: params, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }

    /// Parse for streaming display - removes both complete and incomplete tool call blocks
    /// Use this during streaming when closing tags may not have arrived yet
    /// - Parameter text: Raw streaming text
    /// - Returns: Cleaned text with all tool call XML removed
    nonisolated static func parseForStreaming(_ text: String) -> String {
        var result = text

        // First remove complete blocks: <minimax:tool_call>...</minimax:tool_call>
        if let completeBlockRegex = completeBlockRegex {
            result = completeBlockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Then remove incomplete blocks: <minimax:tool_call> without closing tag
        if let incompleteBlockRegex = incompleteBlockRegex {
            result = incompleteBlockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
