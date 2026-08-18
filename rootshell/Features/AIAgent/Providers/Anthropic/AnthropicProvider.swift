#if !CHINA_BUILD
//
//  AnthropicProvider.swift
//  rootshell
//
//  Anthropic Messages API provider implementation
//

import Foundation
import os.log

/// Anthropic provider implementation using native URLSession
@MainActor
final class AnthropicProvider: AIProvider {
    // MARK: - Static Properties

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AnthropicProvider")

    static let providerID = "anthropic"
    static let displayName = "Anthropic"
    static let defaultBaseURL = "https://api.anthropic.com/v1"
    static let apiVersion = "2023-06-01"

    static var availableModels: [AIProviderModel] {
        AIProviderModel.anthropicModels
    }

    // MARK: - Instance Properties

    private let apiKey: String
    private nonisolated let baseURL: String
    private nonisolated let isCustomEndpoint: Bool
    private var currentTask: Task<Void, Never>?

    var selectedModelID: String

    /// A custom endpoint may be an unauthenticated local server, so an empty key is a valid
    /// configuration there rather than a missing one.
    var isConfigured: Bool {
        !apiKey.isEmpty || isCustomEndpoint
    }

    /// The exact URL every request hits. Surfaced in errors so a wrong path is self-diagnosing
    /// instead of being reported as a missing model.
    nonisolated var messagesURLString: String {
        "\(baseURL)/messages"
    }

    // MARK: - Initialization

    /// Initialize for direct Anthropic API
    init(apiKey: String, selectedModelID: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.baseURL = Self.defaultBaseURL
        self.isCustomEndpoint = false
        self.selectedModelID = selectedModelID
    }

