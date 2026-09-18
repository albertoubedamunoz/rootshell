//
//  DirectoryListingCache.swift
//  rootshell
//

import Foundation

nonisolated struct DirectoryListingKey: Hashable, Sendable {
    let targetKey: String
    /// Normalized request path (also aliased under the resolved path).
    let path: String
}

/// Stale-while-revalidate storage for directory listings, one host round trip
/// at a time: a fresh answer is served as-is, a stale one is served while a
/// refresh runs, and nothing older than `staleTTL` is trusted at all.
nonisolated struct DirectoryListingCache: Sendable {
    static let freshTTL: TimeInterval = 20
    static let staleTTL: TimeInterval = 10 * 60
    static let maxEntries = 256

    struct Entry: Equatable, Sendable {
        var result: DirectoryListingResult
        var validatedAt: Date
    }

    enum Lookup: Equatable, Sendable {
        case fresh(Entry)
        case stale(Entry)
        case miss
    }

    private(set) var entries: [DirectoryListingKey: Entry] = [:]
    private var generations: [DirectoryListingKey: UInt64] = [:]
    private var inFlight: [DirectoryListingKey: UInt64] = [:]

    func lookup(_ key: DirectoryListingKey, now: Date) -> Lookup {
        guard let entry = entries[key] else { return .miss }
        let age = now.timeIntervalSince(entry.validatedAt)
        // Errors are answers too, but never worth serving stale; a capped
        // listing is worth showing, but always worth completing.
        if age < Self.freshTTL && !entry.result.truncated { return .fresh(entry) }
        if entry.result.error != nil || age >= Self.staleTTL { return .miss }
        return .stale(entry)
    }

    func isInFlight(_ key: DirectoryListingKey) -> Bool {
        inFlight[key] != nil
    }

    /// The generation to carry through the fetch, or nil when one is already
    /// running for this key.
    mutating func beginFetch(_ key: DirectoryListingKey) -> UInt64? {
        guard inFlight[key] == nil else { return nil }
        let generation = generations[key, default: 0]
        inFlight[key] = generation
        return generation
    }

    /// Releases the in-flight slot after a failed fetch.
    mutating func endFetch(_ key: DirectoryListingKey, dispatchedGeneration: UInt64) {
        if inFlight[key] == dispatchedGeneration { inFlight.removeValue(forKey: key) }
    }

    /// Stores only if no invalidation landed after dispatch.
    @discardableResult
    mutating func accept(
        _ result: DirectoryListingResult,
        for key: DirectoryListingKey,
        dispatchedGeneration: UInt64,
        now: Date
    ) -> Bool {
        endFetch(key, dispatchedGeneration: dispatchedGeneration)
        guard generations[key, default: 0] == dispatchedGeneration else { return false }
        store(result, for: key, now: now)
        return true
    }

    /// Stores an answer that arrived without a dispatch (scan-ahead).
    mutating func store(_ result: DirectoryListingResult, for key: DirectoryListingKey, now: Date) {
        let entry = Entry(result: result, validatedAt: now)
        entries[key] = entry
        if let resolved = result.resolvedPath, resolved != key.path {
            entries[DirectoryListingKey(targetKey: key.targetKey, path: resolved)] = entry
        }
        trim(now: now)
    }

    mutating func invalidate(_ key: DirectoryListingKey) {
        generations[key, default: 0] &+= 1
        entries.removeValue(forKey: key)
    }

    mutating func invalidate(targetKey: String) {
        for key in entries.keys where key.targetKey == targetKey {
            invalidate(key)
        }
        for key in inFlight.keys where key.targetKey == targetKey {
            generations[key, default: 0] &+= 1
        }
    }

    mutating func evictExpired(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.validatedAt) < Self.staleTTL }
    }

    private mutating func trim(now: Date) {
        evictExpired(now: now)
        guard entries.count > Self.maxEntries else { return }
        let oldestFirst = entries.sorted { $0.value.validatedAt < $1.value.validatedAt }
        for (key, _) in oldestFirst.prefix(entries.count - Self.maxEntries) {
            entries.removeValue(forKey: key)
        }
    }
}
