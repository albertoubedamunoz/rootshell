//
//  SettingsSyncCoordinator.swift
//  rootshell
//
//  Owns per-key sync metadata, device-local pins, outgoing batching, and
//  incoming per-key merge. CloudKitSyncManager is the transport: it hands
//  in AppSettingRecords from the zone and takes batches to push.
//

import Foundation
import UIKit
import os

nonisolated enum SettingPinState: Sendable, Equatable {
    case none
    case key
    case group
    case configFile
    case deviceOnly
}

nonisolated enum GroupPinState: Sendable, Equatable {
    case none
    case partial(pinned: Int, of: Int)
    case all
}

nonisolated enum UnpinResolution: Sendable {
    /// Take the iCloud value this device has been ignoring.
    case adoptCloud
    /// Keep this device's value and send it to iCloud.
    case pushLocal
}

nonisolated enum SettingsMergeChoice: Sendable {
    case useCloud
    case uploadLocal
}

/// What the first-enable merge sheet needs to show.
struct SettingsMergePreview: Sendable {
    let cloud: [AppSettingRecord]
    let cloudCount: Int
    let localCount: Int
    let overlapping: Int
    let newestCloudDate: Date?
    let cloudDeviceIDs: Set<String>
}

@MainActor @Observable
final class SettingsSyncCoordinator {
    static let shared = SettingsSyncCoordinator()

    private static let logger = Logger(subsystem: "com.rootshell", category: "SettingsSyncCoordinator")
    static let outgoingDebounce: Duration = .milliseconds(1500)

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registry: SettingsRegistry
    @ObservationIgnored private let sidecarStore = SettingsSyncSidecarStore()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleToken: NSObjectProtocol?
    @ObservationIgnored private var outgoing: Set<String> = []
    @ObservationIgnored private var outgoingTask: Task<Void, Never>?

    /// Set by CloudKitSyncManager; gates pushes only. Incoming records are always merged.
    var isEnabled = false
    /// Receives debounced batches of changed records to push.
    @ObservationIgnored var onOutgoingBatch: (([AppSettingRecord]) -> Void)?
    /// Bumped on every pin change so views re-evaluate pin state.
    private(set) var pinGeneration = 0

    var sidecar: SettingsSyncSidecar { sidecarStore.sidecar }

