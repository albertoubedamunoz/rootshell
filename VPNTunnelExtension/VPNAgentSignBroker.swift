//
//  VPNAgentSignBroker.swift
//  VPNTunnelExtension (macOS sysext only)
//
//  Sysext side of the VPN agent signing broker. NIO-SSH's signing hook is
//  synchronous on the SSH event loop, but the actual signer (the user's
//  ssh-agent) lives behind the host process: `sign(...)` enqueues a
//  challenge and blocks on a semaphore; the host's long-poll (`agent.poll`)
//  picks the challenge up, signs in user context, and `agent.submit`
//  releases the semaphore with the signature.
//

#if os(macOS)

import Foundation
import os.log

nonisolated final class VPNAgentSignBroker: @unchecked Sendable {
    static let shared = VPNAgentSignBroker()

    private static let logger = Logger(subsystem: "com.kk2.rootshellvpn.tunnel", category: "AgentSignBroker")

    private final class PendingRequest {
        let challenge: VPNAgentSignChallenge
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, VPNAgentBrokerError>?
        var deliveredAt: Date?

        init(challenge: VPNAgentSignChallenge) {
            self.challenge = challenge
        }
    }

    enum VPNAgentBrokerError: LocalizedError {
        case brokerUnavailable
        case timedOut
        case hostReported(String)

        var errorDescription: String? {
            switch self {
            case .brokerUnavailable:
                return "The VPN host isn't polling for signatures (is rootshellvpn running?)"
            case .timedOut:
                return "Timed out waiting for the SSH agent signature."
            case .hostReported(let message):
                return message
            }
        }
    }

    private let lock = NSLock()
    private var pending: [UUID: PendingRequest] = [:]
    /// FIFO of challenges by requestID; delivery order for polls.
    private var queue: [UUID] = []
    private var parkedPoll: ((Data?) -> Void)?
    private var parkedPollTimer: DispatchSourceTimer?
    private var lastPollSeen: Date?

    private let timerQueue = DispatchQueue(label: "vpn.agent.broker.timer")

    // MARK: - Signing (called from the SSH event loop, blocks)

    func sign(socketPath: String, keyBlob: Data, data: Data, flags: UInt32) throws -> Data {
        let challenge = VPNAgentSignChallenge(
            requestID: UUID(),
            socketPath: socketPath,
            keyBlob: keyBlob,
            data: data,
            flags: flags
        )
        let request = PendingRequest(challenge: challenge)

        let (waitSeconds, deliverNow): (TimeInterval, ((Data?) -> Void)?) = lock.withLock {
            pending[challenge.requestID] = request
            queue.append(challenge.requestID)

            // Fast-fail when nothing is polling: without a live host the
            // full sign timeout would stall the reconnect loop for minutes.
            let pollFresh = lastPollSeen.map {
                Date().timeIntervalSince($0) < VPNAgentBrokerMessage.pollWatchdogSeconds
            } ?? false
            let wait = pollFresh
                ? VPNAgentBrokerMessage.signTimeoutSeconds
                : VPNAgentBrokerMessage.brokerAbsentGraceSeconds

            // A poll is parked right now — hand the challenge to it directly.
            if let poll = parkedPoll {
                parkedPoll = nil
                parkedPollTimer?.cancel()
                parkedPollTimer = nil
                markDeliveredLocked(challenge.requestID)
                return (wait, poll)
            }
            return (wait, nil)
        }

        if let deliverNow {
            deliverNow(try? JSONEncoder().encode(challenge))
        }

        Self.logger.info("sign challenge \(challenge.requestID.uuidString.prefix(8), privacy: .public) queued (wait \(Int(waitSeconds))s)")

        let waited = request.semaphore.wait(timeout: .now() + waitSeconds)

        return try lock.withLock {
            pending[challenge.requestID] = nil
            queue.removeAll { $0 == challenge.requestID }

            guard waited == .success, let result = request.result else {
                let pollFresh = lastPollSeen.map {
                    Date().timeIntervalSince($0) < VPNAgentBrokerMessage.pollWatchdogSeconds
                } ?? false
                Self.logger.error("sign challenge \(challenge.requestID.uuidString.prefix(8), privacy: .public) expired (pollFresh=\(pollFresh))")
                throw pollFresh ? VPNAgentBrokerError.timedOut : VPNAgentBrokerError.brokerUnavailable
            }
            switch result {
            case .success(let signature):
                return signature
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: - Provider message handlers (nonisolated NE callbacks)

    /// `agent.poll`: reply immediately with the oldest deliverable challenge,
    /// else park the completion until work arrives or the park timer fires
    /// (empty reply). A newer poll replaces a parked one.
    func handlePoll(_ completion: @escaping (Data?) -> Void) {
        let action: () -> Void = lock.withLock {
            lastPollSeen = Date()

            if let requestID = nextDeliverableLocked() {
                markDeliveredLocked(requestID)
                let payload = pending[requestID].flatMap { try? JSONEncoder().encode($0.challenge) }
                return { completion(payload) }
            }

            // No work: park this poll, replacing (and completing) any
            // previously parked one so NE never accumulates completions.
            let previous = parkedPoll
            parkedPoll = completion
            parkedPollTimer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + VPNAgentBrokerMessage.pollParkSeconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let parked: ((Data?) -> Void)? = self.lock.withLock {
                    let poll = self.parkedPoll
                    self.parkedPoll = nil
                    self.parkedPollTimer = nil
                    return poll
                }
                parked?(Data())
            }
            timer.resume()
            parkedPollTimer = timer

            return { previous?(Data()) }
        }
        action()
    }

    /// `agent.submit <JSON>`: resolve the pending request. Stale or unknown
    /// requestIDs are ignored (the waiter already timed out).
    func handleSubmit(_ json: Data) -> Data {
        guard let submission = try? JSONDecoder().decode(VPNAgentSignSubmission.self, from: json) else {
            Self.logger.error("agent.submit: undecodable payload")
            return Data("bad".utf8)
        }
        lock.withLock {
            guard let request = pending[submission.requestID] else {
                Self.logger.info("agent.submit for unknown/expired request \(submission.requestID.uuidString.prefix(8), privacy: .public)")
                return
            }
            if let signature = submission.signature {
                request.result = .success(signature)
            } else {
                request.result = .failure(.hostReported(
                    submission.error ?? "The SSH agent declined the request."
                ))
            }
            request.semaphore.signal()
        }
        return Data("ok".utf8)
    }

    // MARK: - Locked helpers (callers hold `lock`)

    /// Oldest challenge that is either undelivered or was delivered so long
    /// ago its poll reply was probably dropped by NE (redelivery).
    private func nextDeliverableLocked() -> UUID? {
        for requestID in queue {
            guard let request = pending[requestID], request.result == nil else { continue }
            if let deliveredAt = request.deliveredAt {
                if Date().timeIntervalSince(deliveredAt) > VPNAgentBrokerMessage.pollWatchdogSeconds {
                    return requestID
                }
            } else {
                return requestID
            }
        }
        return nil
    }

    private func markDeliveredLocked(_ requestID: UUID) {
        pending[requestID]?.deliveredAt = Date()
    }
}

#endif
