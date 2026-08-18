#if !CHINA_BUILD
//
//  OpenRouterSSEParser.swift
//  rootshell
//
//  Server-Sent Events parser for OpenRouter API streaming (OpenAI-compatible format)
//

import Foundation
import os.log

// MARK: - SSE Event Types

/// Events emitted during OpenRouter streaming
enum OpenRouterSSEEvent: Sendable {
    /// Text content delta
    case textDelta(String)

    /// Tool call delta (partial arguments)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)

    /// Stream completed successfully
    case done(usage: OpenRouterUsage?, finishReason: String?)

    /// Error occurred
    case error(String)
}

// MARK: - SSE Parser

/// Parses Server-Sent Events from OpenRouter API (OpenAI-compatible format)
/// All methods are nonisolated to allow use from detached tasks in stream processing
final class OpenRouterSSEParser: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "OpenRouterSSEParser")

    private nonisolated(unsafe) var buffer: String = ""
    private nonisolated(unsafe) var currentEventType: String?
    private nonisolated(unsafe) var currentData: [String] = []

    /// Tracks whether the stream has completed successfully
    private nonisolated(unsafe) var streamCompleted = false

    nonisolated init() {}

    /// Parse a line from the SSE stream
    /// Returns an event if one is complete, nil otherwise
    nonisolated func parseLine(_ line: String) -> [OpenRouterSSEEvent] {
        // Empty line signals end of event
        if line.isEmpty {
            defer {
                currentEventType = nil
                currentData.removeAll()
            }

            guard !currentData.isEmpty else {
                return []
            }

            let data = currentData.joined(separator: "\n")
            return parseEvent(data: data)
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

        return []
    }

    /// Reset parser state
    nonisolated func reset() {
        buffer = ""
        currentEventType = nil
        currentData.removeAll()
        streamCompleted = false
    }

    // MARK: - Private Event Parsing

    private nonisolated func parseEvent(data: String) -> [OpenRouterSSEEvent] {
        // Check for [DONE] sentinel
        if data == "[DONE]" {
            streamCompleted = true
            return [.done(usage: nil, finishReason: nil)]
        }

        // Parse JSON data
        guard let jsonData = data.data(using: .utf8) else {
            Self.logger.error("Failed to convert SSE data to UTF-8")
            return []
        }

        do {
            let response = try JSONDecoder().decode(OpenRouterResponse.self, from: jsonData)

            // Check for error in response
            if let error = response.error {
                return [.error(error.message ?? "Unknown error")]
            }

            var events: [OpenRouterSSEEvent] = []

            // Process choices
            if let choices = response.choices {
                for choice in choices {
                    // Check for delta (streaming) or message (non-streaming)
                    if let delta = choice.delta {
                        // Text content
                        if let content = delta.content, !content.isEmpty {
                            events.append(.textDelta(content))
                        }

                        // Tool calls
                        if let toolCalls = delta.tool_calls {
                            for toolCall in toolCalls {
                                events.append(.toolCallDelta(
                                    index: toolCall.index ?? 0,
                                    id: toolCall.id,
                                    name: toolCall.function?.name,
                                    arguments: toolCall.function?.arguments
                                ))
                            }
                        }
                    }

                    // Check for finish reason
                    if let finishReason = choice.finish_reason {
                        streamCompleted = true
                        events.append(.done(usage: response.usage, finishReason: finishReason))
                    }
                }
            }

            return events

        } catch {
            if streamCompleted {
                // Post-completion garbage - debug level only
                Self.logger.debug("Ignoring post-completion SSE parse error: \(error.localizedDescription)")
            } else {
                Self.logger.error("Failed to parse SSE JSON: \(error.localizedDescription)")
                Self.logger.debug("Raw SSE data that failed to parse: '\(data)'")
            }
            return []
        }
    }
}

// MARK: - Async Stream Parser

extension OpenRouterSSEParser {
    /// Create an async stream of SSE events from URL bytes
    /// Marked nonisolated to allow calling from detached tasks in stream processing
    nonisolated static func parseStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<OpenRouterSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let parser = OpenRouterSSEParser()
                var buffer = Data()
                buffer.reserveCapacity(4096)

                let newlineByte = UInt8(ascii: "\n")
                let carriageReturn = UInt8(ascii: "\r")

                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }

                        if byte == newlineByte {
                            // Process the accumulated line (excluding \r if present)
                            var lineData = buffer
                            if let lastByte = lineData.last, lastByte == carriageReturn {
                                lineData.removeLast()
                            }

                            if let line = String(data: lineData, encoding: .utf8) {
                                let events = parser.parseLine(line)
                                for event in events {
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
                            let events = parser.parseLine(line)
                            for event in events {
                                continuation.yield(event)
                            }
                        }
                    }
                    // Final empty line to flush
                    let finalEvents = parser.parseLine("")
                    for event in finalEvents {
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
