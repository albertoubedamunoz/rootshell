#if !CHINA_BUILD
//
//  ChatGPTProvider.swift
//  rootshell
//
//  AIProvider implementation for ChatGPT subscriptions. Speaks the Responses
//  API against chatgpt.com/backend-api/codex/responses with Codex OAuth
//  bearer tokens, reusing the SwiftOpenAI streaming machinery that already
//  powers OpenAIProvider.
//

import Foundation
import SwiftOpenAI
import os.log

/// An encrypted reasoning item retained for replay. With `store: false` the
/// full transcript is re-sent every turn, and the backend wants each replayed
/// function call accompanied by the reasoning that produced it.
nonisolated struct ChatGPTCachedReasoning: Sendable {
    let encryptedContent: String
    let summaryTexts: [String]
}

@MainActor
final class ChatGPTProvider: AIProvider {
    // MARK: - Static Properties

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTProvider")

    static let providerID = "chatgpt"
    static let displayName = "ChatGPT"
    static var availableModels: [AIProviderModel] {
        ChatGPTModelStore.shared.providerModels
    }

    /// One long-timeout client shared across the per-request services;
    /// reasoning models can think for a long time before the first byte.
    private nonisolated(unsafe) static let sharedHTTPClient: HTTPClient = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        return URLSessionHTTPClientAdapter(urlSession: URLSession(configuration: configuration))
    }()

    // MARK: - Instance Properties

    var selectedModelID: String

    var isConfigured: Bool {
        ChatGPTCredentialStore.isSignedInCached
    }

    private var currentStreamTask: Task<Void, Never>?

    /// Reasoning items from prior responses, keyed by the call_id of the
    /// function call each one produced. In-memory only: losing it (provider
    /// rebuild mid-conversation) degrades quality but is accepted by the
    /// backend, which tolerates function calls without preceding reasoning.
    private var reasoningReplayByCallID: [String: ChatGPTCachedReasoning] = [:]

    // MARK: - Initialization

    init(selectedModelID: String) {
        self.selectedModelID = selectedModelID
    }

    // MARK: - AIProvider Protocol

    /// The backend has no non-streaming mode, so this consumes the stream and
    /// returns the accumulated result.
    func sendMessage(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) async throws -> AIProviderResponse {
        var text = ""
        var toolCalls: [AIToolCall] = []
        var usage: AIUsageStats?
        var finishReason: AIProviderResponse.FinishReason?

        for try await event in sendMessageStream(messages: messages, systemPrompt: systemPrompt, tools: tools) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .toolCallComplete(let call):
                if !toolCalls.contains(where: { $0.id == call.id }) {
                    toolCalls.append(call)
                }
            case .responseComplete(let responseUsage, let reason):
                usage = responseUsage
                finishReason = reason
            case .error(let error):
                throw error
            default:
                break
            }
        }

        let content: AIProviderResponse.Content
        if !toolCalls.isEmpty {
            content = text.isEmpty ? .toolCalls(toolCalls) : .textAndToolCalls(text, toolCalls)
        } else {
            content = .text(text)
        }
        return AIProviderResponse(content: content, usage: usage, finishReason: finishReason)
    }

    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let modelID = self.selectedModelID
            let effort = ChatGPTReasoningSettings.effectiveEffort(for: modelID)
            let replayCache = self.reasoningReplayByCallID

            // Newly produced reasoning items hop back to MainActor state so the
            // next turn can replay them.
            let commitReasoning: @Sendable ([String: ChatGPTCachedReasoning]) -> Void = { [weak self] items in
                guard let self, !items.isEmpty else { return }
                Task { @MainActor [self, items] in
                    self.reasoningReplayByCallID.merge(items) { _, new in new }
                }
            }

            Self.logger.debug("sendMessageStream: model \(modelID), effort \(effort.rawValue)")

            // Run stream processing off MainActor to avoid UI stalls
            let streamTask = Task.detached { [modelID, effort, replayCache] in
                var forcedRefresh = false

                while true {
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }

                    // A fresh (or force-refreshed) access token per attempt.
                    let credentials: ChatGPTCredentials
                    do {
                        credentials = try await ChatGPTCredentialStore.shared.validCredentials(forceRefresh: forcedRefresh)
                    } catch {
                        continuation.finish(throwing: Self.mapAuthError(error))
                        return
                    }

                    do {
                        try await Self.executeStreamRequest(
                            accessToken: credentials.accessToken,
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            modelID: modelID,
                            effort: effort,
                            replayCache: replayCache,
                            continuation: continuation,
                            commitReasoning: commitReasoning
                        )
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        // The backend rejects a token once (expired or revoked
                        // server-side): force one refresh and retry. A second
                        // rejection means the grant itself is gone.
                        if !forcedRefresh, Self.isUnauthorized(error) {
                            Self.logger.info("Codex backend rejected the token; refreshing and retrying once")
                            forcedRefresh = true
                            continue
                        }
                        continuation.finish(throwing: Self.mapCodexError(error, modelID: modelID))
                        return
                    }
                }
            }

            self.currentStreamTask = streamTask

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    func cancel() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
    }

    // MARK: - Request execution

    private nonisolated static func executeStreamRequest(
        accessToken: String,
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        modelID: String,
        effort: ChatGPTReasoningEffort,
        replayCache: [String: ChatGPTCachedReasoning],
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation,
        commitReasoning: @Sendable ([String: ChatGPTCachedReasoning]) -> Void
    ) async throws {
        let inputItems = insertReasoningReplay(
            into: OpenAIProvider.convertMessagesToInputItems(messages, isCustomEndpoint: false),
            cache: replayCache
        )
        let responsesTools = OpenAIProvider.convertToolsToResponsesFormat(tools)

        // One UUID shared by session_id / conversation_id / x-client-request-id,
        // fresh per request. The factory's apiKey already becomes the bearer
        // header, so it is stripped from the extras.
        var extraHeaders = ChatGPTOAuth.requestHeaders(accessToken: accessToken, sessionID: UUID().uuidString)
        extraHeaders.removeValue(forKey: "Authorization")

        let service = OpenAIServiceFactory.service(
            apiKey: accessToken,
            overrideBaseURL: "https://chatgpt.com",
            proxyPath: "backend-api",
            overrideVersion: "codex",
            extraHeaders: extraHeaders,
            httpClient: sharedHTTPClient
        )

        let supportsSummary = ChatGPTModelCapabilities.supportsReasoningSummary(modelID)
        let reasoning = Reasoning(
            effort: effort.rawValue,
            summary: supportsSummary ? .auto : nil,
            context: ChatGPTModelCapabilities.supportsAllTurnsContext(modelID) ? "all_turns" : nil
        )

        // store/stream/include/text are all required by this backend. Every
        // sampling parameter is deliberately absent — temperature, top_p,
        // penalties, stop, max_output_tokens, and text.format are each a 400.
        let parameters = ModelResponseParameter(
            input: .array(inputItems),
            model: .custom(modelID),
            include: [.reasoningEncryptedContent],
            instructions: systemPrompt,
            reasoning: reasoning,
            store: false,
            stream: true,
            streamOptions: supportsSummary
                ? StreamOptions(reasoningSummaryDelivery: "sequential_cutoff")
                : nil,
            text: TextConfiguration(verbosity: "medium"),
            tools: responsesTools.isEmpty ? nil : responsesTools
        )

        let stream = try await service.responseCreateStream(parameters)

        // Tool call assembly, mirroring OpenAIProvider.executeStreamRequest.
        var toolCallBuilders: [String: OpenAIProvider.ToolCallBuilder] = [:]
        // Reasoning items pair with the function call that follows them in
        // output order; the pending item waits for its call.
        var pendingReasoning: ChatGPTCachedReasoning?
        var reasoningAssociations: [String: ChatGPTCachedReasoning] = [:]

        for try await event in stream {
            if Task.isCancelled {
                continuation.finish(throwing: AIProviderError.cancelled)
                return
            }

            switch event {
            case .outputTextDelta(let delta):
                continuation.yield(.textDelta(delta.delta))

            case .reasoningSummaryTextDelta(let delta):
                continuation.yield(.thinkingDelta(delta.delta))

            case .reasoningTextDelta(let delta):
                continuation.yield(.thinkingDelta(delta.delta))

            case .functionCallArgumentsDelta(let delta):
                let itemId = delta.itemId
                if toolCallBuilders[itemId] == nil {
                    toolCallBuilders[itemId] = OpenAIProvider.ToolCallBuilder(id: itemId)
                }
                toolCallBuilders[itemId]?.appendArguments(delta.delta)
                continuation.yield(.toolCallDelta(
                    id: itemId,
                    name: toolCallBuilders[itemId]?.name,
                    argumentsDelta: delta.delta
                ))

            case .functionCallArgumentsDone(let done):
                if let builder = toolCallBuilders[done.itemId] {
                    if let args = done.arguments {
                        builder.arguments = args
                    }
                    if let name = done.name {
                        builder.name = name
                    }
                }

            case .outputItemAdded(let itemAdded):
                if case .functionCall(let funcCall) = itemAdded.item {
                    if toolCallBuilders[funcCall.callId] == nil {
                        toolCallBuilders[funcCall.callId] = OpenAIProvider.ToolCallBuilder(id: funcCall.callId)
                    }
                    toolCallBuilders[funcCall.callId]?.name = funcCall.name
                }

            case .outputItemDone(let itemDone):
                switch itemDone.item {
                case .reasoning(let reasoningItem):
                    if let encrypted = reasoningItem.encryptedContent, !encrypted.isEmpty {
                        pendingReasoning = ChatGPTCachedReasoning(
                            encryptedContent: encrypted,
                            summaryTexts: reasoningItem.summary.map(\.text)
                        )
                    }

                case .functionCall(let funcCall):
                    if let reasoningItem = pendingReasoning {
                        reasoningAssociations[funcCall.callId] = reasoningItem
                        pendingReasoning = nil
                    }
                    guard let name = funcCall.name,
                          let arguments = funcCall.arguments else {
                        Self.logger.warning("Function call missing name or arguments: callId=\(funcCall.callId)")
                        continue
                    }
                    continuation.yield(.toolCallComplete(AIToolCall(
                        id: funcCall.callId,
                        name: name,
                        arguments: arguments
                    )))

                default:
                    break
                }

            case .responseCompleted(let completed):
                commitReasoning(reasoningAssociations)
                let usage = OpenAIProvider.extractUsage(from: completed.response)
                let finishReason = OpenAIProvider.extractFinishReason(from: completed.response)
                continuation.yield(.responseComplete(usage: usage, finishReason: finishReason))
                continuation.finish()
                return

            case .responseIncomplete(let incomplete):
                commitReasoning(reasoningAssociations)
                let usage = OpenAIProvider.extractUsage(from: incomplete.response)
                continuation.yield(.responseComplete(usage: usage, finishReason: .length))
                continuation.finish()
                return

            case .responseFailed(let failed):
                let errorMessage = failed.response.error?.message ?? "Unknown error"
                Self.logger.error("Response failed: \(errorMessage)")
                continuation.finish(throwing: mapStreamFailureMessage(errorMessage))
                return

            case .error(let errorEvent):
                let errorMessage = errorEvent.message ?? errorEvent.code ?? "Unknown API error"
                Self.logger.error("Stream error: \(errorMessage)")
                continuation.finish(throwing: mapStreamFailureMessage(errorMessage))
                return

            default:
                // Codex-only events (and everything else this provider doesn't
                // need) fall through here, including unknownEventType.
                break
            }
        }

        // Stream ended without a completion event.
        commitReasoning(reasoningAssociations)
        continuation.finish()
    }

    /// Inserts cached reasoning items ahead of the function calls they produced,
    /// so a `store:false` replay carries the model's own chain of thought.
    nonisolated static func insertReasoningReplay(
        into items: [InputItem],
        cache: [String: ChatGPTCachedReasoning]
    ) -> [InputItem] {
        guard !cache.isEmpty else { return items }

        var result: [InputItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            if case .functionToolCall(let call) = item,
               let cached = cache[call.callId] {
                result.append(.reasoning(ReasoningInputItem(
                    summary: cached.summaryTexts.map(ReasoningInputItem.SummaryText.init(text:)),
                    encryptedContent: cached.encryptedContent
                )))
            }
            result.append(item)
        }
        return result
    }

    // MARK: - Error mapping

    /// 401/403 from the responses endpoint means the token was rejected; usage
    /// limits also arrive as 4xx and must not be mistaken for auth failures.
    private nonisolated static func isUnauthorized(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .responseUnsuccessful(let description, let statusCode) = apiError else {
            return false
        }
        guard statusCode == 401 || statusCode == 403 else { return false }
        let payload = parseErrorPayload(description)
        if let code = payload.code, code == "usage_limit_reached" || code == "usage_not_included" {
            return false
        }
        return true
    }

    /// Errors thrown by the credential store before a request ever starts.
    private nonisolated static func mapAuthError(_ error: Error) -> Error {
        if error is CancellationError { return AIProviderError.cancelled }
        switch error {
        case ChatGPTAuthError.notSignedIn:
            return AIProviderError.notConfigured
        case ChatGPTAuthError.tokenEndpoint(let message) where message.contains("invalid_grant"):
            // The store already cleared the credential; surface as sign-in-needed.
            return AIProviderError.notConfigured
        case ChatGPTAuthError.tokenEndpoint(let message):
            return AIProviderError.networkError("ChatGPT token refresh failed: \(message)")
        default:
            return AIProviderError.networkError(error.localizedDescription)
        }
    }

    /// Maps request failures, handling the Codex-specific error vocabulary
    /// before falling back to the generic OpenAI mapping.
    nonisolated static func mapCodexError(_ error: Error, modelID: String?) -> AIProviderError {
        if let apiError = error as? APIError,
           case .responseUnsuccessful(let description, let statusCode) = apiError {
            let payload = parseErrorPayload(description)

            switch payload.code {
            case "usage_limit_reached":
                return .rateLimited(retryAfter: retryDelay(resetsAt: payload.resetsAt, fallback: 900))
            case "usage_not_included":
                let plan = payload.planType.map { " (\($0) plan)" } ?? ""
                return .unknown(payload.message ?? "This ChatGPT subscription\(plan) does not include Codex model access.")
            case "rate_limit_exceeded":
                return .rateLimited(retryAfter: retryDelay(resetsAt: payload.resetsAt, fallback: 30))
            default:
                break
            }

            if statusCode == 401 || statusCode == 403 {
                // Both attempts rejected: the stored grant no longer works.
                return .notConfigured
            }
            if statusCode == 429 {
                return .rateLimited(retryAfter: retryDelay(resetsAt: payload.resetsAt, fallback: 30))
            }
        }
        return OpenAIProvider.mapError(error, modelID: modelID)
    }

    private nonisolated static func mapStreamFailureMessage(_ message: String) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("usage_limit_reached") || lowered.contains("usage limit") {
            return AIProviderError.rateLimited(retryAfter: 900)
        }
        if lowered.contains("rate_limit") || lowered.contains("rate limit") {
            return AIProviderError.rateLimited(retryAfter: 30)
        }
        return AIProviderError.unknown(message)
    }

    /// Pulls `{error: {code, message, plan_type, resets_at}}` out of the raw
    /// body that the SDK appends to its error description.
    nonisolated static func parseErrorPayload(
        _ description: String
    ) -> (code: String?, message: String?, planType: String?, resetsAt: Double?) {
        guard let braceIndex = description.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(
                with: Data(String(description[braceIndex...]).utf8)
              ) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }

        let error = (json["error"] as? [String: Any]) ?? json
        let code = (error["code"] as? String) ?? (error["type"] as? String)
        let message = error["message"] as? String
        let planType = error["plan_type"] as? String
        var resetsAt: Double?
        if let value = error["resets_at"] as? Double {
            resetsAt = value
        } else if let value = error["resets_at"] as? String {
            resetsAt = Double(value)
        }
        return (code, message, planType, resetsAt)
    }

    /// `resets_at` is absolute epoch seconds.
    private nonisolated static func retryDelay(resetsAt: Double?, fallback: TimeInterval) -> TimeInterval {
        guard let resetsAt else { return fallback }
        return max(1, resetsAt - Date().timeIntervalSince1970)
    }
}
#endif
