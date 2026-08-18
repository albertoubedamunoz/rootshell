//
//  VPNSSHHealthMonitor.swift
//  VPNTunnelExtension
//
//  Lightweight SSH keepalive monitor that runs independently of MainActor.
//  Sends periodic keepalives and fires a callback when the connection is
//  determined dead (3 consecutive failures or SSH disconnect detected).
//

import Foundation
import NIOSSH
import os.log
@preconcurrency import Citadel

nonisolated final class VPNSSHHealthMonitor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "SSHHealthMonitor")

    // Configuration
    private let pingInterval: TimeInterval = 15.0
    private let pingTimeout: TimeInterval = 10.0
    private let maxConsecutiveFailures = 3

    // State (lock-protected)
    private let lock = NSLock()
    private weak var client: SSHClient?
    private var consecutiveFailures = 0
    private var monitorTask: Task<Void, Never>?
    private var stopped = false

    /// Called (from an arbitrary thread) when the connection is determined dead.
    var onConnectionLost: (@Sendable () -> Void)?

    func start(client: SSHClient) {
        let existingTask = lock.withLock { () -> Task<Void, Never>? in
            self.client = client
            self.consecutiveFailures = 0
            self.stopped = false
            return monitorTask
        }

        existingTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMonitorLoop()
        }

        lock.withLock { monitorTask = task }

        Self.logger.info("Health monitor started")
        VPNSOCKS5DebugMetrics.shared.addEvent("health-monitor-started")
    }

    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            let t = monitorTask
            monitorTask = nil
            client = nil
            return t
        }

        task?.cancel()
        Self.logger.info("Health monitor stopped")
        VPNSOCKS5DebugMetrics.shared.addEvent("health-monitor-stopped")
    }

    // MARK: - Private

    private func runMonitorLoop() async {
        while !Task.isCancelled {
            // Wait for ping interval
            do {
                try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
            } catch {
                break // Cancelled
            }

            let isStopped = lock.withLock { stopped }
            if isStopped { break }

            let success = await sendKeepalive()

            let action = lock.withLock { () -> LoopAction in
                if stopped { return .stop }
                if success {
                    consecutiveFailures = 0
                    return .continueLoop
                } else {
                    consecutiveFailures += 1
                    return .checkFailures(consecutiveFailures, maxConsecutiveFailures)
                }
            }

            switch action {
            case .stop:
                break
            case .continueLoop:
                VPNSOCKS5DebugMetrics.shared.increment("ssh.keepalive.success")
                VPNSOCKS5DebugMetrics.shared.tsLog("KEEPALIVE-OK failures=0")
                continue
            case .checkFailures(let failures, let maxFail):
                VPNSOCKS5DebugMetrics.shared.increment("ssh.keepalive.failure")
                Self.logger.warning("SSH keepalive failed (\(failures)/\(maxFail))")
                VPNSOCKS5DebugMetrics.shared.tsLog("KEEPALIVE-FAIL failures=\(failures)/\(maxFail)")

                if failures >= maxFail {
                    Self.logger.error("SSH connection dead: \(failures) consecutive keepalive failures")
                    VPNSOCKS5DebugMetrics.shared.addEvent("ssh.keepalive.dead failures=\(failures)")
                    VPNSOCKS5DebugMetrics.shared.tsLog("KEEPALIVE-DEAD failures=\(failures)")
                    onConnectionLost?()
                    return
                }
                continue
            }
            break
        }
    }

    private enum LoopAction {
        case stop
        case continueLoop
        case checkFailures(Int, Int)
    }

    private func sendKeepalive() async -> Bool {
        let client = lock.withLock { self.client }
        guard let client else { return false }

        // Quick check: if Citadel already knows the connection is gone, fail immediately
        guard client.isConnected else {
            Self.logger.info("SSH client reports disconnected")
            return false
        }

        // Race keepalive against timeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await client.sendKeepalive()
                    return true
                } catch {
                    // SSH_MSG_REQUEST_FAILURE still proves the server is alive —
                    // only TIMEOUT (no response) means the connection is dead.
                    if let sshError = error as? NIOSSHError,
                       sshError.type == .globalRequestRefused {
                        return true
                    }
                    let desc = String(describing: error)
                    Self.logger.debug("Keepalive error: \(desc)")
                    return false
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.pingTimeout * 1_000_000_000))
                    return false // Timed out
                } catch {
                    return false // Cancelled (the other task finished first)
                }
            }

            // Return the first result, cancel the other
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
