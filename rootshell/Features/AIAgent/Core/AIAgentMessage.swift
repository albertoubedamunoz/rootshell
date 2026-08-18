#if !CHINA_BUILD
//
//  AIAgentMessage.swift
//  rootshell
//
//  Message models for AI Agent conversations
//

import Foundation

/// Thinking content with optional signature for API round-trip
struct AIThinkingBlock: Sendable, Equatable {
    let content: String
    let signature: String?  // nil means strip when sending back to API
}

/// A message in the AI Agent conversation
struct AIAgentMessage: Identifiable, Sendable {
    let id: UUID
    let role: Role
    let content: Content
    let timestamp: Date

    // Cached parsed results (computed once at init for scroll performance)
    private let _cachedDisplayText: String?
    private let _cachedThinkingContent: String?

    /// Message role
    enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    /// Message content types
    enum Content: Sendable {
        /// Plain text message (may contain <think> tags for display parsing)
        case text(String)

        /// Text message with structured thinking content (preserves signature for API round-trip)
        case textWithThinking(text: String, thinking: AIThinkingBlock)

        /// Tool call request from assistant
        case toolCall(AIToolCall)

        /// Tool result (command output or error)
        /// isFromXMLToolCall: true if this is a result for an XML-parsed tool call (send as text, not structured)
        case toolResult(toolCallId: String, output: String, isError: Bool, isFromXMLToolCall: Bool = false)

        /// Multiple tool calls in one message (with optional preceding text for display and API round-trip)
        /// Includes thinking block for API round-trip when extended thinking is enabled
        case toolCalls([AIToolCall], precedingText: String?, thinking: AIThinkingBlock?)

        /// Multiple tool results in one message (batched response to parallel tool calls)
        /// Anthropic API requires all results for a batch in a single user message
        case toolResults([AIToolResult])
    }

    // MARK: - Initializers

    init(id: UUID = UUID(), role: Role, content: Content, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp

        // Pre-compute display text and thinking content at creation time
        // This eliminates 3 parser calls per render during scrolling
        switch content {
        case .text(let text):
            let thinkingResult = ThinkingParser.parse(text)
            let withoutMiniMax = MiniMaxToolCallParser.parse(thinkingResult.text).remainingText
            self._cachedDisplayText = TextToolCallParser.parse(withoutMiniMax).remainingText
            self._cachedThinkingContent = thinkingResult.thinking

        case .textWithThinking(let text, let thinking):
            // For structured thinking, the text is already clean
            self._cachedDisplayText = text
            self._cachedThinkingContent = thinking.content

        case .toolResult(_, let output, _, _):
            // Parse tool result output for display
            let thinkingResult = ThinkingParser.parse(output)
            let withoutMiniMax = MiniMaxToolCallParser.parse(thinkingResult.text).remainingText
            self._cachedDisplayText = TextToolCallParser.parse(withoutMiniMax).remainingText
            self._cachedThinkingContent = nil

        case .toolCall, .toolCalls, .toolResults:
            self._cachedDisplayText = nil
            self._cachedThinkingContent = nil
        }
    }

    // MARK: - Convenience Factories

    /// Create a user message
    static func user(_ text: String) -> AIAgentMessage {
        AIAgentMessage(role: .user, content: .text(text))
    }

    /// Create an assistant text message
    static func assistant(_ text: String) -> AIAgentMessage {
        AIAgentMessage(role: .assistant, content: .text(text))
    }

    /// Create an assistant message with optional thinking content
    static func assistant(_ text: String, thinking: AIThinkingBlock?) -> AIAgentMessage {
        if let thinking = thinking {
            return AIAgentMessage(role: .assistant, content: .textWithThinking(text: text, thinking: thinking))
        }
        return AIAgentMessage(role: .assistant, content: .text(text))
    }

    /// Create a system message
    static func system(_ text: String) -> AIAgentMessage {
        AIAgentMessage(role: .system, content: .text(text))
    }

    /// Create an assistant message with tool calls (and optional preceding text and thinking)
    static func assistantToolCalls(_ calls: [AIToolCall], precedingText: String? = nil, thinking: AIThinkingBlock? = nil) -> AIAgentMessage {
        AIAgentMessage(role: .assistant, content: .toolCalls(calls, precedingText: precedingText, thinking: thinking))
    }

    /// Create a tool result message
    static func toolResult(toolCallId: String, output: String, isError: Bool = false, isFromXMLToolCall: Bool = false) -> AIAgentMessage {
        AIAgentMessage(role: .tool, content: .toolResult(toolCallId: toolCallId, output: output, isError: isError, isFromXMLToolCall: isFromXMLToolCall))
    }

