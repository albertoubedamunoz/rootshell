#if !CHINA_BUILD
//
//  VoiceAgentToolExecutor.swift
//  rootshell
//
//  Executes voice agent tool calls against the terminal and SSH connections.
//  Handles approval flow and delegates to existing AI Agent infrastructure.
//

import Foundation
import UIKit
import os.log

@MainActor
final class VoiceAgentToolExecutor {

    @ObservationIgnored
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VoiceAgentToolExecutor")

    /// The terminal view to interact with for scrollback/keystrokes/screenshots.
    weak var terminalView: Ghostty.TerminalView?

    /// The AI agent executor for SSH command execution.
    var agentExecutor: AIAgentExecutor?

    /// Callback for requesting expert consultation (Gemini Pro).
    var onConsultExpert: ((_ question: String, _ context: String?) async throws -> String)?

    // MARK: - Tool Execution

    /// Execute a tool call and return the result string.
    func execute(_ toolCall: LiveToolCall) async throws -> String {
        try Task.checkCancellation()
        Self.logger.info("Executing tool: \(toolCall.name) args=\(toolCall.args)")
        let result: String
        switch toolCall.name {
        case "get_scrollback":
            result = executeGetScrollback(args: toolCall.args)
        case "get_screenshot":
            result = executeGetScreenshot()
        case "send_keystrokes":
            result = executeSendKeystrokes(args: toolCall.args)
        case "send_paste":
            result = executeSendPaste(args: toolCall.args)
        case "execute_ssh_command":
            result = try await executeSSHCommand(args: toolCall.args)
        case "consult_expert":
            result = try await executeConsultExpert(args: toolCall.args)
        case "web_search":
            result = try await executeWebSearch(args: toolCall.args)
        case "web_fetch":
            result = try await executeWebFetch(args: toolCall.args)
        default:
            result = "Unknown tool: \(toolCall.name)"
        }
        try Task.checkCancellation()
        let preview = result.count > 200 ? String(result.prefix(200)) + "..." : result
        Self.logger.info("Tool \(toolCall.name) result (\(result.count) chars): \(preview)")
        return result
    }

    // MARK: - Read-Only Tools

    private func executeGetScrollback(args: [String: String]) -> String {
        guard let terminal = terminalView,
              let surface = terminal.surface else {
            return "Error: No active terminal"
        }

        let isAlternate = ghostty_surface_is_alternate_active(surface)

        var len: UInt = 0
        let ptr: UnsafePointer<CChar>?
        if isAlternate {
            ptr = ghostty_surface_dump_alternate_screen(surface, &len)
        } else {
            ptr = ghostty_surface_dump_primary_screen(surface, &len)
        }

        guard let ptr else {
            return "Terminal screen is empty"
        }

        let data = Data(bytes: ptr, count: Int(len))
        ghostty_surface_free_dump(ptr, len)

        let rawText = String(data: data, encoding: .utf8) ?? "Unable to decode terminal content"
        let sanitized = Self.sanitizeTerminalContent(rawText)

        if isAlternate {
            return "[alternate screen mode - a TUI application is active]\n\(sanitized)"
        }
        return sanitized
    }

    private func executeGetScreenshot() -> String {
        guard let terminal = terminalView else {
            return "Error: No active terminal"
        }

        let renderer = UIGraphicsImageRenderer(bounds: terminal.bounds)
        let image = renderer.image { _ in
            terminal.drawHierarchy(in: terminal.bounds, afterScreenUpdates: true)
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.7) else {
            return "Error: Failed to capture screenshot"
        }

        let sizeKB = jpegData.count / 1024
        Self.logger.info("Screenshot captured: \(sizeKB)KB")

        // The Live API currently only supports audio responses, so we return a text description.
        // A future enhancement could send the image as inline data in the tool response.
        return "[Screenshot captured: \(Int(terminal.bounds.width))x\(Int(terminal.bounds.height)) pixels, \(sizeKB)KB JPEG. Use get_scrollback for text content.]"
    }

    // MARK: - Write Tools

    private func executeSendKeystrokes(args: [String: String]) -> String {
        guard let keys = args["keys"], !keys.isEmpty else {
            return "Error: No keystrokes specified"
        }

        guard let terminal = terminalView,
              let surface = terminal.surface else {
            return "Error: No active terminal"
        }

        let segments = parseKeystrokes(keys)
        for segment in segments {
            switch segment {
            case .text(let text):
                sendText(text, to: surface)
            case .special(let key):
                sendSpecialKey(key, to: surface)
            }
        }

        let description = keys.count > 80 ? String(keys.prefix(80)) + "..." : keys
        return "Sent keystrokes: \(description)"
    }

