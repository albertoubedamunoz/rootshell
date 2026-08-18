#if !CHINA_BUILD
//
//  BedrockEventStreamParser.swift
//  rootshell
//
//  Parses the AWS event-stream binary protocol used by
//  `InvokeModelWithResponseStream` into Anthropic SSE events.
//
//  Wire format (each frame):
//    [4 B] total length            (big-endian)
//    [4 B] header length           (big-endian)
//    [4 B] prelude CRC32            (skipped — TLS already protects integrity)
//    [N B] headers                  see below
//    [M B] payload (JSON)
//    [4 B] message CRC32            (skipped)
//
//  Header serialization:
//    [1 B] name length
//    [N B] name (UTF-8)
//    [1 B] value type   (only type 7 = string is used by Bedrock here)
//    [2 B] value length (big-endian)
//    [N B] value bytes
//
//  For chunk frames (`:event-type=chunk`) the JSON payload is
//  `{ "bytes": "<base64-of-anthropic-event-json>" }`. We base64-decode
//  the inner bytes and feed them to `AnthropicSSEParser.parseEventJSON`,
//  which produces the same `AnthropicSSEEvent` the direct-API path emits.
//
//  For exception frames (`:message-type=exception`) we map the AWS
//  exception type into an `AIProviderError` and surface it as a thrown
//  error on the stream.
//

import Foundation
import os.log

enum BedrockEventStreamParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BedrockEventStream")

    /// Maximum allowed frame length (16 MB). Bedrock's actual cap is 1 MB
    /// for InvokeModel; this is a defensive ceiling against framing bugs.
    private nonisolated static let maxFrameLength = 16 * 1024 * 1024

    /// Yield `AnthropicSSEEvent`s from a Bedrock streaming response body.
    /// Errors propagate via the throwing stream and finish it.
    nonisolated static func parseStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<AnthropicSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(8192)

                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)

                        // Drain whole frames as they accumulate.
                        while let totalLength = peekFrameLength(buffer),
                              buffer.count >= totalLength {
                            let frame = Data(buffer.prefix(totalLength))
                            buffer.removeSubrange(0..<totalLength)

                            switch parseFrame(frame) {
                            case .event(let sseEvent):
                                continuation.yield(sseEvent)
                            case .exception(let error):
                                continuation.finish(throwing: error)
                                return
                            case .skip:
                                break
                            case .invalid(let reason):
                                logger.error("Bedrock event-stream frame invalid: \(reason)")
                                continuation.finish(throwing: AIProviderError.networkError(
                                    "Bedrock streaming protocol error: \(reason)"))
                                return
                            }
                        }
                    }

                    continuation.finish()
                } catch {
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

    // MARK: - Frame parsing

    private enum FrameResult {
        case event(AnthropicSSEEvent)
        case exception(Error)
        case skip
        case invalid(String)
    }

    private nonisolated static func peekFrameLength(_ buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let totalLength = readBigEndianUInt32(buffer, offset: 0)
        guard totalLength > 0, totalLength <= maxFrameLength else {
            return nil
        }
        return Int(totalLength)
    }

    private nonisolated static func parseFrame(_ frame: Data) -> FrameResult {
        guard frame.count >= 16 else {
            return .invalid("frame too short (\(frame.count) bytes)")
        }

        let totalLength = Int(readBigEndianUInt32(frame, offset: 0))
        let headerLength = Int(readBigEndianUInt32(frame, offset: 4))

        guard totalLength == frame.count else {
            return .invalid("frame length mismatch (declared \(totalLength), got \(frame.count))")
        }
        let preludeAndHeadersEnd = 12 + headerLength
        guard preludeAndHeadersEnd + 4 <= totalLength else {
            return .invalid("headers exceed frame size")
        }

        let headers = parseHeaders(frame, headersStart: 12, headersEnd: preludeAndHeadersEnd)
        let payload = frame.subdata(in: preludeAndHeadersEnd..<(totalLength - 4))

        // Server-side errors are signaled via :message-type=exception.
        if headers[":message-type"] == "exception" {
            let exceptionType = headers[":exception-type"] ?? "UnknownException"
            let message = decodedMessage(payload) ?? exceptionType
            return .exception(mapBedrockException(type: exceptionType, message: message))
        }

        // Some non-fatal control frames (e.g., periodic pings) carry no chunk.
        guard headers[":event-type"] == "chunk" else {
            // Bedrock doesn't currently emit other event types for InvokeModel,
            // but we ignore unknown ones rather than failing — forward
            // compatibility for any future extra event types.
            return .skip
        }

        // Chunk payload: { "bytes": "<base64-of-anthropic-event-json>" }
        guard let chunkJSON = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let base64 = chunkJSON["bytes"] as? String,
              let anthropicJSON = Data(base64Encoded: base64) else {
            return .skip
        }

        guard let event = AnthropicSSEParser.parseEventJSON(anthropicJSON) else {
            // Anthropic's event JSON didn't decode — log and continue;
            // mid-stream parse drops are not fatal in the SSE path either.
            return .skip
        }

        return .event(event)
    }

    private nonisolated static func parseHeaders(
        _ frame: Data,
        headersStart: Int,
        headersEnd: Int
    ) -> [String: String] {
        var headers: [String: String] = [:]
        var offset = headersStart
        while offset < headersEnd {
            // [1 B] name length
            guard offset + 1 <= headersEnd else { break }
            let nameLength = Int(frame[offset])
            offset += 1
            guard offset + nameLength <= headersEnd else { break }
            let nameData = frame.subdata(in: offset..<(offset + nameLength))
            offset += nameLength
            guard let name = String(data: nameData, encoding: .utf8) else { break }

            // [1 B] value type
            guard offset + 1 <= headersEnd else { break }
            let valueType = frame[offset]
            offset += 1

            // Bedrock currently only emits string-typed (7) headers for
            // chunks/exceptions. Anything else we can't safely interpret —
            // skip the rest of this header block to avoid mis-decoding.
            guard valueType == 7 else {
                logger.debug("Bedrock event-stream: unsupported header type \(valueType) for \(name)")
                return headers
            }

            // [2 B] value length, big-endian
            guard offset + 2 <= headersEnd else { break }
            let valueLength = (Int(frame[offset]) << 8) | Int(frame[offset + 1])
            offset += 2
            guard offset + valueLength <= headersEnd else { break }
            let valueData = frame.subdata(in: offset..<(offset + valueLength))
            offset += valueLength
            guard let value = String(data: valueData, encoding: .utf8) else { break }

            headers[name] = value
        }
        return headers
    }

    private nonisolated static func decodedMessage(_ payload: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return (json["message"] as? String) ?? (json["Message"] as? String)
    }

    /// Map a Bedrock exception type onto our generic provider error space.
    /// Reasons live alongside the existing direct-API error mapping in
    /// AnthropicProvider so the UI surfaces consistent guidance regardless
    /// of which transport actually failed.
    private nonisolated static func mapBedrockException(type: String, message: String) -> AIProviderError {
        switch type {
        case "ThrottlingException":
            return .rateLimited(retryAfter: nil)
        case "AccessDeniedException":
            return .invalidAPIKey
        case "ResourceNotFoundException", "ModelNotReadyException":
            return .modelNotAvailable(message)
        case "ValidationException":
            return .invalidResponse(message)
        case "ModelStreamErrorException",
             "InternalServerException",
             "ServiceUnavailableException":
            return .networkError(message)
        case "ModelTimeoutException":
            return .networkError("Bedrock model timed out: \(message)")
        default:
            return .unknown("Bedrock \(type): \(message)")
        }
    }

    private nonisolated static func readBigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
#endif
