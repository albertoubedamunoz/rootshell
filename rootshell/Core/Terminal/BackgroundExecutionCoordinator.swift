import Crypto
import os
import UIKit

/// Serial queue for window-state and scrollback writes. Finalize enqueues a
/// marker behind the saves to know when they have landed.
nonisolated enum BackgroundPersistenceQueue {
    static let queue = DispatchQueue(label: "com.rootshell.background.persistence", qos: .utility)
}

/// A background task id that exactly one caller gets to end.
private final class TaskIDBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UIBackgroundTaskIdentifier>(initialState: .invalid)
    func store(_ id: UIBackgroundTaskIdentifier) { lock.withLock { $0 = id } }
    func take() -> UIBackgroundTaskIdentifier {
        lock.withLock { id in
            defer { id = .invalid }
            return id
        }
    }
}

/// App-wide window-state and scrollback save, run as the app backgrounds and
/// again when background processing finalizes.
@MainActor
enum BackgroundStatePersistence {
    /// `clearsWhenClosed` is false for finalize: by then a scene disconnect
    /// (force-quit, reclaim) may have unregistered the windows, so empty is teardown.
    static func save(label: String, clearsWhenClosed: Bool) {
        let start = CFAbsoluteTimeGetCurrent()
        let windowState = WindowStateManager.shared.gatherState()
        // An empty result after a populated one this launch means the user
        // closed everything; before that, restoration may not have run yet.
        if clearsWhenClosed
            && windowState == nil
            && WindowStateManager.isSessionPersistenceEnabled
            && WindowStateManager.shared.hasObservedNonEmptyStateThisLaunch {
            WindowStateManager.shared.clearSavedState()
        }

        let terminalRefs = ScrollbackPersistenceManager.shared.gatherTerminalRefs()
        let encryptionKey: SymmetricKey? = {
            guard !terminalRefs.isEmpty else { return nil }
            do {
                return try ScrollbackEncryptionManager.shared.getKey()
            } catch {
                Ghostty.logger.warning("Failed to pre-fetch encryption key, scrollback will not be saved: \(error.localizedDescription)")
                // Release the in-flight markers gatherTerminalRefs took.
                ScrollbackPersistenceManager.clearInFlightSurfaces(terminalRefs)
                return nil
            }
        }()
        LifecycleDebugLogger.shared.checkpoint("\(label).gather",
            ms: (CFAbsoluteTimeGetCurrent() - start) * 1000, [
                ("windowState", windowState != nil),
                ("scrollbackRefs", terminalRefs.count),
                ("key", encryptionKey != nil),
            ])

        guard windowState != nil || encryptionKey != nil else { return }
        let refCount = terminalRefs.count

        // Its own assertion: without a session grace task the process could
        // suspend mid-write.
        let saveTask = TaskIDBox()
        let endSaveTask: @Sendable () -> Void = {
            DispatchQueue.main.async {
                let id = saveTask.take()
                guard id != .invalid else { return }
                MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(id) }
            }
        }
        saveTask.store(UIApplication.shared.beginBackgroundTask(withName: "StateSave") {
            // Called on main; must end the task before returning.
            let id = saveTask.take()
            guard id != .invalid else { return }
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(id) }
        })

        BackgroundPersistenceQueue.queue.async {
            defer { endSaveTask() }
            let persistStart = CFAbsoluteTimeGetCurrent()
            LifecycleDebugLogger.shared.criticalCheckpoint("\(label).persist.start", ms: nil, [
                ("refs", refCount),
            ])
            if let windowState {
                WindowStateManager.writeStateToDisk(windowState)
            }
            if let encryptionKey {
                for ref in terminalRefs {
                    ScrollbackPersistenceManager.saveScrollbackInBackground(
                        ref: ref,
                        encryptionKey: encryptionKey
                    )
                }
            }
            LifecycleDebugLogger.shared.criticalCheckpoint("\(label).persist.complete",
                ms: (CFAbsoluteTimeGetCurrent() - persistStart) * 1000)
        }
    }
}

/// Owns the app's single background task and decides when background terminal
/// processing stops, saving state shortly before execution time ends.
/// iOS only: on Catalyst the phase never leaves `.foreground`.
@MainActor
final class BackgroundExecutionCoordinator {
    static let shared = BackgroundExecutionCoordinator()

    nonisolated static var phase: BackgroundExecutionPhase {
        phaseLock.withLock { $0 }
    }

    private nonisolated static let phaseLock = OSAllocatedUnfairLock(initialState: BackgroundExecutionPhase.foreground)

