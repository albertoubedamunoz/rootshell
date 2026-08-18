#if !CHINA_BUILD
//
//  AnthropicMessageHelpers.swift
//  rootshell
//
//  Static helpers shared between the direct Anthropic provider and the
//  AWS Bedrock provider. Both endpoints accept identical Messages-API bodies
//  and emit identical streaming events; only the transport (auth, URL, wire
//  format) differs, so message construction, tool serialization, response
//  parsing, and event-stream interpretation all live here.
//

import Foundation
import os.log

enum AnthropicMessageHelpers {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AnthropicHelpers")

    // MARK: - Message Conversion

    nonisolated static func buildMessages(_ messages: [AIAgentMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []

        for message in messages {
            switch message.content {
            case .text(let text):
                switch message.role {
                case .user:
                    result.append(.user(text))
                case .assistant:
                    let parsed = ThinkingParser.parse(text)
                    let cleanText = parsed.text
                    if !cleanText.isEmpty {
                        result.append(.assistant(cleanText))
                    }
                case .system, .tool:
                    continue
                }

            case .textWithThinking(let text, let thinking):
                guard message.role == .assistant else { continue }
                var blocks: [AnthropicContentBlock] = []
                if let signature = thinking.signature {
                    blocks.append(.thinking(AnthropicThinkingBlock(
                        thinking: thinking.content,
                        signature: signature
                    )))
                }
                if !text.isEmpty {
                    blocks.append(.text(AnthropicTextBlock(text: text)))
                }
                if !blocks.isEmpty {
                    result.append(.assistant(blocks))
                }

            case .toolCall(let call):
                guard !call.isFromXMLParsing else { continue }
                let input = parseJSONArguments(call.arguments)
                let block = AnthropicToolUseBlock(id: call.id, name: call.name, input: input)
                result.append(.assistant([.toolUse(block)]))

            case .toolCalls(let calls, let precedingText, let thinking):
                var blocks: [AnthropicContentBlock] = []
                if let thinking = thinking, let signature = thinking.signature {
                    blocks.append(.thinking(AnthropicThinkingBlock(
                        thinking: thinking.content,
                        signature: signature
                    )))
                }
                if let text = precedingText, !text.isEmpty {
                    blocks.append(.text(AnthropicTextBlock(text: text)))
                }
                for call in calls where !call.isFromXMLParsing {
                    let input = parseJSONArguments(call.arguments)
                    blocks.append(.toolUse(AnthropicToolUseBlock(id: call.id, name: call.name, input: input)))
                }
                if !blocks.isEmpty {
                    result.append(.assistant(blocks))
                }

            case .toolResult(let toolCallId, let output, let isError, let isFromXMLToolCall):
                if isFromXMLToolCall {
                    result.append(.user("[Tool Result]\n\(output)"))
                } else {
                    let block = AnthropicToolResultBlock(toolUseId: toolCallId, content: output, isError: isError)
                    result.append(.user([.toolResult(block)]))
                }

            case .toolResults(let results):
                var nativeBlocks: [AnthropicContentBlock] = []
                var xmlResults: [String] = []
                for toolResult in results {
                    if toolResult.isFromXMLToolCall {
                        xmlResults.append("[Tool Result for \(toolResult.toolCallId)]\n\(toolResult.output)")
                    } else {
                        let block = AnthropicToolResultBlock(
                            toolUseId: toolResult.toolCallId,
                            content: toolResult.output,
                            isError: toolResult.isError
                        )
                        nativeBlocks.append(.toolResult(block))
                    }
                }
                if !nativeBlocks.isEmpty {
                    result.append(.user(nativeBlocks))
                }
                for xmlResult in xmlResults {
                    result.append(.user(xmlResult))
                }
            }
        }

        return result
    }

    nonisolated static func parseJSONArguments(_ jsonString: String) -> [String: AnyCodableValue] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { AnyCodableValue.from($0) }
    }

    // MARK: - Tool Conversion

