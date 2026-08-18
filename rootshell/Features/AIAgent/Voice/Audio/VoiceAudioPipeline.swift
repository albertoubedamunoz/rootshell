#if !CHINA_BUILD
//
//  VoiceAudioPipeline.swift
//  rootshell
//
//  Unified audio capture + playback engine using a single AVAudioEngine
//  for proper acoustic echo cancellation (AEC).
//
//  Using separate AVAudioEngine instances for capture and playback breaks AEC
//  because the voice-processing I/O unit on the capture engine has no reference
//  to the playback audio, so it can't subtract speaker output from the mic input.
//  With a single engine, the VPIO unit sees both paths and cancels the echo.
//

@preconcurrency import AVFoundation
import os.log

@MainActor
final class VoiceAudioPipeline {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VoiceAudioPipeline")

    // MARK: - Public Interface

    /// Called with PCM16 data chunks (~100ms) ready for WebSocket transmission.
    var onAudioChunk: ((Data) -> Void)?

    /// Current microphone audio level (0.0 - 1.0) for UI visualization.
    private(set) var inputLevel: Float = 0.0

    /// Current output audio level (0.0 - 1.0) for UI visualization.
    private(set) var outputLevel: Float = 0.0

    /// Whether audio is currently playing.
    private(set) var isPlaying = false

    // MARK: - Private State

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureContext: CaptureContext?
    private var playbackContext: PlaybackContext?
    private var isRunning = false
    private var isMuted = false

