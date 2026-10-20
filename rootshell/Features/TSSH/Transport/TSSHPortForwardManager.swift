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

    private var forwarderCreation: Task<TSSHForwarderRef, Error>?

    /// Forwards started from the remote-port pill, ready ones by id.
    private var adHocHandles: [UUID: AdHocForwardHandle] = [:]
    private var adHocRemotePorts: [UInt16: UUID] = [:]
    private var adHocWaiters: [UUID: AdHocReadyWaiter] = [:]
    /// Every status-bar forward live on the Go side, with its requested port.
    private var adHocBindPorts: [UUID: Int] = [:]
    /// One start per remote port at a time; a second caller shares it.
    private var adHocStarts: [UInt16: Task<AdHocForwardHandle, Error>] = [:]

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

        let fRef: TSSHForwarderRef
        do {
            fRef = try await ensureForwarder()
        } catch {
            guard !isStopped else { return }
            let msg = error.localizedDescription
            Self.logger.error("Failed to create PortForwarder: \(msg)")
            for forward in config.forwards where forward.enabled {
                updateStatus(forward, .failed("Failed to create forwarder: \(msg)"))
            }
            return
        }
        // The forwarder may be shared with status-bar forwards by now; a
        // cancelled start leaves it to stopAllForwards.
        guard !isStopped, !Task.isCancelled else { return }

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
    }

    /// One Go forwarder per manager, shared by configured and status-bar
    /// forwards. Concurrent callers wait for the same creation.
    private func ensureForwarder() async throws -> TSSHForwarderRef {
        guard !isStopped else { throw PortForwardError.sessionClosed }
        if let forwarderRef { return forwarderRef }
        if let forwarderCreation {
            let ref = try await forwarderCreation.value
            guard !isStopped else { throw PortForwardError.sessionClosed }
            return ref
        }
        let bridge = TrzszGoForwardCallbackBridge(manager: self)
        callbackBridge = bridge
        let transportRef = self.transportRef
        let creation = Task {
            try await TSSHCallGate.shared.newPortForwarder(on: transportRef, callback: bridge)
        }
        forwarderCreation = creation
        defer { forwarderCreation = nil }
        let ref = try await creation.value
        guard !isStopped else {
            await TSSHCallGate.shared.close(ref)
            throw PortForwardError.sessionClosed
        }
        forwarderRef = ref
        return ref
    }

    // MARK: - Ad Hoc Forwarding (status bar)

    func startAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle {
        if let existing = adHocForward(forRemotePort: remotePort) { return existing }
        if let pending = adHocStarts[remotePort] { return try await pending.value }
        let task = Task {
            try await self.startAdHocForward(
                remoteHost: remoteHost, remotePort: remotePort, preferredLocalPort: preferredLocalPort
            )
        }
        adHocStarts[remotePort] = task
        defer {
            if adHocStarts[remotePort] == task { adHocStarts.removeValue(forKey: remotePort) }
        }
        return try await task.value
    }

    func adHocForward(forRemotePort remotePort: UInt16) -> AdHocForwardHandle? {
        adHocRemotePorts[remotePort].flatMap { adHocHandles[$0] }
    }

    func stopAdHocLocalForward(_ handle: AdHocForwardHandle) async {
        guard adHocHandles.removeValue(forKey: handle.id) != nil else { return }
        if adHocRemotePorts[handle.remotePort] == handle.id {
            adHocRemotePorts.removeValue(forKey: handle.remotePort)
        }
        adHocBindPorts.removeValue(forKey: handle.id)
        guard let forwarderRef else { return }
        await TSSHCallGate.shared.stopForward(on: forwarderRef, forwardID: handle.id.uuidString)
    }

    private func startAdHocForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle {
        // Go's listener sets SO_REUSEADDR, so a port a local server already
        // listens on would bind anyway and shadow it; check first.
        if let preferredLocalPort, LoopbackPort.isFree(preferredLocalPort) {
            do {
                return try await attemptAdHocForward(
                    remoteHost: remoteHost, remotePort: remotePort, bindPort: Int(preferredLocalPort)
                )
            } catch PortForwardError.bindFailed {
                // Taken between the check and Go's bind.
            }
        }
        return try await attemptAdHocForward(remoteHost: remoteHost, remotePort: remotePort, bindPort: 0)
    }

    private func attemptAdHocForward(
        remoteHost: String,
        remotePort: UInt16,
        bindPort: Int
    ) async throws -> AdHocForwardHandle {
        let id = UUID()
        let waiter = AdHocReadyWaiter()
        adHocWaiters[id] = waiter
        adHocBindPorts[id] = bindPort
        var startedOn: TSSHForwarderRef?
        do {
            let ref = try await ensureForwarder()
            startedOn = ref
            let params = TSSHForwardParams(
                forwardID: id.uuidString,
                direction: "local",
                bindAddress: "127.0.0.1",
                bindPort: bindPort,
                targetHost: remoteHost,
                targetPort: Int(remotePort),
                recoverRemoteListener: false
            )
            try await TSSHCallGate.shared.startForward(on: ref, params)
            let actualPort = try await waiter.wait(timeout: 10)
            guard !isStopped else { throw PortForwardError.sessionClosed }
            guard let localPort = UInt16(exactly: actualPort), localPort > 0 else {
                throw PortForwardError.invalidConfiguration("Forwarder returned an invalid local port")
            }
            let handle = AdHocForwardHandle(id: id, remotePort: remotePort, localPort: localPort)
            adHocHandles[id] = handle
            adHocRemotePorts[remotePort] = id
            return handle
        } catch {
            adHocWaiters.removeValue(forKey: id)
            adHocBindPorts.removeValue(forKey: id)
            // A listener that comes up after the deadline would otherwise
            // hold the port with nothing able to reach or stop it.
            if let startedOn {
                await TSSHCallGate.shared.stopForward(on: startedOn, forwardID: id.uuidString)
            }
            throw error
        }
    }

    /// Status-bar forwards stay out of the configured forwards' status and
    /// connection-death accounting. Returns false for any other forward.
    private func handleAdHocEvent(_ event: ForwardCallbackEvent) -> Bool {
        let idString: String
        switch event {
        case .ready(let id, _), .error(let id, _), .stopped(let id), .opened(let id, _), .closed(let id, _, _, _):
            idString = id
        }
        guard let id = UUID(uuidString: idString), let bindPort = adHocBindPorts[id] else { return false }
        switch event {
        case .ready(_, let actualPort):
            adHocWaiters.removeValue(forKey: id)?.resolve(.success(actualPort))
        case .error(_, let message):
            // Before ready this is the listen failing; later errors are
            // single connections whose dial failed.
            let underlying = NSError(
                domain: "TrzszPortForward", code: -1, userInfo: [NSLocalizedDescriptionKey: message]
            )
            adHocWaiters.removeValue(forKey: id)?
                .resolve(.failure(PortForwardError.bindFailed(port: bindPort, underlying: underlying)))
        case .stopped:
            adHocWaiters.removeValue(forKey: id)?.resolve(.failure(PortForwardError.sessionClosed))
            adHocBindPorts.removeValue(forKey: id)
            if let handle = adHocHandles.removeValue(forKey: id),
               adHocRemotePorts[handle.remotePort] == id {
                adHocRemotePorts.removeValue(forKey: handle.remotePort)
            }
        case .opened, .closed:
            break
        }
        return true
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
        for waiter in adHocWaiters.values {
            waiter.resolve(.failure(PortForwardError.sessionClosed))
        }
        adHocWaiters.removeAll()
        adHocHandles.removeAll()
        adHocRemotePorts.removeAll()
        adHocBindPorts.removeAll()
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
        guard !isStopped, !handleAdHocEvent(event) else { return }
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
