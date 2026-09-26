#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationRecognizer.swift
//  rootshell
//
//  One listening session. Silero VAD splits 16 kHz audio into phrases; the
//  open phrase is re-decoded as it grows for live text, and each phrase is
//  decoded once more, with vocabulary boost, when the speaker pauses.
//

import FluidAudio
import Foundation
import os

actor DictationRecognizer {
    enum Event: Sendable {
        /// Best guess for the phrase still being spoken.
        case partial(String)
        /// Decoded speech. Long utterances are cut at the model's window limit and
        /// arrive in pieces; only a single-piece utterance is `isWholeUtterance`.
        case phrase(String, isWholeUtterance: Bool)
        /// The speaker paused or listening stopped. Sent once per utterance,
        /// even when its last piece decoded to nothing.
        case utteranceEnded
        case speechStarted
        /// No speech for the configured auto-stop interval.
        case silenceTimeout
        case failed(String)
    }

    struct Configuration: Sendable {
        var language: String?
        var speechThreshold: Double
        var pauseDuration: Double
        var autoStopSilence: Double
        var normalizeNumbers: Bool
        var boost: Bool
    }

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Dictation")
    private static let sampleRate = 16_000
    private static let chunk = VadManager.chunkSize
    /// Audio kept ahead of a detected onset so first syllables survive.
    private static let preRollSamples = 6_400
    /// Parakeet decodes at most 15 s per window; cut long phrases before that.
    private static let maxPhraseSamples = 14 * 16_000
    private static let minPhraseSamples = 4_800
    /// A trailing piece of a long utterance may be a single short word.
    private static let minContinuationSamples = 1_600

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let input: AsyncStream<[Float]>
    private nonisolated let inputContinuation: AsyncStream<[Float]>.Continuation

    private let engine: DictationEngine
    private let vad: VadManager
    private let configuration: Configuration
    private let segmentation: VadSegmentationConfig

    private var vadState: VadStreamState
    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var phrase: [Float] = []
    private var inSpeech = false
    /// Pieces of the current utterance already emitted at the window limit.
    private var piecesInUtterance = 0
    private var heardSpeech = false
    private var samplesSinceSpeech = 0
    private var samplesSincePartial = 0
    private var partialStride = 9_600
    private var timedOut = false
    private var loop: Task<Void, Never>?

    private var vadFailed = false

    init(engine: DictationEngine, vad: VadManager, configuration: Configuration) {
        self.engine = engine
        self.vad = vad
        self.configuration = configuration
        // The entry threshold is the negative threshold plus this offset.
        // silenceThresholdForSplit only affects batch segmentation, but FluidAudio
        // asserts it is at least the negative threshold.
        let offset: Float = 0.15
        let negative = min(0.85, max(0.05, Float(configuration.speechThreshold) - offset))
        segmentation = VadSegmentationConfig(
            minSilenceDuration: configuration.pauseDuration,
            silenceThresholdForSplit: max(0.3, negative),
            negativeThreshold: negative,
            negativeThresholdOffset: offset)
        vadState = .initial()
        let output = AsyncStream.makeStream(of: Event.self)
        events = output.stream
        continuation = output.continuation
        let audio = AsyncStream.makeStream(of: [Float].self)
        input = audio.stream
        inputContinuation = audio.continuation
    }

    func start() {
        loop = Task { [weak self] in
            guard let self else { return }
            for await samples in self.input {
                await self.process(samples)
            }
            await self.flush()
        }
    }

    /// 16 kHz mono samples, in order. Safe to call from the audio thread.
    nonisolated func append(_ samples: [Float]) {
        inputContinuation.yield(samples)
    }

    /// Decodes whatever is still open, then ends the event stream.
    func finish() async {
        inputContinuation.finish()
        await loop?.value
    }

    func cancel() {
        inputContinuation.finish()
        loop?.cancel()
        continuation.finish()
    }

    private func process(_ samples: [Float]) async {
        guard !Task.isCancelled else { return }
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunk {
            let chunk = Array(pending.prefix(Self.chunk))
            pending.removeFirst(Self.chunk)
            await consume(chunk)
        }
    }

    private func consume(_ chunk: [Float]) async {
        guard !vadFailed else { return }
        let result: VadStreamResult
        do {
            result = try await vad.processStreamingChunk(chunk, state: vadState, config: segmentation)
        } catch {
            vadFailed = true
            continuation.yield(.failed(error.localizedDescription))
            return
        }
        vadState = result.state

        if let event = result.event, event.kind == .speechStart, !inSpeech {
            inSpeech = true
            heardSpeech = true
            phrase = preRoll
            samplesSincePartial = 0
            continuation.yield(.speechStarted)
        }

        if inSpeech {
            phrase.append(contentsOf: chunk)
            samplesSinceSpeech = 0
            samplesSincePartial += chunk.count
        } else {
            preRoll.append(contentsOf: chunk)
            if preRoll.count > Self.preRollSamples { preRoll.removeFirst(preRoll.count - Self.preRollSamples) }
            samplesSinceSpeech += chunk.count
        }

        if let event = result.event, event.kind == .speechEnd, inSpeech {
            inSpeech = false
            await endUtterance()
        } else if inSpeech, phrase.count >= Self.maxPhraseSamples {
            await decodePiece(isLast: false)
            piecesInUtterance += 1
        } else if inSpeech, samplesSincePartial >= partialStride {
            await decodePartial()
        }

        checkSilence()
    }

    private func decodePartial() async {
        samplesSincePartial = 0
        guard phrase.count >= Self.minPhraseSamples else { return }
        let started = ContinuousClock.now
        do {
            let transcript = try await engine.transcribe(phrase, language: configuration.language, boost: false)
            if !transcript.text.isEmpty { continuation.yield(.partial(normalize(transcript.text))) }
        } catch {
            Self.logger.error("Partial decode failed: \(error.localizedDescription, privacy: .public)")
        }
        // Back off when decoding approaches real time, so audio never piles up.
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        partialStride = min(32_000, max(9_600, Int(elapsed * Double(Self.sampleRate)) * 3))
    }

    private func endUtterance() async {
        await decodePiece(isLast: true)
        piecesInUtterance = 0
        continuation.yield(.utteranceEnded)
    }

    private func decodePiece(isLast: Bool) async {
        let samples = phrase
        phrase = []
        samplesSincePartial = 0
        let continuing = piecesInUtterance > 0
        let minimum = continuing ? Self.minContinuationSamples : Self.minPhraseSamples
        guard samples.count >= minimum else {
            continuation.yield(.partial(""))
            return
        }
        do {
            let transcript = try await engine.transcribe(samples, language: configuration.language, boost: configuration.boost)
            let text = normalize(transcript.text)
            let whole = isLast && !continuing
            continuation.yield(text.isEmpty ? .partial("") : .phrase(text, isWholeUtterance: whole))
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    private func flush() async {
        if !pending.isEmpty, inSpeech { phrase.append(contentsOf: pending) }
        pending = []
        if inSpeech || !phrase.isEmpty || piecesInUtterance > 0 { await endUtterance() }
        continuation.finish()
    }

    private func checkSilence() {
        guard configuration.autoStopSilence > 0, !timedOut, !inSpeech else { return }
        // Allow a longer wait before the first word than between phrases.
        let limit = heardSpeech ? configuration.autoStopSilence : max(configuration.autoStopSilence, 8)
        if Double(samplesSinceSpeech) / Double(Self.sampleRate) >= limit {
            timedOut = true
            continuation.yield(.silenceTimeout)
        }
    }

    private func normalize(_ text: String) -> String {
        guard configuration.normalizeNumbers else { return text }
        return TextNormalizer.shared.normalizeSentence(text)
    }
}
#endif