    /// Create a batched tool results message (multiple results in one message for API)
    static func toolResults(_ results: [AIToolResult]) -> AIAgentMessage {
        AIAgentMessage(role: .tool, content: .toolResults(results))
    }

    // MARK: - Computed Properties

    /// Extract text content if available (raw, may contain <think> tags for legacy .text case)
    var textContent: String? {
        switch content {
        case .text(let text):
            return text
        case .textWithThinking(let text, _):
            return text
        case .toolResult(_, let output, _, _):
            return output
        default:
            return nil
        }
    }

    /// Parse and extract display text (with thinking and text-based tool calls removed)
    /// Returns cached value computed at init for scroll performance
    var displayText: String? {
        _cachedDisplayText
    }

    /// Parse and extract thinking content if present
    /// Returns cached value computed at init for scroll performance
    var thinkingContent: String? {
        _cachedThinkingContent
    }

    /// Whether this is a user message
    var isUser: Bool {
        role == .user
    }

    /// Whether this is an assistant message
    var isAssistant: Bool {
        role == .assistant
    }

    /// Whether this message contains tool calls
    var hasToolCalls: Bool {
        switch content {
        case .toolCall, .toolCalls:
            return true
        default:
            return false
        }
    }

    /// Get tool calls if present
    var toolCalls: [AIToolCall]? {
        switch content {
        case .toolCall(let call):
            return [call]
        case .toolCalls(let calls, _, _):
            return calls
        default:
            return nil
        }
    }

    /// Get preceding text for tool calls if present
    var toolCallPrecedingText: String? {
        switch content {
        case .toolCalls(_, let text, _):
            return text
        default:
            return nil
        }
    }
}

/// A tool call requested by the AI
struct AIToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    let arguments: String  // JSON string
    let isFromXMLParsing: Bool  // True if parsed from MiniMax XML format
    let thoughtSignature: String?  // Gemini 3.0+ thought signature for function calls

    nonisolated init(id: String, name: String, arguments: String, isFromXMLParsing: Bool = false, thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.isFromXMLParsing = isFromXMLParsing
        self.thoughtSignature = thoughtSignature
    }

    /// Parse arguments as a dictionary
    nonisolated func parseArguments() -> [String: Any]? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Get a specific argument value
    nonisolated func argument<T>(_ key: String) -> T? {
        parseArguments()?[key] as? T
    }
}

/// A tool result to be sent back to the AI
struct AIToolResult: Sendable {
    let toolCallId: String
    let output: String
    let isError: Bool
    let isFromXMLToolCall: Bool

    init(toolCallId: String, output: String, isError: Bool, isFromXMLToolCall: Bool = false) {
        self.toolCallId = toolCallId
        self.output = output
        self.isError = isError
        self.isFromXMLToolCall = isFromXMLToolCall
    }
}

/// Tool definition for the LLM
struct AIAgentTool: Sendable {
    let name: String
    let description: String
    let parameters: AIToolParameters

