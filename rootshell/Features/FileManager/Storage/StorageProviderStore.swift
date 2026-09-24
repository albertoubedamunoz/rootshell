//
//  StorageProviderStore.swift
//  rootshell
//
//  Saved storage providers, read from the iCloud Keychain. The keychain posts
//  no change notifications for synced items, so the list reloads whenever
//  the app becomes active.
//

import Foundation
import UIKit
import os.log

@MainActor
@Observable
final class StorageProviderStore {
    static let shared = StorageProviderStore()

    private static let logger = Logger(subsystem: "com.rootshell", category: "StorageProviders")

    private(set) var providers: [StorageProvider] = []

    @ObservationIgnored private var activationObserver: Task<Void, Never>?

    private init() {
        reload()
        activationObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.reload()
            }
        }
    }

    func provider(for id: UUID) -> StorageProvider? {
        providers.first { $0.id == id }
    }

    func reload() {
        do {
            let decoder = JSONDecoder()
            let loaded = try KeychainManager.shared.loadAllStorageProviders().compactMap { data in
                try? decoder.decode(StorageProvider.self, from: data)
            }
            let sorted = loaded.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if sorted != providers { providers = sorted }
        } catch {
            Self.logger.error("Loading storage providers failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save(_ provider: StorageProvider) throws {
        let data = try JSONEncoder().encode(provider)
        try KeychainManager.shared.saveStorageProvider(data, identifier: provider.id.uuidString, label: "rootshell: \(provider.displayName)")
        // An open connection would keep the old endpoint and keys.
        FileConnectionPool.shared.disconnect(.storage(provider.id))
        reload()
    }

    func delete(_ id: UUID) throws {
        try KeychainManager.shared.deleteStorageProvider(identifier: id.uuidString)
        FileConnectionPool.shared.disconnect(.storage(id))
        reload()
    }
}
