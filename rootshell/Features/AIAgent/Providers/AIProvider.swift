#if !CHINA_BUILD
//
//  AIProvider.swift
//  rootshell
//
//  Protocol for AI LLM providers
//

import Foundation

/// Response from an AI provider
struct AIProviderResponse: Sendable {
    /// Response content type
    enum Content: Sendable {
        /// Plain text response
        case text(String)
        /// Tool calls requested by the model
        case toolCalls([AIToolCall])
        /// Combined text and tool calls
        case textAndToolCalls(String, [AIToolCall])
    }

    let content: Content
    let usage: AIUsageStats?
    let finishReason: FinishReason?

    enum FinishReason: String, Sendable {
        case stop
        case toolCalls = "tool_calls"
        case length
        case contentFilter = "content_filter"
    }
}

// MARK: - Streaming Events

/// Events emitted during streaming AI responses
enum AIProviderStreamEvent: Sendable {
    /// Partial text chunk received
    case textDelta(String)

    /// Partial thinking/reasoning content received (separate from text for UI)
    case thinkingDelta(String)

    /// Complete thinking block with optional signature for API round-trip
    /// - Parameters:
    ///   - thinking: The accumulated thinking content
    ///   - signature: Cryptographic signature (if present, include in API requests)
    case thinkingComplete(thinking: String, signature: String?)

    /// Partial tool call arguments received
    /// - Parameters:
    ///   - id: The tool call ID
    ///   - name: The tool name (only present on first delta for this call)
    ///   - argumentsDelta: Partial JSON arguments string
    case toolCallDelta(id: String, name: String?, argumentsDelta: String)

    /// A complete tool call has been assembled
    case toolCallComplete(AIToolCall)

    /// The response is complete
    case responseComplete(usage: AIUsageStats?, finishReason: AIProviderResponse.FinishReason?)

    /// An error occurred during streaming
    case error(Error)
}

/// Protocol for AI LLM providers
@MainActor
protocol AIProvider: AnyObject {
    /// Unique identifier for this provider
    static var providerID: String { get }

    /// Human-readable display name
    static var displayName: String { get }

    /// Available models for this provider
    static var availableModels: [AIProviderModel] { get }

    /// Whether the provider is configured (has valid credentials)
    var isConfigured: Bool { get }

    /// Currently selected model ID
    var selectedModelID: String { get set }

    /// Send a message to the AI and get a response
    /// - Parameters:
    ///   - messages: Conversation history
    ///   - systemPrompt: System prompt for context
    ///   - tools: Available tools the AI can use
    /// - Returns: The AI's response
    func sendMessage(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) async throws -> AIProviderResponse

    /// Send a message to the AI with streaming response
    /// - Parameters:
    ///   - messages: Conversation history
    ///   - systemPrompt: System prompt for context
    ///   - tools: Available tools the AI can use
    /// - Returns: An async stream of response events
    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error>

    /// Cancel any ongoing request
    func cancel()
}

// MARK: - Provider Errors

/// Errors that can occur with AI providers
enum AIProviderError: LocalizedError, Sendable {
    case notConfigured
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case modelNotAvailable(String)
    case networkError(String)
    case invalidResponse(String)
    case toolCallFailed(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "API key not configured"
        case .invalidAPIKey:
            return "Invalid API key"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry in \(Int(seconds)) seconds"
            }
            return "Rate limited. Please wait and try again"
        case .quotaExceeded:
            return "API quota exceeded"
        case .modelNotAvailable(let model):
            return "Model '\(model)' is not available"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .toolCallFailed(let message):
            return "Tool call failed: \(message)"
        case .cancelled:
            return "Request cancelled"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Provider Registry

/// Registry for available AI providers
@MainActor
final class AIProviderRegistry {
    /// Singleton instance
    static let shared = AIProviderRegistry()

    /// Registered provider types
    private var providerTypes: [String: any AIProvider.Type] = [:]

    /// Active provider instances
    private var providers: [String: any AIProvider] = [:]

    private init() {}

    /// Register a provider type
    func register<T: AIProvider>(_ providerType: T.Type) {
        providerTypes[T.providerID] = providerType
    }

    /// Get or create a provider instance
    func provider(for providerID: String) -> (any AIProvider)? {
        if let existing = providers[providerID] {
            return existing
        }

        // For now, we only support OpenAI
        // Provider creation is handled elsewhere since it needs credentials
        return nil
    }

    /// Set an active provider instance
    func setProvider(_ provider: any AIProvider, for providerID: String) {
        providers[providerID] = provider
    }

    /// Get all registered provider IDs
    var registeredProviderIDs: [String] {
        Array(providerTypes.keys)
    }

    /// Clear all provider instances (for logout/reset)
    func clearProviders() {
        providers.removeAll()
    }
}
#endif
