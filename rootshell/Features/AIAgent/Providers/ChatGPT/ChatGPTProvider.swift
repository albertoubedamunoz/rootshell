#if !CHINA_BUILD
//
//  ChatGPTProvider.swift
//  rootshell
//
//  AIProvider implementation for ChatGPT plan usage. Speaks the public
//  Responses API at api.openai.com with a Sign in with ChatGPT access token,
//  reusing the SwiftOpenAI streaming machinery that already powers
//  OpenAIProvider.
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
        ChatGPTCredentialStore.isUsableCached
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
                    let session: ChatGPTSession
                    do {
                        session = try await ChatGPTCredentialStore.shared.validSession(forceRefresh: forcedRefresh)
                    } catch {
                        continuation.finish(throwing: Self.mapAuthError(error))
                        return
                    }

                    do {
                        try await Self.executeStreamRequest(
                            accessToken: session.accessToken,
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
                        // A 401 may be a token expired or revoked server-side:
                        // force one refresh and retry. A second rejection means
                        // the grant itself is gone.
                        if !forcedRefresh, Self.isUnauthorized(error) {
                            Self.logger.info("Responses API rejected the token; refreshing and retrying once")
                            forcedRefresh = true
                            continue
                        }
                        continuation.finish(throwing: Self.mapRequestError(error, modelID: modelID))
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
            into: developerRoleMessages(OpenAIProvider.convertMessagesToInputItems(messages, isCustomEndpoint: false)),
            cache: replayCache
        )
        let responsesTools = OpenAIProvider.convertToolsToResponsesFormat(tools)

        // The access token becomes the bearer header; nothing else is sent.
        let service = OpenAIServiceFactory.service(
            apiKey: accessToken,
            httpClient: sharedHTTPClient
        )

        let supportsSummary = ChatGPTModelCapabilities.supportsReasoningSummary(modelID)
        let reasoning = Reasoning(
            effort: effort.rawValue,
            summary: supportsSummary ? .auto : nil
        )

        // Plan usage requires store:false and stream:true with the full history
        // in `input`. Sampling and output-limit fields (temperature, top_p,
        // max_output_tokens, metadata, previous_response_id, …) are rejected.
        let parameters = ModelResponseParameter(
            input: .array(inputItems),
            model: .custom(modelID),
            include: [.reasoningEncryptedContent],
            instructions: systemPrompt,
            reasoning: reasoning,
            store: false,
            stream: true,
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
                let code = failed.response.error?.code
                let errorMessage = failed.response.error?.message ?? code ?? "Unknown error"
                Self.logger.error("Response failed: \(code ?? "-", privacy: .public) \(errorMessage)")
                continuation.finish(throwing: mapPlanError(code: code, message: errorMessage, param: nil)
                    ?? AIProviderError.unknown(errorMessage))
                return

            case .error(let errorEvent):
                let errorMessage = errorEvent.message ?? errorEvent.code ?? "Unknown API error"
                Self.logger.error("Stream error: \(errorEvent.code ?? "-", privacy: .public) \(errorMessage)")
                continuation.finish(throwing: mapPlanError(code: errorEvent.code, message: errorMessage, param: errorEvent.param)
                    ?? AIProviderError.unknown(errorMessage))
                return

            default:
                // Everything this provider doesn't need falls through here,
                // including unknownEventType.
                break
            }
        }

        // Only response.completed counts as success.
        commitReasoning(reasoningAssociations)
        continuation.finish(throwing: AIProviderError.networkError(
            String(localized: "The response ended before it completed. Try again.")
        ))
    }

    /// Explicit system-role input items are rejected on this route; the
    /// Responses API's developer role carries the same weight.
    nonisolated static func developerRoleMessages(_ items: [InputItem]) -> [InputItem] {
        items.map { item in
            guard case .message(let message) = item, message.role == "system" else { return item }
            return .message(InputMessage(
                role: "developer",
                content: message.content,
                type: message.type,
                status: message.status,
                id: message.id
            ))
        }
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

    /// A 401 may be an access token revoked or expired server-side, worth one
    /// forced refresh. 403s are policy decisions and are never retried.
    private nonisolated static func isUnauthorized(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .responseUnsuccessful(_, let statusCode) = apiError else {
            return false
        }
        return statusCode == 401
    }

    /// Errors thrown by the credential store before a request ever starts.
    private nonisolated static func mapAuthError(_ error: Error) -> Error {
        if error is CancellationError { return AIProviderError.cancelled }
        switch error {
        case ChatGPTAuthError.notSignedIn:
            return AIProviderError.unavailable(String(localized: "Sign in with ChatGPT in Settings to use your ChatGPT plan."))
        case ChatGPTAuthError.planNotEnabled, ChatGPTAuthError.sessionExpired, ChatGPTAuthError.invalidClient:
            return AIProviderError.unavailable(error.localizedDescription)
        case ChatGPTAuthError.tokenEndpoint(let status, let code, let message):
            return AIProviderError.networkError("ChatGPT token refresh failed: \(status) \(code ?? message)")
        default:
            return AIProviderError.networkError(error.localizedDescription)
        }
    }

    /// Recovery for the documented plan-usage error codes; nil for anything else.
    nonisolated static func mapPlanError(code: String?, message: String, param: String?) -> AIProviderError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .chatGPTUsageLimit
        case "subscription_sharing_user_not_eligible":
            return .unavailable(String(localized: "ChatGPT plan usage isn't available for this account or workspace."))
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .networkError(String(localized: "ChatGPT usage couldn't be checked right now. Try again in a moment."))
        case "subscription_sharing_unsupported_capability":
            let feature = param ?? String(localized: "part of this request")
            return .unavailable(String(localized: "ChatGPT plan usage doesn't support \(feature). \(message)"))
        case "subscription_sharing_route_not_supported":
            return .unavailable(message)
        case "subscription_sharing_invalid_user":
            return .unavailable(String(localized: "ChatGPT couldn't validate this account. Sign out of ChatGPT in Settings and sign in again."))
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .unavailable(String(localized: "ChatGPT didn't authorize this request. Sign out of ChatGPT in Settings and sign in again."))
        default:
            return nil
        }
    }

    /// Maps request failures: plan-usage codes first, then direct-admission
    /// statuses (whose `{"detail": …}` body is diagnostic text only), then the
    /// generic OpenAI mapping.
    nonisolated static func mapRequestError(_ error: Error, modelID: String?) -> AIProviderError {
        guard let apiError = error as? APIError,
              case .responseUnsuccessful(let description, let statusCode) = apiError else {
            return OpenAIProvider.mapError(error, modelID: modelID)
        }

        let payload = parseErrorPayload(description)
        logger.error("Responses request failed: HTTP \(statusCode) \(payload.code ?? "-", privacy: .public)")

        if let mapped = mapPlanError(code: payload.code, message: payload.message ?? description, param: payload.param) {
            return mapped
        }

        let detail = payload.message ?? payload.detail
        switch statusCode {
        case 401:
            return .unavailable(String(localized: "ChatGPT didn't accept this sign-in. Check the selected account in Settings, or sign in again."))
        case 403:
            return .unavailable(detail ?? String(localized: "ChatGPT blocked this request by policy."))
        case 429:
            return .rateLimited(retryAfter: nil)
        case 503:
            return .networkError(detail ?? String(localized: "ChatGPT plan usage is temporarily unavailable. Try again later."))
        default:
            return OpenAIProvider.mapError(error, modelID: modelID)
        }
    }

    /// Pulls `{error: {code, message, param}}` or `{detail}` out of the raw
    /// body that the SDK appends to its error description.
    nonisolated static func parseErrorPayload(
        _ description: String
    ) -> (code: String?, message: String?, param: String?, detail: String?) {
        guard let braceIndex = description.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(
                with: Data(String(description[braceIndex...]).utf8)
              ) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }

        let error = json["error"] as? [String: Any]
        return (
            error?["code"] as? String,
            error?["message"] as? String,
            error?["param"] as? String,
            json["detail"] as? String
        )
    }
}
#endif
