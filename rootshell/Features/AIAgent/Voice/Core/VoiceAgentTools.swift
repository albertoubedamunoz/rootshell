#if !CHINA_BUILD
//
//  VoiceAgentTools.swift
//  rootshell
//
//  Tool declarations for the Gemini Live API voice agent.
//  Defines the 6 tools available during voice sessions.
//

import Foundation

enum VoiceAgentTools {

    /// All function declarations for the Live API setup message.
    static var functionDeclarations: [GeminiLiveSetup.FunctionDeclaration] {
        [getScrollback, getScreenshot, sendKeystrokes, sendPaste, executeSSHCommand, consultExpert]
    }

    // MARK: - Read-Only Tools

    static let getScrollback = GeminiLiveSetup.FunctionDeclaration(
        name: "get_scrollback",
        description: "Get the current terminal screen content. Returns the primary screen with scrollback when at a shell prompt, or the alternate screen content when a TUI app (vim, htop, man, less) is running. ANSI escape sequences are preserved as visible \\x1b notation. Use this to see what the user sees on their terminal.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "lines": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "Number of lines to retrieve. Defaults to visible screen if omitted."
                )
            ],
            required: []
        ),
        behavior: "NON_BLOCKING"
    )

    static let getScreenshot = GeminiLiveSetup.FunctionDeclaration(
        name: "get_screenshot",
        description: "Capture a screenshot of the terminal as a JPEG image. Useful for seeing colors, formatting, and visual layout that ANSI text cannot capture.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [:],
            required: []
        ),
        behavior: "NON_BLOCKING"
    )

    // MARK: - Write Tools (Require Approval)

    static let sendKeystrokes = GeminiLiveSetup.FunctionDeclaration(
        name: "send_keystrokes",
        description: """
            Type keystrokes into the terminal. Use for special keys, shortcuts, TUI navigation, \
            tab completion, or pressing Enter after a paste. Supports plain text \
            and special keys in {braces}: \
            {enter}, {tab}, {escape}, {backspace}, {delete}, {space}, \
            {up}, {down}, {left}, {right}, {home}, {end}, {pageup}, {pagedown}, \
            {f1}-{f12}, {shift+tab}, \
            {ctrl+c}, {ctrl+d}, {ctrl+z}, {ctrl+a}-{ctrl+z}, {alt+letter}. \
            For vim: send {escape} first to ensure normal mode, then type commands. \
            Examples: "ls -la{enter}" types and runs a command. \
            "{escape}:wq{enter}" saves and quits vim. \
            "{escape}:q!{enter}" force-quits vim without saving.
            """,
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "keys": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The keystrokes to send, with special keys in {braces}."
                )
            ],
            required: ["keys"]
        ),
        behavior: "NON_BLOCKING"
    )

    static let sendPaste = GeminiLiveSetup.FunctionDeclaration(
        name: "send_paste",
        description: "Paste literal text into the terminal using Ghostty's native paste handling. Prefer this over keystrokes for commands, quoted text, paths, and especially multi-line content. Paste does not press Enter automatically.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "text": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The text to paste into the terminal."
                )
            ],
            required: ["text"]
        ),
        behavior: "NON_BLOCKING"
    )

    static let executeSSHCommand = GeminiLiveSetup.FunctionDeclaration(
        name: "execute_ssh_command",
        description: "Execute a command on the remote server via a background SSH connection. Returns stdout/stderr and exit code. Use this for commands where you need to process the output programmatically.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "command": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The shell command to execute."
                )
            ],
            required: ["command"]
        ),
        behavior: "NON_BLOCKING"
    )

    // MARK: - Web Tools (Conditional)

    static let webSearch = GeminiLiveSetup.FunctionDeclaration(
        name: "web_search",
        description: "Search the internet for information. Returns relevant results with titles, URLs, and snippets. Use for documentation, error messages, current events, or any information not available on the terminal.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "query": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The search query. Be specific and include relevant keywords."
                ),
                "max_results": GeminiLiveSetup.LivePropertySchema(
                    type: "integer",
                    description: "Maximum number of results to return (1-10, default 5)"
                ),
                "engine": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "Search engine to use",
                    enumValues: ["duckduckgo", "google"]
                )
            ],
            required: ["query"]
        ),
        behavior: "NON_BLOCKING"
    )

    static let webFetch = GeminiLiveSetup.FunctionDeclaration(
        name: "web_fetch",
        description: "Fetch and extract the main content from a web page URL. Returns the page title, text content, and optionally extracted links. Use after web_search to read full page content.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "url": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The complete URL to fetch (must include https:// or http://)"
                ),
                "extract_links": GeminiLiveSetup.LivePropertySchema(
                    type: "boolean",
                    description: "Whether to extract and include links from the page (default true)"
                )
            ],
            required: ["url"]
        ),
        behavior: "NON_BLOCKING"
    )

    /// Web tool declarations, included only when web search is enabled.
    static var webToolDeclarations: [GeminiLiveSetup.FunctionDeclaration] {
        [webSearch, webFetch]
    }

    // MARK: - Hybrid Tool

    static let consultExpert = GeminiLiveSetup.FunctionDeclaration(
        name: "consult_expert",
        description: "Delegate a complex question to a more powerful reasoning model (Gemini Pro) for deeper analysis. Use this when the question requires multi-step reasoning, complex debugging, or architectural analysis that benefits from more thorough thinking.",
        parameters: GeminiLiveSetup.LiveParameterSchema(
            properties: [
                "question": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "The question to send to the expert model."
                ),
                "context": GeminiLiveSetup.LivePropertySchema(
                    type: "string",
                    description: "Relevant terminal output or system context to include with the question."
                )
            ],
            required: ["question"]
        ),
        behavior: "NON_BLOCKING"
    )

    // MARK: - Tool Classification

    /// Whether a tool requires user approval based on the current approval mode.
    static func requiresApproval(_ toolName: String, args: [String: String], mode: CommandApprovalMode) -> Bool {
        switch mode {
        case .yolo:
            return false
        case .approveWritesOnly:
            switch toolName {
            case "get_scrollback", "get_screenshot", "consult_expert", "web_search", "web_fetch":
                return false
            case "send_keystrokes", "send_paste", "execute_ssh_command":
                if toolName == "execute_ssh_command",
                   let command = args["command"] {
                    let analysis = CommandRiskAnalyzer.analyze(command)
                    return analysis.operationType != .read
                }
                return true
            default:
                return true
            }
        case .askAll:
            return true
        }
    }

    /// Risk level for a tool call.
    static func riskLevel(for toolName: String, args: [String: String]) -> AIAgentCommand.RiskLevel {
        switch toolName {
        case "get_scrollback", "get_screenshot", "consult_expert", "web_search", "web_fetch":
            return .low
        case "send_keystrokes":
            // Check for dangerous patterns in keystrokes
            let keys = args["keys"] ?? ""
            if keys.contains("rm ") || keys.contains("sudo ") {
                return .high
            }
            return .medium
        case "send_paste":
            let text = args["text"] ?? ""
            if text.contains("rm ") || text.contains("sudo ") {
                return .high
            }
            return .medium
        case "execute_ssh_command":
            let command = args["command"] ?? ""
            return CommandRiskAnalyzer.analyze(command).level
        default:
            return .medium
        }
    }

    /// Human-readable description of what a tool call will do.
    static func describeToolCall(name: String, args: [String: String]) -> String {
        switch name {
        case "get_scrollback":
            return "Read terminal screen content"
        case "get_screenshot":
            return "Capture terminal screenshot"
        case "send_keystrokes":
            let keys = args["keys"] ?? ""
            let truncated = keys.count > 50 ? String(keys.prefix(50)) + "..." : keys
            return "Type: \(truncated)"
        case "send_paste":
            let text = args["text"] ?? ""
            let lines = text.components(separatedBy: "\n").count
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            let truncated = preview.count > 60 ? String(preview.prefix(60)) + "..." : preview
            return "Paste \(lines) line\(lines == 1 ? "" : "s"): \(truncated)"
        case "execute_ssh_command":
            let command = args["command"] ?? ""
            let truncated = command.count > 60 ? String(command.prefix(60)) + "..." : command
            return "Run: \(truncated)"
        case "consult_expert":
            return "Consulting expert model..."
        case "web_search":
            let query = args["query"] ?? ""
            let truncated = query.count > 50 ? String(query.prefix(50)) + "..." : query
            return "Search: \(truncated)"
        case "web_fetch":
            let url = args["url"] ?? ""
            let truncated = url.count > 50 ? String(url.prefix(50)) + "..." : url
            return "Fetch: \(truncated)"
        default:
            return "Unknown tool: \(name)"
        }
    }
}
#endif