    /// Capture target format: 16kHz, 16-bit signed integer, mono
    private nonisolated static let captureSampleRate: Double = 16000
    private nonisolated static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: captureSampleRate,
        channels: 1,
        interleaved: true
    )!

    /// Gemini API output format: 24kHz, 16-bit signed integer, mono
    private nonisolated static let playbackSampleRate: Double = 24000
    private nonisolated static let geminiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: playbackSampleRate,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let (engine, player, inputFormat, playerFormat) = try Self.createEngine(voiceProcessing: true)

        Self.logger.info("VP enabled: input=\(engine.inputNode.isVoiceProcessingEnabled)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.logger.error("Invalid input format — sampleRate or channelCount is 0")
            throw VoiceAudioPipelineError.invalidInputFormat
        }

        // 6. Create playback converter (Gemini 24kHz PCM16 → engine native format)
        guard let pbConverter = AVAudioConverter(from: Self.geminiFormat, to: playerFormat) else {
            Self.logger.error("Failed to create playback converter")
            throw VoiceAudioPipelineError.playbackConverterFailed
        }
        let pbCtx = PlaybackContext(converter: pbConverter, format: playerFormat)
        self.playbackContext = pbCtx

        // 7. Create capture converter (mono at input sample rate → 16kHz PCM16).
        //    When the input has multiple channels (e.g. VPIO aggregate on Studio
        //    Display with Dolby outputs), we extract channel 0 in the tap callback
        //    before converting, so the converter always works with mono input.
        let monoInputFormat: AVAudioFormat
        if inputFormat.channelCount > 1 {
            monoInputFormat = AVAudioFormat(
                commonFormat: inputFormat.commonFormat,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            Self.logger.info("Multi-channel input (\(inputFormat.channelCount)ch) — will extract ch0 to mono for capture")
        } else {
            monoInputFormat = inputFormat
        }

        guard let captureConverter = AVAudioConverter(from: monoInputFormat, to: Self.captureFormat) else {
            throw VoiceAudioPipelineError.captureConverterFailed
        }

        let needsChannelExtraction = inputFormat.channelCount > 1
        let capCtx = CaptureContext(converter: captureConverter, extractChannel0: needsChannelExtraction)
        self.captureContext = capCtx

        // 8. Install capture tap with low-latency buffer so AEC/VAD stay aligned
        let inputNode = engine.inputNode
        let bufferSize = AVAudioFrameCount(max(480, Int(inputFormat.sampleRate * 0.02)))
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.processInputBuffer(buffer, context: capCtx)
        }

        // 9. Start engine and player
        try engine.start()
        player.play()

        self.audioEngine = engine
        self.playerNode = player
        isRunning = true
        Self.logger.info("Voice audio pipeline started (single-engine AEC)")
    }

    func stop() {
        guard isRunning else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        captureContext = nil
        playbackContext = nil
        isRunning = false
        isPlaying = false
        inputLevel = 0.0
        outputLevel = 0.0
        Self.logger.info("Voice audio pipeline stopped")
    }

    // MARK: - Private: Engine Factory

    /// Creates a prepared AVAudioEngine with player node attached.
    /// Returns the engine, player, and negotiated input/player formats.
    private static func createEngine(
        voiceProcessing: Bool
    ) throws -> (AVAudioEngine, AVAudioPlayerNode, AVAudioFormat, AVAudioFormat) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        // Enable VPIO after the player→mainMixer edge exists. Enabling it on a
        // bare input node leaves the graph in a state where the input tap
        // stops delivering buffers on most launches (the node is VP-configured
        // but the engine never performs the post-connect graph rebuild that
        // wires the tap into the VP unit). AVFoundation can raise an ObjC
        // NSException from this call when the audio session or route can't
        // support VPIO; Swift's try/catch cannot catch that, so it unwinds
        // into C++ and aborts. AVExceptionCatcher converts it into a Swift
        // throw instead of SIGABRT.
        if voiceProcessing {
            var swiftError: Error?
            let caught = AVExceptionCatcher.catchException {
                do {
                    try inputNode.setVoiceProcessingEnabled(true)
                } catch {
                    swiftError = error
                }
            }
            if let nsException = caught {
                let name = nsException.name.rawValue
                let reason = nsException.reason ?? "no reason"
                logger.error("setVoiceProcessingEnabled raised NSException \(name): \(reason)")
                throw VoiceAudioPipelineError.voiceProcessingFailed("\(name): \(reason)")
            }
            if let error = swiftError {
                let desc = error.localizedDescription
                logger.error("setVoiceProcessingEnabled threw Swift error: \(desc)")
                throw VoiceAudioPipelineError.voiceProcessingFailed(desc)
            }
            logger.info("Voice processing enabled on input node")
        } else {
            logger.info("Voice processing disabled")
        }

        engine.prepare()

        let playerFormat = player.outputFormat(forBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        logger.info("After prepare — player format: \(playerFormat.sampleRate)Hz, \(playerFormat.channelCount)ch | input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        return (engine, player, inputFormat, playerFormat)
    }

    // MARK: - Capture Control

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    // MARK: - Playback

    /// Schedule PCM16 audio data (24kHz from Gemini) for playback.
    func scheduleAudio(_ pcmData: Data) {
        guard let player = playerNode, let pbCtx = playbackContext, isRunning else { return }

        let srcFrameCount = pcmData.count / MemoryLayout<Int16>.size
        guard srcFrameCount > 0 else { return }

        // Create source buffer in Gemini's format (24kHz PCM16 mono)
        guard let srcBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.geminiFormat,
            frameCapacity: AVAudioFrameCount(srcFrameCount)
        ) else { return }
        srcBuffer.frameLength = AVAudioFrameCount(srcFrameCount)

        pcmData.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress else { return }
            if let dest = srcBuffer.int16ChannelData?[0] {
                memcpy(dest, src, pcmData.count)
            }
        }

        // Convert to the engine's negotiated format for scheduling
        let dstFrameCount = AVAudioFrameCount(
            ceil(Double(srcFrameCount) * pbCtx.format.sampleRate / Self.playbackSampleRate)
        )
        guard let dstBuffer = AVAudioPCMBuffer(
            pcmFormat: pbCtx.format,
            frameCapacity: dstFrameCount
        ) else { return }

        var error: NSError?
        let status = pbCtx.converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }

        guard status != .error, error == nil, dstBuffer.frameLength > 0 else { return }

        outputLevel = Self.calculatePCM16Level(from: pcmData)
        isPlaying = true

        player.scheduleBuffer(dstBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkPlaybackFinished()
            }
        }
    }

    /// Immediately stop playback (barge-in).
    func interruptPlayback() {
        playerNode?.stop()
        playerNode?.reset()
        playerNode?.play()  // Restart node so it can accept new buffers
        isPlaying = false
        outputLevel = 0.0
        Self.logger.info("Playback interrupted, buffers cleared")
    }

    // MARK: - Private: Context Wrappers

    /// Holds non-Sendable AVAudioConverter for the capture audio thread callback.
    private nonisolated final class CaptureContext: @unchecked Sendable {
        let converter: AVAudioConverter
        let extractChannel0: Bool
        var didLogFirst = false
        init(converter: AVAudioConverter, extractChannel0: Bool = false) {
            self.converter = converter
            self.extractChannel0 = extractChannel0
        }
    }

    /// Holds non-Sendable converter and format info for playback conversion.
    private final class PlaybackContext: @unchecked Sendable {
        let converter: AVAudioConverter
        let format: AVAudioFormat
        init(converter: AVAudioConverter, format: AVAudioFormat) {
            self.converter = converter
            self.format = format
        }
    }

    // MARK: - Private: Capture Processing

    private nonisolated func processInputBuffer(_ buffer: AVAudioPCMBuffer, context: CaptureContext) {
        // Log first tap callback to confirm the tap is active
        if !context.didLogFirst {
            context.didLogFirst = true
            let level = Self.calculateFloatLevel(buffer)
            VoiceAudioPipeline.logger.info("Tap active: \(buffer.frameLength) frames at \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch, level=\(level)")
        }

        let level = Self.calculateFloatLevel(buffer)

        // If the input is multi-channel (e.g. VPIO aggregate on Studio Display),
        // extract channel 0 (the mic) into a mono buffer so the converter works.
        let monoBuffer: AVAudioPCMBuffer
        if context.extractChannel0 {
            guard let extracted = Self.extractChannel0(from: buffer) else { return }
            monoBuffer = extracted
        } else {
            monoBuffer = buffer
        }

        let frameCount = AVAudioFrameCount(
            Double(monoBuffer.frameLength) * Self.captureSampleRate / monoBuffer.format.sampleRate
        )
        guard frameCount > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.captureFormat,
            frameCapacity: frameCount
        ) else { return }

        var error: NSError?
        let status = context.converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return monoBuffer
        }

        guard status != .error, error == nil else {
            VoiceAudioPipeline.logger.error("Capture conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        guard let int16Data = outputBuffer.int16ChannelData, outputBuffer.frameLength > 0 else { return }
        let data = Data(
            bytes: int16Data[0],
            count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.inputLevel = level
            if !self.isMuted {
                self.onAudioChunk?(data)
            }
        }
    }

    // MARK: - Private: Helpers

    private func checkPlaybackFinished() {
        isPlaying = false
        outputLevel = 0.0
    }

    /// Extract channel 0 from a multi-channel float buffer into a new mono buffer.
    private nonisolated static func extractChannel0(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let srcChannelData = buffer.floatChannelData else { return nil }
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
            return nil
        }
        monoBuf.frameLength = buffer.frameLength
        guard let dstData = monoBuf.floatChannelData else { return nil }
        memcpy(dstData[0], srcChannelData[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return monoBuf
    }

    private nonisolated static func calculateFloatLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        return min(rms * 3.0, 1.0)
    }

    private nonisolated static func calculatePCM16Level(from pcmData: Data) -> Float {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        return pcmData.withUnsafeBytes { rawBuffer -> Float in
            guard let ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return 0 }
            var sum: Float = 0
            for i in 0..<sampleCount {
                let sample = Float(ptr[i]) / Float(Int16.max)
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(sampleCount))
            return min(rms * 3.0, 1.0)
        }
    }
}

// MARK: - Errors

enum VoiceAudioPipelineError: LocalizedError {
    case playbackConverterFailed
    case captureConverterFailed
    case invalidInputFormat
    case voiceProcessingFailed(String)

    var errorDescription: String? {
        switch self {
        case .playbackConverterFailed:
            return "Failed to create playback format converter"
        case .captureConverterFailed:
            return "Failed to create capture format converter"
        case .invalidInputFormat:
            return "Audio input format is invalid (0Hz or 0 channels)"
        case .voiceProcessingFailed(let detail):
            return "Echo cancellation unavailable — voice agent cannot start. (\(detail))"
        }
    }
}
#endif
