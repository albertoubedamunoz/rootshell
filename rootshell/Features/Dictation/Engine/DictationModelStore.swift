#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationModelStore.swift
//  rootshell
//
//  Downloads, verifies and deletes dictation models. Files live in
//  FluidAudio's cache under Application Support, excluded from backups.
//

import FluidAudio
import Foundation
import Observation
import os

nonisolated enum DictationAsset: Hashable, Sendable {
    case speech(DictationModel)
    /// Silero voice activity detection, needed by every model.
    case voiceActivity
    /// CTC keyword spotter used by vocabulary boost.
    case vocabulary
}

@MainActor
@Observable
final class DictationModelStore {
    static let shared = DictationModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Dictation")

    private(set) var states: [DictationAsset: State] = [:]
    private(set) var sizes: [DictationAsset: Int64] = [:]
    @ObservationIgnored private var tasks: [DictationAsset: Task<Void, Never>] = [:]

    private init() { refresh() }

    func state(_ asset: DictationAsset) -> State { states[asset] ?? .notDownloaded }

    /// Speech model plus VAD: everything listening needs.
    func isReady(_ model: DictationModel) -> Bool {
        state(.speech(model)) == .ready && state(.voiceActivity) == .ready
    }

    var totalBytes: Int64 { sizes.values.reduce(0, +) }

    func refresh() {
        let precision = SettingsStore.shared.get(Settings.Dictation.encoderPrecision)
        var assets: [DictationAsset] = DictationModel.allCases.map { .speech($0) }
        assets += [.voiceActivity, .vocabulary]
        for asset in assets {
            if case .downloading = states[asset] { continue }
            let present = Self.isPresent(asset, precision: precision)
            if present {
                states[asset] = .ready
            } else if case .failed = states[asset] {
                // Keep the error visible until the next attempt.
            } else {
                states[asset] = .notDownloaded
            }
            sizes[asset] = present ? Self.directorySize(Self.directory(asset)) : nil
        }
    }

    /// Downloads the model and VAD if missing.
    func downloadForListening(_ model: DictationModel) {
        if state(.voiceActivity) != .ready { download(.voiceActivity) }
        if state(.speech(model)) != .ready { download(.speech(model)) }
    }

    func download(_ asset: DictationAsset) {
        guard tasks[asset] == nil else { return }
        let precision = SettingsStore.shared.get(Settings.Dictation.encoderPrecision)
        states[asset] = .downloading(0)
        let progress: ProgressHandler = { [weak self] update in
            let fraction = update.fractionCompleted
            Task { @MainActor [weak self] in self?.report(fraction, for: asset) }
        }
        tasks[asset] = Task { [weak self] in
            do {
                try await Self.fetch(asset, precision: precision, progress: progress)
                Self.excludeFromBackup()
                self?.tasks[asset] = nil
                self?.states[asset] = nil
                self?.refresh()
            } catch {
                self?.tasks[asset] = nil
                let cancelled = error is CancellationError || Task.isCancelled
                self?.states[asset] = cancelled ? .notDownloaded : .failed(error.localizedDescription)
                if !cancelled { Self.logger.error("Model download failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func report(_ fraction: Double, for asset: DictationAsset) {
        guard case .downloading = states[asset] else { return }
        states[asset] = .downloading(min(0.99, fraction))
    }

    func cancel(_ asset: DictationAsset) {
        tasks[asset]?.cancel()
    }

    func delete(_ asset: DictationAsset) async {
        cancel(asset)
        await DictationEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory(asset))
        states[asset] = nil
        refresh()
    }

    // MARK: - Files

    private nonisolated static func fetch(_ asset: DictationAsset, precision: DictationEncoderPrecision,
                                          progress: @escaping ProgressHandler) async throws {
        switch asset {
        case .speech(let model):
            try await AsrModels.download(version: model.asrVersion,
                                         encoderPrecision: model.encoderPrecision(precision),
                                         progressHandler: progress)
        case .voiceActivity:
            _ = try await VadManager(config: .default, progressHandler: progress)
        case .vocabulary:
            try await CtcModels.download(variant: .ctc110m)
        }
    }

    nonisolated static func directory(_ asset: DictationAsset) -> URL {
        switch asset {
        case .speech(let model): AsrModels.defaultCacheDirectory(for: model.asrVersion)
        case .voiceActivity: MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
        case .vocabulary: CtcModels.defaultCacheDirectory(for: .ctc110m)
        }
    }

    private nonisolated static func isPresent(_ asset: DictationAsset, precision: DictationEncoderPrecision) -> Bool {
        let directory = directory(asset)
        switch asset {
        case .speech(let model):
            return AsrModels.modelsExist(at: directory, version: model.asrVersion,
                                         encoderPrecision: model.encoderPrecision(precision))
        case .voiceActivity:
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ModelNames.VAD.sileroVadFile).path)
        case .vocabulary:
            return CtcModels.modelsExist(at: directory)
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        }
    }

    private nonisolated static func excludeFromBackup() {
        var root = MLModelConfigurationUtils.defaultModelsDirectory()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

nonisolated extension DictationModel {
    /// Approximate download size in megabytes, shown before downloading.
    func downloadMegabytes(_ precision: DictationEncoderPrecision) -> Int {
        switch self {
        case .parakeetV3: encoderPrecision(precision) == .int4 ? 320 : 460
        case .parakeetUltra: 600
        case .parakeetRedux: 210
        case .parakeetV2English: 440
        }
    }
}
#endif