    private func executeSendPaste(args: [String: String]) -> String {
        guard let text = args["text"], !text.isEmpty else {
            return "Error: No text specified"
        }

        guard let terminal = terminalView,
              terminal.surface != nil else {
            return "Error: No active terminal"
        }

        guard terminal.insertPastedText(text, recordHistory: false) else {
            return "Error: Paste action failed"
        }

        let lines = text.components(separatedBy: "\n").count
        return "Pasted \(lines) line\(lines == 1 ? "" : "s") of text"
    }

    // MARK: - SSH Execution

    private func executeSSHCommand(args: [String: String]) async throws -> String {
        guard let command = args["command"], !command.isEmpty else {
            return "Error: No command specified"
        }

        guard let executor = agentExecutor else {
            return "Error: No SSH connection available. Use send_keystrokes to type commands into the terminal instead."
        }

        let result = try await executor.execute(command: command, timeout: 30)
        try Task.checkCancellation()
        let output = result.output
        let exitCode = result.exitCode ?? -1
        return "Exit code: \(exitCode)\n\(output)"
    }

    // MARK: - Hybrid Consultation

    private func executeConsultExpert(args: [String: String]) async throws -> String {
        guard let question = args["question"], !question.isEmpty else {
            return "Error: No question specified"
        }

        guard let consultExpert = onConsultExpert else {
            return "Error: Expert consultation not available"
        }

        let context = args["context"]
        let result = try await consultExpert(question, context)
        try Task.checkCancellation()
        return result
    }

    // MARK: - Web Tools

    private func executeWebSearch(args: [String: String]) async throws -> String {
        guard let query = args["query"], !query.isEmpty else {
            return "Error: No search query specified"
        }

        let maxResults = Int(args["max_results"] ?? "") ?? 5
        let engine: SearchEngine
        if let engineStr = args["engine"], let parsed = SearchEngine(rawValue: engineStr) {
            engine = parsed
        } else {
            engine = AICredentialsManager.shared.defaultSearchEngine
        }

        do {
            let results = try await WebBrowserManager.shared.search(
                query: query,
                engine: engine,
                maxResults: min(maxResults, 10)
            )
            try Task.checkCancellation()
            return WebSearchParser.formatSearchResults(results, query: query, engine: engine)
        } catch let error as WebBrowserError {
            return WebSearchParser.formatError(error)
        } catch {
            return "Error searching for '\(query)': \(error.localizedDescription)"
        }
    }

    private func executeWebFetch(args: [String: String]) async throws -> String {
        guard let urlString = args["url"], !urlString.isEmpty else {
            return "Error: No URL specified"
        }

        let extractLinks = args["extract_links"]?.lowercased() != "false"

        do {
            let content = try await WebBrowserManager.shared.fetch(
                urlString: urlString,
                extractLinks: extractLinks
            )
            try Task.checkCancellation()
            return WebSearchParser.formatPageContent(content, includeLinks: extractLinks)
        } catch let error as WebBrowserError {
            return WebSearchParser.formatError(error)
        } catch {
            return "Error fetching '\(urlString)': \(error.localizedDescription)"
        }
    }

    // MARK: - Text Sanitization

