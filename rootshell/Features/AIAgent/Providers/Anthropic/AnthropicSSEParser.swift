#if !CHINA_BUILD
//
//  AnthropicSSEParser.swift
//  rootshell
//
//  Server-Sent Events parser for Anthropic Messages API streaming
//

import Foundation
import os.log

// MARK: - SSE Event Types

/// Events emitted during Anthropic streaming
enum AnthropicSSEEvent: Sendable {
    case messageStart(id: String, model: String, usage: AnthropicUsage?)
    case contentBlockStart(index: Int, contentBlock: ContentBlockInfo)
    case contentBlockDelta(index: Int, delta: AnthropicDelta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, usage: AnthropicUsage?)
    case messageStop
    case ping
    case error(String)

    /// Information about a content block when it starts
    nonisolated struct ContentBlockInfo: Sendable {
        let type: String
        let id: String?      // For tool_use blocks
        let name: String?    // For tool_use blocks
        let data: String?    // For redacted_thinking blocks (encrypted data)

        init(type: String, id: String? = nil, name: String? = nil, data: String? = nil) {
            self.type = type
            self.id = id
            self.name = name
            self.data = data
        }
    }
}

/// Delta types for content block updates
enum AnthropicDelta: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case signatureDelta(String)
    case inputJsonDelta(String)
}

// MARK: - SSE Parser

/// Parses Server-Sent Events from Anthropic API
/// All methods are nonisolated to allow use from detached tasks in stream processing
/// Thread safety is handled by single-task usage pattern (one parser per stream)
final class AnthropicSSEParser: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AnthropicSSEParser")

    private nonisolated(unsafe) var buffer: String = ""
    private nonisolated(unsafe) var currentEventType: String?
    private nonisolated(unsafe) var currentData: [String] = []

    /// Tracks whether the stream has completed successfully (received message_stop or stop_reason)
    /// Used to distinguish mid-stream errors (which cause truncation) from post-completion garbage
    private nonisolated(unsafe) var streamCompleted = false

    nonisolated init() {}

    /// Parse a line from the SSE stream
    /// Returns an event if one is complete, nil otherwise
    nonisolated func parseLine(_ line: String) -> AnthropicSSEEvent? {
        // Empty line signals end of event
        if line.isEmpty {
            defer {
                currentEventType = nil
                currentData.removeAll()
            }

            guard !currentData.isEmpty else {
                return nil
            }

            let data = currentData.joined(separator: "\n")
            return parseEvent(type: currentEventType, data: data)
        }

        // Parse line type
        if line.hasPrefix("event:") {
            currentEventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let dataContent = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            currentData.append(dataContent)
        } else if line.hasPrefix(":") {
            // Comment line, ignore
        } else if line.hasPrefix("id:") || line.hasPrefix("retry:") {
            // ID and retry fields, ignore for now
        }

        return nil
    }

    /// Parse buffered bytes and yield events
    nonisolated func parseBytes(_ data: Data) -> [AnthropicSSEEvent] {
        guard let string = String(data: data, encoding: .utf8) else {
            return []
        }

        buffer += string
        var events: [AnthropicSSEEvent] = []

        // Split by newlines and process
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])

            if let event = parseLine(line) {
                events.append(event)
            }
        }

        return events
    }

    /// Reset parser state
    nonisolated func reset() {
        buffer = ""
        currentEventType = nil
        currentData.removeAll()
        streamCompleted = false
    }

    // MARK: - Event Parsing

    /// Parse a single Anthropic event JSON payload.
    /// Exposed to allow Bedrock's binary-frame parser to feed each frame's
    /// base64-decoded chunk (which carries the same Anthropic event JSON the
    /// SSE path produces) through identical decoding.
    nonisolated static func parseEventJSON(_ data: Data) -> AnthropicSSEEvent? {
        guard let dataString = String(data: data, encoding: .utf8) else {
            return nil
        }
        let parser = AnthropicSSEParser()
        return parser.parseEvent(type: nil, data: dataString)
    }

    nonisolated func parseEvent(type: String?, data: String) -> AnthropicSSEEvent? {
        // Handle special event types
        if type == "ping" {
            return .ping
        }

        if type == "error" {
            return parseErrorEvent(data: data)
        }

        // Parse JSON data
        guard let jsonData = data.data(using: .utf8) else {
            Self.logger.error("Failed to convert SSE data to UTF-8")
            return nil
        }

        do {
            let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            guard let eventType = json?["type"] as? String else {
                Self.logger.error("Missing 'type' field in SSE event")
                return nil
            }

            switch eventType {
            case "message_start":
                return parseMessageStart(json: json)
            case "content_block_start":
                return parseContentBlockStart(json: json)
            case "content_block_delta":
                return parseContentBlockDelta(json: json)
            case "content_block_stop":
                return parseContentBlockStop(json: json)
            case "message_delta":
                return parseMessageDelta(json: json)
            case "message_stop":
                streamCompleted = true
                return .messageStop
            case "error":
                return parseErrorFromJson(json: json)
            default:
                Self.logger.debug("Unknown SSE event type: \(eventType)")
                return nil
            }
        } catch {
            if streamCompleted {
                // Post-completion garbage - debug level only (not a real error)
                Self.logger.debug("Ignoring post-completion SSE parse error: \(error.localizedDescription)")
            } else {
                // Mid-stream error - this may cause truncation
                Self.logger.error("Failed to parse SSE JSON (may cause truncation): \(error.localizedDescription)")
                Self.logger.debug("Raw SSE data that failed to parse: '\(data)'")
            }
            return nil
        }
    }

    private nonisolated func parseErrorEvent(data: String) -> AnthropicSSEEvent {
        // Try to parse as JSON error
        if let jsonData = data.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return .error(message)
        }
        return .error(data)
    }

    private nonisolated func parseErrorFromJson(json: [String: Any]?) -> AnthropicSSEEvent {
        if let errorObj = json?["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return .error(message)
        }
        return .error("Unknown error")
    }

    private nonisolated func parseMessageStart(json: [String: Any]?) -> AnthropicSSEEvent? {
        guard let message = json?["message"] as? [String: Any],
              let id = message["id"] as? String,
              let model = message["model"] as? String else {
            return nil
        }

        let usage = parseUsage(from: message["usage"] as? [String: Any])
        return .messageStart(id: id, model: model, usage: usage)
    }

    private nonisolated func parseContentBlockStart(json: [String: Any]?) -> AnthropicSSEEvent? {
        guard let index = json?["index"] as? Int,
              let contentBlock = json?["content_block"] as? [String: Any],
              let type = contentBlock["type"] as? String else {
            return nil
        }

        let id = contentBlock["id"] as? String
        let name = contentBlock["name"] as? String

        // For redacted_thinking, capture the encrypted data from the start event
        // redacted_thinking blocks contain a "data" field with the encrypted content
        var data: String? = nil
        if type == "redacted_thinking" {
            data = contentBlock["data"] as? String
        }

        return .contentBlockStart(
            index: index,
            contentBlock: AnthropicSSEEvent.ContentBlockInfo(type: type, id: id, name: name, data: data)
        )
    }

    private nonisolated func parseContentBlockDelta(json: [String: Any]?) -> AnthropicSSEEvent? {
        guard let index = json?["index"] as? Int,
              let delta = json?["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String else {
            return nil
        }

        let anthropicDelta: AnthropicDelta
        switch deltaType {
        case "text_delta":
            guard let text = delta["text"] as? String else { return nil }
            anthropicDelta = .textDelta(text)
        case "thinking_delta":
            guard let thinking = delta["thinking"] as? String else { return nil }
            anthropicDelta = .thinkingDelta(thinking)
        case "signature_delta":
            guard let signature = delta["signature"] as? String else { return nil }
            anthropicDelta = .signatureDelta(signature)
        case "input_json_delta":
            guard let partialJson = delta["partial_json"] as? String else { return nil }
            anthropicDelta = .inputJsonDelta(partialJson)
        default:
            Self.logger.debug("Unknown delta type: \(deltaType)")
            return nil
        }

        return .contentBlockDelta(index: index, delta: anthropicDelta)
    }

    private nonisolated func parseContentBlockStop(json: [String: Any]?) -> AnthropicSSEEvent? {
        guard let index = json?["index"] as? Int else {
            return nil
        }
        return .contentBlockStop(index: index)
    }

    private nonisolated func parseMessageDelta(json: [String: Any]?) -> AnthropicSSEEvent? {
        let delta = json?["delta"] as? [String: Any]
        let stopReason = delta?["stop_reason"] as? String
        let usage = parseUsage(from: json?["usage"] as? [String: Any])

        // Mark stream as complete when we receive a stop_reason
        if stopReason != nil {
            streamCompleted = true
        }

        return .messageDelta(stopReason: stopReason, usage: usage)
    }

    private nonisolated func parseUsage(from dict: [String: Any]?) -> AnthropicUsage? {
        guard let dict = dict else { return nil }

        // Handle both input_tokens (message_start) and output_tokens (message_delta)
        let inputTokens = dict["input_tokens"] as? Int ?? 0
        let outputTokens = dict["output_tokens"] as? Int ?? 0

        return AnthropicUsage(
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            cache_creation_input_tokens: dict["cache_creation_input_tokens"] as? Int,
            cache_read_input_tokens: dict["cache_read_input_tokens"] as? Int
        )
    }
}

