#if !CHINA_BUILD
//
//  GeminiAPITypes.swift
//  rootshell
//
//  Request and response types for the Google Gemini API
//

import Foundation

// MARK: - Request Types

/// Main request structure for Gemini generateContent API
struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiSystemInstruction?
    let tools: [GeminiTool]?
    let generationConfig: GeminiGenerationConfig?

    init(
        contents: [GeminiContent],
        systemInstruction: String?,
        tools: [GeminiTool]? = nil,
        generationConfig: GeminiGenerationConfig? = nil
    ) {
        self.contents = contents
        self.systemInstruction = systemInstruction.map { GeminiSystemInstruction(parts: [.text($0)]) }
        self.tools = tools?.isEmpty == true ? nil : tools
        self.generationConfig = generationConfig
    }
}

/// System instruction wrapper
struct GeminiSystemInstruction: Encodable {
    let parts: [GeminiPart]
}

/// Generation configuration
struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int?
    let temperature: Double?
    let topP: Double?
    let topK: Int?

    init(maxOutputTokens: Int? = nil, temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
    }
}

/// A content block in the conversation
nonisolated struct GeminiContent: Codable {
    let role: String  // "user" or "model"
    let parts: [GeminiPart]

    static func user(_ parts: [GeminiPart]) -> GeminiContent {
        GeminiContent(role: "user", parts: parts)
    }

    static func user(_ text: String) -> GeminiContent {
        GeminiContent(role: "user", parts: [.text(text)])
    }

    static func model(_ parts: [GeminiPart]) -> GeminiContent {
        GeminiContent(role: "model", parts: parts)
    }

    static func model(_ text: String) -> GeminiContent {
        GeminiContent(role: "model", parts: [.text(text)])
    }
}

/// Part types in a content block
nonisolated enum GeminiPart: Codable {
    case text(String)
    case functionCall(GeminiFunctionCall, thoughtSignature: String?)
    case functionResponse(GeminiFunctionResponse)

    enum CodingKeys: String, CodingKey {
        case text
        case functionCall
        case functionResponse
        case thoughtSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let functionCall = try container.decodeIfPresent(GeminiFunctionCall.self, forKey: .functionCall) {
            let signature = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
            self = .functionCall(functionCall, thoughtSignature: signature)
        } else if let functionResponse = try container.decodeIfPresent(GeminiFunctionResponse.self, forKey: .functionResponse) {
            self = .functionResponse(functionResponse)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown GeminiPart type"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .functionCall(let call, let signature):
            try container.encode(call, forKey: .functionCall)
            try container.encodeIfPresent(signature, forKey: .thoughtSignature)
        case .functionResponse(let response):
            try container.encode(response, forKey: .functionResponse)
        }
    }
}

/// Function call from model
nonisolated struct GeminiFunctionCall: Codable {
    let name: String
    let args: [String: AnyCodableValue]

    init(name: String, args: [String: AnyCodableValue]) {
        self.name = name
        self.args = args
    }
}

/// Function response from client
nonisolated struct GeminiFunctionResponse: Codable {
    let name: String
    let response: GeminiFunctionResponseContent

    init(name: String, result: String) {
        self.name = name
        self.response = GeminiFunctionResponseContent(result: result)
    }
}

/// Function response content wrapper
nonisolated struct GeminiFunctionResponseContent: Codable {
    let result: String
}

// MARK: - Tool Definitions

/// Tool definition containing function declarations
struct GeminiTool: Encodable {
    let functionDeclarations: [GeminiFunctionDeclaration]
}

/// Function declaration for tool definition
struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: GeminiParameterSchema
}

/// JSON Schema for function parameters
struct GeminiParameterSchema: Encodable {
    let type: String
    let properties: [String: GeminiPropertySchema]
    let required: [String]

    init(properties: [String: GeminiPropertySchema], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// Box wrapper to allow recursive GeminiPropertySchema
final class GeminiPropertySchemaBox: Encodable, @unchecked Sendable {
    let value: GeminiPropertySchema

    init(_ value: GeminiPropertySchema) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// Schema for a single property
struct GeminiPropertySchema: Encodable {
    let type: String
    let description: String?
    let `enum`: [String]?
    let items: GeminiPropertySchemaBox?

    init(type: String, description: String? = nil, enumValues: [String]? = nil, items: GeminiPropertySchema? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
        self.items = items.map { GeminiPropertySchemaBox($0) }
    }
}

// MARK: - Response Types

/// Main response structure from Gemini generateContent API
nonisolated struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
    let promptFeedback: GeminiPromptFeedback?
}

/// A candidate response
nonisolated struct GeminiCandidate: Decodable {
    let content: GeminiContent?
    let finishReason: String?
    let safetyRatings: [GeminiSafetyRating]?
}

/// Safety rating for content
nonisolated struct GeminiSafetyRating: Decodable {
    let category: String
    let probability: String
}

/// Prompt feedback (for blocked prompts)
nonisolated struct GeminiPromptFeedback: Decodable {
    let blockReason: String?
    let safetyRatings: [GeminiSafetyRating]?
}

/// Token usage statistics
nonisolated struct GeminiUsageMetadata: Decodable, Sendable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?

    nonisolated var inputTokens: Int { promptTokenCount ?? 0 }
    nonisolated var outputTokens: Int { candidatesTokenCount ?? 0 }
}

// MARK: - Error Response

/// Error response from Gemini API
nonisolated struct GeminiErrorResponse: Decodable, Sendable {
    let error: GeminiError
}

nonisolated struct GeminiError: Decodable, Sendable {
    let code: Int
    let message: String
    let status: String?
}

// MARK: - Streaming Response

/// Streaming response chunk (same structure as GeminiResponse)
typealias GeminiStreamChunk = GeminiResponse
#endif
