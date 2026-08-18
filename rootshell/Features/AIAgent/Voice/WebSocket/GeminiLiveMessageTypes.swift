#if !CHINA_BUILD
//
//  GeminiLiveMessageTypes.swift
//  rootshell
//
//  JSON message types for the Gemini Live API WebSocket protocol.
//  Reference: https://ai.google.dev/api/multimodal-live
//

import Foundation

// MARK: - Client → Server Messages

/// Initial setup message sent immediately after WebSocket connection.
struct GeminiLiveSetup: Encodable {
    let setup: SetupPayload

    struct SetupPayload: Encodable {
        let model: String
        let generationConfig: GenerationConfig?
        let systemInstruction: SystemInstruction?
        let tools: [ToolDeclaration]?
        let realtimeInputConfig: RealtimeInputConfig?
        let sessionResumption: SessionResumptionConfig?
        let contextWindowCompression: ContextWindowCompressionConfig?
        let inputAudioTranscription: AudioTranscriptionConfig?
        let outputAudioTranscription: AudioTranscriptionConfig?
    }

    struct GenerationConfig: Encodable {
        let responseModalities: [String]
        let speechConfig: SpeechConfig?
    }

    struct SpeechConfig: Encodable {
        let voiceConfig: VoiceConfig
    }

    struct VoiceConfig: Encodable {
        let prebuiltVoiceConfig: PrebuiltVoiceConfig
    }

    struct PrebuiltVoiceConfig: Encodable {
        let voiceName: String
    }

    struct SystemInstruction: Encodable {
        let parts: [TextPart]
    }

    struct TextPart: Encodable {
        let text: String
    }

    struct ToolDeclaration: Encodable {
        let functionDeclarations: [FunctionDeclaration]
    }

    struct RealtimeInputConfig: Encodable {
        let activityHandling: String?
        let automaticActivityDetection: AutomaticActivityDetection?
    }

    struct AutomaticActivityDetection: Encodable {
        let disabled: Bool?
        let startOfSpeechSensitivity: String?
        let prefixPaddingMs: Int?
        let endOfSpeechSensitivity: String?
        let silenceDurationMs: Int?
    }

    struct SessionResumptionConfig: Encodable {
        let handle: String?
    }

    struct ContextWindowCompressionConfig: Encodable {
        let slidingWindow: SlidingWindow

        struct SlidingWindow: Encodable {}
    }

    struct AudioTranscriptionConfig: Encodable {}

    struct FunctionDeclaration: Encodable {
        let name: String
        let description: String
        let parameters: LiveParameterSchema
        let behavior: String?

        init(name: String, description: String, parameters: LiveParameterSchema, behavior: String? = nil) {
            self.name = name
            self.description = description
            self.parameters = parameters
            self.behavior = behavior
        }
    }

    /// Simplified parameter schema for Live API function declarations.
    struct LiveParameterSchema: Encodable {
        let type: String
        let properties: [String: LivePropertySchema]
        let required: [String]

        init(properties: [String: LivePropertySchema], required: [String]) {
            self.type = "object"
            self.properties = properties
            self.required = required
        }
    }

    struct LivePropertySchema: Encodable {
        let type: String
        let description: String?
        let `enum`: [String]?

        init(type: String, description: String? = nil, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enum = enumValues
        }
    }
}

/// Audio input sent as real-time stream.
/// Uses the raw WebSocket audio format for Gemini 3.1 Flash Live.
struct GeminiLiveAudioInput: Encodable {
    let realtimeInput: RealtimeInput

    struct RealtimeInput: Encodable {
        let audio: AudioBlob
    }

    struct AudioBlob: Encodable {
        let mimeType: String
        let data: String  // base64-encoded PCM16
    }

    init(pcmData: Data) {
        self.realtimeInput = RealtimeInput(
            audio: AudioBlob(
                mimeType: "audio/pcm;rate=16000",
                data: pcmData.base64EncodedString()
            )
        )
    }
}

/// Tool response sent after executing a function call.
struct GeminiLiveToolResponse: Encodable {
    let toolResponse: ToolResponsePayload

    struct ToolResponsePayload: Encodable {
        let functionResponses: [FunctionResponse]
    }

