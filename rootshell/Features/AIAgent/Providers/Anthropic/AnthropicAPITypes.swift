#if !CHINA_BUILD
//
//  AnthropicAPITypes.swift
//  rootshell
//
//  Request and response types for the Anthropic Messages API
//

import Foundation

// MARK: - Request Types

/// Main request structure for Anthropic Messages API.
///
/// Used for both the direct Anthropic API and Bedrock's `InvokeModel` family.
/// The two flavors differ in how the model and version are addressed:
/// - Direct API: `model` is in the body, version is in the `anthropic-version` header.
/// - Bedrock: model is in the URL path, `anthropic_version` is in the body, beta
///   features move from the `anthropic-beta` header into the body's `anthropic_beta` array.
///
/// A custom `encode(to:)` omits nil fields entirely so Bedrock doesn't see a stray
/// `model: null` (and the direct API doesn't see stray Bedrock-only fields).
nonisolated struct AnthropicRequest: Encodable {
    let model: String?
    let anthropic_version: String?
    let anthropic_beta: [String]?
    let messages: [AnthropicMessage]
    let system: [AnthropicSystemBlock]?
    let max_tokens: Int
    let tools: [AnthropicTool]?
    let stream: Bool?
    let temperature: Double?
    let thinking: AnthropicThinkingConfig?

    /// Direct Anthropic Messages API request.
    init(
        model: String,
        messages: [AnthropicMessage],
        system: String?,
        maxTokens: Int,
        tools: [AnthropicTool]? = nil,
        stream: Bool = true,
        temperature: Double? = nil,
        thinking: AnthropicThinkingConfig? = nil
    ) {
        self.model = model
        self.anthropic_version = nil
        self.anthropic_beta = nil
        self.messages = messages
        self.system = system.map { [AnthropicSystemBlock(text: $0)] }
        self.max_tokens = maxTokens
        self.tools = tools?.isEmpty == true ? nil : tools
        self.stream = stream
        self.temperature = temperature
        self.thinking = thinking
    }

    /// Bedrock-flavored request body. `model` is in the URL path and omitted here;
    /// `stream` is implied by `/invoke` vs `/invoke-with-response-stream` and omitted.
    init(
        bedrockAnthropicVersion: String,
        bedrockAnthropicBeta: [String]?,
        messages: [AnthropicMessage],
        system: String?,
        maxTokens: Int,
        tools: [AnthropicTool]? = nil,
        temperature: Double? = nil,
        thinking: AnthropicThinkingConfig? = nil
    ) {
        self.model = nil
        self.anthropic_version = bedrockAnthropicVersion
        self.anthropic_beta = bedrockAnthropicBeta?.isEmpty == true ? nil : bedrockAnthropicBeta
        self.messages = messages
        self.system = system.map { [AnthropicSystemBlock(text: $0)] }
        self.max_tokens = maxTokens
        self.tools = tools?.isEmpty == true ? nil : tools
        self.stream = nil
        self.temperature = temperature
        self.thinking = thinking
    }

    private enum CodingKeys: String, CodingKey {
        case model, anthropic_version, anthropic_beta, messages, system, max_tokens
        case tools, stream, temperature, thinking
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(anthropic_version, forKey: .anthropic_version)
        try container.encodeIfPresent(anthropic_beta, forKey: .anthropic_beta)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(system, forKey: .system)
        try container.encode(max_tokens, forKey: .max_tokens)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(thinking, forKey: .thinking)
    }
}

/// Configuration for extended thinking mode
nonisolated struct AnthropicThinkingConfig: Encodable {
    let type: String
    let budget_tokens: Int?
    /// Opus 5 and Opus 4.8 default to "omitted"; set "summarized" to restore older display behavior
    /// where streamed `thinking` blocks contain a human-readable summary.
    let display: String?

    static func enabled(budgetTokens: Int) -> AnthropicThinkingConfig {
        AnthropicThinkingConfig(type: "enabled", budget_tokens: budgetTokens, display: nil)
    }

    static let adaptive = AnthropicThinkingConfig(type: "adaptive", budget_tokens: nil, display: nil)

    static let adaptiveSummarized = AnthropicThinkingConfig(type: "adaptive", budget_tokens: nil, display: "summarized")

    static let disabled = AnthropicThinkingConfig(type: "disabled", budget_tokens: nil, display: nil)
}

/// A message in the conversation
nonisolated struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]

    static func user(_ text: String) -> AnthropicMessage {
        AnthropicMessage(role: "user", content: [.text(AnthropicTextBlock(text: text))])
    }

    static func user(_ blocks: [AnthropicContentBlock]) -> AnthropicMessage {
        AnthropicMessage(role: "user", content: blocks)
    }

    static func assistant(_ text: String) -> AnthropicMessage {
        AnthropicMessage(role: "assistant", content: [.text(AnthropicTextBlock(text: text))])
    }

    static func assistant(_ blocks: [AnthropicContentBlock]) -> AnthropicMessage {
        AnthropicMessage(role: "assistant", content: blocks)
    }
}

/// Content block types in a message
nonisolated enum AnthropicContentBlock: Encodable {
    case text(AnthropicTextBlock)
    case thinking(AnthropicThinkingBlock)
    case toolUse(AnthropicToolUseBlock)
    case toolResult(AnthropicToolResultBlock)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let block):
            try container.encode(block)
        case .thinking(let block):
            try container.encode(block)
        case .toolUse(let block):
            try container.encode(block)
        case .toolResult(let block):
            try container.encode(block)
        }
    }
}

/// Plain text content block
nonisolated struct AnthropicTextBlock: Codable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

