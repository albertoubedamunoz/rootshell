#if !CHINA_BUILD
//
//  GeminiProvider.swift
//  rootshell
//
//  Google Gemini API provider implementation
//

import Foundation
import os.log

/// Google Gemini provider implementation using native URLSession
@MainActor
final class GeminiProvider: AIProvider {
    // MARK: - Static Properties

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GeminiProvider")

    static let providerID = "google"
    static let displayName = "Google"
    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    static var availableModels: [AIProviderModel] {
        AIProviderModel.googleModels
    }

    // MARK: - Instance Properties

    private let apiKey: String
    private let baseURL: String
    private var currentTask: Task<Void, Never>?

    var selectedModelID: String

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    // MARK: - Initialization

    /// Initialize for direct Gemini API
    init(apiKey: String, selectedModelID: String = "gemini-2.5-pro") {
        self.apiKey = apiKey
        self.baseURL = Self.defaultBaseURL
        self.selectedModelID = selectedModelID
    }

    // MARK: - AIProvider Protocol

    func sendMessage(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) async throws -> AIProviderResponse {
        guard isConfigured else {
            throw AIProviderError.notConfigured
        }

        let request = try buildRequest(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        try checkHTTPResponse(httpResponse, data: data, modelID: selectedModelID)

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return parseResponse(geminiResponse)
    }

    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        // Capture values needed for the detached task
        let isConfigured = self.isConfigured
        let modelID = self.selectedModelID

        return AsyncThrowingStream { continuation in
            // Run stream processing off MainActor to avoid UI freezes
            // Network I/O and byte-by-byte parsing should not block the main thread
            let task = Task.detached { [weak self] in
                guard isConfigured else {
                    continuation.finish(throwing: AIProviderError.notConfigured)
                    return
                }

                guard let self = self else {
                    continuation.finish(throwing: AIProviderError.cancelled)
                    return
                }

                // Retry logic for connection lost errors (common with SSH port forwards)
                let maxRetries = 2
                var lastError: Error?

                for attempt in 0...maxRetries {
                    // Check cancellation before each attempt
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }

                    if attempt > 0 {
                        Self.logger.info("Retrying stream request (attempt \(attempt + 1)/\(maxRetries + 1)) after connection error")
                        // Brief delay before retry to allow connection to reset
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    }

                    do {
                        try await self.executeStreamRequest(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            modelID: modelID,
                            continuation: continuation
                        )
                        // Success - exit retry loop
                        return
                    } catch {
                        // Check for cancellation first
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }

                        let nsError = error as NSError
                        // Only retry on connection lost errors (-1005)
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
                            Self.logger.warning("Connection lost during stream (attempt \(attempt + 1)): \(error.localizedDescription)")
                            lastError = error
                            continue
                        }
                        // For other errors, don't retry - finish with error
                        continuation.finish(throwing: self.mapError(error))
                        return
                    }
                }