// MARK: - Async Stream Parser

extension AnthropicSSEParser {
    /// Create an async stream of SSE events from URL bytes
    /// Optimized to use Data buffer instead of character-by-character processing
    /// Marked nonisolated to allow calling from detached tasks in stream processing
    nonisolated static func parseStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<AnthropicSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let parser = AnthropicSSEParser()
                var buffer = Data()
                buffer.reserveCapacity(4096)  // Pre-allocate for typical SSE lines

                let newlineByte = UInt8(ascii: "\n")
                let carriageReturn = UInt8(ascii: "\r")

                do {
                    for try await byte in bytes {
                        // Check cancellation early to avoid processing after consumer stops
                        if Task.isCancelled { break }

                        if byte == newlineByte {
                            // Process the accumulated line (excluding \r if present)
                            var lineData = buffer
                            if let lastByte = lineData.last, lastByte == carriageReturn {
                                lineData.removeLast()
                            }

                            if let line = String(data: lineData, encoding: .utf8) {
                                if let event = parser.parseLine(line) {
                                    continuation.yield(event)
                                }
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }

                    // Process any remaining data
                    if !buffer.isEmpty {
                        if let line = String(data: buffer, encoding: .utf8) {
                            if let event = parser.parseLine(line) {
                                continuation.yield(event)
                            }
                        }
                    }
                    // Final empty line to flush
                    if let event = parser.parseLine("") {
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch {
                    // If cancelled, don't report the error as it's expected
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
#endif