/// Thinking content block (extended thinking mode)
nonisolated struct AnthropicThinkingBlock: Codable {
    let type: String
    let thinking: String
    let signature: String?

    init(thinking: String, signature: String? = nil) {
        self.type = "thinking"
        self.thinking = thinking
        self.signature = signature
    }
}

/// Tool use content block (assistant requests tool call)
nonisolated struct AnthropicToolUseBlock: Encodable {
    let type: String
    let id: String
    let name: String
    let input: [String: AnyCodableValue]

    init(id: String, name: String, input: [String: AnyCodableValue]) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Tool result content block (user provides tool output)
nonisolated struct AnthropicToolResultBlock: Encodable {
    let type: String
    let tool_use_id: String
    let content: String
    let is_error: Bool?

    init(toolUseId: String, content: String, isError: Bool = false) {
        self.type = "tool_result"
        self.tool_use_id = toolUseId
        self.content = content
        self.is_error = isError ? true : nil
    }
}

/// System message block
nonisolated struct AnthropicSystemBlock: Encodable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

// MARK: - Tool Definitions

/// Tool definition for the API
nonisolated struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let input_schema: AnthropicInputSchema
}

/// JSON Schema for tool input parameters
nonisolated struct AnthropicInputSchema: Encodable {
    let type: String
    let properties: [String: AnthropicPropertySchema]
    let required: [String]

    init(properties: [String: AnthropicPropertySchema], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// Box wrapper to allow recursive AnthropicPropertySchema
nonisolated final class AnthropicPropertySchemaBox: Encodable, @unchecked Sendable {
    let value: AnthropicPropertySchema

    init(_ value: AnthropicPropertySchema) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// Schema for a single property
nonisolated struct AnthropicPropertySchema: Encodable {
    let type: String
    let description: String?
    let `enum`: [String]?
    let items: AnthropicPropertySchemaBox?

    init(type: String, description: String? = nil, enumValues: [String]? = nil, items: AnthropicPropertySchema? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
        self.items = items.map { AnthropicPropertySchemaBox($0) }
    }
}

// MARK: - Response Types

/// Main response structure from Anthropic Messages API
nonisolated struct AnthropicResponse: Decodable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicResponseContent]
    let model: String
    let stop_reason: String?
    let stop_sequence: String?
    let usage: AnthropicUsage?
}

/// Content block in a response
nonisolated enum AnthropicResponseContent: Decodable {
    case text(text: String)
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)  // Encrypted thinking
    case toolUse(id: String, name: String, input: [String: Any])

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature, id, name, input, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text: text)
        case "thinking":
            let thinking = try container.decode(String.self, forKey: .thinking)
            let signature = try container.decode(String.self, forKey: .signature)
            self = .thinking(text: thinking, signature: signature)
        case "redacted_thinking":
            let data = try container.decode(String.self, forKey: .data)
            self = .redactedThinking(data: data)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode([String: AnyCodableValue].self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input.mapValues { $0.value })
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }
}

/// Token usage statistics
nonisolated struct AnthropicUsage: Decodable, Sendable {
    let input_tokens: Int
    let output_tokens: Int
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?

    var totalTokens: Int {
        input_tokens + output_tokens
    }
}

// MARK: - Error Response

/// Error response from Anthropic API
nonisolated struct AnthropicErrorResponse: Decodable, Sendable {
    let type: String
    let error: AnthropicError
}

nonisolated struct AnthropicError: Decodable, Sendable {
    let type: String
    let message: String
}

/// OpenAI-shaped error body. Anthropic-compatible servers (oMLX, LiteLLM, vLLM) return this shape
/// from /v1/messages, and it fails to decode as `AnthropicErrorResponse` because that type requires
/// a top-level `type` key.
nonisolated struct OpenAIStyleErrorResponse: Decodable, Sendable {
    nonisolated struct Body: Decodable, Sendable {
        let message: String
        let type: String?
    }

    let error: Body
}

/// Best-effort message extraction from an error body of unknown shape, shared by the Anthropic
/// provider and custom-endpoint model discovery. Handles the Anthropic shape, the OpenAI shape,
/// and FastAPI's `{"detail": "..."}`.
nonisolated enum CustomEndpointErrorBody {
    private nonisolated struct DetailResponse: Decodable {
        let detail: String
    }

    static func message(from data: Data) -> String? {
        let decoder = JSONDecoder()
        if let anthropic = try? decoder.decode(AnthropicErrorResponse.self, from: data) {
            return anthropic.error.message
        }
        if let openAI = try? decoder.decode(OpenAIStyleErrorResponse.self, from: data) {
            return openAI.error.message
        }
        if let detail = try? decoder.decode(DetailResponse.self, from: data) {
            return detail.detail
        }
        return nil
    }
}

// MARK: - Type-Erased Codable Value

/// Type-erased value for encoding/decoding arbitrary JSON
nonisolated enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    var value: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let arr): return arr.map { $0.value }
        case .dictionary(let dict): return dict.mapValues { $0.value }
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodableValue"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .bool(let b):
            try container.encode(b)
        case .array(let arr):
            try container.encode(arr)
        case .dictionary(let dict):
            try container.encode(dict)
        case .null:
            try container.encodeNil()
        }
    }

    static func from(_ any: Any) -> AnyCodableValue {
        switch any {
        case let s as String:
            return .string(s)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let b as Bool:
            return .bool(b)
        case let arr as [Any]:
            return .array(arr.map { from($0) })
        case let dict as [String: Any]:
            return .dictionary(dict.mapValues { from($0) })
        default:
            return .null
        }
    }
}
#endif
