//
//  AgentRepositoryRefreshState.swift
//  rootshell
//
//  Pure cache and invalidation policy for agent project repository facts.
//  Kept free of UIKit and connection types so races and expiry semantics can
//  be exercised by tests/agent-attention/run.sh.
//

import Foundation

/// One answered working directory on one machine.
nonisolated struct AgentRepositoryPathKey: Hashable, Sendable {
    let hostKey: String
    let path: String
}

/// Classifies whether a transport-successful probe actually answered every
/// operation the caller requested.
nonisolated enum AgentRepositoryProbeAnswer {
    static func isIncomplete(
        _ result: ProjectProbeResult,
        requestedPaths: [String],
        requestedWorkingDirectory: Bool
    ) -> Bool {
        let missingRepositoryLine = !result.gitUnavailable
            && requestedPaths.contains { result.repos[$0] == nil }
        let missingWorkingDirectory = requestedWorkingDirectory
            && result.paneWorkingDirectory == nil
        return missingRepositoryLine || missingWorkingDirectory
    }
}

/// Per-host admission policy for repository commands.
///
/// The normal cache TTL lives on each repository entry, while this host-wide
/// state prevents noisy dirty hints and repeated transport failures from
/// turning into an exec loop.
nonisolated struct AgentRepositoryHostProbeHealth: Equatable, Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var retryAfter: Date?
    private(set) var lastStartedAt: Date?

    mutating func recordStarted(now: Date) {
        lastStartedAt = now
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAfter = nil
    }

    mutating func recordFailure(
        now: Date,
        baseDelay: TimeInterval,
        maximumDelay: TimeInterval
    ) {
        consecutiveFailures += 1
        let exponent = min(consecutiveFailures - 1, 8)
        let delay = min(
            baseDelay * pow(2, Double(exponent)),
            maximumDelay
        )
        retryAfter = now.addingTimeInterval(delay)
    }

    func canStart(now: Date) -> Bool {
        retryAfter.map { $0 <= now } ?? true
    }

    func isBelowRefreshFloor(
        now: Date,
        floor: TimeInterval
    ) -> Bool {
        guard let lastStartedAt else { return false }
        return now.timeIntervalSince(lastStartedAt) < floor
    }
}

/// Stale-while-revalidate storage for repository facts.
///
/// A dirty or expired entry remains readable so a transient remote failure
/// never blanks a card. `generation` protects each requested path
/// independently: invalidating repository A while a host-wide batch is in
/// flight does not force us to discard a valid answer for repository B.
nonisolated struct AgentRepositoryRefreshState: Sendable {
    static let refreshTTL: TimeInterval = 5 * 60

    struct Entry: Equatable, Sendable {
        var facts: ProjectProbeRepo
        var validatedAt: Date
        var isDirty: Bool
    }

    private(set) var entries: [AgentRepositoryPathKey: Entry] = [:]
    private var generations: [AgentRepositoryPathKey: UInt64] = [:]

    func entry(for key: AgentRepositoryPathKey) -> Entry? {
        entries[key]
    }

    func facts(for key: AgentRepositoryPathKey) -> ProjectProbeRepo? {
        entries[key]?.facts
    }

    func hasFacts(for key: AgentRepositoryPathKey) -> Bool {
        entries[key] != nil
    }

    func needsRefresh(
        _ key: AgentRepositoryPathKey,
        now: Date,
        ttl: TimeInterval = refreshTTL
    ) -> Bool {
        guard let entry = entries[key] else { return true }
        return entry.isDirty || now.timeIntervalSince(entry.validatedAt) >= ttl
    }

    func generation(for key: AgentRepositoryPathKey) -> UInt64 {
        generations[key, default: 0]
    }

    /// Marks the exact path and every cached path in the same worktree dirty.
    ///
    /// Git branches are worktree-scoped. Using the probed root means panes in
    /// `repo/a` and `repo/b` update together while linked worktrees, whose
    /// roots differ, remain independent.
    @discardableResult
    mutating func invalidateRepository(containing key: AgentRepositoryPathKey) -> Set<AgentRepositoryPathKey> {
        var affected: Set<AgentRepositoryPathKey> = [key]
        if let root = entries[key]?.facts.root {
            for (candidate, entry) in entries
            where candidate.hostKey == key.hostKey && entry.facts.root == root {
                affected.insert(candidate)
            }
        }

        for affectedKey in affected {
            generations[affectedKey, default: 0] &+= 1
            if entries[affectedKey] != nil {
                entries[affectedKey]?.isDirty = true
            }
        }
        return affected
    }

    /// Marks every retained answer stale, preserving it for stale-while-
    /// revalidate display where it is already visible.
    ///
    /// Used when project lookup is disabled: repository state may change while
    /// command-derived pane identities are hidden, so none of the private
    /// cache may be considered current when lookup is enabled again.
    mutating func invalidateAll() {
        let keys = Array(entries.keys)
        for key in keys {
            generations[key, default: 0] &+= 1
            entries[key]?.isDirty = true
        }
    }

    /// Forgets an answer whose path identity is about to be hidden.
    ///
    /// If the directory itself came from a command, there is no key left on
    /// the pane while lookup is disabled that could invalidate this entry.
    /// Discarding it makes rediscovery an uncached first lookup rather than
    /// briefly reviving a stale branch.
    mutating func discard(_ key: AgentRepositoryPathKey) {
        generations[key, default: 0] &+= 1
        entries.removeValue(forKey: key)
    }

    /// Stores an answer only if it is still current for this exact path.
    ///
    /// Returns false when an invalidation landed after dispatch. Missing
    /// response lines never call this method, preserving the distinction
    /// between "not a repository" and "the host did not answer".
    @discardableResult
    mutating func accept(
        _ facts: ProjectProbeRepo,
        for key: AgentRepositoryPathKey,
        dispatchedGeneration: UInt64,
        now: Date
    ) -> Bool {
        guard generation(for: key) == dispatchedGeneration else { return false }
        entries[key] = Entry(facts: facts, validatedAt: now, isDirty: false)
        return true
    }

    /// Test/setup convenience for a known-current answer.
    mutating func store(
        _ facts: ProjectProbeRepo,
        for key: AgentRepositoryPathKey,
        now: Date
    ) {
        entries[key] = Entry(facts: facts, validatedAt: now, isDirty: false)
    }
}
