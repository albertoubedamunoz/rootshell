//
//  TSSHPortForwardManager.swift
//  rootshell
//
//  Port forward manager for TSSH (KCP/QUIC) transports.
//  All Swift→Go calls funnel through `TSSHCallGate.shared`. This file does
//  not import `TrzszSSH` directly; it holds a `TSSHTransportRef` and a
//  `TSSHForwarderRef` vended by the gate.
//

import Foundation
import os
import OSLog

/// Manages active port forwards over a TSSH transport
@MainActor
final class TrzszPortForwardManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TrzszPortForwardManager")

    private let transportRef: TSSHTransportRef
    private let config: PortForwardConfig
    private let recoveringRemoteForwards: Set<UUID>
    private var forwarderRef: TSSHForwarderRef?
    private var callbackBridge: TrzszGoForwardCallbackBridge?
    private var isStopped = false
    /// A stopped callback does not prove that a deployed server released -R.
    private var boundRemoteForwards: Set<UUID> = []

    /// Status of each forward
    private var forwardStatus: [UUID: PortForwardStatus] = [:]

    /// Map forward ID string back to UUID for lookups
    private var forwardIDMap: [String: UUID] = [:]

    /// Map forward ID to PortForward config for callbacks
    private var forwardConfigMap: [UUID: PortForwardConfig.PortForward] = [:]

    /// Forwards started from the remote-port pill. The Go forwarder has no
    /// per-forward stop, so these live until the session (and forwarder) ends.
    private var adHocHandles: [UUID: AdHocForwardHandle] = [:]
    private var adHocRemotePorts: [UInt16: UUID] = [:]
    private var adHocWaiters: [UUID: AdHocReadyWaiter] = [:]

    /// Race-free readiness: the callback may fire before the caller awaits.
    @MainActor
    private final class AdHocReadyWaiter {
        private var result: Result<Int, Error>?
        private var continuation: CheckedContinuation<Int, Error>?

        func resolve(_ result: Result<Int, Error>) {
            if let continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                self.result = result
            }
        }

        func wait(timeout: TimeInterval) async throws -> Int {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.resolve(.failure(TimeoutError(seconds: timeout)))
                }
            }
        }
    }

    // MARK: - Callbacks (same interface as PortForwardManager)

    var onForwardError: ((PortForwardConfig.PortForward, Error) -> Void)?
    var onForwardStatusChange: ((PortForwardConfig.PortForward, PortForwardStatus) -> Void)?
    var onBytesReceived: (@Sendable (UUID, Int) -> Void)?
    var onBytesSent: (@Sendable (UUID, Int) -> Void)?
    var onConnectionOpened: ((UUID) -> Void)?
    var onConnectionClosed: ((UUID) -> Void)?
    var onConnectionDead: (() -> Void)?

    /// Count of consecutive errors indicating connection death
    private var consecutiveErrors: Int = 0
    private static let errorThreshold = 3

    // MARK: - Init

    init(transportRef: TSSHTransportRef, config: PortForwardConfig, recoveringRemoteForwards: Set<UUID> = []) {
        self.transportRef = transportRef
        self.config = config
        self.recoveringRemoteForwards = recoveringRemoteForwards

        // Build lookup maps
        for forward in config.forwards where forward.enabled {
            let idString = forward.id.uuidString
            forwardIDMap[idString] = forward.id
            forwardConfigMap[forward.id] = forward
        }
    }

    // MARK: - Public Methods

    func startAllForwards() async {
        guard !isStopped else { return }
        Self.logger.info("Starting \(self.config.forwards.count) port forwards via TSSH")

        let bridge = TrzszGoForwardCallbackBridge(manager: self)
        self.callbackBridge = bridge

        let fRef: TSSHForwarderRef
        do {
            fRef = try await TSSHCallGate.shared.newPortForwarder(on: transportRef, callback: bridge)
        } catch {
            let msg = error.localizedDescription
            Self.logger.error("Failed to create PortForwarder: \(msg)")
            for forward in config.forwards where forward.enabled {
                updateStatus(forward, .failed("Failed to create forwarder: \(msg)"))
            }
            return
        }
        guard !isStopped, !Task.isCancelled else {
            await TSSHCallGate.shared.close(fRef)
            return
        }
        self.forwarderRef = fRef

        for forward in config.forwards where forward.enabled {
            guard !isStopped, !Task.isCancelled else { return }
            updateStatus(forward, .pending)

            // For dynamic forwards, check port registry first
            if forward.direction == .dynamic {
                guard SOCKSPortRegistry.shared.claim(port: forward.bindPort, forwardID: forward.id) else {
                    Self.logger.info("SOCKS5 port \(forward.bindPort) handled by another session")
                    updateStatus(forward, .active)
                    continue
                }
            }

            let directionString: String = switch forward.direction {
            case .local: "local"
            case .remote: "remote"
            case .dynamic: "dynamic"
            }
            let params = TSSHForwardParams(
                forwardID: forward.id.uuidString,
                direction: directionString,
                bindAddress: forward.bindAddress,
                bindPort: forward.bindPort,
                targetHost: forward.targetHost,
                targetPort: forward.targetPort,
                recoverRemoteListener: forward.direction == .remote && recoveringRemoteForwards.contains(forward.id)
            )

            do {
                try await TSSHCallGate.shared.startForward(on: fRef, params)
            } catch {
                let msg = error.localizedDescription
                Self.logger.error("Failed to start forward \(forward.displayString): \(msg)")
                updateStatus(forward, .failed(msg))
                if forward.direction == .dynamic {
                    SOCKSPortRegistry.shared.release(port: forward.bindPort, forwardID: forward.id)
                }
                onForwardError?(forward, error)
            }
        }
    }

    func stopAllForwards() {
        // Use the gate's emergency close path so a wedged transport call on
        // the serial executor cannot prevent the forwarder from being torn
        // down. PortForwarder.Close() is documented as safe to call
        // independently of any in-flight transport call.
        if let priorForwarder = detachForwarder() {
            TSSHCallGate.shared.emergencyClosePortForwarder(priorForwarder)
        }
        for waiter in adHocWaiters.values {
            waiter.resolve(.failure(PortForwardError.sessionClosed))
        }
        adHocWaiters.removeAll()
        adHocHandles.removeAll()
        adHocRemotePorts.removeAll()
    }

    // MARK: - Ad Hoc Forwarding (status bar)

    private func ensureForwarder() async throws -> TSSHForwarderRef {
        if let forwarderRef { return forwarderRef }
        let bridge = TrzszGoForwardCallbackBridge(manager: self)
        callbackBridge = bridge
        let ref = try await TSSHCallGate.shared.newPortForwarder(on: transportRef, callback: bridge)
        guard !isStopped, !Task.isCancelled else {
            await TSSHCallGate.shared.close(ref)
            throw CancellationError()
        }
        forwarderRef = ref
        return ref
    }

    func startAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle {
        if let existingID = adHocRemotePorts[remotePort],
           let existing = adHocHandles[existingID] {
            return existing
        }

        let id = UUID()
        let waiter = AdHocReadyWaiter()
        adHocWaiters[id] = waiter

        let forward = PortForwardConfig.PortForward(
            direction: .local,
            bindAddress: "127.0.0.1",
            bindPort: Int(preferredLocalPort ?? 0),
            targetHost: remoteHost,
            targetPort: Int(remotePort)
        )
        forwardIDMap[id.uuidString] = id
        forwardConfigMap[id] = forward

        do {
            let ref = try await ensureForwarder()
            let params = TSSHForwardParams(
                forwardID: id.uuidString,
                direction: "local",
                bindAddress: "127.0.0.1",
                bindPort: forward.bindPort,
                targetHost: remoteHost,
                targetPort: Int(remotePort),
                recoverRemoteListener: false
            )
            try await TSSHCallGate.shared.startForward(on: ref, params)
            let actualPort = try await waiter.wait(timeout: 10)
            guard let localPort = UInt16(exactly: actualPort), localPort > 0 else {
                throw PortForwardError.invalidConfiguration("Forwarder returned an invalid local port")
            }
            let handle = AdHocForwardHandle(
                id: id,
                remotePort: remotePort,
                localPort: localPort,
                canStop: false
            )
            adHocWaiters.removeValue(forKey: id)
            adHocHandles[id] = handle
            adHocRemotePorts[remotePort] = id
            return handle
        } catch {
            adHocWaiters.removeValue(forKey: id)
            forwardIDMap.removeValue(forKey: id.uuidString)
            forwardConfigMap.removeValue(forKey: id)

            // A busy preferred port is the common failure; any other error
            // (including an ephemeral-port bind failing) is surfaced.
            if let preferredLocalPort, preferredLocalPort > 0 {
                return try await startAdHocLocalForward(
                    remoteHost: remoteHost,
                    remotePort: remotePort,
                    preferredLocalPort: nil
                )
            }
            throw error
        }
    }

    func stopAdHocLocalForward(_ handle: AdHocForwardHandle) async {
        // The Go forwarder cannot stop one listener without stopping them
        // all. Dropping the handle here would leave a live listener with no
        // way to reach it, so the forward lives until the session ends; the
        // handle marks itself non-stoppable and the UI hides that action.
        guard adHocHandles.removeValue(forKey: handle.id) != nil else { return }
        if adHocRemotePorts[handle.remotePort] == handle.id {
            adHocRemotePorts.removeValue(forKey: handle.remotePort)
        }
    }


    /// Wait for client listeners to close and remember remote listeners that
    /// may still be bound on deployed servers. The replacement forwarder must
    /// wake those listeners and receive a successful remote bind acknowledgment.
    func stopAllForwardsAndWait() async -> Set<UUID> {
        let remoteIDs = Set(config.forwards.compactMap { forward -> UUID? in
            guard forward.enabled, forward.direction == .remote else { return nil }
            return boundRemoteForwards.contains(forward.id) || forwardStatus[forward.id] == .pending
                ? forward.id : nil
        })
        if let priorForwarder = detachForwarder() {
            await TSSHCallGate.shared.close(priorForwarder)
        }
        return remoteIDs
    }

    private func detachForwarder() -> TSSHForwarderRef? {
        Self.logger.info("Stopping all TSSH port forwards")
        isStopped = true
        let priorForwarder = forwarderRef
        forwarderRef = nil
        callbackBridge = nil
        for forward in config.forwards {
            updateStatus(forward, .stopped)
            if forward.direction == .dynamic {
                SOCKSPortRegistry.shared.release(port: forward.bindPort, forwardID: forward.id)
            }
        }
        return priorForwarder
    }

    func status(for forward: PortForwardConfig.PortForward) -> PortForwardStatus {
        forwardStatus[forward.id] ?? .pending
    }

    // MARK: - Callback Routing (called from TrzszGoForwardCallbackBridge)

    func handleCallbackEvent(_ event: ForwardCallbackEvent) {
        guard !isStopped else { return }
        switch event {
        case .ready(let idString, let actualPort):
            handleForwardReady(idString: idString, actualPort: actualPort)
        case .error(let idString, let message):
            handleForwardError(idString: idString, message: message)
        case .stopped(let idString):
            handleForwardStopped(idString: idString)
        case .opened(let idString, let connectionID):
            handleConnectionOpened(idString: idString, connectionID: connectionID)
        case .closed(let idString, let connectionID, let bytesIn, let bytesOut):
            handleConnectionClosed(idString: idString, connectionID: connectionID, bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }

    fileprivate func handleForwardReady(idString: String, actualPort: Int) {
        guard let uuid = forwardIDMap[idString],
              let forward = forwardConfigMap[uuid] else { return }
        consecutiveErrors = 0
        if forward.direction == .remote { boundRemoteForwards.insert(forward.id) }
        let portInfo = actualPort
        Self.logger.info("Forward ready: \(forward.displayString) on port \(portInfo)")
        updateStatus(forward, .active)
        adHocWaiters.removeValue(forKey: uuid)?.resolve(.success(actualPort))
    }

    fileprivate func handleForwardError(idString: String, message: String) {
        guard let uuid = forwardIDMap[idString],
              let forward = forwardConfigMap[uuid] else {
            // Unknown forward ID — still count toward connection death
            consecutiveErrors += 1
            if consecutiveErrors >= Self.errorThreshold {
                Self.logger.error("Connection appears dead after \(self.consecutiveErrors) consecutive errors")
                onConnectionDead?()
            }
            return
        }

        Self.logger.error("Forward error for \(forward.displayString): \(message)")
        consecutiveErrors += 1

        let error = PortForwardError.connectionFailed(
            target: "\(forward.targetHost):\(forward.targetPort)",
            underlying: NSError(domain: "TrzszPortForward", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        )
        onForwardError?(forward, error)
        adHocWaiters.removeValue(forKey: uuid)?.resolve(.failure(error))

        if consecutiveErrors >= Self.errorThreshold {
            Self.logger.error("Connection appears dead after \(self.consecutiveErrors) consecutive errors")
            onConnectionDead?()
        }
    }

    fileprivate func handleForwardStopped(idString: String) {
        guard let uuid = forwardIDMap[idString],
              let forward = forwardConfigMap[uuid] else { return }
        if forward.direction == .dynamic {
            SOCKSPortRegistry.shared.release(port: forward.bindPort, forwardID: forward.id)
        }
        updateStatus(forward, .stopped)
        adHocWaiters.removeValue(forKey: uuid)?.resolve(.failure(PortForwardError.sessionClosed))
    }

    fileprivate func handleConnectionOpened(idString: String, connectionID: Int64) {
        guard let uuid = forwardIDMap[idString] else { return }
        consecutiveErrors = 0
        onConnectionOpened?(uuid)
    }

    fileprivate func handleConnectionClosed(idString: String, connectionID: Int64, bytesIn: Int64, bytesOut: Int64) {
        guard let uuid = forwardIDMap[idString] else { return }
        if bytesIn > 0 {
            onBytesReceived?(uuid, Int(bytesIn))
        }
        if bytesOut > 0 {
            onBytesSent?(uuid, Int(bytesOut))
        }
        onConnectionClosed?(uuid)
    }

    // MARK: - Status Management

    private func updateStatus(_ forward: PortForwardConfig.PortForward, _ status: PortForwardStatus) {
        forwardStatus[forward.id] = status
        onForwardStatusChange?(forward, status)
    }
}

// MARK: - AdHocForwarding

extension TrzszPortForwardManager: AdHocForwarding {}