    init(store: SettingsStore = .shared, registry: SettingsRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            guard let stream = self?.store.changes() else { return }
            for await change in stream {
                self?.handle(change)
            }
        }
        lifecycleToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushOutgoingNow()
                self?.sidecarStore.saveNow()
            }
        }
        flushDeferredRemote()
    }

    private var deviceID: String { CloudKitSyncSettings.deviceID }

    // MARK: - Local changes

    private func handle(_ change: SettingsChange) {
        guard change.origin == .local || change.origin == .restore else { return }
        let now = Date()
        let device = deviceID
        var toPush: [String] = []
        sidecarStore.mutate { sidecar in
            for key in change.keys where registry.isSyncable(key) {
                var meta = sidecar.meta[key] ?? SettingSyncMeta()
                meta.modifiedAt = now
                meta.deviceID = device
                sidecar.meta[key] = meta
                toPush.append(key)
            }
        }
        guard isEnabled else { return }
        for key in toPush where !isPinned(key) {
            outgoing.insert(key)
        }
        scheduleOutgoingFlush()
    }

    func meta(for key: String) -> SettingSyncMeta? {
        sidecar.meta[key]
    }

    // MARK: - Outgoing

    private func scheduleOutgoingFlush() {
        guard !outgoing.isEmpty else { return }
        outgoingTask?.cancel()
        outgoingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.outgoingDebounce)
            guard !Task.isCancelled else { return }
            self?.flushOutgoingNow()
        }
    }

    /// Build records for every queued key whose content differs from the last push.
    func flushOutgoingNow() {
        outgoingTask?.cancel()
        outgoingTask = nil
        guard isEnabled, !outgoing.isEmpty, let sink = onOutgoingBatch else { return }
        let keys = outgoing
        outgoing = []
        var records: [AppSettingRecord] = []
        for key in keys {
            guard let record = record(for: key) else { continue }
            if let pushed = sidecar.meta[key]?.lastPushedHash, pushed == record.contentHash { continue }
            guard record.payloadSizeOK else {
                Self.logger.error("Skipping \(key, privacy: .public): payload exceeds CloudKit limit")
                continue
            }
            records.append(record)
        }
        guard !records.isEmpty else { return }
        Self.logger.info("Pushing \(records.count) setting records")
        sink(records)
    }

    /// Current value as a record, or a tombstone when the key is unset but was once synced.
    func record(for key: String) -> AppSettingRecord? {
        guard registry.isSyncable(key) else { return nil }
        let meta = sidecar.meta[key]
        let modifiedAt = meta?.modifiedAt ?? Date()
        let device = meta?.deviceID ?? deviceID
        if let value = store.codableValue(key) {
            return AppSettingRecord(key: key, payload: value, modifiedAt: modifiedAt, isDeleted: false, deviceID: device)
        }
        guard meta != nil else { return nil }
        return AppSettingRecord(key: key, payload: nil, modifiedAt: modifiedAt, isDeleted: true, deviceID: device)
    }

    /// Every user-set syncable, unpinned key. Unknown-age values are stamped now so they win on other devices.
    func recordsForInitialPush(stampUnknownAs stamp: Date = Date()) -> [AppSettingRecord] {
        guard !SettingsStore.looksCorrupted() else {
            Self.logger.fault("Refusing initial push: defaults look unreadable")
            return []
        }
        let snapshot = store.snapshot(keys: registry.syncableKeys)
        var out: [AppSettingRecord] = []
        let device = deviceID
        sidecarStore.mutate { sidecar in
            for (key, value) in snapshot where !isPinned(key) {
                var meta = sidecar.meta[key] ?? SettingSyncMeta()
                if meta.modifiedAt == nil {
                    meta.modifiedAt = stamp
                    meta.deviceID = device
                    sidecar.meta[key] = meta
                }
                let record = AppSettingRecord(
                    key: key, payload: value, modifiedAt: meta.modifiedAt ?? stamp,
                    isDeleted: false, deviceID: meta.deviceID ?? device)
                if record.payloadSizeOK { out.append(record) }
            }
        }
        return out
    }

    func markPushed(_ records: [AppSettingRecord]) {
        sidecarStore.mutate { sidecar in
            for record in records {
                var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                meta.lastPushedHash = record.contentHash
                meta.lastPushedModifiedAt = record.modifiedAt
                sidecar.meta[record.key] = meta
            }
        }
    }

    // MARK: - Incoming

    /// Merge records from iCloud: drop unknown keys, shadow pinned ones, LWW the rest, apply once.
    func applyRemote(_ records: [AppSettingRecord]) {
        guard !records.isEmpty else { return }
        guard store.isReady else {
            deferRemote(records)
            return
        }
        var batch: [String: CodableValue?] = [:]
        var pushBack: [String] = []
        var accepted: [AppSettingRecord] = []
        var shadowed = 0

        for record in records {
            let key = record.key
            guard let def = registry.definition(for: key), def.isSyncable else { continue }
            if let payload = record.payload, !def.validate(payload) {
                Self.logger.warning("Ignoring \(key, privacy: .public): remote value has the wrong type")
                continue
            }
            if isPinned(key) {
                shadowed += 1
                sidecarStore.mutate { sidecar in
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.shadowCloud = ShadowValue(payload: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
                    sidecar.meta[key] = meta
                }
                continue
            }
            let meta = sidecar.meta[key]
            let localValue = store.codableValue(key)
            let local = SettingsMergeResolver.Local(value: localValue, modifiedAt: meta?.modifiedAt, deviceID: meta?.deviceID)
            let remote = SettingsMergeResolver.Remote(value: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
            let alreadyPushed = meta?.lastPushedHash == AppSettingRecord.contentHash(of: localValue)
            switch SettingsMergeResolver.resolve(local: local, remote: remote, alreadyPushed: alreadyPushed) {
            case .applyRemote:
                batch[key] = record.payload
                accepted.append(record)
            case .keepLocalAndPush:
                pushBack.append(key)
            case .keepLocal:
                break
            case .noop:
                sidecarStore.mutate { sidecar in
                    var m = sidecar.meta[key] ?? SettingSyncMeta()
                    m.lastPushedHash = record.contentHash
                    m.lastPushedModifiedAt = record.modifiedAt
                    if m.modifiedAt == nil { m.modifiedAt = record.modifiedAt; m.deviceID = record.deviceID }
                    sidecar.meta[key] = m
                }
            }
        }

        if !batch.isEmpty {
            store.applyBatch(batch, origin: .remote)
            sidecarStore.mutate { sidecar in
                for record in accepted {
                    var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                    meta.modifiedAt = record.modifiedAt
                    meta.deviceID = record.deviceID
                    meta.lastPushedHash = record.contentHash
                    meta.lastPushedModifiedAt = record.modifiedAt
                    meta.shadowCloud = nil
                    sidecar.meta[record.key] = meta
                }
            }
        }
        if !pushBack.isEmpty, isEnabled {
            outgoing.formUnion(pushBack)
            scheduleOutgoingFlush()
        }
        Self.logger.info("Merged \(records.count) remote settings: \(batch.count) applied, \(pushBack.count) kept local, \(shadowed) shadowed")
    }

    private func deferRemote(_ records: [AppSettingRecord]) {
        sidecarStore.mutate { sidecar in
            for record in records {
                sidecar.deferredRemote[record.key] = ShadowValue(
                    payload: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
            }
        }
        Self.logger.info("Deferred \(records.count) remote settings until the store is ready")
    }

    /// Re-play records received before protected data was available.
    func flushDeferredRemote() {
        guard store.isReady, !sidecar.deferredRemote.isEmpty else { return }
        let deferred = sidecar.deferredRemote
        sidecarStore.mutate { $0.deferredRemote = [:] }
        applyRemote(deferred.map { key, shadow in
            AppSettingRecord(key: key, payload: shadow.payload, modifiedAt: shadow.modifiedAt,
                             isDeleted: shadow.payload == nil, deviceID: shadow.deviceID)
        })
    }

    // MARK: - First enable

    func mergePreview(cloud: [AppSettingRecord]) -> SettingsMergePreview {
        let live = cloud.filter { !$0.isDeleted && registry.isSyncable($0.key) }
        let localKeys = Set(store.snapshot(keys: registry.syncableKeys).keys)
        let cloudKeys = Set(live.map(\.key))
        return SettingsMergePreview(
            cloud: cloud,
            cloudCount: live.count,
            localCount: localKeys.count,
            overlapping: localKeys.intersection(cloudKeys).count,
            newestCloudDate: live.map(\.modifiedAt).max(),
            cloudDeviceIDs: Set(live.map(\.deviceID))
        )
    }

    /// Resolve the first-enable merge. Returns the records this device must push.
    func completeInitialMerge(cloud: [AppSettingRecord], choice: SettingsMergeChoice) -> [AppSettingRecord] {
        let now = Date()
        let cloudByKey = Dictionary(cloud.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        switch choice {
        case .useCloud:
            // Cloud wins for every key it knows; local-only keys are uploaded.
            var batch: [String: CodableValue?] = [:]
            var accepted: [AppSettingRecord] = []
            for record in cloud where registry.isSyncable(record.key) && !isPinned(record.key) {
                if let payload = record.payload, let def = registry.definition(for: record.key), !def.validate(payload) { continue }
                batch[record.key] = record.payload
                accepted.append(record)
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .remote) }
            sidecarStore.mutate { sidecar in
                for record in accepted {
                    var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                    meta.modifiedAt = record.modifiedAt
                    meta.deviceID = record.deviceID
                    meta.lastPushedHash = record.contentHash
                    meta.lastPushedModifiedAt = record.modifiedAt
                    sidecar.meta[record.key] = meta
                }
                sidecar.initialMergeCompleted = true
            }
            return recordsForInitialPush(stampUnknownAs: now).filter { cloudByKey[$0.key] == nil }

        case .uploadLocal:
            // Local wins: stamp everything now so it beats cloud everywhere; adopt cloud-only keys.
            var batch: [String: CodableValue?] = [:]
            let localKeys = Set(store.snapshot(keys: registry.syncableKeys).keys)
            for record in cloud where !record.isDeleted && !localKeys.contains(record.key)
                && registry.isSyncable(record.key) && !isPinned(record.key) {
                if let payload = record.payload, let def = registry.definition(for: record.key), def.validate(payload) {
                    batch[record.key] = payload
                }
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .remote) }
            sidecarStore.mutate { sidecar in
                for key in localKeys {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = now
                    meta.deviceID = deviceID
                    sidecar.meta[key] = meta
                }
                sidecar.initialMergeCompleted = true
            }
            return recordsForInitialPush(stampUnknownAs: now)
        }
    }

    func setAccountIdentity(_ identity: String) {
        sidecarStore.mutate { $0.accountIdentity = identity }
    }

    // MARK: - Config file overlay

    /// Keys currently bound by the text config file; pinned while present.
    private(set) var configFileKeys: Set<String> = []

    /// Apply the overlay: file-bound keys take the file's value and become pinned;
    /// keys that left the file rejoin iCloud (adopting its value when known).
    func applyConfigFile(values: [String: CodableValue?]) {
        let newKeys = Set(values.keys)
        let removed = configFileKeys.subtracting(newKeys)
        configFileKeys = newKeys
        pinGeneration += 1
        var batch: [String: CodableValue?] = [:]
        for (key, value) in values where store.codableValue(key) != value {
            batch[key] = value
        }
        if !batch.isEmpty {
            store.applyBatch(batch, origin: .configFile)
        }
        if !removed.isEmpty {
            resolveUnpin(Array(removed), resolution: .adoptCloud)
        }
    }

    /// Forget push bookkeeping and shadows; keep timestamps and pins.
    func resetSyncState() {
        outgoingTask?.cancel()
        outgoing = []
        sidecarStore.mutate { sidecar in
            for key in sidecar.meta.keys {
                sidecar.meta[key]?.lastPushedHash = nil
                sidecar.meta[key]?.lastPushedModifiedAt = nil
                sidecar.meta[key]?.shadowCloud = nil
            }
            sidecar.initialMergeCompleted = false
            sidecar.deferredRemote = [:]
        }
    }

    // MARK: - Pins

    func pinState(for key: String) -> SettingPinState {
        _ = pinGeneration
        guard let def = registry.definition(for: key) else { return .deviceOnly }
        if def.policy == .deviceOnly { return .deviceOnly }
        if configFileKeys.contains(key) { return .configFile }
        if sidecar.pinnedGroups.contains(def.group) { return .group }
        if isPinned(key) { return .key }
        return .none
    }

    func isPinned(_ key: String) -> Bool {
        guard let def = registry.definition(for: key), def.policy != .deviceOnly else { return true }
        if configFileKeys.contains(key) { return true }
        if sidecar.pinnedGroups.contains(def.group) { return true }
        switch def.policy {
        case .synced: return sidecar.pinnedKeys.contains(key)
        case .localByDefault: return !sidecar.unpinnedKeys.contains(key)
        case .deviceOnly: return true
        }
    }

    func pinState(for group: SettingGroup) -> GroupPinState {
        _ = pinGeneration
        if sidecar.pinnedGroups.contains(group) { return .all }
        let keys = registry.keys(in: group).filter(\.isSyncable)
        guard !keys.isEmpty else { return .none }
        let pinned = keys.filter { isPinned($0.name) }.count
        if pinned == 0 { return .none }
        if pinned == keys.count { return .all }
        return .partial(pinned: pinned, of: keys.count)
    }

    func shadowValue(for key: String) -> ShadowValue? {
        sidecar.meta[key]?.shadowCloud
    }

    func setPinned(_ key: String, _ pinned: Bool, resolution: UnpinResolution = .adoptCloud) {
        guard let def = registry.definition(for: key), def.policy != .deviceOnly else { return }
        sidecarStore.mutate { sidecar in
            switch def.policy {
            case .synced:
                if pinned { sidecar.pinnedKeys.insert(key) } else { sidecar.pinnedKeys.remove(key) }
            case .localByDefault:
                if pinned { sidecar.unpinnedKeys.remove(key) } else { sidecar.unpinnedKeys.insert(key) }
            case .deviceOnly:
                break
            }
            if !pinned, sidecar.pinnedGroups.contains(def.group) {
                // Dissolve the group pin into per-key pins so the others stay pinned.
                sidecar.pinnedGroups.remove(def.group)
                for other in registry.keys(in: def.group) where other.name != key && other.isSyncable {
                    if other.policy == .synced { sidecar.pinnedKeys.insert(other.name) }
                    if other.policy == .localByDefault { sidecar.unpinnedKeys.remove(other.name) }
                }
            }
        }
        pinGeneration += 1
        if !pinned { resolveUnpin([key], resolution: resolution) }
    }

    func setPinned(group: SettingGroup, _ pinned: Bool, resolution: UnpinResolution = .adoptCloud) {
        let keys = registry.keys(in: group).filter(\.isSyncable).map(\.name)
        sidecarStore.mutate { sidecar in
            if pinned {
                sidecar.pinnedGroups.insert(group)
            } else {
                sidecar.pinnedGroups.remove(group)
                for def in registry.keys(in: group) {
                    sidecar.pinnedKeys.remove(def.name)
                    if def.policy == .localByDefault { sidecar.unpinnedKeys.insert(def.name) }
                }
            }
        }
        pinGeneration += 1
        if !pinned { resolveUnpin(keys, resolution: resolution) }
    }

    private func resolveUnpin(_ keys: [String], resolution: UnpinResolution) {
        switch resolution {
        case .adoptCloud:
            var batch: [String: CodableValue?] = [:]
            var adopted: [String: ShadowValue] = [:]
            for key in keys {
                guard let shadow = sidecar.meta[key]?.shadowCloud else { continue }
                if let payload = shadow.payload, let def = registry.definition(for: key), !def.validate(payload) { continue }
                batch[key] = shadow.payload
                adopted[key] = shadow
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .unpin) }
            sidecarStore.mutate { sidecar in
                for (key, shadow) in adopted {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = shadow.modifiedAt
                    meta.deviceID = shadow.deviceID
                    meta.lastPushedHash = AppSettingRecord.contentHash(of: shadow.payload)
                    meta.shadowCloud = nil
                    sidecar.meta[key] = meta
                }
            }
        case .pushLocal:
            let now = Date()
            let device = deviceID
            sidecarStore.mutate { sidecar in
                for key in keys {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = now
                    meta.deviceID = device
                    meta.shadowCloud = nil
                    sidecar.meta[key] = meta
                }
            }
            if isEnabled {
                outgoing.formUnion(keys)
                scheduleOutgoingFlush()
            }
        }
    }

    /// Syncable keys currently pinned by any rule, for the pinned-settings list.
    func pinnedDefinitions() -> [AnySettingDefinition] {
        _ = pinGeneration
        return registry.definitions.values
            .filter { $0.isSyncable && isPinned($0.name) }
            .sorted { $0.name < $1.name }
    }
}