                // All retries exhausted
                if let error = lastError {
                    continuation.finish(throwing: self.mapError(error))
                }
            }

            Task { @MainActor [weak self] in
                self?.currentTask = task
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Execute the actual stream request (extracted for retry logic)
    private nonisolated func executeStreamRequest(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        modelID: String,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        let request = try await MainActor.run {
            try self.buildRequest(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                stream: true
            )
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        // Check for error status codes
        if httpResponse.statusCode >= 400 {
            // Try to read error body with cancellation check and size limit
            var errorData = Data()
            let maxErrorSize = 16384  // 16KB max error body
            for try await byte in bytes {
                if Task.isCancelled { break }
                errorData.append(byte)
                if errorData.count >= maxErrorSize { break }
            }
            try self.checkHTTPResponse(httpResponse, data: errorData, modelID: modelID)
        }

        // Process SSE stream
        try await self.processStream(bytes: bytes, continuation: continuation)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Request Building

    private func buildRequest(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        stream: Bool
    ) throws -> URLRequest {
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        let urlString = "\(baseURL)/\(selectedModelID):\(endpoint)?key=\(apiKey)"

        // Add alt=sse for streaming
        let finalURLString = stream ? "\(urlString)&alt=sse" : urlString

        guard let url = URL(string: finalURLString) else {
            throw AIProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Get max tokens for the model tier
        let modelInfo = AIProviderModel.googleModel(id: selectedModelID)
        let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

        // Get user-configured or default temperature
        let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
            for: GeminiProvider.providerID,
            supportsTemperature: true
        ) ?? AICredentialsManager.defaultTemperatures[GeminiProvider.providerID] ?? 0.4

        let geminiContents = convertMessages(messages)
        let geminiTools = convertTools(tools)

        let geminiRequest = GeminiRequest(
            contents: geminiContents,
            systemInstruction: systemPrompt.isEmpty ? nil : systemPrompt,
            tools: geminiTools.isEmpty ? nil : geminiTools,
            generationConfig: GeminiGenerationConfig(
                maxOutputTokens: maxTokens,
                temperature: effectiveTemperature
            )
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(geminiRequest)

        Self.logger.debug("Gemini request: model=\(self.selectedModelID), stream=\(stream), contents=\(geminiContents.count)")

        return request
    }

    // MARK: - Message Conversion

    private func convertMessages(_ messages: [AIAgentMessage]) -> [GeminiContent] {
        var result: [GeminiContent] = []

        for message in messages {
            switch message.content {
            case .text(let text):
                switch message.role {
                case .user:
                    result.append(.user(text))
                case .assistant:
                    // Strip thinking from text messages
                    let parsed = ThinkingParser.parse(text)
                    let cleanText = parsed.text
                    if !cleanText.isEmpty {
                        result.append(.model(cleanText))
                    }
                case .system:
                    // System messages are handled via systemInstruction
                    continue
                case .tool:
                    // Should be handled by toolResult case
                    continue
                }

            case .textWithThinking(let text, _):
                // Gemini doesn't have a native thinking format yet
                // Just use the text content
                guard message.role == .assistant else { continue }
                if !text.isEmpty {
                    result.append(.model(text))
                }

            case .toolCall(let call):
                guard !call.isFromXMLParsing else { continue }
                let args = parseJSONArguments(call.arguments)
                let part = GeminiPart.functionCall(GeminiFunctionCall(name: call.name, args: args), thoughtSignature: call.thoughtSignature)
                result.append(.model([part]))

            case .toolCalls(let calls, let precedingText, _):
                var parts: [GeminiPart] = []

                // Add text part first if present
                if let text = precedingText, !text.isEmpty {
                    parts.append(.text(text))
                }

                // Add function call parts with thought signatures (Gemini 3.0+)
                for call in calls where !call.isFromXMLParsing {
                    let args = parseJSONArguments(call.arguments)
                    parts.append(.functionCall(GeminiFunctionCall(name: call.name, args: args), thoughtSignature: call.thoughtSignature))
                }

                if !parts.isEmpty {
                    result.append(.model(parts))
                }

            case .toolResult(let toolCallId, let output, _, let isFromXMLToolCall):
                if isFromXMLToolCall {
                    // For XML-parsed tool calls, send as user message
                    result.append(.user("[Tool Result]\n\(output)"))
                } else {
                    // Extract tool name from toolCallId or use generic name
                    // Gemini uses function name, not ID for responses
                    let functionName = extractFunctionName(from: toolCallId, messages: messages)
                    let part = GeminiPart.functionResponse(GeminiFunctionResponse(name: functionName, result: output))
                    result.append(.user([part]))
                }

            case .toolResults(let results):
                var nativeParts: [GeminiPart] = []
                var xmlResults: [String] = []

                for toolResult in results {
                    if toolResult.isFromXMLToolCall {
                        xmlResults.append("[Tool Result for \(toolResult.toolCallId)]\n\(toolResult.output)")
                    } else {
                        let functionName = extractFunctionName(from: toolResult.toolCallId, messages: messages)
                        nativeParts.append(.functionResponse(GeminiFunctionResponse(name: functionName, result: toolResult.output)))
                    }
                }

                // Add native results as single message
                if !nativeParts.isEmpty {
                    result.append(.user(nativeParts))
                }

                // Add XML results as separate text messages
                for xmlResult in xmlResults {
                    result.append(.user(xmlResult))
                }
            }
        }

        return result
    }

    /// Extract function name from tool call ID by searching previous messages
    private func extractFunctionName(from toolCallId: String, messages: [AIAgentMessage]) -> String {
        for message in messages {
            switch message.content {
            case .toolCall(let call) where call.id == toolCallId:
                return call.name
            case .toolCalls(let calls, _, _):
                if let call = calls.first(where: { $0.id == toolCallId }) {
                    return call.name
                }
            default:
                continue
            }
        }
        // Fallback: use the ID as name (may not work but better than nothing)
        return toolCallId
    }

    private func parseJSONArguments(_ jsonString: String) -> [String: AnyCodableValue] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { AnyCodableValue.from($0) }
    }

    // MARK: - Tool Conversion

    private func convertTools(_ tools: [AIAgentTool]) -> [GeminiTool] {
        guard !tools.isEmpty else { return [] }

        let declarations = tools.map { tool in
            let properties = tool.parameters.properties.mapValues { param -> GeminiPropertySchema in
                convertParameter(param)
            }

            return GeminiFunctionDeclaration(
                name: tool.name,
                description: tool.description,
                parameters: GeminiParameterSchema(
                    properties: properties,
                    required: tool.parameters.required
                )
            )
        }

        return [GeminiTool(functionDeclarations: declarations)]
    }

    private func convertParameter(_ param: AIToolParameter) -> GeminiPropertySchema {
        var items: GeminiPropertySchema?
        if let itemsBox = param.items {
            items = convertParameter(itemsBox.value)
        }

        return GeminiPropertySchema(
            type: param.type,
            description: param.description,
            enumValues: param.enumValues,
            items: items
        )
    }

    // MARK: - Stream Processing

    /// Process SSE stream - runs off MainActor to avoid blocking UI
    private nonisolated func processStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        var accumulatedUsage: GeminiUsageMetadata?

        for try await event in GeminiSSEParser.parseStream(from: bytes) {
            if Task.isCancelled {
                continuation.finish(throwing: AIProviderError.cancelled)
                return
            }

            switch event {
            case .contentPart(let part):
                switch part {
                case .text(let text):
                    continuation.yield(.textDelta(text))

                case .functionCall(let call, let signature):
                    // Gemini sends complete function calls in streaming (not partial)
                    // Convert args to JSON string
                    if let argsData = try? JSONEncoder().encode(call.args),
                       let argsString = String(data: argsData, encoding: .utf8) {
                        // Generate a unique ID for the tool call
                        let toolCallId = "gemini_\(call.name)_\(UUID().uuidString.prefix(8))"

                        // Emit complete tool call with thought signature (Gemini 3.0+)
                        let toolCall = AIToolCall(id: toolCallId, name: call.name, arguments: argsString, thoughtSignature: signature)
                        Self.logger.debug("Tool call complete: id=\(toolCallId), name=\(call.name), hasSignature=\(signature != nil)")
                        continuation.yield(.toolCallComplete(toolCall))
                    }

                case .functionResponse:
                    // Function responses are sent from client, not received
                    break
                }

            case .finishReason(let reason):
                let finishReason = mapFinishReason(reason)
                let usageStats = accumulatedUsage.map { usage in
                    AIUsageStats(
                        promptTokens: usage.inputTokens,
                        completionTokens: usage.outputTokens,
                        totalTokens: usage.totalTokenCount ?? (usage.inputTokens + usage.outputTokens)
                    )
                }
                continuation.yield(.responseComplete(usage: usageStats, finishReason: finishReason))

            case .usageMetadata(let usage):
                accumulatedUsage = usage

            case .error(let message):
                continuation.finish(throwing: AIProviderError.unknown(message))
                return
            }
        }

        continuation.finish()
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: GeminiResponse) -> AIProviderResponse {
        var text = ""
        var toolCalls: [AIToolCall] = []

        if let candidates = response.candidates {
            for candidate in candidates {
                if let content = candidate.content {
                    for part in content.parts {
                        switch part {
                        case .text(let t):
                            text += t

                        case .functionCall(let call, let signature):
                            if let argsData = try? JSONEncoder().encode(call.args),
                               let argsString = String(data: argsData, encoding: .utf8) {
                                let toolCallId = "gemini_\(call.name)_\(UUID().uuidString.prefix(8))"
                                toolCalls.append(AIToolCall(id: toolCallId, name: call.name, arguments: argsString, thoughtSignature: signature))
                            }

                        case .functionResponse:
                            // Function responses are from client, not in responses
                            break
                        }
                    }
                }
            }
        }

        let usage = response.usageMetadata.map { u in
            AIUsageStats(
                promptTokens: u.inputTokens,
                completionTokens: u.outputTokens,
                totalTokens: u.totalTokenCount ?? (u.inputTokens + u.outputTokens)
            )
        }

        let finishReason: AIProviderResponse.FinishReason?
        if let candidate = response.candidates?.first, let reason = candidate.finishReason {
            finishReason = mapFinishReason(reason)
        } else {
            finishReason = nil
        }

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

    private nonisolated func mapFinishReason(_ reason: String) -> AIProviderResponse.FinishReason? {
        switch reason.uppercased() {
        case "STOP":
            return .stop
        case "MAX_TOKENS":
            return .length
        case "SAFETY":
            return .contentFilter
        case "RECITATION":
            return .contentFilter
        case "OTHER":
            return nil
        default:
            return nil
        }
    }

    // MARK: - Error Handling

    private nonisolated func checkHTTPResponse(_ response: HTTPURLResponse, data: Data, modelID: String) throws {
        guard response.statusCode < 400 else {
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                throw mapGeminiError(errorResponse.error, modelID: modelID)
            }
            throw mapHTTPError(statusCode: response.statusCode, modelID: modelID)
        }
    }

    private nonisolated func mapGeminiError(_ error: GeminiError, modelID: String) -> AIProviderError {
        switch error.code {
        case 401, 403:
            return .invalidAPIKey
        case 429:
            return .rateLimited(retryAfter: nil)
        case 400:
            return .invalidResponse(error.message)
        case 404:
            return .modelNotAvailable(modelID)
        default:
            return .unknown(error.message)
        }
    }

    private nonisolated func mapHTTPError(statusCode: Int, modelID: String) -> AIProviderError {
        switch statusCode {
        case 401, 403:
            return .invalidAPIKey
        case 429:
            return .rateLimited(retryAfter: nil)
        case 404:
            return .modelNotAvailable(modelID)
        case 500...599:
            return .networkError("Server error (\(statusCode))")
        default:
            return .networkError("HTTP error \(statusCode)")
        }
    }

    private nonisolated func mapError(_ error: Error) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return .networkError("No internet connection")
            case NSURLErrorNetworkConnectionLost:
                return .networkError("Connection lost")
            case NSURLErrorTimedOut:
                return .networkError("Request timed out")
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .networkError(error.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }
}
#endif
