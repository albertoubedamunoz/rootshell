//
//  LocalInterfaceMonitor.swift
//  rootshell
//
//  Polls getifaddrs() to detect local interface/IP changes (e.g., VPN utun
//  appearing/disappearing) that NWPathMonitor may miss or coalesce.
//  Only runs while a Live Activity is using network info.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import Combine
import Foundation
import os.log

@MainActor
final class LocalInterfaceMonitor {
    static let shared = LocalInterfaceMonitor()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell", category: "LocalInterfaceMonitor"
    )

    /// Fires when the set of local interface:address pairs changes.
    let interfacesChanged = PassthroughSubject<Void, Never>()

    private var pollTask: Task<Void, Never>?
    private var previousSnapshot: Set<String> = []
    private var pendingSnapshot: Set<String>?
    private var pendingReplayScheduled = false
    private(set) var isRunning = false

    /// Backstop only — NWPathMonitor reports most path changes immediately;
    /// this poll exists for utun churn it coalesces. 15s keeps the Xcode
    /// energy "overhead" wakes down vs the original 5s.
    private static let pollInterval: Duration = .seconds(15)

    /// Interface name prefixes to exclude from monitoring.
    private nonisolated static let excludedPrefixes = ["lo", "awdl", "llw", "anpi", "bridge"]

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
            ForegroundActivationGate.shared.runWhenSafe(
                reason: "localInterfaceMonitor.start",
                timeoutPolicy: .fireIfNotBackgrounded
            ) { [weak self] in
                self?.start()
            }
            return
        }
        isRunning = true
        Self.logger.info("Starting local interface polling")

        pollTask = Task {
            // Capture initial snapshot without firing. getifaddrs/getnameinfo can
            // block during scene activation, so keep the syscall work off MainActor.
            previousSnapshot = await Self.currentSnapshotOffMainActor()
            pendingSnapshot = nil
            pendingReplayScheduled = false

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }

                let snapshot = await Self.currentSnapshotOffMainActor()
                handleObservedSnapshot(snapshot)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        previousSnapshot = []
        pendingSnapshot = nil
        pendingReplayScheduled = false
        Self.logger.info("Stopped local interface polling")
    }

    // MARK: - Private

    private func handleObservedSnapshot(_ snapshot: Set<String>) {
        if pendingSnapshot != nil {
            if snapshot == previousSnapshot {
                pendingSnapshot = nil
                return
            }
            pendingSnapshot = snapshot
            if ForegroundActivationGate.shared.isUnsafeForSceneMutation {
                LifecycleDebugLogger.shared.bumpSuppression("local_interface_monitor")
                schedulePendingReplayWhenSafe()
            } else {
                replayPendingSnapshotIfNeeded()
            }
            return
        }

        guard snapshot != previousSnapshot else { return }

        if ForegroundActivationGate.shared.isUnsafeForSceneMutation {
            pendingSnapshot = snapshot
            LifecycleDebugLogger.shared.bumpSuppression("local_interface_monitor")
            schedulePendingReplayWhenSafe()
            return
        }

        emitInterfaceChange(to: snapshot)
    }

    private func schedulePendingReplayWhenSafe() {
        guard !pendingReplayScheduled else { return }
        pendingReplayScheduled = true
        ForegroundActivationGate.shared.runWhenSafe(
            reason: "localInterfaceMonitor.interfacesChanged",
            timeoutPolicy: .fireIfNotBackgrounded
        ) { [weak self] in
            guard let self else { return }
            self.pendingReplayScheduled = false
            self.replayPendingSnapshotIfNeeded()
        }
    }

    private func replayPendingSnapshotIfNeeded() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard isRunning else { return }
        guard snapshot != previousSnapshot else { return }
        emitInterfaceChange(to: snapshot)
    }

    private func emitInterfaceChange(to snapshot: Set<String>) {
        let added = snapshot.subtracting(previousSnapshot)
        let removed = previousSnapshot.subtracting(snapshot)
        Self.logger.info("Interfaces changed — added: \(added), removed: \(removed)")
        previousSnapshot = snapshot
        interfacesChanged.send()
    }

    private nonisolated static func currentSnapshotOffMainActor() async -> Set<String> {
        await Task.detached(priority: .utility) {
            currentSnapshot()
        }.value
    }

    /// Build a set of "ifName:ipAddress" strings from getifaddrs().
    /// Excludes loopback, AWDL, link-local wireless, and fe80:: link-local addresses.
    private nonisolated static func currentSnapshot() -> Set<String> {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }

            guard let sa = ifa.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let name = String(cString: ifa.pointee.ifa_name)

            // Skip excluded interfaces.
            if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }

            let address = String(cString: hostname)

            // Skip IPv6 link-local (fe80::).
            if family == AF_INET6 && address.hasPrefix("fe80:") { continue }

            result.insert("\(name):\(address)")
        }

        return result
    }
}
#endif