    /// Initialize for custom Anthropic-compatible endpoint.
    /// `baseURL` is whatever the user typed; it is resolved to an API root here so no call site
    /// can bypass the rule.
    init(apiKey: String, baseURL: String, selectedModelID: String) {
        self.apiKey = apiKey
        self.baseURL = CustomProviderConfig.resolvedAPIRoot(baseURL, format: .anthropicMessages)
        self.isCustomEndpoint = true
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

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return AnthropicMessageHelpers.parseResponse(anthropicResponse)
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

        // Process SSE stream — convert bytes → AnthropicSSEEvent → AIProviderStreamEvent
        // via the shared helper. The Bedrock provider does the same with its own
        // binary-frame parser feeding into `processEvents`.
        let events = AnthropicSSEParser.parseStream(from: bytes)
        try await AnthropicMessageHelpers.processEvents(events, continuation: continuation)
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
        guard let url = URL(string: messagesURLString) else {
            throw AIProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Omitted rather than sent empty: an empty x-api-key reads as a failed auth attempt on
        // servers that would otherwise allow anonymous access.
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Anthropic-specific request semantics (adaptive thinking, display:summarized) must only
        // apply when talking to the real Anthropic API. Custom anthropic-compatible endpoints may
        // reuse these model IDs without supporting the matching semantics, so keep legacy behavior
        // (explicit budget + interleaved-thinking beta header) for them.
        // Opus 4.x stays listed even though we no longer offer it: a stale stored
        // selection or a custom gateway model ID would 400 on `enabled` + budget.
        let adaptivePrefixes = isCustomEndpoint
            ? ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-4-6", "claude-sonnet-5"]
            : ["claude-opus-5", "claude-opus-4-", "claude-sonnet-4-6", "claude-sonnet-5"]
        let usesAdaptiveThinking = adaptivePrefixes.contains { selectedModelID.hasPrefix($0) }
        if !usesAdaptiveThinking {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }

        // Check if model supports thinking
        let modelInfo = AIProviderModel.anthropicModel(id: selectedModelID)
        let supportsThinking = modelInfo?.supportsThinking ?? false

        // Get max tokens for the model tier
        let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

        let anthropicMessages = AnthropicMessageHelpers.buildMessages(messages)
        let anthropicTools = AnthropicMessageHelpers.buildTools(tools)

        // Get user-configured or default temperature
        // Note: When thinking is enabled, temperature must be nil (API requirement)
        let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
            for: AnthropicProvider.providerID,
            supportsTemperature: !supportsThinking
        )

        let anthropicRequest = AnthropicRequest(
            model: selectedModelID,
            messages: anthropicMessages,
            system: systemPrompt,
            maxTokens: maxTokens,
            tools: anthropicTools.isEmpty ? nil : anthropicTools,
            stream: stream,
            temperature: effectiveTemperature,
            thinking: supportsThinking ? thinkingConfig(for: selectedModelID, usesAdaptive: usesAdaptiveThinking, isCustomEndpoint: isCustomEndpoint) : nil
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(anthropicRequest)

        Self.logger.debug("Anthropic request: model=\(self.selectedModelID), stream=\(stream), messages=\(anthropicMessages.count)")

        return request
    }

    /// Opus 5, Opus 4.8, and Sonnet 5 omit thinking content by default; opt in to
    /// "summarized" so the UI keeps showing reasoning progress during long thinking
    /// pauses. Only applied when talking to the real Anthropic API — custom endpoints
    /// may not support `display`.
    private func thinkingConfig(for modelID: String, usesAdaptive: Bool, isCustomEndpoint: Bool) -> AnthropicThinkingConfig {
        guard usesAdaptive else {
            return .enabled(budgetTokens: 4096)
        }
        let summarizedPrefixes = ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"]
        if !isCustomEndpoint, summarizedPrefixes.contains(where: { modelID.hasPrefix($0) }) {
            return .adaptiveSummarized
        }
        return .adaptive
    }

    // MARK: - Error Handling

    private nonisolated func checkHTTPResponse(_ response: HTTPURLResponse, data: Data, modelID: String) throws {
        guard response.statusCode >= 400 else { return }

        // Status wins for the categories the UI routes on. A server is free to label a 401 body
        // "invalid_request_error", and trusting that would offer Retry instead of sending the
        // user to fix their credentials.
        switch response.statusCode {
        case 401, 403:
            throw AIProviderError.invalidAPIKey
        case 429:
            throw AIProviderError.rateLimited(retryAfter: nil)
        default:
            break
        }

        if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
            throw mapAnthropicError(errorResponse.error, modelID: modelID)
        }

        // Many Anthropic-compatible servers answer /v1/messages with an OpenAI-shaped error, which
        // has no top-level `type` and so fails the decode above. Reading it keeps the server's own
        // message instead of collapsing every failure into a status-code guess.
        if let openAIError = try? JSONDecoder().decode(OpenAIStyleErrorResponse.self, from: data) {
            throw mapAnthropicError(
                AnthropicError(type: openAIError.error.type ?? "", message: openAIError.error.message),
                modelID: modelID
            )
        }

        throw mapHTTPError(statusCode: response.statusCode, modelID: modelID)
    }

    private nonisolated func mapAnthropicError(_ error: AnthropicError, modelID: String) -> AIProviderError {
        switch error.type {
        case "authentication_error":
            return .invalidAPIKey
        case "rate_limit_error":
            return .rateLimited(retryAfter: nil)
        case "overloaded_error":
            return .rateLimited(retryAfter: nil)
        case "invalid_request_error":
            return .invalidResponse(error.message)
        case "not_found_error":
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
            // An unrecognized 404 body from a custom endpoint means a wrong path far more often
            // than a missing model, and a router that never matched the request also never logs
            // it server-side. A recognized not_found_error still maps to .modelNotAvailable above.
            guard isCustomEndpoint else { return .modelNotAvailable(modelID) }
            let shownURL = CustomProviderConfig.redactedURL(messagesURLString)
            return .networkError("No Anthropic Messages endpoint at \(shownURL). Check the Endpoint URL in Settings.")
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