    nonisolated static func buildTools(_ tools: [AIAgentTool]) -> [AnthropicTool] {
        tools.map { tool in
            let properties = tool.parameters.properties.mapValues { param -> AnthropicPropertySchema in
                convertParameter(param)
            }
            return AnthropicTool(
                name: tool.name,
                description: tool.description,
                input_schema: AnthropicInputSchema(
                    properties: properties,
                    required: tool.parameters.required
                )
            )
        }
    }

    private nonisolated static func convertParameter(_ param: AIToolParameter) -> AnthropicPropertySchema {
        var items: AnthropicPropertySchema?
        if let itemsBox = param.items {
            items = convertParameter(itemsBox.value)
        }
        return AnthropicPropertySchema(
            type: param.type,
            description: param.description,
            enumValues: param.enumValues,
            items: items
        )
    }

    // MARK: - Response Parsing

    nonisolated static func parseResponse(_ response: AnthropicResponse) -> AIProviderResponse {
        var text = ""
        var thinkingText = ""
        var toolCalls: [AIToolCall] = []

        for content in response.content {
            switch content {
            case .text(let t):
                text += t
            case .thinking(let t, _):
                if !thinkingText.isEmpty {
                    thinkingText += "\n"
                }
                thinkingText += t
            case .redactedThinking:
                break
            case .toolUse(let id, let name, let input):
                if let jsonData = try? JSONSerialization.data(withJSONObject: input),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("Parsed tool call: id=\(id), name=\(name)")
                    toolCalls.append(AIToolCall(id: id, name: name, arguments: jsonString))
                }
            }
        }

        if !thinkingText.isEmpty {
            text = "<think>\(thinkingText)</think>\(text)"
        }

        let usage = response.usage.map { u in
            AIUsageStats(
                promptTokens: u.input_tokens,
                completionTokens: u.output_tokens,
                totalTokens: u.totalTokens
            )
        }
        let finishReason = mapStopReason(response.stop_reason)

        let content: AIProviderResponse.Content
        if !toolCalls.isEmpty && !text.isEmpty {
            content = .textAndToolCalls(text, toolCalls)
        } else if !toolCalls.isEmpty {
            content = .toolCalls(toolCalls)
        } else {
            content = .text(text)
        }

