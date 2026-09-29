import Foundation

/// Where the process is in its iOS background lifetime. Catalyst stays in
/// `.foreground`: its scenes background while the app keeps running.
nonisolated enum BackgroundExecutionPhase: UInt8, Sendable, CustomStringConvertible {
    /// Active or inactive; presentation allowed.
    case foreground
    /// Backgrounded with a background task: terminals keep parsing, nothing presents.
    case processing
    /// Execution time is about to end: work stops and state is saved.
    case finalizing
    /// Finalized, or backgrounded without a task: today's frozen behavior.
    case parked

    /// Whether Ghostty's app mailbox may be drained while presentation is revoked.
    var allowsBackgroundTick: Bool { self == .processing }

    var description: String {
        switch self {
        case .foreground: "foreground"
        case .processing: "processing"
        case .finalizing: "finalizing"
        case .parked: "parked"
        }
    }
}

nonisolated enum BackgroundExecutionPolicy {
    /// Finalize this long before iOS reports the background task expiring.
    static let finalizeMargin: TimeInterval = 5

    /// Background ticks are batched to at most one per interval.
    static let backgroundTickInterval: Duration = .milliseconds(100)

    /// Per-terminal pipe-writer cap while backgrounded; background jetsam
    /// limits are far lower than the foreground's.
    static let backgroundPipeWriterMaxBytes = 4 * 1024 * 1024

    /// Phase to enter on backgrounding, given whether a task was granted.
    static func phaseOnBackground(hasBackgroundTask: Bool) -> BackgroundExecutionPhase {
        hasBackgroundTask ? .processing : .parked
    }

    /// Seconds from now to begin finalizing, or nil when the remaining time is
    /// unbounded (Location Diary keeps the app alive) and no timer is needed.
    static func finalizeDelay(backgroundTimeRemaining: TimeInterval) -> TimeInterval? {
        guard backgroundTimeRemaining.isFinite,
              backgroundTimeRemaining < .greatestFiniteMagnitude else { return nil }
        return max(0, backgroundTimeRemaining - finalizeMargin)
    }

    /// Ghostty's app tick may run when presentation is allowed, or while processing.
    static func allowsTick(isPresentationRevoked: Bool, phase: BackgroundExecutionPhase) -> Bool {
        !isPresentationRevoked || phase.allowsBackgroundTick
    }

    enum TrzszOutputRoute: Equatable {
        /// Emit straight into the terminal pipe.
        case writeThrough
        /// Hold in the bounded transport buffer until foreground.
        case buffer
    }

    /// tssh output keeps flowing into the terminal while processing. Once the
    /// server reports lost output while backgrounded, the rest buffers so the
    /// resume path can queue a tmux reset before any bytes after the gap parse.
    static func trzszOutputRoute(
        isPresentationRevoked: Bool,
        phase: BackgroundExecutionPhase,
        writeThroughAllowed: Bool,
        hasBackgroundLoss: Bool
    ) -> TrzszOutputRoute {
        guard isPresentationRevoked else { return .writeThrough }
        guard phase == .processing, writeThroughAllowed, !hasBackgroundLoss else { return .buffer }
        return .writeThrough
    }
}

/// How a held tmux reconcile coalesces with what is already held.
nonisolated enum HeldReconcileKind: Equatable {
    /// Empty topology: the control session ended. Supersedes everything held
    /// before it and stays as a boundary, so a reattach after it starts clean.
    case teardown
    /// Full topology snapshot: supersedes earlier syncs, and updates it carries,
    /// back to the last teardown.
    case fullSync
    /// Incremental update; only the latest per `key` since the last teardown is
    /// kept. `coveredByFullSync` updates are also dropped by a later full sync;
    /// the rest move after it, since the sync does not carry them.
    case update(key: String, coveredByFullSync: Bool)
}

/// Ordered hold for tmux reconciles that must not run while backgrounded.
/// Coalescing keeps it bounded by the gateway's window count, not by time.
nonisolated struct BackgroundHeldQueue<Owner: Hashable, Element> {
    struct Entry {
        let owner: Owner
        let kind: HeldReconcileKind
        let element: Element
    }

    private(set) var entries: [Entry] = []

    /// Safety net for unkeyed updates; the oldest updates go first.
    let maxEntries: Int

    init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
    }

    /// Appends `element` and returns the entries it superseded, which the
    /// caller must release.
    mutating func append(_ element: Element, owner: Owner, kind: HeldReconcileKind) -> [Element] {
        var superseded: [Element] = []
        let boundary = entries.lastIndex { $0.owner == owner && $0.kind == .teardown }
        var kept: [Entry] = []
        var moved: [Entry] = []
        for (index, entry) in entries.enumerated() {
            guard entry.owner == owner else {
                kept.append(entry)
                continue
            }
            // A teardown supersedes everything before it; otherwise only entries
            // after the last teardown are candidates.
            let isSettled = boundary.map { index <= $0 } ?? false
            switch kind {
            case .teardown:
                superseded.append(entry.element)
            case .fullSync:
                if isSettled {
                    kept.append(entry)
                    continue
                }
                switch entry.kind {
                case .teardown:
                    kept.append(entry)
                case .fullSync, .update(_, coveredByFullSync: true):
                    superseded.append(entry.element)
                case .update(_, coveredByFullSync: false):
                    moved.append(entry)
                }
            case .update(let key, _):
                if !isSettled, case .update(key, _) = entry.kind {
                    superseded.append(entry.element)
                } else {
                    kept.append(entry)
                }
            }
        }
        entries = kept + [Entry(owner: owner, kind: kind, element: element)] + moved

        while entries.count > maxEntries,
              let oldest = entries.firstIndex(where: {
                  if case .update = $0.kind { return true }
                  return false
              }) {
            superseded.append(entries.remove(at: oldest).element)
        }
        return superseded
    }

    /// Removes and returns every entry in arrival order.
    mutating func drain() -> [Entry] {
        defer { entries.removeAll() }
        return entries
    }

    var isEmpty: Bool { entries.isEmpty }
}
