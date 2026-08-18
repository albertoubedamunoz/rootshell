#if !CHINA_BUILD
//
//  GeminiLiveConnection.swift
//  rootshell
//
//  WebSocket connection manager for the Gemini Live API.
//  Handles connection lifecycle, message sending/receiving, and reconnection.
//

import Foundation
import os.log

/// Delegate for receiving parsed messages from the Live API connection.
@MainActor
protocol GeminiLiveConnectionDelegate: AnyObject {
    func connectionDidOpen()
    func connectionDidClose(reason: String?)
    func connectionDidReceive(message: GeminiLiveServerMessage)
    func connectionDidFail(error: Error)
}

/// Manages the WebSocket connection to the Gemini Live API.
@MainActor
final class GeminiLiveConnection {

    // MARK: - Properties

    @ObservationIgnored
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GeminiLiveConnection")

    weak var delegate: GeminiLiveConnectionDelegate?

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private let apiKey: String

    /// The model name extracted from the setup message, used to build the URL.
    static let defaultModel = "gemini-3.1-flash-live-preview"

    // MARK: - Initialization

    init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
    }

    deinit {
        pingTask?.cancel()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connection

    func connect(setup: GeminiLiveSetup) async throws {
        guard !isConnected else { return }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw GeminiLiveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        receiveCount = 0
        audioChunkCount = 0
        Self.logger.info("Connecting to Live API (v1beta) with model: \(setup.setup.model)")

        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        // Send setup message (proto3 canonical JSON uses camelCase)
        let encoder = JSONEncoder()
        let setupData = try encoder.encode(setup)
        guard let setupString = String(data: setupData, encoding: .utf8) else {
            throw GeminiLiveError.encodingFailed
        }

        Self.logger.debug("Setup JSON: \(setupString.prefix(500))")
        try await task.send(.string(setupString))
        Self.logger.info("Sent setup message, waiting for setupComplete")

        // Start receive loop and keep-alive ping
        startReceiving()
        startPinging()
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    // MARK: - Sending

    private var audioChunkCount = 0
    private var receiveCount = 0

    func sendAudio(_ pcmData: Data) {
        guard let task = webSocketTask, isConnected else { return }

        let message = GeminiLiveAudioInput(pcmData: pcmData)
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else { return }

        audioChunkCount += 1
        if audioChunkCount == 1 || audioChunkCount % 50 == 0 {
            // Analyze PCM16 audio level to verify we're sending real audio.
            // Widen to Int32 before abs() — abs(Int16.min) traps on overflow.
            let sampleCount = pcmData.count / 2
            var maxSample: Int32 = 0
            var sumSquares: Float = 0
            pcmData.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    let sample = Int32(samples[i])
                    let absSample = abs(sample)
                    if absSample > maxSample { maxSample = absSample }
                    sumSquares += Float(sample) * Float(sample)
                }
            }
            let rms = sqrt(sumSquares / Float(max(sampleCount, 1)))
            Self.logger.info("Audio chunk #\(self.audioChunkCount): \(pcmData.count)B PCM, rms=\(rms, format: .fixed(precision: 1)), max=\(maxSample), \(string.count)B JSON")
        }

        task.send(.string(string)) { error in
            if let error {
                GeminiLiveConnection.logger.error("Audio send error: \(error.localizedDescription)")
            }
        }
    }

    /// Send a text message as client_content (useful for testing or text-based interaction).
    func sendClientContent(_ text: String) async throws {
        guard let task = webSocketTask else {
            throw GeminiLiveError.notConnected
        }

        // BidiGenerateContentClientContent JSON
        let json: [String: Any] = [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": text]]]
                ],
                "turnComplete": true
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GeminiLiveError.encodingFailed
        }

        Self.logger.info("Sending client_content: \(text.prefix(100))")
        try await task.send(.string(string))
    }

    func sendToolResponses(_ responses: [(id: String, name: String, result: String, scheduling: String?)]) async throws {
        guard let task = webSocketTask else {
            throw GeminiLiveError.notConnected
        }

        let message = GeminiLiveToolResponse(responses: responses)
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GeminiLiveError.encodingFailed
        }

        try await task.send(.string(string))
        Self.logger.info("Sent tool responses for \(responses.count) calls")
    }

    // MARK: - Receiving

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, let task = self.webSocketTask else { return }
                task.sendPing { error in
                    if let error {
                        GeminiLiveConnection.logger.warning("Ping failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                receiveCount += 1
                let msgNum = receiveCount
                switch message {
                case .string(let text):
                    // Log top-level keys of every received message
                    let keys = Self.extractTopLevelKeys(text)
                    Self.logger.info("WS recv #\(msgNum) (\(text.count)B): keys=[\(keys)]")
                    let parsed = GeminiLiveMessageParser.parse(text)
                    if !parsed.isEmpty {
                        handleParsedMessages(parsed)
                    } else if Self.isIgnorableEnvelope(text) {
                        continue
                    } else {
                        Self.logger.warning("Unparseable #\(msgNum): \(text.prefix(300))")
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        let keys = Self.extractTopLevelKeys(text)
                        Self.logger.info("WS recv #\(msgNum) binary (\(data.count)B): keys=[\(keys)]")
                        let parsed = GeminiLiveMessageParser.parse(text)
                        if !parsed.isEmpty {
                            handleParsedMessages(parsed)
                        } else if Self.isIgnorableEnvelope(text) {
                            continue
                        } else {
                            Self.logger.warning("Unparseable #\(msgNum): \(text.prefix(300))")
                        }
                    } else {
                        let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
                        Self.logger.warning("WS recv #\(msgNum) raw binary (\(data.count)B): \(hex)")
                    }
                @unknown default:
                    Self.logger.warning("WS recv #\(msgNum) unknown message type")
                }
            } catch {
                if !Task.isCancelled {
                    // Capture WebSocket close code for diagnostics
                    let closeCode = task.closeCode
                    let closeReason: String?
                    if let reasonData = task.closeReason {
                        closeReason = String(data: reasonData, encoding: .utf8)
                    } else {
                        closeReason = nil
                    }
                    Self.logger.error("WebSocket receive error: \(error.localizedDescription), closeCode=\(closeCode.rawValue), closeReason=\(closeReason ?? "nil")")
                    let reason = closeReason ?? error.localizedDescription
                    delegate?.connectionDidClose(reason: "[\(closeCode.rawValue)] \(reason)")
                }
                return
            }
        }
    }

    private func handleParsedMessages(_ messages: [GeminiLiveServerMessage]) {
        for message in messages {
            handleParsedMessage(message)
        }
    }

    private func handleParsedMessage(_ message: GeminiLiveServerMessage) {
        switch message {
        case .setupComplete:
            isConnected = true
            Self.logger.info("Live API setup complete")
            delegate?.connectionDidOpen()

        case .goAway(let timeLeft):
            let timeLeftDescription = timeLeft ?? "unknown"
            Self.logger.info("Received go-away signal, time left: \(timeLeftDescription)")
            delegate?.connectionDidReceive(message: message)

        case .toolCalls(let calls):
            let names = calls.map(\.name).joined(separator: ", ")
            Self.logger.info("Tool calls received: [\(names)]")
            delegate?.connectionDidReceive(message: message)

        case .toolCallCancellation(let ids):
            Self.logger.info("Tool call cancellation received for ids: \(ids.joined(separator: ", "))")
            delegate?.connectionDidReceive(message: message)

        case .sessionResumptionUpdate(let newHandle, let resumable):
            let handleDescription = newHandle ?? "nil"
            Self.logger.info("Session resumption update: resumable=\(resumable), handle=\(handleDescription)")
            delegate?.connectionDidReceive(message: message)

        case .audioData(let data):
            // Don't log every audio chunk — too noisy
            delegate?.connectionDidReceive(message: message)
            _ = data  // suppress unused warning

        case .textContent(let text):
            Self.logger.info("Text content: \(text.prefix(120))")
            delegate?.connectionDidReceive(message: message)

        case .inputTranscription(let text):
            Self.logger.info("Input transcription: \(text.prefix(120))")
            delegate?.connectionDidReceive(message: message)

        case .outputTranscription(let text):
            Self.logger.info("Output transcription: \(text.prefix(120))")
            delegate?.connectionDidReceive(message: message)

        case .generationComplete:
            Self.logger.info("Generation complete")
            delegate?.connectionDidReceive(message: message)

        case .turnComplete:
            Self.logger.info("Turn complete")
            delegate?.connectionDidReceive(message: message)

        case .interrupted:
            Self.logger.info("Interrupted by user")
            delegate?.connectionDidReceive(message: message)

        case .error(let msg):
            Self.logger.error("Server error: \(msg)")
            delegate?.connectionDidReceive(message: message)
        }
    }

    /// Extract top-level JSON keys for logging (e.g. "serverContent,usageMetadata").
    private nonisolated static func extractTopLevelKeys(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "?"
        }
        return obj.keys.sorted().joined(separator: ", ")
    }

    private nonisolated static func isIgnorableEnvelope(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        if let serverContent = obj["serverContent"] as? [String: Any], serverContent.isEmpty {
            let ignorableKeys: Set<String> = ["serverContent", "usageMetadata"]
            return Set(obj.keys).isSubset(of: ignorableKeys)
        }

        return false
    }
}

// MARK: - Errors

enum GeminiLiveError: LocalizedError {
    case invalidURL
    case encodingFailed
    case notConnected
    case setupFailed(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Live API URL"
        case .encodingFailed:
            return "Failed to encode message"
        case .notConnected:
            return "Not connected to Live API"
        case .setupFailed(let reason):
            return "Live API setup failed: \(reason)"
        case .sessionExpired:
            return "Voice session expired (30 minute limit)"
        }
    }
}
#endif