    /// Escape control characters into visible `\xHH` hex representations so the
    /// LLM can still interpret ANSI sequences while the JSON payload stays valid.
    /// Keeps TAB (U+0009) and LF (U+000A) as-is since they're JSON-safe and meaningful.
    private nonisolated static func sanitizeTerminalContent(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.utf8.count)
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                // Keep tab and newline as-is
                result.append(Character(scalar))
            case 0x00...0x1F, 0x7F:
                // Escape all other control chars to visible hex
                result.append(String(format: "\\x%02x", scalar.value))
            default:
                result.append(Character(scalar))
            }
        }
        return result
    }

    // MARK: - Surface Key Event Helpers

    /// Send a single key press+release event via ghostty_surface_key.
    /// This bypasses bracketed paste mode, so the terminal processes each
    /// keystroke as if typed on a real keyboard.
    private func sendKeyEvent(
        hidUsage: UIKeyboardHIDUsage,
        text: String?,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        to surface: ghostty_surface_t
    ) {
        guard let nativeKeyCode = Ghostty.Input.nativeKeyCode(for: hidUsage) else { return }
        let inputMods = Ghostty.Input.Mods(cMods: mods)

        let press = Ghostty.Input.KeyEvent(
            nativeKeyCode: nativeKeyCode,
            action: .press,
            text: text,
            mods: inputMods
        )
        press.withCValue { ghostty_surface_key(surface, $0) }

        let release = Ghostty.Input.KeyEvent(
            nativeKeyCode: nativeKeyCode,
            action: .release,
            mods: inputMods
        )
        release.withCValue { ghostty_surface_key(surface, $0) }
    }

    /// Send text as raw bytes via sendUserInput, the same I/O path as the real keyboard.
    /// Newlines are converted to CR (0x0D) matching Enter key behavior.
    private func sendText(_ text: String, to surface: ghostty_surface_t) {
        let converted = text.replacingOccurrences(of: "\n", with: "\r")
        if let data = converted.data(using: .utf8) {
            terminalView?.sendUserInput(data)
        }
    }

    /// Send raw bytes to the terminal via the same path as the real keyboard.
    /// This routes through the session (SSH, local shell) for correct I/O handling.
    private func sendRawInput(_ bytes: [UInt8]) {
        terminalView?.sendUserInput(Data(bytes))
    }

    /// Send a special key to the terminal.
    /// Control characters and escape use sendUserInput (raw bytes to session),
    /// matching how the real keyboard sends them. Mode-dependent keys like arrows
    /// use ghostty_surface_key so Ghostty handles DECCKM/encoding correctly.
    private func sendSpecialKey(_ key: String, to surface: ghostty_surface_t) {
        switch key {
        case "enter":
            sendRawInput([0x0d]) // CR
        case "tab":
            sendRawInput([0x09]) // HT
        case "escape", "esc", "ctrl+[":
            sendRawInput([0x1b]) // ESC
        case "backspace":
            sendRawInput([0x7f]) // DEL
        case "delete":
            sendRawInput([0x1b, 0x5b, 0x33, 0x7e]) // \e[3~
        case "space":
            sendRawInput([0x20]) // SP
        case "shift+tab":
            sendRawInput([0x1b, 0x5b, 0x5a]) // \e[Z
        // Arrow keys: route through Ghostty for DECCKM mode handling
        case "up":
            sendKeyEvent(hidUsage: .keyboardUpArrow, text: nil, to: surface)
        case "down":
            sendKeyEvent(hidUsage: .keyboardDownArrow, text: nil, to: surface)
        case "right":
            sendKeyEvent(hidUsage: .keyboardRightArrow, text: nil, to: surface)
        case "left":
            sendKeyEvent(hidUsage: .keyboardLeftArrow, text: nil, to: surface)
        // Navigation keys: route through Ghostty for proper escape sequence generation
        case "home":
            sendKeyEvent(hidUsage: .keyboardHome, text: nil, to: surface)
        case "end":
            sendKeyEvent(hidUsage: .keyboardEnd, text: nil, to: surface)
        case "pageup":
            sendKeyEvent(hidUsage: .keyboardPageUp, text: nil, to: surface)
        case "pagedown":
            sendKeyEvent(hidUsage: .keyboardPageDown, text: nil, to: surface)
        case "insert":
            sendKeyEvent(hidUsage: .keyboardInsert, text: nil, to: surface)
        default:
            // Ctrl+letter: send raw control byte (0x01-0x1A) matching real keyboard
            if key.hasPrefix("ctrl+"), key.count == 6,
               let letter = key.last?.asciiValue,
               letter >= Character("a").asciiValue!, letter <= Character("z").asciiValue! {
                sendRawInput([letter - Character("a").asciiValue! + 1])
            }
            // Alt+letter: send ESC prefix + letter
            else if key.hasPrefix("alt+"), key.count == 5,
                    let letter = key.last?.asciiValue {
                sendRawInput([0x1b, letter])
            }
            // Function keys: route through Ghostty
            else if key.hasPrefix("f"), let num = Int(key.dropFirst(1)), (1...12).contains(num) {
                let fKeys: [UIKeyboardHIDUsage] = [
                    .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4,
                    .keyboardF5, .keyboardF6, .keyboardF7, .keyboardF8,
                    .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
                ]
                sendKeyEvent(hidUsage: fKeys[num - 1], text: nil, to: surface)
            } else {
                Self.logger.warning("Unknown special key: \(key)")
            }
        }
    }

    // MARK: - Keystroke Parsing

    private enum KeySegment {
        case text(String)
        case special(String)
    }

    /// Aliases for common key name variations LLMs produce.
    private static let keyAliases: [String: String] = [
        "ret": "enter",
        "return": "enter",
        "cr": "enter",
        "bs": "backspace",
        "del": "delete",
        "pgup": "pageup",
        "pgdn": "pagedown",
        "pgdown": "pagedown",
        "ins": "insert",
    ]

    /// Normalize a special key name: lowercase, replace hyphens with +, apply aliases.
    private static func normalizeKeyName(_ key: String) -> String {
        let normalized = key.replacingOccurrences(of: "-", with: "+")
        return keyAliases[normalized] ?? normalized
    }

    private func parseKeystrokes(_ input: String) -> [KeySegment] {
        var segments: [KeySegment] = []
        var currentText = ""
        var i = input.startIndex

        while i < input.endIndex {
            if input[i] == "{" {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                if let closeIndex = input[i...].firstIndex(of: "}") {
                    let rawKey = String(input[input.index(after: i)..<closeIndex]).lowercased()
                    segments.append(.special(Self.normalizeKeyName(rawKey)))
                    i = input.index(after: closeIndex)
                } else {
                    currentText.append("{")
                    i = input.index(after: i)
                }
            } else {
                currentText.append(input[i])
                i = input.index(after: i)
            }
        }

        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }
}
#endif