    struct FunctionResponse: Encodable {
        let id: String
        let name: String
        let response: ResponseContent
    }

    struct ResponseContent: Encodable {
        let result: String
        let scheduling: String?
    }

    init(responses: [(id: String, name: String, result: String, scheduling: String?)]) {
        self.toolResponse = ToolResponsePayload(
            functionResponses: responses.map { resp in
                FunctionResponse(
                    id: resp.id,
                    name: resp.name,
                    response: ResponseContent(result: resp.result, scheduling: resp.scheduling)
                )
            }
        )
    }
}

// MARK: - Server → Client Messages

/// Parsed server message from the Gemini Live API WebSocket.
enum GeminiLiveServerMessage: Sendable {
    /// Setup completed acknowledgment
    case setupComplete

    /// Audio data from the model
    case audioData(Data)

    /// Text content from the model (transcript of speech)
    case textContent(String)

    /// Transcribed user speech.
    case inputTranscription(String)

    /// Transcribed model speech.
    case outputTranscription(String)

    /// Model turn complete
    case turnComplete

    /// Model generation complete; playback may still continue.
    case generationComplete

    /// Model was interrupted by user speech (barge-in)
    case interrupted

    /// Tool calls requested by the model
    case toolCalls([LiveToolCall])

    /// Previously issued tool calls should be cancelled.
    case toolCallCancellation([String])

    /// Session resumption state changed.
    case sessionResumptionUpdate(newHandle: String?, resumable: Bool)

    /// Error from server
    case error(String)

    /// Go-away signal (session ending)
    case goAway(timeLeft: String?)
}

/// A tool call from the Live API.
struct LiveToolCall: Sendable {
    let id: String
    let name: String
    let args: [String: String]
}

// MARK: - Server Message Parsing

enum GeminiLiveMessageParser {

    /// Parse a raw WebSocket text message into one or more typed server messages.
    static func parse(_ text: String) -> [GeminiLiveServerMessage] {
        guard let data = text.data(using: .utf8) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var messages: [GeminiLiveServerMessage] = []

        // Setup complete
        if json["setupComplete"] != nil {
            messages.append(.setupComplete)
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            let calls = functionCalls.compactMap { call -> LiveToolCall? in
                guard let id = call["id"] as? String,
                      let name = call["name"] as? String else { return nil }
                let args = (call["args"] as? [String: Any])?.compactMapValues { value -> String? in
                    stringify(value)
                } ?? [:]
                return LiveToolCall(id: id, name: name, args: args)
            }
            if !calls.isEmpty {
                messages.append(.toolCalls(calls))
            }
        }

        if let cancellation = json["toolCallCancellation"] as? [String: Any],
           let ids = cancellation["ids"] as? [String], !ids.isEmpty {
            messages.append(.toolCallCancellation(ids))
        }

        if let update = json["sessionResumptionUpdate"] as? [String: Any] {
            let newHandle = update["newHandle"] as? String
            let resumable = update["resumable"] as? Bool ?? false
            messages.append(.sessionResumptionUpdate(newHandle: newHandle, resumable: resumable))
        }

        if let goAway = json["goAway"] as? [String: Any] {
            messages.append(.goAway(timeLeft: stringify(goAway["timeLeft"])))
        } else if json["goAway"] != nil {
            messages.append(.goAway(timeLeft: nil))
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            messages.append(.error(message))
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String,
               !text.isEmpty {
                messages.append(.inputTranscription(text))
            }

            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String,
               !text.isEmpty {
                messages.append(.outputTranscription(text))
            }

            // Interrupted
            if serverContent["interrupted"] as? Bool == true {
                messages.append(.interrupted)
            }

            // Generation complete (end of model's response)
            if serverContent["generationComplete"] as? Bool == true {
                messages.append(.generationComplete)
            }

            // Turn complete (may also include usageMetadata)
            if serverContent["turnComplete"] as? Bool == true {
                messages.append(.turnComplete)
            }

            // Model turn parts (audio + text)
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    // Audio data
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let b64 = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: b64) {
                        messages.append(.audioData(audioData))
                    }
                    // Text
                    if let text = part["text"] as? String, !text.isEmpty {
                        messages.append(.textContent(text))
                    }
                }
            }
        }

        return messages
    }

    private static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }
}
#endif
