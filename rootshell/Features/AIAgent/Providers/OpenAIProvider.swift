#if !CHINA_BUILD
//
//  OpenAIProvider.swift
//  rootshell
//
//  OpenAI implementation of AIProvider protocol
//

import Foundation
import SwiftOpenAI
import os.log

/// OpenAI provider implementation using SwiftOpenAI SDK
@MainActor
final class OpenAIProvider: AIProvider {
    // MARK: - Static Properties
    
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "OpenAIProvider")
    
    static let providerID = "openai"
    static let displayName = "OpenAI"
    static let availableModels = AIProviderModel.openAIModels
    
    // MARK: - Instance Properties
    
    private var service: OpenAIService?
    private var currentTask: Task<AIProviderResponse, Error>?
    private struct SendableOpenAIService: @unchecked Sendable {
        nonisolated(unsafe) let service: OpenAIService
    }
    private let apiKey: String
    private let baseURL: String?
    
    var selectedModelID: String
    
    var isConfigured: Bool {
        service != nil
    }

    /// Whether this provider is using a custom endpoint
    var isCustomEndpoint: Bool {
        baseURL != nil
    }
    
    // MARK: - Initialization
    
    /// Initialize with OpenAI's default endpoint
    init(apiKey: String, selectedModelID: String = AIProviderModel.defaultModelID) {
        self.apiKey = apiKey
        self.baseURL = nil
        self.selectedModelID = selectedModelID
        
        if !apiKey.isEmpty {
            self.service = OpenAIServiceFactory.service(apiKey: apiKey)
        }
    }
    
    /// Initialize with a custom OpenAI-compatible endpoint.
    /// `baseURL` is whatever the user typed; it is resolved to an API root here so no call site
    /// can bypass the rule. The service is built even without a key because local servers
    /// (oMLX, Ollama, LM Studio) commonly need no credential at all.
    ///
    /// A keyless provider authenticates as `.none`, so no credential header is sent at all —
    /// some local servers reject a present-but-unknown token instead of ignoring it. Model
    /// discovery omits the header the same way, so listing models and inference never disagree.
    init(apiKey: String, baseURL: String, selectedModelID: String) {
        let root = CustomProviderConfig.resolvedAPIRoot(baseURL, format: .openAIChatCompletions)
        self.apiKey = apiKey
        self.baseURL = root
        self.selectedModelID = selectedModelID

        // The resolved root already carries its version segment, so the SDK must not inject one —
        // an empty overrideVersion suppresses it and avoids the /v1/v1 paths that 404 everywhere.
        let (origin, proxyPath) = Self.splitBaseURL(root)
        self.service = OpenAIServiceFactory.service(
            authorization: apiKey.isEmpty ? .none : .bearer(apiKey),
            overrideBaseURL: origin,
            proxyPath: proxyPath,
            overrideVersion: ""
        )
    }
    
    // MARK: - AIProvider Protocol
    
    func sendMessage(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) async throws -> AIProviderResponse {
        guard let service = service else {
            throw AIProviderError.notConfigured
        }
        
        // Convert messages to OpenAI format
        var openAIMessages = [ChatCompletionParameters.Message]()
        
        // Add system prompt
        openAIMessages.append(.init(
            role: .system,
            content: .text(systemPrompt)
        ))
        
        // Add conversation messages
        for message in messages {
            if let openAIMessage = convertMessage(message) {
                openAIMessages.append(openAIMessage)
            }
        }
        
        // Convert tools to OpenAI format
        let openAITools = tools.map { tool -> ChatCompletionParameters.Tool in
            let schema = JSONSchema(
                type: .object,
                properties: tool.parameters.properties.mapValues { param in
                    Self.convertParameterToSchema(param)
                },
                required: tool.parameters.required,
                additionalProperties: false
            )
            
            // Use strict mode only for tools where all properties are required
            let allPropertiesRequired = tool.parameters.properties.count == tool.parameters.required.count
            return ChatCompletionParameters.Tool(
                function: ChatCompletionParameters.ChatFunction(
                    name: tool.name,
                    strict: allPropertiesRequired,
                    description: tool.description,
                    parameters: schema
                )
            )
        }
        
        // Build parameters
        // Look up model info for capabilities and limits
        let modelInfo: AIProviderModel?
        if isCustomEndpoint {
            // For custom endpoints, check stored custom models across all providers
            modelInfo = AICredentialsManager.shared.findCustomModel(id: selectedModelID)
        } else {
            modelInfo = AIProviderModel.openAIModel(id: selectedModelID)
        }
        
        let modelSupportsTemperature = modelInfo?.supportsTemperature ?? isCustomEndpoint
        let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

        // Get user-configured or default temperature
        let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
            for: OpenAIProvider.providerID,
            supportsTemperature: modelSupportsTemperature
        )

        Self.logger.debug("Using maxTokens=\(maxTokens) for model \(self.selectedModelID)")

        // Create parameters - use max_completion_tokens for OpenAI, max_tokens for custom endpoints
        var parameters = ChatCompletionParameters(
            messages: openAIMessages,
            model: .custom(selectedModelID),
            tools: openAITools.isEmpty ? nil : openAITools,
            temperature: effectiveTemperature
        )
        
        // OpenAI's newer models require max_completion_tokens instead of max_tokens
        // Custom endpoints typically use max_tokens (OpenAI-compatible API)
        if isCustomEndpoint {
            parameters.maxTokens = maxTokens
        } else {
            parameters.maCompletionTokens = maxTokens  // SDK typo: should be maxCompletionTokens
        }
        
        // Create and store the task for cancellation support
        let task = Task<AIProviderResponse, Error> {
            let result = try await service.startChat(parameters: parameters)
            return try parseResponse(result)
        }
        
        currentTask = task
        
        do {
            let response = try await task.value
            currentTask = nil
            return response
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch {
            currentTask = nil
            throw Self.mapError(error, modelID: selectedModelID)
        }
    }
    
    func cancel() {
        currentTask?.cancel()
        currentStreamTask?.cancel()
        currentTask = nil
        currentStreamTask = nil
    }
    
    // MARK: - Streaming Implementation
    
    private var currentStreamTask: Task<Void, Never>?
    
    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        // Check if we should use Chat Completions fallback for custom endpoints
        let useResponsesAPI = !isCustomEndpoint || AICredentialsManager.shared.usesResponsesAPI(for: selectedModelID)
        
        if !useResponsesAPI {
            // Fall back to Chat Completions API (wrapped as stream)
            return sendMessageStreamViaChatCompletions(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools
            )
        }
        
        // Use Responses API with streaming
        return sendMessageStreamViaResponsesAPI(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )
    }
    
    /// Stream via Chat Completions API (fallback for custom endpoints)
    private func sendMessageStreamViaChatCompletions(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // This method uses sendMessage which is MainActor-isolated
            // The actual network call is handled by the SDK on a background thread
            let task = Task { @MainActor in
                do {
                    // Use the existing non-streaming sendMessage
                    let response = try await self.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools
                    )

                    // Emit the complete response as stream events
                    switch response.content {
                    case .text(let text):
                        if !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                    case .toolCalls(let calls):
                        for call in calls {
                            continuation.yield(.toolCallComplete(call))
                        }
                    case .textAndToolCalls(let text, let calls):
                        if !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        for call in calls {
                            continuation.yield(.toolCallComplete(call))
                        }
                    }

                    continuation.yield(.responseComplete(usage: response.usage, finishReason: response.finishReason))
                    continuation.finish()

                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
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
    
    /// Stream via Responses API (default for OpenAI)
    private func sendMessageStreamViaResponsesAPI(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        // Check if streaming is disabled for this custom endpoint
        let useStreaming = !isCustomEndpoint || AICredentialsManager.shared.isStreamingEnabled(for: selectedModelID)

        if !useStreaming {
            // Use non-streaming Responses API
            return sendMessageNonStreamViaResponsesAPI(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools
            )
        }

        // Use streaming Responses API
        return sendMessageStreamingViaResponsesAPI(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )
    }

    /// Non-streaming Responses API (for models that break with streaming)
    private func sendMessageNonStreamViaResponsesAPI(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard let service = service else {
                    continuation.finish(throwing: AIProviderError.notConfigured)
                    return
                }

                do {
                    // Convert messages to Responses API InputItem format
                    let inputItems = Self.convertMessagesToInputItems(messages, isCustomEndpoint: isCustomEndpoint)

                    // Debug: log the input items being sent
                    Self.logger.debug("sendMessageNonStream: Sending \(inputItems.count) input items")
                    for (index, item) in inputItems.enumerated() {
                        Self.logger.debug("  Item \(index): \(String(describing: item))")
                    }

                    // Convert tools to Responses API Tool format
                    let responsesTools = Self.convertToolsToResponsesFormat(tools)

                    // Get model info
                    let modelInfo: AIProviderModel?
                    if isCustomEndpoint {
                        modelInfo = AICredentialsManager.shared.findCustomModel(id: selectedModelID)
                    } else {
                        modelInfo = AIProviderModel.openAIModel(id: selectedModelID)
                    }

                    let modelSupportsTemperature = modelInfo?.supportsTemperature ?? isCustomEndpoint
                    let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

                    // Get user-configured or default temperature
                    let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
                        for: OpenAIProvider.providerID,
                        supportsTemperature: modelSupportsTemperature
                    )

                    Self.logger.debug("sendMessageNonStream: Using maxTokens=\(maxTokens) for model \(self.selectedModelID)")

                    // Create parameters for Responses API (non-streaming)
                    let parameters = ModelResponseParameter(
                        input: .array(inputItems),
                        model: .custom(selectedModelID),
                        instructions: systemPrompt,
                        maxOutputTokens: maxTokens,
                        temperature: effectiveTemperature,
                        tools: responsesTools.isEmpty ? nil : responsesTools
                    )

                    // Call non-streaming Responses API
                    let response = try await service.responseCreate(parameters)

                    // Extract and emit response as stream events
                    try self.emitResponseAsStreamEvents(response: response, continuation: continuation)

                } catch {
                    // Check for cancellation first
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }
                    // Debug: log the full error details
                    Self.logger.error("sendMessageNonStream failed: \(error)")
                    if let apiError = error as? APIError {
                        Self.logger.error("APIError details: \(String(describing: apiError))")
                    }
                    continuation.finish(throwing: Self.mapError(error, modelID: selectedModelID))
                }
            }

            currentStreamTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Extract content from ResponseModel and emit as stream events
    private func emitResponseAsStreamEvents(
        response: ResponseModel,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) throws {
        var accumulatedText = ""
        var toolCalls: [AIToolCall] = []

        // Process output items
        if let outputItems = response.output {
            for item in outputItems {
                switch item {
                case .message(let message):
                    // Extract text from message content
                    for contentItem in message.content {
                        switch contentItem {
                        case .outputText(let outputText):
                            accumulatedText += outputText.text
                        case .refusal:
                            // Ignore refusals for now
                            break
                        }
                    }

                case .functionCall(let funcCall):
                    // Extract function call
                    guard let name = funcCall.name,
                          let arguments = funcCall.arguments else {
                        Self.logger.warning("Function call missing name or arguments: callId=\(funcCall.callId)")
                        continue
                    }
                    let toolCall = AIToolCall(
                        id: funcCall.callId,
                        name: name,
                        arguments: arguments
                    )
                    toolCalls.append(toolCall)

                default:
                    // Ignore other output types (reasoning, file search, etc.)
                    break
                }
            }
        }

        // Emit text if present
        if !accumulatedText.isEmpty {
            continuation.yield(.textDelta(accumulatedText))
        }

        // Check for MiniMax XML tool calls in accumulated text
        let miniMaxResult = MiniMaxToolCallParser.parse(accumulatedText)
        if !miniMaxResult.toolCalls.isEmpty {
            Self.logger.debug("NonStream: Found \(miniMaxResult.toolCalls.count) MiniMax XML tool call(s)")
            for toolCall in miniMaxResult.toolCalls {
                continuation.yield(.toolCallComplete(toolCall))
            }
        }

        // Emit tool calls
        for toolCall in toolCalls {
            continuation.yield(.toolCallComplete(toolCall))
        }

        // Extract usage and finish reason
        let usage = Self.extractUsage(from: response)
        let finishReason = Self.extractFinishReason(from: response)

        continuation.yield(.responseComplete(usage: usage, finishReason: finishReason))
        continuation.finish()
    }

    /// Streaming Responses API implementation
    private func sendMessageStreamingViaResponsesAPI(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let isConfigured = self.isConfigured
            let modelID = self.selectedModelID
            let isCustomEndpoint = self.isCustomEndpoint
            let serviceBox = service.map(SendableOpenAIService.init)

            // Get model info and user-configured temperature on MainActor
            let modelInfo: AIProviderModel?
            if isCustomEndpoint {
                modelInfo = AICredentialsManager.shared.findCustomModel(id: modelID)
            } else {
                modelInfo = AIProviderModel.openAIModel(id: modelID)
            }

            let modelSupportsTemperature = modelInfo?.supportsTemperature ?? isCustomEndpoint
            let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens
            let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
                for: OpenAIProvider.providerID,
                supportsTemperature: modelSupportsTemperature
            )

            Self.logger.debug("sendMessageStream: Using maxTokens=\(maxTokens) for model \(modelID)")

            // Run stream processing off MainActor to avoid UI stalls
            let streamTask = Task.detached { [isConfigured, modelID, isCustomEndpoint, maxTokens, effectiveTemperature, serviceBox] in
                guard isConfigured, let service = serviceBox?.service else {
                    continuation.finish(throwing: AIProviderError.notConfigured)
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
                        try await Self.executeStreamRequest(
                            service: service,
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            modelID: modelID,
                            isCustomEndpoint: isCustomEndpoint,
                            maxTokens: maxTokens,
                            effectiveTemperature: effectiveTemperature,
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
                        continuation.finish(throwing: Self.mapError(error, modelID: modelID))
                        return
                    }
                }

                // All retries exhausted
                if let error = lastError {
                    continuation.finish(throwing: Self.mapError(error, modelID: modelID))
                }
            }

            // Store task reference synchronously to ensure cancel() works immediately
            // This is safe because we're on MainActor (the AsyncThrowingStream closure
            // runs synchronously in the calling context)
            self.currentStreamTask = streamTask

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }
    
    /// Execute the actual stream request (extracted for retry logic)
    private nonisolated static func executeStreamRequest(
        service: OpenAIService,
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        modelID: String,
        isCustomEndpoint: Bool,
        maxTokens: Int,
        effectiveTemperature: Double?,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        // Convert messages to Responses API InputItem format
        let inputItems = Self.convertMessagesToInputItems(messages, isCustomEndpoint: isCustomEndpoint)
        
        // Convert tools to Responses API Tool format
        let responsesTools = Self.convertToolsToResponsesFormat(tools)

        // Create parameters for Responses API
        let parameters = ModelResponseParameter(
            input: .array(inputItems),
            model: .custom(modelID),
            instructions: systemPrompt,
            maxOutputTokens: maxTokens,
            temperature: effectiveTemperature,
            tools: responsesTools.isEmpty ? nil : responsesTools
        )
        
        // Start streaming
        let stream = try await service.responseCreateStream(parameters)
        
        // Track tool call state for assembly
        var toolCallBuilders: [String: ToolCallBuilder] = [:]
        // Accumulate text for MiniMax XML parsing at end
        var accumulatedText = ""
        
        for try await event in stream {
            if Task.isCancelled {
                continuation.finish(throwing: AIProviderError.cancelled)
                return
            }
            
            switch event {
                // Text streaming
            case .outputTextDelta(let delta):
                accumulatedText += delta.delta
                continuation.yield(.textDelta(delta.delta))
                
                // Function call arguments streaming
            case .functionCallArgumentsDelta(let delta):
                let itemId = delta.itemId
                if toolCallBuilders[itemId] == nil {
                    toolCallBuilders[itemId] = ToolCallBuilder(id: itemId)
                }
                toolCallBuilders[itemId]?.appendArguments(delta.delta)
                continuation.yield(.toolCallDelta(
                    id: itemId,
                    name: toolCallBuilders[itemId]?.name,
                    argumentsDelta: delta.delta
                ))
                
                // Function call arguments complete
            case .functionCallArgumentsDone(let done):
                if let builder = toolCallBuilders[done.itemId] {
                    if let args = done.arguments {
                        builder.arguments = args
                    }
                    if let name = done.name {
                        builder.name = name
                    }
                }
                
                // Output item done - check for complete tool calls
            case .outputItemDone(let itemDone):
                // Extract function call from done item if present
                if case .functionCall(let funcCall) = itemDone.item {
                    // Only emit complete tool call if we have both name and arguments
                    guard let name = funcCall.name,
                          let arguments = funcCall.arguments else {
                        Self.logger.warning("Function call missing name or arguments: callId=\(funcCall.callId)")
                        continue
                    }
                    let toolCall = AIToolCall(
                        id: funcCall.callId,
                        name: name,
                        arguments: arguments
                    )
                    continuation.yield(.toolCallComplete(toolCall))
                }
                
                // Response completed successfully
            case .responseCompleted(let completed):
                // Check accumulated text for MiniMax XML tool calls
                let miniMaxResult = MiniMaxToolCallParser.parse(accumulatedText)
                if !miniMaxResult.toolCalls.isEmpty {
                    Self.logger.debug("Stream: Found \(miniMaxResult.toolCalls.count) MiniMax XML tool call(s)")
                    for toolCall in miniMaxResult.toolCalls {
                        continuation.yield(.toolCallComplete(toolCall))
                    }
                }
                let usage = Self.extractUsage(from: completed.response)
                let finishReason = Self.extractFinishReason(from: completed.response)
                continuation.yield(.responseComplete(usage: usage, finishReason: finishReason))
                continuation.finish()
                return
                
                // Response failed
            case .responseFailed(let failed):
                let errorMessage = failed.response.error?.message ?? "Unknown error"
                Self.logger.error("Response failed: \(errorMessage)")
                continuation.finish(throwing: AIProviderError.unknown(errorMessage))
                return
                
                // Response incomplete (e.g., hit token limit)
            case .responseIncomplete(let incomplete):
                // Check accumulated text for MiniMax XML tool calls
                let miniMaxResult = MiniMaxToolCallParser.parse(accumulatedText)
                if !miniMaxResult.toolCalls.isEmpty {
                    Self.logger.debug("Stream incomplete: Found \(miniMaxResult.toolCalls.count) MiniMax XML tool call(s)")
                    for toolCall in miniMaxResult.toolCalls {
                        continuation.yield(.toolCallComplete(toolCall))
                    }
                }
                let usage = Self.extractUsage(from: incomplete.response)
                continuation.yield(.responseComplete(usage: usage, finishReason: .length))
                continuation.finish()
                return
                
                // Output item added - capture tool call name
            case .outputItemAdded(let itemAdded):
                if case .functionCall(let funcCall) = itemAdded.item {
                    if toolCallBuilders[funcCall.callId] == nil {
                        toolCallBuilders[funcCall.callId] = ToolCallBuilder(id: funcCall.callId)
                    }
                    toolCallBuilders[funcCall.callId]?.name = funcCall.name
                }
                
                // Error event
            case .error(let errorEvent):
                let errorMessage = errorEvent.message ?? errorEvent.code ?? "Unknown API error"
                Self.logger.error("Stream error: \(errorMessage)")
                continuation.finish(throwing: AIProviderError.unknown(errorMessage))
                return
                
            default:
                // Ignore other events (reasoning, file search, etc.)
                break
            }
        }
        
        // Stream ended without completion event - check for MiniMax XML tool calls
        let miniMaxResult = MiniMaxToolCallParser.parse(accumulatedText)
        if !miniMaxResult.toolCalls.isEmpty {
            Self.logger.debug("Stream ended: Found \(miniMaxResult.toolCalls.count) MiniMax XML tool call(s)")
            for toolCall in miniMaxResult.toolCalls {
                continuation.yield(.toolCallComplete(toolCall))
            }
        }
        continuation.finish()
    }
    
    // MARK: - Responses API Conversion Helpers
    
    /// Helper class to build tool calls from streaming deltas
    /// Marked nonisolated to allow use from detached tasks in stream processing
    /// Thread safety is handled by single-task usage pattern (one builder per tool call)
    /// Internal so ChatGPTProvider's stream loop can reuse it.
    final class ToolCallBuilder: @unchecked Sendable {
        nonisolated let id: String
        nonisolated(unsafe) var name: String?
        nonisolated(unsafe) var arguments: String = ""

        nonisolated init(id: String) {
            self.id = id
        }

        nonisolated func appendArguments(_ delta: String) {
            arguments += delta
        }
    }
    
    /// Convert AIAgentMessages to Responses API InputItems
    /// Internal so ChatGPTProvider can share the transcript rebuild.
    nonisolated static func convertMessagesToInputItems(_ messages: [AIAgentMessage], isCustomEndpoint: Bool) -> [InputItem] {
        var items: [InputItem] = []
        
        for message in messages {
            switch message.content {
            case .text(let text):
                let role: String
                switch message.role {
                case .user:
                    role = "user"
                case .assistant:
                    role = "assistant"
                case .system:
                    role = "system"
                case .tool:
                    // Tool results are handled separately
                    continue
                }
                items.append(.message(InputMessage(role: role, content: .text(text))))

            case .textWithThinking(let text, _):
                // For OpenAI, just use the text content (thinking is Anthropic-specific)
                guard message.role == .assistant else { continue }
                items.append(.message(InputMessage(role: "assistant", content: .text(text))))

            case .toolCall(let call):
                // Skip XML-parsed tool calls - VLLM doesn't recognize synthetic IDs
                if call.isFromXMLParsing {
                    continue
                }
                // Previous tool call from assistant
                // Only provide custom item IDs for custom endpoints (vLLM needs this)
                // Official OpenAI should use nil to let API manage IDs
                let itemId: String? = isCustomEndpoint ? "item_\(call.id)" : nil
                items.append(.functionToolCall(FunctionToolCall(
                    arguments: call.arguments,
                    callId: call.id,
                    name: call.name,
                    id: itemId
                )))

            case .toolCalls(let calls, let precedingText, _):
                // Multiple tool calls from assistant (with optional preceding text per API best practices)

                // Add assistant message with text content first if present
                if let text = precedingText, !text.isEmpty {
                    items.append(.message(InputMessage(role: "assistant", content: .text(text))))
                }

                // Add function tool calls - skip XML-parsed ones
                for call in calls where !call.isFromXMLParsing {
                    let itemId: String? = isCustomEndpoint ? "item_\(call.id)" : nil
                    items.append(.functionToolCall(FunctionToolCall(
                        arguments: call.arguments,
                        callId: call.id,
                        name: call.name,
                        id: itemId
                    )))
                }
                
            case .toolResult(let toolCallId, let output, _, let isFromXMLToolCall):
                if isFromXMLToolCall {
                    // For XML-parsed tool calls (MiniMax), send result as text to avoid API errors
                    // VLLM doesn't recognize our synthetic tool call IDs
                    items.append(.message(InputMessage(
                        role: "user",
                        content: .text("[Tool Result]\n\(output)")
                    )))
                } else {
                    // Standard structured tool result
                    // Only provide custom output IDs for custom endpoints (vLLM needs this)
                    let outputItemId: String? = isCustomEndpoint ? "output_\(toolCallId)" : nil
                    items.append(.functionToolCallOutput(FunctionToolCallOutput(
                        callId: toolCallId,
                        output: output,
                        id: outputItemId
                    )))
                }

            case .toolResults(let results):
                // Batched tool results from parallel tool calls
                for toolResult in results {
                    if toolResult.isFromXMLToolCall {
                        // For XML-parsed tool calls, send result as text
                        items.append(.message(InputMessage(
                            role: "user",
                            content: .text("[Tool Result for \(toolResult.toolCallId)]\n\(toolResult.output)")
                        )))
                    } else {
                        // Standard structured tool result
                        let outputItemId: String? = isCustomEndpoint ? "output_\(toolResult.toolCallId)" : nil
                        items.append(.functionToolCallOutput(FunctionToolCallOutput(
                            callId: toolResult.toolCallId,
                            output: toolResult.output,
                            id: outputItemId
                        )))
                    }
                }
            }
        }

        return items
    }
    
    /// Convert AIAgentTools to Responses API Tools
    /// Internal so ChatGPTProvider can share the tool serialization.
    nonisolated static func convertToolsToResponsesFormat(_ tools: [AIAgentTool]) -> [Tool] {
        tools.map { tool -> Tool in
            let schema = JSONSchema(
                type: .object,
                properties: tool.parameters.properties.mapValues { param in
                    Self.convertParameterToSchema(param)
                },
                required: tool.parameters.required,
                additionalProperties: false
            )
            
            let allPropertiesRequired = tool.parameters.properties.count == tool.parameters.required.count
            return .function(Tool.FunctionTool(
                name: tool.name,
                parameters: schema,
                strict: allPropertiesRequired,
                description: tool.description
            ))
        }
    }
    
    /// Extract usage stats from ResponseModel
    nonisolated static func extractUsage(from response: ResponseModel) -> AIUsageStats? {
        guard let usage = response.usage else { return nil }
        return AIUsageStats(
            promptTokens: usage.inputTokens ?? 0,
            completionTokens: usage.outputTokens ?? 0,
            totalTokens: usage.totalTokens ?? 0
        )
    }
    
    /// Extract finish reason from ResponseModel
    nonisolated static func extractFinishReason(from response: ResponseModel) -> AIProviderResponse.FinishReason? {
        guard let status = response.status else { return nil }
        switch status {
        case .completed:
            return .stop
        case .incomplete:
            return .length
        case .failed, .cancelled:
            return nil
        default:
            return nil
        }
    }
    
    // MARK: - URL Helpers

    /// Split an already-resolved API root like "https://host.com/openai/v1" into
    /// origin ("https://host.com") and path prefix ("openai/v1").
    /// The SDK's proxyPath parameter prepends the path prefix to endpoint paths,
    /// working around the SDK replacing the base URL's path instead of appending.
    /// Pair it with `overrideVersion: ""` so the SDK does not append a second version segment.
    private static func splitBaseURL(_ baseURL: String) -> (origin: String, proxyPath: String?) {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host else {
            return (baseURL, nil)
        }

        // `URL.host` strips the brackets from an IPv6 literal, so put them back before
        // interpolating: "::1" would otherwise rebuild as http://::1:8000.
        let literalHost = host.contains(":") ? "[\(host)]" : host
        var origin = "\(scheme)://\(literalHost)"
        if let port = url.port {
            origin += ":\(port)"
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (origin, path.isEmpty ? nil : path)
    }

    // MARK: - Private Helpers (Legacy Chat Completions)
    
    private func convertMessage(_ message: AIAgentMessage) -> ChatCompletionParameters.Message? {
        switch message.content {
        case .text(let text):
            // Send the full raw text (including any <think> tags) to preserve context
            let role: ChatCompletionParameters.Message.Role
            switch message.role {
            case .system:
                role = .system
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            case .tool:
                // Tool messages are handled separately
                return nil
            }
            return .init(role: role, content: .text(text))

        case .textWithThinking(let text, _):
            // For OpenAI, just use the text content (thinking is Anthropic-specific)
            guard message.role == .assistant else { return nil }
            return .init(role: .assistant, content: .text(text))

        case .toolCall(let call):
            // Skip XML-parsed tool calls - VLLM doesn't recognize synthetic IDs
            if call.isFromXMLParsing {
                return nil
            }
            // Assistant message with tool calls
            return .init(
                role: .assistant,
                content: .text(""),
                toolCalls: [ToolCall(
                    id: call.id,
                    function: FunctionCall(arguments: call.arguments, name: call.name)
                )]
            )
            
        case .toolCalls(let calls, let precedingText, _):
            // Skip XML-parsed tool calls
            let nonXMLCalls = calls.filter { !$0.isFromXMLParsing }
            if nonXMLCalls.isEmpty {
                return nil
            }
            // Assistant message with multiple tool calls (include preceding text per API best practices)
            let toolCalls = nonXMLCalls.map { call in
                ToolCall(
                    id: call.id,
                    function: FunctionCall(arguments: call.arguments, name: call.name)
                )
            }
            return .init(
                role: .assistant,
                content: .text(precedingText ?? ""),
                toolCalls: toolCalls
            )
            
        case .toolResult(let toolCallId, let output, _, let isFromXMLToolCall):
            if isFromXMLToolCall {
                // For XML-parsed tool calls (MiniMax), send result as user message
                return .init(role: .user, content: .text("[Tool Result]\n\(output)"))
            }
            // Standard tool result message
            return .init(
                role: .tool,
                content: .text(output),
                toolCallID: toolCallId
            )

        case .toolResults:
            // Batched tool results - should not reach here in Chat Completions API
            // The session should use separate messages for Chat Completions
            // Return nil to skip, individual results will be handled separately
            return nil
        }
    }
    
    private func parseResponse(_ result: ChatCompletionObject) throws -> AIProviderResponse {
        guard let choice = result.choices?.first else {
            throw AIProviderError.invalidResponse("No choices in response")
        }
        
        // Debug log the raw response structure
        Self.logger.debug("parseResponse: choice.finishReason raw = \(String(describing: choice.finishReason))")
        Self.logger.debug("parseResponse: choice.message?.content = \(choice.message?.content ?? "<nil>")")
        Self.logger.debug("parseResponse: choice.message?.toolCalls count = \(choice.message?.toolCalls?.count ?? 0)")
        
        let usage: AIUsageStats?
        if let resultUsage = result.usage {
            usage = AIUsageStats(
                promptTokens: resultUsage.promptTokens ?? 0,
                completionTokens: resultUsage.completionTokens ?? 0,
                totalTokens: resultUsage.totalTokens ?? 0
            )
        } else {
            usage = nil
        }
        
        let finishReason: AIProviderResponse.FinishReason?
        if let reason = choice.finishReason {
            switch reason {
            case .string(let value):
                Self.logger.debug("parseResponse: finishReason string value = '\(value)'")
                finishReason = AIProviderResponse.FinishReason(rawValue: value)
                if finishReason == nil {
                    Self.logger.warning("parseResponse: Unknown finishReason value '\(value)' - not in FinishReason enum")
                }
            case .int(let value):
                Self.logger.debug("parseResponse: finishReason int value = \(value)")
                finishReason = nil
            }
        } else {
            Self.logger.debug("parseResponse: finishReason is nil")
            finishReason = nil
        }
        
        Self.logger.debug("parseResponse: parsed finishReason = \(String(describing: finishReason))")
        
        // Check for tool calls
        if let toolCalls = choice.message?.toolCalls, !toolCalls.isEmpty {
            let aiToolCalls = toolCalls.compactMap { call -> AIToolCall? in
                guard let id = call.id, let name = call.function.name else {
                    return nil
                }
                return AIToolCall(
                    id: id,
                    name: name,
                    arguments: call.function.arguments
                )
            }
            
            // Check if there's also text content
            if let textContent = choice.message?.content, !textContent.isEmpty {
                return AIProviderResponse(
                    content: .textAndToolCalls(textContent, aiToolCalls),
                    usage: usage,
                    finishReason: finishReason
                )
            }
            
            return AIProviderResponse(
                content: .toolCalls(aiToolCalls),
                usage: usage,
                finishReason: finishReason
            )
        }
        
        // Check for MiniMax XML tool calls in text content
        let text = choice.message?.content ?? ""
        let miniMaxResult = MiniMaxToolCallParser.parse(text)
        if !miniMaxResult.toolCalls.isEmpty {
            Self.logger.debug("parseResponse: Found \(miniMaxResult.toolCalls.count) MiniMax XML tool call(s)")
            if miniMaxResult.remainingText.isEmpty {
                return AIProviderResponse(
                    content: .toolCalls(miniMaxResult.toolCalls),
                    usage: usage,
                    finishReason: finishReason
                )
            } else {
                return AIProviderResponse(
                    content: .textAndToolCalls(miniMaxResult.remainingText, miniMaxResult.toolCalls),
                    usage: usage,
                    finishReason: finishReason
                )
            }
        }
        
        // Text-only response
        return AIProviderResponse(
            content: .text(text),
            usage: usage,
            finishReason: finishReason
        )
    }
    
    private nonisolated static func convertParameterToSchema(_ param: AIToolParameter) -> JSONSchema {
        let schemaType = Self.jsonSchemaType(from: param.type)
        
        // Handle array types with items
        if schemaType == .array, let itemsBox = param.items {
            return JSONSchema(
                type: schemaType,
                description: param.description,
                items: Self.convertParameterToSchema(itemsBox.value)
            )
        }
        
        // Handle non-array types
        return JSONSchema(
            type: schemaType,
            description: param.description,
            enum: param.enumValues
        )
    }
    
    private nonisolated static func jsonSchemaType(from typeString: String) -> JSONSchemaType {
        switch typeString.lowercased() {
        case "string":
            return .string
        case "number":
            return .number
        case "integer":
            return .integer
        case "boolean":
            return .boolean
        case "object":
            return .object
        case "array":
            return .array
        default:
            return .string
        }
    }
    
    /// Internal so ChatGPTProvider can fall back to it for generic failures.
    nonisolated static func mapError(_ error: Error, modelID: String?) -> AIProviderError {
        // First, try to extract the description from SwiftOpenAI's APIError
        var errorDescription: String
        var statusCode: Int?
        
        if let apiError = error as? APIError {
            switch apiError {
            case .requestFailed(let description):
                errorDescription = description
            case .responseUnsuccessful(let description, let code):
                errorDescription = description
                statusCode = code
            case .invalidData:
                errorDescription = "Invalid data received"
            case .jsonDecodingFailure(let description):
                errorDescription = "JSON decoding failed: \(description)"
            case .dataCouldNotBeReadMissingData(let description):
                errorDescription = description
            case .bothDecodingStrategiesFailed:
                errorDescription = "Failed to decode response"
            case .timeOutError:
                return .networkError("Request timed out")
            }
        } else {
            errorDescription = error.localizedDescription
        }
        
        let nsError = error as NSError
        
        // Check for common HTTP status codes in the error
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return .networkError("No internet connection")
            case NSURLErrorNetworkConnectionLost:
                return .networkError("Connection lost (tunnel may have closed)")
            case NSURLErrorTimedOut:
                return .networkError("Request timed out")
            default:
                break
            }
        }
        
        // Check error description for common API errors
        let descriptionLower = errorDescription.lowercased()
        
        if descriptionLower.contains("invalid api key") || descriptionLower.contains("invalid_api_key") ||
            descriptionLower.contains("incorrect api key") {
            return .invalidAPIKey
        }
        
        if descriptionLower.contains("rate limit") || descriptionLower.contains("rate_limit") {
            return .rateLimited(retryAfter: nil)
        }
        
        if descriptionLower.contains("quota") || descriptionLower.contains("insufficient_quota") {
            return .quotaExceeded
        }
        
        // Check for model not found errors
        if descriptionLower.contains("model") && (descriptionLower.contains("not found") || descriptionLower.contains("does not exist")) {
            return .modelNotAvailable(modelID ?? "unknown")
        }
        
        // Check for authentication errors by status code
        if statusCode == 401 {
            return .invalidAPIKey
        }
        
        if statusCode == 404 && descriptionLower.contains("model") {
            return .modelNotAvailable(modelID ?? "unknown")
        }
        
        if statusCode == 429 {
            return .rateLimited(retryAfter: nil)
        }
        
        return .unknown(errorDescription)
    }
    
}
#endif
