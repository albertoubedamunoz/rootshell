#if !CHINA_BUILD
//
//  BedrockProvider.swift
//  rootshell
//
//  Anthropic-on-AWS-Bedrock provider implementation. Mirrors AnthropicProvider
//  but routes through Bedrock's region-scoped endpoint, signs with SigV4 using
//  credentials from a linked Cloud account, and decodes the AWS event-stream
//  binary protocol into the same `AnthropicSSEEvent`s the direct path emits.
//

import Foundation
import os.log

@MainActor
final class BedrockProvider: AIProvider {
    // MARK: - Static Properties

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BedrockProvider")

    static let providerID = "bedrock"
    static let displayName = "AWS Bedrock"

    /// Anthropic-on-Bedrock API version constant. Lives in the request body
    /// (not the `anthropic-version` header used by the direct API).
    static let bedrockAnthropicVersion = "bedrock-2023-05-31"

    /// SigV4 service name for Bedrock requests. Even though the Runtime API's
    /// endpoint hostname is `bedrock-runtime.{region}.amazonaws.com`, the
    /// credential scope's service component is the bare `bedrock` — both the
    /// control plane and the runtime share a single signing service. Using
    /// `bedrock-runtime` here makes AWS reject the request with
    /// "Credential should be scoped to correct service".
    static let signingService = "bedrock"

    static var availableModels: [AIProviderModel] {
        AIProviderModel.bedrockModels
    }

    // MARK: - Instance Properties

    private let cloudAccountID: UUID
    private let region: String
    private var currentTask: Task<Void, Never>?

    var selectedModelID: String

    var isConfigured: Bool {
        // Linked AWS account must still exist and must be AWS-typed; the
        // selected model must resolve in this region. The actual credentials
        // are not loaded here — they're fetched on-demand per request via
        // `CloudAccountManager.getRefreshedAWSCredentials`.
        guard let account = CloudAccountManager.shared.account(for: cloudAccountID) else {
            return false
        }
        guard account.providerID == AWSProvider.providerID else { return false }
        guard BedrockRegions.isSupported(region) else { return false }
        return BedrockModelMapping.bedrockModelID(internalID: selectedModelID, region: region) != nil
    }

    // MARK: - Initialization

