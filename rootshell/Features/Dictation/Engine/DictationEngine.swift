#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationEngine.swift
//  rootshell
//
//  Owns the loaded FluidAudio models. One instance serves every window;
//  models stay warm between phrases and unload after an idle period.
//

import CoreML
import FluidAudio
import Foundation
import os

nonisolated extension DictationModel {
    var asrVersion: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetUltra: .ultra
        case .parakeetRedux: .redux
        case .parakeetV2English: .v2
        }
    }

    /// Only v3 ships an int4 encoder.
    func encoderPrecision(_ precision: DictationEncoderPrecision) -> ParakeetEncoderPrecision {
        self == .parakeetV3 && precision == .int4 ? .int4 : .int8
    }

    var supportsLanguageHint: Bool { self != .parakeetV2English }
}

nonisolated struct DictationTranscript: Sendable {
    var text: String
    var confidence: Float
}

actor DictationEngine {
    static let shared = DictationEngine()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Dictation")

    private struct LoadedModel: Equatable {
        let model: DictationModel
        let precision: ParakeetEncoderPrecision
    }

    private var asr: AsrManager?
    private var loaded: LoadedModel?
    private var vad: VadManager?
    private var ctcModels: CtcModels?
    private var boosting: VocabularyBoostingSession?
    private var boostingTerms: [DictationVocabulary.Entry] = []
    private var unloadTask: Task<Void, Never>?
    /// Sessions holding the models. Nothing unloads while this is above zero.
    private var users = 0
    /// A load in flight, shared by sessions that want the same model.
    private var loading: (model: LoadedModel, task: Task<Void, Error>)?

    var isLoaded: Bool { asr != nil }

    /// Takes a use of the speech and VAD models, loading them from disk if needed
    /// (never downloads). Each successful call needs exactly one `release`.
    func acquire(model: DictationModel, precision: DictationEncoderPrecision) async throws {
        users += 1
        unloadTask?.cancel()
        unloadTask = nil
        let wanted = LoadedModel(model: model, precision: model.encoderPrecision(precision))
        do {
            try await ensureLoaded(wanted)
        } catch {
            users -= 1
            throw error
        }
    }

    /// Returns a use; the last one out starts the keep-loaded timer.
    func release(keepLoadedMinutes minutes: Int) {
        users = max(0, users - 1)
        guard users == 0 else { return }
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, minutes) * 60))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func ensureLoaded(_ wanted: LoadedModel) async throws {
        if loaded == wanted, asr != nil, vad != nil { return }
        if let pending = loading, pending.model == wanted {
            try await pending.task.value
            return
        }
        let task = Task { try await self.load(wanted) }
        loading = (wanted, task)
        defer { if loading?.model == wanted { loading = nil } }
        try await task.value
    }

    private func load(_ wanted: LoadedModel) async throws {
        if loaded != wanted || asr == nil {
            await asr?.cleanup()
            asr = nil
            loaded = nil
            let version = wanted.model.asrVersion
            let directory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version, encoderPrecision: wanted.precision) else {
                throw DictationError.modelMissing
            }
            let models = try await AsrModels.load(from: directory, version: version, encoderPrecision: wanted.precision)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
            loaded = wanted
            Self.logger.info("Loaded \(wanted.model.rawValue, privacy: .public)")
        }
        if vad == nil {
            vad = try await VadManager(config: .default)
        }
    }

    func vadManager() throws -> VadManager {
        guard let vad else { throw DictationError.modelMissing }
        return vad
    }

    /// Rebuilds the boosting session only when the term list changes.
    func configureVocabulary(_ entries: [DictationVocabulary.Entry]) async {
        guard !entries.isEmpty else { boosting = nil; boostingTerms = []; return }
        guard entries != boostingTerms || boosting == nil else { return }
        do {
            if ctcModels == nil {
                let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
                guard CtcModels.modelsExist(at: directory) else { boosting = nil; return }
                ctcModels = try await CtcModels.load(from: directory, variant: .ctc110m)
            }
            guard let ctcModels else { return }
            let terms = entries.map {
                CustomVocabularyTerm(text: $0.term, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
            }
            boosting = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctcModels)
            boostingTerms = entries
        } catch {
            boosting = nil
            boostingTerms = []
            Self.logger.error("Vocabulary boost unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(_ samples: [Float], language: String?, boost: Bool) async throws -> DictationTranscript {
        guard let asr, let loaded else { throw DictationError.modelMissing }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let hint = loaded.model.supportsLanguageHint ? language.flatMap(Language.init(rawValue:)) : nil
        let result = try await asr.transcribe(samples, decoderState: &state, language: hint)
        var text = result.text
        if boost, let boosting, let timings = result.tokenTimings, !timings.isEmpty,
           let rescored = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: samples) {
            text = rescored.text
        }
        return DictationTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: result.confidence)
    }

    /// Frees the models unless a session is using them.
    func unload() async {
        guard users == 0, loading == nil else { return }
        unloadTask?.cancel()
        unloadTask = nil
        await asr?.cleanup()
        asr = nil
        loaded = nil
        vad = nil
        ctcModels = nil
        boosting = nil
        boostingTerms = []
        Self.logger.info("Unloaded dictation models")
    }
}

nonisolated enum DictationError: LocalizedError, Equatable {
    case modelMissing
    case microphoneDenied
    case audioUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            String(localized: "The speech model isn't downloaded.")
        case .microphoneDenied:
            String(localized: "Microphone access is off for Rootshell.")
        case .audioUnavailable(let reason):
            String(localized: "The microphone couldn't start: \(reason)")
        }
    }
}
#endif