        return AIProviderResponse(content: content, usage: usage, finishReason: finishReason)
    }

    nonisolated static func mapStopReason(_ reason: String?) -> AIProviderResponse.FinishReason? {
        guard let reason = reason else { return nil }
        switch reason {
        case "end_turn", "stop_sequence":
            return .stop
        case "tool_use":
            return .toolCalls
        case "max_tokens":
            return .length
        case "content_filter":
            return .contentFilter
        default:
            return nil
        }
    }

    nonisolated static func mergeUsage(_ existing: AnthropicUsage?, _ new: AnthropicUsage) -> AnthropicUsage {
        guard let existing = existing else { return new }
        return AnthropicUsage(
            input_tokens: existing.input_tokens + new.input_tokens,
            output_tokens: existing.output_tokens + new.output_tokens,
            cache_creation_input_tokens: (existing.cache_creation_input_tokens ?? 0) + (new.cache_creation_input_tokens ?? 0),
            cache_read_input_tokens: (existing.cache_read_input_tokens ?? 0) + (new.cache_read_input_tokens ?? 0)
        )
    }

    // MARK: - Stream Event Processing

    /// Translate Anthropic event-stream events into provider-agnostic
    /// `AIProviderStreamEvent`s. Both the direct Anthropic API and AWS
    /// Bedrock emit the same event shapes (Bedrock just wraps them in
    /// binary framing); this loop is the shared back end after format-specific
    /// decoding.
    nonisolated static func processEvents(
        _ events: AsyncThrowingStream<AnthropicSSEEvent, Error>,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        var contentBlockTypes: [Int: String] = [:]
        var toolCallBuilders: [Int: ToolCallBuilder] = [:]
        var thinkingBuffers: [Int: String] = [:]
        var thinkingSignatures: [Int: String] = [:]
        var accumulatedUsage: AnthropicUsage?

        for try await event in events {
            if Task.isCancelled {
                continuation.finish(throwing: AIProviderError.cancelled)
                return
            }

            switch event {
            case .messageStart(_, _, let usage):
                accumulatedUsage = usage

            case .contentBlockStart(let index, let contentBlock):
                contentBlockTypes[index] = contentBlock.type
                let blockType = contentBlock.type
                let blockID = contentBlock.id ?? "nil"
                logger.debug("Content block start: index=\(index), type=\(blockType), id=\(blockID)")
                switch contentBlock.type {
                case "thinking":
                    thinkingBuffers[index] = ""
                case "redacted_thinking":
                    thinkingBuffers[index] = ""
                case "tool_use":
                    if let id = contentBlock.id, let name = contentBlock.name {
                        toolCallBuilders[index] = ToolCallBuilder(id: id, name: name)
                    }
                default:
                    break
                }

            case .contentBlockDelta(let index, let delta):
                switch delta {
                case .textDelta(let text):
                    continuation.yield(.textDelta(text))
                case .thinkingDelta(let thinking):
                    thinkingBuffers[index, default: ""] += thinking
                    continuation.yield(.thinkingDelta(thinking))
                case .signatureDelta(let signature):
                    thinkingSignatures[index, default: ""] += signature
                case .inputJsonDelta(let jsonDelta):
                    if let builder = toolCallBuilders[index] {
                        builder.appendArguments(jsonDelta)
                        continuation.yield(.toolCallDelta(
                            id: builder.id,
                            name: builder.name,
                            argumentsDelta: jsonDelta
                        ))
                    }
                }

            case .contentBlockStop(let index):
                let blockType = contentBlockTypes[index] ?? "unknown"
                logger.debug("Content block stop: index=\(index), type=\(blockType)")
                if contentBlockTypes[index] == "thinking" {
                    let content = thinkingBuffers.removeValue(forKey: index) ?? ""
                    let signature = thinkingSignatures.removeValue(forKey: index)
                    continuation.yield(.thinkingComplete(thinking: content, signature: signature))
                } else if contentBlockTypes[index] == "redacted_thinking" {
                    thinkingBuffers.removeValue(forKey: index)
                    thinkingSignatures.removeValue(forKey: index)
                }
                if let builder = toolCallBuilders[index] {
                    let toolCall = builder.build()
                    let argsPreview = String(toolCall.arguments.prefix(100))
                    logger.debug("Tool call complete: id=\(toolCall.id), name=\(toolCall.name), args=\(argsPreview)")
                    continuation.yield(.toolCallComplete(toolCall))
                    toolCallBuilders.removeValue(forKey: index)
                }

            case .messageDelta(let stopReason, let usage):
                if let usage = usage {
                    accumulatedUsage = mergeUsage(accumulatedUsage, usage)
                }
                let finishReason = mapStopReason(stopReason)
                let usageStats = accumulatedUsage.map { usage in
                    AIUsageStats(
                        promptTokens: usage.input_tokens,
                        completionTokens: usage.output_tokens,
                        totalTokens: usage.totalTokens
                    )
                }
                continuation.yield(.responseComplete(usage: usageStats, finishReason: finishReason))

            case .messageStop:
                continuation.finish()
                return

            case .ping:
                break

            case .error(let message):
                continuation.finish(throwing: AIProviderError.unknown(message))
                return
            }
        }

        continuation.finish()
    }
}

/// Tool call assembled from streaming `input_json_delta` events.
/// Marked `@unchecked Sendable` because each instance is mutated by exactly
/// one task — the stream loop that constructed it — so external locking is
/// unnecessary.
final class ToolCallBuilder: @unchecked Sendable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated(unsafe) var arguments: String = ""

    nonisolated init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    nonisolated func appendArguments(_ delta: String) {
        arguments += delta
    }

    nonisolated func build() -> AIToolCall {
        AIToolCall(id: id.trimmingCharacters(in: .whitespaces), name: name, arguments: arguments)
    }
}
#endif
