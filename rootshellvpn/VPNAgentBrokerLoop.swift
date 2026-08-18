//
//  VPNAgentBrokerLoop.swift
//  rootshellvpn (VPN host)
//
//  Host side of the VPN agent signing broker. The sysext (root) cannot reach
//  a user-session ssh-agent socket and cannot initiate IPC to us, so we keep
//  an `agent.poll` sendProviderMessage outstanding; when the sysext needs a
//  userauth signature it answers the poll with a challenge, we sign it
//  against the agent socket in user context, and submit the result with
//  `agent.submit`. Runs for the tunnel's whole lifetime so in-tunnel
//  reconnects can re-sign, and resumes on host relaunch (main.swift checks
//  the persisted `usesAgentSigning` flag).
//

import Foundation
import NetworkExtension
import os
import os.log

@MainActor
final class VPNAgentBrokerLoop {
    static let shared = VPNAgentBrokerLoop()

    private let log = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "agentBroker")
    nonisolated private static let watchdogLog = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "agentBroker")

    private var loopTask: Task<Void, Never>?
    /// Increments per start(); a finished stale loop must not clear a newer
    /// loop's task handle.
    private var loopGeneration = 0
    /// Challenges currently being signed, so a redelivered challenge (poll
    /// reply lost by NE, sysext handed it out again) isn't signed twice.
    private var inFlight: Set<UUID> = []
    /// Child signing tasks, cancelled on stop() so a disconnected tunnel
    /// doesn't leave an approval flow trying to submit to a dead session.
    private var signTasks: [UUID: Task<Void, Never>] = [:]

    func start() {
        guard loopTask == nil else { return }
        log.info("agent broker loop starting")
        loopGeneration += 1
        let generation = loopGeneration
        inFlight.removeAll()
        loopTask = Task { [weak self] in
            await self?.run()
            if let self, self.loopGeneration == generation {
                self.loopTask = nil
            }
        }
    }

    func stop() {
        guard loopTask != nil || !signTasks.isEmpty else { return }
        log.info("agent broker loop stopping")
        loopTask?.cancel()
        loopTask = nil
        for task in signTasks.values { task.cancel() }
        signTasks.removeAll()
        inFlight.removeAll()
    }

    var isRunning: Bool { loopTask != nil }

    private func run() async {
        var downSince: Date?

        while !Task.isCancelled {
            guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
                  let manager = managers.first,
                  let session = manager.connection as? NETunnelProviderSession else {
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            switch session.status {
            case .connecting, .connected, .reasserting:
                downSince = nil
            case .disconnected, .disconnecting, .invalid:
                // Tolerate brief gaps (profile switch, quick restart); give
                // up when the tunnel stays down so the loop doesn't outlive
                // the session it serves. A later startVPN restarts it.
                if let downSince, Date().timeIntervalSince(downSince) > 30 {
                    log.info("tunnel stayed down; agent broker loop exiting")
                    return
                }
                if downSince == nil { downSince = Date() }
                try? await Task.sleep(for: .seconds(2))
                continue
            @unknown default:
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            let reply = await pollOnce(session: session)

            if Task.isCancelled { return }

            guard let reply, !reply.isEmpty else {
                // Empty reply = parked poll expired with no work; nil = drop
                // or watchdog. Brief pause, then re-poll.
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard let challenge = try? JSONDecoder().decode(VPNAgentSignChallenge.self, from: reply) else {
                log.error("agent.poll returned undecodable payload (\(reply.count) bytes)")
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            guard !inFlight.contains(challenge.requestID) else {
                log.info("challenge \(challenge.requestID.uuidString.prefix(8), privacy: .public) already in flight; ignoring redelivery")
                continue
            }
            inFlight.insert(challenge.requestID)

            // Sign + submit in a tracked child task so overlapping requests
            // (jump host + target) don't serialize behind one approval
            // dialog — the loop re-polls immediately — and stop() can
            // cancel work aimed at a session that no longer exists.
            let requestID = challenge.requestID
            let generation = loopGeneration
            let task = Task { [weak self] in
                await self?.signAndSubmit(challenge: challenge, session: session)
                // Stale tasks from a stopped loop must not evict a newer
                // task tracked under a redelivered requestID.
                if let self, self.loopGeneration == generation {
                    self.signTasks[requestID] = nil
                }
            }
            signTasks[requestID] = task
        }
    }

    private func signAndSubmit(challenge: VPNAgentSignChallenge, session: NETunnelProviderSession) async {
        defer { inFlight.remove(challenge.requestID) }
        guard !Task.isCancelled else { return }

        let socketPath = challenge.socketPath
        let keyBlob = challenge.keyBlob
        let data = challenge.data
        let flags = challenge.flags

        // The cancellation token lets stop() actually abort the blocking
        // agent round trip: cancelling this task shuts the socket down, the
        // blocked read returns, and the agent dismisses its approval prompt
        // instead of leaving it pending for the full sign timeout.
        let token = ExternalAgentCancellationToken()
        var submission: VPNAgentSignSubmission
        do {
            let signature = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ExternalSSHAgentClient(socketPath: socketPath).sign(
                        keyBlob: keyBlob,
                        data: data,
                        flags: flags,
                        timeout: VPNAgentBrokerMessage.signTimeoutSeconds,
                        cancellation: token
                    )
                }.value
            } onCancel: {
                token.cancel()
            }
            submission = VPNAgentSignSubmission(requestID: challenge.requestID, signature: signature, error: nil)
            log.info("signed challenge \(challenge.requestID.uuidString.prefix(8), privacy: .public) (\(signature.count) bytes)")
        } catch {
            submission = VPNAgentSignSubmission(requestID: challenge.requestID, signature: nil, error: error.localizedDescription)
            log.error("agent signing failed: \(error.localizedDescription, privacy: .public)")
        }

        // The blocking agent round trip itself can't be interrupted, but a
        // cancelled (stopped) broker must not submit to an obsolete session.
        guard !Task.isCancelled else {
            log.info("broker stopped while signing; dropping result for \(challenge.requestID.uuidString.prefix(8), privacy: .public)")
            return
        }

        guard let body = try? JSONEncoder().encode(submission) else { return }
        var message = Data(VPNAgentBrokerMessage.submitPrefix.utf8)
        message.append(body)
        do {
            try session.sendProviderMessage(message) { _ in }
        } catch {
            log.error("agent.submit send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One long-poll round trip. Returns the reply data (empty = no work) or
    /// nil on drop/watchdog. The sysext parks the poll for up to
    /// `pollParkSeconds`; our watchdog must outlast that.
    private func pollOnce(session: NETunnelProviderSession) async -> Data? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Data?) -> Bool = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
                return first
            }
            do {
                try session.sendProviderMessage(Data(VPNAgentBrokerMessage.poll.utf8)) { data in
                    _ = finish(data)
                }
            } catch {
                Self.watchdogLog.error("agent.poll send failed: \(error.localizedDescription, privacy: .public)")
                _ = finish(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + VPNAgentBrokerMessage.pollWatchdogSeconds) {
                if finish(nil) {
                    Self.watchdogLog.error("agent.poll reply timed out (watchdog)")
                }
            }
        }
    }
}