    private var taskBox: TaskIDBox?
    private var finalizeTimer: Task<Void, Never>?
    /// Set once a background period has finalized, so a late window can't
    /// restart processing.
    private var finalizedThisBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        #if !targetEnvironment(macCatalyst)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BackgroundExecutionCoordinator.shared.finalize(reason: "memoryWarning")
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BackgroundExecutionCoordinator.shared.finalizeForTermination()
            }
        })
        #endif
    }

    var hasBackgroundTask: Bool { taskBox != nil }

    /// Called by each window as the app backgrounds, before the presentation
    /// gates flip, with that window's count of sessions worth keeping alive.
    func windowDidEnterBackground(sessionCount: Int) {
        #if !targetEnvironment(macCatalyst)
        #if !os(visionOS)
        // Background tunnels are app-wide and keep running as well.
        let tunnelCount = BackgroundTunnelManager.shared.activeTunnels.values
            .filter { $0.state.isActive }.count
        beginTaskIfNeeded(sessionCount: sessionCount + tunnelCount)
        #endif
        guard !finalizedThisBackground else { return }
        let next = BackgroundExecutionPolicy.phaseOnBackground(hasBackgroundTask: hasBackgroundTask)
        let current = Self.phase
        // A later window's sessions can win the task after an earlier window parked.
        if current == .foreground || (current == .parked && next == .processing) {
            setPhase(next)
        }
        #endif
    }

    /// Called as the app returns to the foreground; idempotent across windows.
    func appWillEnterForeground() {
        #if !targetEnvironment(macCatalyst)
        finalizeTimer?.cancel()
        finalizeTimer = nil
        finalizedThisBackground = false
        if Self.phase != .foreground {
            setPhase(.foreground)
        }
        endTask(reason: "foreground")
        #endif
    }

    // MARK: - Background task

    /// Requested even with a Live Activity or Location Diary running; neither
    /// guarantees execution time. Mirrored into the VNC log so a Screen
    /// Sharing drop sits next to the assertion decision that preceded it.
    private func beginTaskIfNeeded(sessionCount: Int) {
        if let reason = RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: UserPreferences.backgroundSessionKeepaliveEnabled,
            sessionCount: sessionCount,
            hasActiveTask: hasBackgroundTask
        ) {
            LifecycleDebugLogger.shared.checkpoint("BG.remoteSessionTask.skipped", ms: nil, [
                ("reason", reason.rawValue),
                ("sessions", sessionCount),
            ])
            VNCDebugLogger.shared.lifecycle("backgroundAssertion.skipped", [
                ("reason", reason.rawValue),
                ("sessions", sessionCount),
            ])
            return
        }

        let box = TaskIDBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "RemoteSessionGrace") {
            // UIKit calls expiration handlers on the main thread.
            MainActor.assumeIsolated {
                BackgroundExecutionCoordinator.shared.handleExpiration(box)
            }
        }
        guard taskID != .invalid else { return }
        box.store(taskID)
        taskBox = box
        armFinalizeTimer()

        LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.begin", ms: nil, [
            ("sessions", sessionCount),
            ("task", taskID),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
        VNCDebugLogger.shared.lifecycle("backgroundAssertion.begin", [
            ("sessions", sessionCount),
            ("remaining", String(format: "%.0fs", UIApplication.shared.backgroundTimeRemaining)),
        ])
    }

    private func endTask(reason: String) {
        guard let box = taskBox else { return }
        taskBox = nil
        let taskID = box.take()
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.end", ms: nil, [
            ("reason", reason),
            ("task", taskID),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
    }

    /// Backstop only: the deadline timer normally finalizes first. Starts the
    /// finalize without waiting on it, then ends the task before returning.
    private func handleExpiration(_ box: TaskIDBox) {
        let taskID = box.take()
        guard taskID != .invalid else { return }
        LifecycleDebugLogger.shared.criticalCheckpoint("BG.remoteSessionTask.expired", ms: nil, [
            ("task", taskID),
            ("phase", Self.phase.description),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
        finalize(reason: "expired")
        VNCDebugLogger.shared.lifecycle("backgroundAssertion.expired")
        UIApplication.shared.endBackgroundTask(taskID)
        if taskBox === box { taskBox = nil }
    }

    /// Re-reads the remaining time every few seconds; it is only meaningful once
    /// backgrounded, and is unbounded while Location Diary keeps the app alive.
    private func armFinalizeTimer() {
        finalizeTimer?.cancel()
        finalizeTimer = Task { @MainActor in
            while !Task.isCancelled {
                let remaining = UIApplication.shared.backgroundTimeRemaining
                guard let delay = BackgroundExecutionPolicy.finalizeDelay(
                    backgroundTimeRemaining: remaining) else {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                if delay <= 0 {
                    BackgroundExecutionCoordinator.shared.finalize(reason: "deadline")
                    return
                }
                try? await Task.sleep(for: .seconds(min(delay, 5)))
            }
        }
    }

    // MARK: - Finalize

    /// Stops background processing and saves state, then ends the task once
    /// the save has landed.
    func finalize(reason: String) {
        guard Self.phase == .processing else { return }
        finalizedThisBackground = true
        finalizeTimer?.cancel()
        finalizeTimer = nil
        setPhase(.finalizing)
        LifecycleDebugLogger.shared.criticalCheckpoint("BG.finalize.begin", ms: nil, [
            ("reason", reason),
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
        BackgroundStatePersistence.save(label: "BG.finalize", clearsWhenClosed: false)
        // Serial queue: this marker runs after the save queued above.
        BackgroundPersistenceQueue.queue.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BackgroundExecutionCoordinator.shared.completeFinalize()
                }
            }
        }
    }

    private func completeFinalize() {
        // Foregrounded while the saves ran.
        guard Self.phase == .finalizing else { return }
        setPhase(.parked)
        LifecycleDebugLogger.shared.criticalCheckpoint("BG.finalize.complete", ms: nil, [
            ("remaining", UIApplication.shared.backgroundTimeRemaining),
        ])
        endTask(reason: "finalized")
    }

    /// The process exits when this returns, so give the saves a bounded wait.
    private func finalizeForTermination() {
        guard Self.phase == .processing else { return }
        finalize(reason: "terminate")
        let done = DispatchSemaphore(value: 0)
        BackgroundPersistenceQueue.queue.async { done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    private func setPhase(_ phase: BackgroundExecutionPhase) {
        Self.phaseLock.withLock { $0 = phase }
        LifecycleDebugLogger.shared.checkpoint("BG.phase", ms: nil, [
            ("phase", phase.description),
        ])
        // Wakeups dropped before processing began may have left a full mailbox
        // with no pending wakeup; drain it once to restart the pump.
        if phase == .processing {
            Ghostty.App.shared?.appTick()
        }
    }
}
