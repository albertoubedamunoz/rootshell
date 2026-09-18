//
//  DirectoryListingService.swift
//  rootshell
//
//  Stale-while-revalidate directory listings with a strict budget per host:
//  one command in flight per target, a bounded scan-ahead of the children of
//  the last listed directory, and nothing issued twice while an answer is
//  fresh.
//

import Foundation

struct DirectoryListingSnapshot: Equatable {
    let result: DirectoryListingResult
    /// Served from cache past its fresh window; a refresh is running.
    let isStale: Bool
}

@MainActor
final class DirectoryListingService {
    static let shared = DirectoryListingService()

    private var cache = DirectoryListingCache()
    /// Serializes commands per target so a burst of keystrokes never stacks
    /// probes on one host (and tssh's single probe slot is never contended).
    private var queueTails: [String: Task<Void, Never>] = [:]
    private var scanAheadTasks: [String: Task<Void, Never>] = [:]
    private var scanAheadValidatedAt: [DirectoryListingKey: Date] = [:]

    // MARK: Listing

    /// Yields the cached snapshot immediately when one exists, then the fresh
    /// answer when the cache was stale or empty. Throws only when nothing at
    /// all could be served.
    func listing(
        _ target: DirectoryTarget,
        using lister: any DirectoryLister,
        force: Bool = false
    ) -> AsyncThrowingStream<DirectoryListingSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [self] in
                var served = false
                do {
                    let canonical = Self.canonical(target, home: lister.homeDirectory)
                    let key = DirectoryListingKey(targetKey: lister.targetKey, path: Self.cachePath(canonical))
                    switch force ? .miss : cache.lookup(key, now: Date()) {
                    case .fresh(let entry):
                        continuation.yield(DirectoryListingSnapshot(result: entry.result, isStale: false))
                        continuation.finish()
                        return
                    case .stale(let entry):
                        continuation.yield(DirectoryListingSnapshot(result: entry.result, isStale: true))
                        served = true
                    case .miss:
                        break
                    }
                    let result = try await fetch(canonical, key: key, using: lister)
                    try Task.checkCancellation()
                    continuation.yield(DirectoryListingSnapshot(result: result, isStale: false))
                    continuation.finish()
                } catch {
                    // A stale answer already on screen beats an error.
                    continuation.finish(throwing: served ? nil : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The cached answer, if any, without touching the host.
    func cached(_ target: DirectoryTarget, using lister: any DirectoryLister) -> DirectoryListingResult? {
        let canonical = Self.canonical(target, home: lister.homeDirectory)
        let key = DirectoryListingKey(targetKey: lister.targetKey, path: Self.cachePath(canonical))
        switch cache.lookup(key, now: Date()) {
        case .fresh(let entry), .stale(let entry): return entry.result
        case .miss: return nil
        }
    }

    func invalidate(targetKey: String) {
        cache.invalidate(targetKey: targetKey)
        scanAheadValidatedAt = scanAheadValidatedAt.filter { $0.key.targetKey != targetKey }
    }

    private func fetch(
        _ target: DirectoryTarget,
        key: DirectoryListingKey,
        using lister: any DirectoryLister
    ) async throws -> DirectoryListingResult {
        // Another caller already asked: wait for it, then read the cache.
        guard let generation = cache.beginFetch(key) else {
            while cache.isInFlight(key) {
                try await Task.sleep(for: .milliseconds(30))
            }
            if case .fresh(let entry) = cache.lookup(key, now: Date()) { return entry.result }
            return try await fetch(target, key: key, using: lister)
        }
        // A new listing outranks the scan-ahead still waiting behind it.
        scanAheadTasks[lister.targetKey]?.cancel()
        do {
            let result = try await serialized(lister.targetKey) { try await lister.list(target) }
            cache.accept(result, for: key, dispatchedGeneration: generation, now: Date())
            return result
        } catch {
            cache.endFetch(key, dispatchedGeneration: generation)
            throw error
        }
    }

    // MARK: Scan-ahead

    /// Warms the children of `result` so descending one level, and the preview
    /// of a highlighted child, need no round trip. `preferred` (the candidates
    /// on screen) go first; one such probe per target at a time.
    func scanAhead(from result: DirectoryListingResult, preferred: [String], using lister: any DirectoryLister) {
        guard lister.supportsScanAhead, let directory = result.resolvedPath, result.error == nil else { return }
        let parentKey = DirectoryListingKey(targetKey: lister.targetKey, path: directory)
        if let last = scanAheadValidatedAt[parentKey], Date().timeIntervalSince(last) < DirectoryListingCache.freshTTL {
            return
        }
        let now = Date()
        var children: [String] = []
        var seen: Set<String> = []
        let ranked = preferred + PathCompletion.rankedFolders(result.directories.map(\.name), prefix: "")
        for name in ranked where seen.insert(name).inserted {
            let key = DirectoryListingKey(targetKey: lister.targetKey, path: PathCompletion.join(directory, name))
            if case .fresh = cache.lookup(key, now: now) { continue }
            children.append(name)
            if children.count == DirectoryListingProbe.scanAheadMaxChildren { break }
        }
        guard !children.isEmpty else { return }

        scanAheadTasks[lister.targetKey]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let listings = try await serialized(lister.targetKey) {
                    try await lister.scanAhead(directory: directory, children: children)
                }
                let stored = Date()
                for (name, listing) in listings {
                    let key = DirectoryListingKey(targetKey: lister.targetKey, path: PathCompletion.join(directory, name))
                    cache.store(listing, for: key, now: stored)
                }
                scanAheadValidatedAt[parentKey] = stored
            } catch {
                // Best effort: a failed warm-up costs nothing visible.
            }
        }
        scanAheadTasks[lister.targetKey] = task
    }

    // MARK: Per-target serialization

    /// Runs `body` after every earlier command for the target has finished.
    /// The body stays in the caller's task, so cancelling the caller cancels it.
    private func serialized<T>(_ targetKey: String, _ body: () async throws -> T) async throws -> T {
        let previous = queueTails[targetKey]
        let (waiters, release) = AsyncStream<Void>.makeStream()
        queueTails[targetKey] = Task { for await _ in waiters {} }
        defer { release.finish() }
        _ = await previous?.value
        try Task.checkCancellation()
        return try await body()
    }

    // MARK: Keys

    /// `~` forms collapse onto the absolute path once home is known, so a
    /// typed `~/x` and a listed `/home/kit/x` share one cache entry.
    nonisolated static func canonical(_ target: DirectoryTarget, home: String?) -> DirectoryTarget {
        guard let home, !home.isEmpty else { return target }
        switch target {
        case .home: return .absolute(PathCompletion.normalize(home))
        case .homeRelative(let rest): return .absolute(PathCompletion.normalize(PathCompletion.join(home, rest)))
        case .absolute, .userHome: return target
        }
    }

    nonisolated static func cachePath(_ target: DirectoryTarget) -> String {
        switch target {
        case .absolute(let path): return path
        case .home: return "~"
        case .homeRelative(let rest): return "~/" + rest
        case .userHome(let user, let rest): return rest.isEmpty ? "~\(user)" : "~\(user)/\(rest)"
        }
    }
}