    init(cloudAccountID: UUID, region: String, selectedModelID: String) {
        self.cloudAccountID = cloudAccountID
        self.region = region
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

        let request = try await buildRequest(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            streaming: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        try Self.checkHTTPResponse(httpResponse, data: data, modelID: selectedModelID)

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return AnthropicMessageHelpers.parseResponse(anthropicResponse)
    }

    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        let isConfigured = self.isConfigured
        let modelID = self.selectedModelID

        return AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard isConfigured else {
                    continuation.finish(throwing: AIProviderError.notConfigured)
                    return
                }
                guard let self = self else {
                    continuation.finish(throwing: AIProviderError.cancelled)
                    return
                }

                // Same connection-lost retry pattern used by the direct provider —
                // useful when the chat is being run through a flaky SSH port-forward
                // or when Bedrock's regional endpoint resets a long-idle stream.
                let maxRetries = 2
                var lastError: Error?

                for attempt in 0...maxRetries {
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }
                    if attempt > 0 {
                        Self.logger.info("Retrying Bedrock stream (attempt \(attempt + 1)/\(maxRetries + 1)) after connection error")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }

                    do {
                        try await self.executeStreamRequest(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            modelID: modelID,
                            continuation: continuation
                        )
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
                            Self.logger.warning("Connection lost during Bedrock stream (attempt \(attempt + 1)): \(error.localizedDescription)")
                            lastError = error
                            continue
                        }
                        continuation.finish(throwing: Self.mapError(error))
                        return
                    }
                }

                if let error = lastError {
                    continuation.finish(throwing: Self.mapError(error))
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

    private nonisolated func executeStreamRequest(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        modelID: String,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        // Hops to MainActor for credential fetch + body construction + signing,
        // then hops back here for the actual HTTP I/O.
        let request = try await self.buildRequest(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            streaming: true
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode >= 400 {
            // Drain a bounded portion of the error body for diagnostics.
            var errorData = Data()
            let maxErrorSize = 16384
            for try await byte in bytes {
                if Task.isCancelled { break }
                errorData.append(byte)
                if errorData.count >= maxErrorSize { break }
            }
            try Self.checkHTTPResponse(httpResponse, data: errorData, modelID: modelID)
        }

        let events = BedrockEventStreamParser.parseStream(from: bytes)
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
        streaming: Bool
    ) async throws -> URLRequest {
        // 1. Refresh credentials (handles SSO/STS rotation transparently).
        let creds: AWSCredentials
        do {
            creds = try await CloudAccountManager.shared.getRefreshedAWSCredentials(for: cloudAccountID)
        } catch CloudAccountManager.AccountError.accountNotFound {
            throw AIProviderError.notConfigured
        } catch CloudAccountManager.AccountError.invalidCredentials {
            throw AIProviderError.notConfigured
        }

        // 2. Resolve the Bedrock invocation ID for this region. Newer Anthropic
        //    models on Bedrock require cross-region inference profiles, and the
        //    geography prefix differs per region — `BedrockModelMapping` owns it.
        guard let bedrockModelID = BedrockModelMapping.bedrockModelID(internalID: selectedModelID, region: region) else {
            throw AIProviderError.modelNotAvailable(selectedModelID)
        }

        // 3. Build the URL. The model ID contains colons and dots that are
        //    valid URL path characters, but encode just to be safe.
        let endpointSegment = streaming ? "invoke-with-response-stream" : "invoke"
        let encodedModel = bedrockModelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bedrockModelID
        guard let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/\(endpointSegment)") else {
            throw AIProviderError.networkError("Invalid Bedrock URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            streaming ? "application/vnd.amazon.eventstream" : "application/json",
            forHTTPHeaderField: "Accept"
        )

        // 4. Build the body. Same shape as the direct Anthropic API except
        //    `model` is in the URL (not the body), `anthropic_version` is the
        //    Bedrock-specific constant, and beta features go in an
        //    `anthropic_beta` array (not the `anthropic-beta` header).
        let anthropicMessages = AnthropicMessageHelpers.buildMessages(messages)
        let anthropicTools = AnthropicMessageHelpers.buildTools(tools)

        // Bedrock model IDs map back to the same Anthropic model family for
        // capability lookup (max tokens, supportsThinking, etc.).
        let familyID = BedrockModelMapping.anthropicFamilyID(internalID: selectedModelID) ?? selectedModelID
        let modelInfo = AIProviderModel.anthropicModel(id: familyID)
        let supportsThinking = modelInfo?.supportsThinking ?? false
        let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

        let temperature = AICredentialsManager.shared.effectiveTemperature(
            for: BedrockProvider.providerID,
            supportsTemperature: !supportsThinking
        )

        // Pick thinking flavor by family. Opus 5, Opus 4.x, Sonnet 4.6, and Sonnet 5
        // use `thinking.type: "adaptive"` (Opus 5, Opus 4.8, and Sonnet 5 *require*
        // it; sending `enabled` with `budget_tokens` returns a 400). Older thinking
        // models accept the classic `enabled`+budget shape paired with the
        // `interleaved-thinking-2025-05-14` beta. We omit the
        // `display: "summarized"` direct-API extension here — it isn't part
        // of the Bedrock contract.
        let adaptivePrefixes = ["claude-opus-5", "claude-opus-4-", "claude-sonnet-4-6", "claude-sonnet-5"]
        let usesAdaptiveThinking = adaptivePrefixes.contains { familyID.hasPrefix($0) }
        let thinkingConfig: AnthropicThinkingConfig?
        let beta: [String]?
        if !supportsThinking {
            thinkingConfig = nil
            beta = nil
        } else if usesAdaptiveThinking {
            thinkingConfig = .adaptive
            beta = nil
        } else {
            thinkingConfig = .enabled(budgetTokens: 4096)
            beta = ["interleaved-thinking-2025-05-14"]
        }

        let body = AnthropicRequest(
            bedrockAnthropicVersion: Self.bedrockAnthropicVersion,
            bedrockAnthropicBeta: beta,
            messages: anthropicMessages,
            system: systemPrompt,
            maxTokens: maxTokens,
            tools: anthropicTools.isEmpty ? nil : anthropicTools,
            temperature: temperature,
            thinking: thinkingConfig
        )
        request.httpBody = try JSONEncoder().encode(body)

        // 5. Sign last so the body's payload SHA-256 covers what we just set.
        AWSSignatureV4.sign(
            request: &request,
            credentials: creds.signingCredentials,
            region: region,
            service: Self.signingService
        )

        Self.logger.debug("Bedrock request: model=\(bedrockModelID), region=\(self.region), stream=\(streaming), messages=\(anthropicMessages.count)")

        return request
    }

    // MARK: - Error Mapping

    /// AWS REST errors carry a JSON body shaped `{"message": "...", "__type": "ValidationException"}`.
    /// Map the modeled exception types onto the same `AIProviderError` cases the
    /// direct provider produces so the chat UI surfaces consistent guidance.
    private nonisolated static func checkHTTPResponse(_ response: HTTPURLResponse, data: Data, modelID: String) throws {
        guard response.statusCode < 400 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let typeRaw = (json["__type"] as? String) ?? (json["code"] as? String) ?? ""
                let exceptionType = typeRaw.split(separator: "#").last.map(String.init) ?? typeRaw
                let message = (json["message"] as? String) ?? (json["Message"] as? String) ?? "Bedrock error"
                throw mapBedrockError(exceptionType: exceptionType, message: message, modelID: modelID)
            }
            throw mapHTTPStatusCode(response.statusCode, modelID: modelID)
        }
    }

    private nonisolated static func mapBedrockError(
        exceptionType: String,
        message: String,
        modelID: String
    ) -> AIProviderError {
        switch exceptionType {
        case "ThrottlingException":
            return .rateLimited(retryAfter: nil)
        case "AccessDeniedException", "UnrecognizedClientException":
            return .invalidAPIKey
        case "ResourceNotFoundException", "ModelNotReadyException":
            return .modelNotAvailable(modelID)
        case "ValidationException":
            return .invalidResponse(message)
        case "ServiceQuotaExceededException":
            return .quotaExceeded
        case "ModelTimeoutException", "InternalServerException", "ServiceUnavailableException":
            return .networkError(message)
        default:
            return .unknown("Bedrock \(exceptionType): \(message)")
        }
    }

    private nonisolated static func mapHTTPStatusCode(_ statusCode: Int, modelID: String) -> AIProviderError {
        switch statusCode {
        case 401, 403:
            return .invalidAPIKey
        case 404:
            return .modelNotAvailable(modelID)
        case 429:
            return .rateLimited(retryAfter: nil)
        case 500...599:
            return .networkError("Server error (\(statusCode))")
        default:
            return .networkError("HTTP error \(statusCode)")
        }
    }

    private nonisolated static func mapError(_ error: Error) -> AIProviderError {
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
