#if !CHINA_BUILD
//
//  GeminiSSEParser.swift
//  rootshell
//
//  Server-Sent Events parser for Gemini API streaming
//

import Foundation
import os.log

// MARK: - SSE Event Types

/// Events emitted during Gemini streaming
enum GeminiSSEEvent: Sendable {
    case contentPart(GeminiPart)
    case finishReason(String)
    case usageMetadata(GeminiUsageMetadata)
    case error(String)
}

// MARK: - SSE Parser

/// Parses Server-Sent Events from Gemini API
/// All methods are nonisolated to allow use from detached tasks in stream processing
final class GeminiSSEParser: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GeminiSSEParser")

    private nonisolated(unsafe) var buffer: String = ""
    private nonisolated(unsafe) var currentData: [String] = []

    /// Tracks whether the stream has completed successfully
    private nonisolated(unsafe) var streamCompleted = false

    nonisolated init() {}

    /// Parse a line from the SSE stream
    /// Returns events if data is complete, empty array otherwise
    nonisolated func parseLine(_ line: String) -> [GeminiSSEEvent] {
        // Empty line signals end of event
        if line.isEmpty {
            defer {
                currentData.removeAll()
            }

            guard !currentData.isEmpty else {
                return []
            }

            let data = currentData.joined(separator: "")
            return parseData(data)
        }

        // Parse line type
        if line.hasPrefix("data:") {
            let dataContent = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            currentData.append(dataContent)
        } else if line.hasPrefix(":") {
            // Comment line, ignore
        } else if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") {
            // Other SSE fields, ignore for now
        }

        return []
    }

    /// Parse buffered bytes and yield events
    nonisolated func parseBytes(_ data: Data) -> [GeminiSSEEvent] {
        guard let string = String(data: data, encoding: .utf8) else {
            return []
        }

        buffer += string
        var events: [GeminiSSEEvent] = []

        // Split by newlines and process
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])

            events.append(contentsOf: parseLine(line))
        }

        return events
    }

    /// Reset parser state
    nonisolated func reset() {
        buffer = ""
        currentData.removeAll()
        streamCompleted = false
    }

    // MARK: - Private Data Parsing

    private nonisolated func parseData(_ data: String) -> [GeminiSSEEvent] {
        // Parse JSON data
        guard let jsonData = data.data(using: .utf8) else {
            Self.logger.error("Failed to convert SSE data to UTF-8")
            return []
        }

        do {
            let response = try JSONDecoder().decode(GeminiStreamChunk.self, from: jsonData)
            return extractEvents(from: response)
        } catch {
            if streamCompleted {
                Self.logger.debug("Ignoring post-completion SSE parse error: \(error.localizedDescription)")
            } else {
                Self.logger.error("Failed to parse Gemini SSE JSON: \(error.localizedDescription)")
                Self.logger.debug("Raw SSE data: '\(data.prefix(500))'")
            }
            return []
        }
    }

    private nonisolated func extractEvents(from response: GeminiStreamChunk) -> [GeminiSSEEvent] {
        var events: [GeminiSSEEvent] = []

        // Extract content parts from candidates
        if let candidates = response.candidates {
            for candidate in candidates {
                if let content = candidate.content {
                    for part in content.parts {
                        events.append(.contentPart(part))
                    }
                }

                if let finishReason = candidate.finishReason {
                    streamCompleted = true
                    events.append(.finishReason(finishReason))
                }
            }
        }

        // Extract usage metadata
        if let usage = response.usageMetadata {
            events.append(.usageMetadata(usage))
        }

        // Check for blocked prompts
        if let feedback = response.promptFeedback, let blockReason = feedback.blockReason {
            events.append(.error("Prompt blocked: \(blockReason)"))
        }

        return events
    }
}

// MARK: - Async Stream Parser

extension GeminiSSEParser {
    /// Create an async stream of SSE events from URL bytes
    /// Marked nonisolated to allow calling from detached tasks in stream processing
    nonisolated static func parseStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<GeminiSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let parser = GeminiSSEParser()
                var buffer = Data()
                buffer.reserveCapacity(4096)

                let newlineByte = UInt8(ascii: "\n")
                let carriageReturn = UInt8(ascii: "\r")

                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }

                        if byte == newlineByte {
                            // Process the accumulated line
                            var lineData = buffer
                            if let lastByte = lineData.last, lastByte == carriageReturn {
                                lineData.removeLast()
                            }

                            if let line = String(data: lineData, encoding: .utf8) {
                                for event in parser.parseLine(line) {
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
                            for event in parser.parseLine(line) {
                                continuation.yield(event)
                            }
                        }
                    }

                    // Final empty line to flush
                    for event in parser.parseLine("") {
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
