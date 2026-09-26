#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationAudioCapture.swift
//  rootshell
//
//  Microphone tap converted to 16 kHz mono Float32, the rate Parakeet and
//  Silero expect. Samples go straight from the audio thread to the sink.
//

@preconcurrency import AVFoundation
import os

@MainActor
final class DictationAudioCapture {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Dictation")
    nonisolated static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Input level, 0...1, delivered on the main actor.
    var onLevel: ((Float) -> Void)?
    private var engine: AVAudioEngine?

    var isRunning: Bool { engine?.isRunning == true }

    func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationError.audioUnavailable(String(localized: "No input device."))
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw DictationError.audioUnavailable(String(localized: "Unsupported input format."))
        }
        // Keep only the first (microphone) channel of multi-channel inputs.
        if inputFormat.channelCount > 1 { converter.channelMap = [0] }
        let context = TapContext(converter: converter)
        let level: @Sendable (Float) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in self?.onLevel?(value) }
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat,
                         block: Self.tap(context: context, sink: sink, level: level))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.audioUnavailable(error.localizedDescription)
        }
        self.engine = engine
        Self.logger.info("Dictation capture started at \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        onLevel?(0)
    }

    /// Converter state lives on the audio thread only.
    private nonisolated final class TapContext: @unchecked Sendable {
        let converter: AVAudioConverter
        init(converter: AVAudioConverter) { self.converter = converter }
    }

    /// Used synchronously inside one `convert` call on the audio thread.
    private nonisolated final class PendingBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    private nonisolated static func tap(
        context: TapContext,
        sink: @escaping @Sendable ([Float]) -> Void,
        level: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            // Hand the converter this buffer exactly once; asking again means "wait for more".
            let pending = PendingBuffer(buffer)
            var error: NSError?
            let status = context.converter.convert(to: output, error: &error) { _, outStatus in
                guard let next = pending.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else {
                if let error { logger.error("Dictation conversion failed: \(error.localizedDescription, privacy: .public)") }
                return
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            sink(samples)
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            let rms = (sum / Float(samples.count)).squareRoot()
            // Map roughly -50...-10 dBFS onto 0...1 for the meter.
            let db = 20 * log10(max(rms, 1e-6))
            level(min(1, max(0, (db + 50) / 40)))
        }
    }
}
#endif