    /// Standard execute_command tool
    static let executeCommand = AIAgentTool(
        name: "execute_command",
        description: "Execute a shell command on the remote server. You MUST use this tool for ALL commands - never write commands in text without calling this tool. The user approves commands via UI before execution.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "command": AIToolParameter(
                    type: "string",
                    description: "The shell command to execute"
                ),
                "reason": AIToolParameter(
                    type: "string",
                    description: "Brief explanation of why this command is needed (1-2 sentences)"
                ),
                "operation_type": AIToolParameter(
                    type: "string",
                    description: "Whether this command reads or writes data. Use 'read' for commands that only inspect/view (ls, cat, grep, ps, df, find, head, tail, stat). Use 'write' for commands that modify state (rm, mv, cp, mkdir, chmod, chown, apt install, systemctl start/stop, kill). If unsure, use 'write'.",
                    enumValues: ["read", "write"]
                )
            ],
            required: ["command"]
        )
    )

    /// Ask user tool for structured user input
    static let askUser = AIAgentTool(
        name: "ask_user",
        description: "Ask the user a question and wait for their response. Use this when you need clarification, confirmation, or input from the user before proceeding. The question will be displayed in a structured UI card.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "question": AIToolParameter(
                    type: "string",
                    description: "The question to ask the user. Be clear and concise."
                ),
                "input_type": AIToolParameter(
                    type: "string",
                    description: "The type of input expected: yes_no for binary approval, single_choice to select one option, multi_choice to select multiple options, text for free-form input.",
                    enumValues: ["yes_no", "single_choice", "multi_choice", "text"]
                ),
                "options": AIToolParameter(
                    type: "array",
                    description: "Options for single_choice or multi_choice input types. Required for those types, ignored for yes_no and text.",
                    items: AIToolParameter(type: "string", description: "An option string")
                ),
                "placeholder": AIToolParameter(
                    type: "string",
                    description: "Optional placeholder text for text input type."
                ),
                "context": AIToolParameter(
                    type: "string",
                    description: "Optional additional context or explanation to help the user answer."
                )
            ],
            required: ["question", "input_type"]
        )
    )

    /// Web search tool for searching the internet
    static let webSearch = AIAgentTool(
        name: "web_search",
        description: "Search the internet. Returns relevant results with titles, URLs, and snippets. Use this to find information, documentation, tutorials, or answers to questions about technologies, configurations, error messages, or best practices.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "query": AIToolParameter(
                    type: "string",
                    description: "The search query. Be specific and include relevant keywords."
                ),
                "max_results": AIToolParameter(
                    type: "integer",
                    description: "Maximum number of results to return (1-10, default 5)"
                ),
                "engine": AIToolParameter(
                    type: "string",
                    description: "Search engine to use: 'duckduckgo' (default, privacy-focused) or 'google' (comprehensive but may have CAPTCHAs)",
                    enumValues: ["duckduckgo", "google"]
                )
            ],
            required: ["query"]
        )
    )

    /// Read file contents with line numbers
    static let readFile = AIAgentTool(
        name: "read_file",
        description: "Read the contents of a file. Returns numbered lines. Use offset/limit for large files.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "path": AIToolParameter(
                    type: "string",
                    description: "Path to the file to read (relative to working directory or absolute)"
                ),
                "offset": AIToolParameter(
                    type: "integer",
                    description: "Line number to start reading from (1-indexed, default: 1)"
                ),
                "limit": AIToolParameter(
                    type: "integer",
                    description: "Maximum number of lines to read"
                )
            ],
            required: ["path"]
        )
    )

    /// Create or overwrite a file
    static let writeFile = AIAgentTool(
        name: "write_file",
        description: "Create or overwrite a file with the given content. Creates parent directories if needed.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "path": AIToolParameter(
                    type: "string",
                    description: "Path to the file to write (relative to working directory or absolute)"
                ),
                "content": AIToolParameter(
                    type: "string",
                    description: "The full content to write to the file"
                )
            ],
            required: ["path", "content"]
        )
    )

    /// Make a targeted edit to a file
    static let editFile = AIAgentTool(
        name: "edit_file",
        description: "Make a targeted edit by replacing an exact string match. old_string must match exactly including whitespace and line breaks.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "path": AIToolParameter(
                    type: "string",
                    description: "Path to the file to edit (relative to working directory or absolute)"
                ),
                "old_string": AIToolParameter(
                    type: "string",
                    description: "The exact string to find and replace (must match exactly, including whitespace)"
                ),
                "new_string": AIToolParameter(
                    type: "string",
                    description: "The replacement string"
                )
            ],
            required: ["path", "old_string", "new_string"]
        )
    )

    /// List files and directories at a path
    static let listFiles = AIAgentTool(
        name: "list_files",
        description: "List files and directories at a path. Returns names with trailing / for directories.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "path": AIToolParameter(
                    type: "string",
                    description: "Directory path to list (relative to working directory or absolute)"
                )
            ],
            required: ["path"]
        )
    )

    /// Web fetch tool for retrieving page content
    static let webFetch = AIAgentTool(
        name: "web_fetch",
        description: "Fetch and extract the main content from a web page URL. Returns the page title, main text content, and important links. Use after web_search to read full articles, documentation, or tutorials.",
        parameters: AIToolParameters(
            type: "object",
            properties: [
                "url": AIToolParameter(
                    type: "string",
                    description: "The URL to fetch. Must be a complete URL including protocol (e.g., https://example.com/page)"
                ),
                "extract_links": AIToolParameter(
                    type: "boolean",
                    description: "Whether to include links found on the page (default true)"
                )
            ],
            required: ["url"]
        )
    )
}

/// Tool parameter schema
struct AIToolParameters: Sendable {
    let type: String
    let properties: [String: AIToolParameter]
    let required: [String]
}

/// Box wrapper to allow recursive AIToolParameter
final class AIToolParameterBox: @unchecked Sendable {
    let value: AIToolParameter

    init(_ value: AIToolParameter) {
        self.value = value
    }
}

/// Individual tool parameter
struct AIToolParameter: Sendable {
    let type: String
    let description: String
    let enumValues: [String]?
    let items: AIToolParameterBox?  // For array types (boxed to allow recursion)

    init(type: String, description: String, enumValues: [String]? = nil, items: AIToolParameter? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items.map { AIToolParameterBox($0) }
    }
}

// MARK: - Usage Stats

/// Token usage statistics from API
struct AIUsageStats: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}
#endif
