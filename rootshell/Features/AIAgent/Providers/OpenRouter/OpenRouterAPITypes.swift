#if !CHINA_BUILD
//
//  OpenRouterAPITypes.swift
//  rootshell
//
//  API request/response types for OpenRouter
//

import Foundation

// MARK: - Chat Completion Request

struct OpenRouterRequest: Encodable {
    let model: String
    let messages: [OpenRouterMessage]
    let tools: [OpenRouterTool]?
    let stream: Bool
    let max_tokens: Int?
    let temperature: Double?
}

// MARK: - Messages

struct OpenRouterMessage: Codable {
    let role: String
    let content: OpenRouterContent?
    let tool_calls: [OpenRouterToolCall]?
    let tool_call_id: String?
    let name: String?

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
        self.tool_calls = nil
        self.tool_call_id = nil
        self.name = nil
    }

    init(role: String, toolCalls: [OpenRouterToolCall]) {
        self.role = role
        self.content = nil
        self.tool_calls = toolCalls
        self.tool_call_id = nil
        self.name = nil
    }

    init(role: String, toolCallId: String, content: String) {
        self.role = role
        self.content = .text(content)
        self.tool_calls = nil
        self.tool_call_id = toolCallId
        self.name = nil
    }
}

enum OpenRouterContent: Codable {
    case text(String)
    case parts([OpenRouterContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([OpenRouterContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.typeMismatch(
                OpenRouterContent.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or [Part]")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

struct OpenRouterContentPart: Codable {
    let type: String
    let text: String?
}

// MARK: - Tool Calls

struct OpenRouterToolCall: Codable {
    let id: String
    let type: String
    let function: OpenRouterFunctionCall

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = OpenRouterFunctionCall(name: name, arguments: arguments)
    }
}

struct OpenRouterFunctionCall: Codable {
    let name: String
    let arguments: String
}

// MARK: - Tools

struct OpenRouterTool: Encodable {
    let type: String
    let function: OpenRouterFunctionDefinition

    init(function: OpenRouterFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct OpenRouterFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: OpenRouterToolParameters
}

struct OpenRouterToolParameters: Encodable {
    let type: String
    let properties: [String: OpenRouterPropertySchema]
    let required: [String]

    init(properties: [String: OpenRouterPropertySchema], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// Box wrapper for recursive Encodable types
final class OpenRouterSchemaBox: Encodable {
    let value: OpenRouterPropertySchema
    init(_ value: OpenRouterPropertySchema) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

struct OpenRouterPropertySchema: Encodable {
    let type: String
    let description: String?
    let `enum`: [String]?
    let items: OpenRouterSchemaBox?

    init(type: String, description: String? = nil, enumValues: [String]? = nil, items: OpenRouterPropertySchema? = nil) {
        self.type = type
        self.description = description
        self.`enum` = enumValues
        self.items = items.map { OpenRouterSchemaBox($0) }
    }
}

// MARK: - Chat Completion Response

nonisolated struct OpenRouterResponse: Decodable {
    let id: String?
    let choices: [OpenRouterChoice]?
    let usage: OpenRouterUsage?
    let error: OpenRouterErrorDetail?
}

nonisolated struct OpenRouterChoice: Decodable {
    let index: Int?
    let message: OpenRouterResponseMessage?
    let delta: OpenRouterResponseMessage?
    let finish_reason: String?
}

nonisolated struct OpenRouterResponseMessage: Decodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenRouterResponseToolCall]?
}

nonisolated struct OpenRouterResponseToolCall: Decodable {
    let id: String?
    let index: Int?
    let type: String?
    let function: OpenRouterResponseFunctionCall?
}

nonisolated struct OpenRouterResponseFunctionCall: Decodable {
    let name: String?
    let arguments: String?
}

nonisolated struct OpenRouterUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
}

nonisolated struct OpenRouterErrorDetail: Decodable {
    let message: String?
    let type: String?
    let code: String?
}

// MARK: - Error Response

nonisolated struct OpenRouterErrorResponse: Decodable {
    let error: OpenRouterErrorDetail
}

// MARK: - Model Discovery

struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterAPIModel]
}

struct OpenRouterAPIModel: Decodable {
    let id: String
    let name: String?
    let description: String?
    let context_length: Int?
    let pricing: OpenRouterPricing?
    let top_provider: OpenRouterTopProvider?
    let per_request_limits: OpenRouterRequestLimits?
    let architecture: OpenRouterArchitecture?

    /// Parse provider name from model ID (e.g., "anthropic/claude-3.5-sonnet" → "anthropic")
    var providerName: String {
        guard let slash = id.firstIndex(of: "/") else { return "unknown" }
        return String(id[..<slash])
    }

    /// Check if this is a free model variant
    var isFree: Bool {
        id.hasSuffix(":free")
    }
}

struct OpenRouterPricing: Decodable {
    let prompt: String?
    let completion: String?
    let request: String?
    let image: String?
}

struct OpenRouterTopProvider: Decodable {
    let is_moderated: Bool?
    let max_completion_tokens: Int?
}

struct OpenRouterRequestLimits: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
}

struct OpenRouterArchitecture: Decodable {
    let tokenizer: String?
    let instruct_type: String?
    let modality: String?
}
#endif
