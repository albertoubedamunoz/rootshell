//
//  SettingsSyncCoordinator.swift
//  rootshell
//
//  Owns per-key sync metadata and device-local pins. Stamps every local
//  change with a timestamp so later devices can merge by age. CloudKit
//  transport arrives in a later phase; this file is the state it needs.
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

@MainActor @Observable
final class SettingsSyncCoordinator {
    static let shared = SettingsSyncCoordinator()

    private static let logger = Logger(subsystem: "com.rootshell", category: "SettingsSyncCoordinator")

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registry: SettingsRegistry
    @ObservationIgnored private let sidecarStore = SettingsSyncSidecarStore()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleToken: NSObjectProtocol?
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
            MainActor.assumeIsolated { self?.sidecarStore.saveNow() }
        }
    }

    private func handle(_ change: SettingsChange) {
        guard change.origin == .local else { return }
        let now = Date()
        let device = CloudKitSyncSettings.deviceID
        sidecarStore.mutate { sidecar in
            for key in change.keys where registry.isSyncable(key) {
                var meta = sidecar.meta[key] ?? SettingSyncMeta()
                meta.modifiedAt = now
                meta.deviceID = device
                sidecar.meta[key] = meta
            }
        }
    }

    func meta(for key: String) -> SettingSyncMeta? {
        sidecar.meta[key]
    }

    // MARK: - Pins

    func pinState(for key: String) -> SettingPinState {
        _ = pinGeneration
        guard let def = registry.definition(for: key) else { return .deviceOnly }
        if def.policy == .deviceOnly { return .deviceOnly }
        if sidecar.pinnedGroups.contains(def.group) { return .group }
        if isPinned(key) { return .key }
        return .none
    }

    func isPinned(_ key: String) -> Bool {
        guard let def = registry.definition(for: key), def.policy != .deviceOnly else { return true }
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

    func setPinned(_ key: String, _ pinned: Bool) {
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
            if !pinned { sidecar.pinnedGroups.remove(def.group) }
        }
        pinGeneration += 1
    }

    func setPinned(group: SettingGroup, _ pinned: Bool) {
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
    }

    /// Syncable keys currently pinned by any rule, for the pinned-settings list.
    func pinnedDefinitions() -> [AnySettingDefinition] {
        _ = pinGeneration
        return registry.definitions.values
            .filter { $0.isSyncable && isPinned($0.name) }
            .sorted { $0.name < $1.name }
    }
}
