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
    private var forwarderRef: TSSHForwarderRef?
    private var callbackBridge: TrzszGoForwardCallbackBridge?

    /// Status of each forward
    private var forwardStatus: [UUID: PortForwardStatus] = [:]

    /// Map forward ID string back to UUID for lookups
    private var forwardIDMap: [String: UUID] = [:]

    /// Map forward ID to PortForward config for callbacks
    private var forwardConfigMap: [UUID: PortForwardConfig.PortForward] = [:]

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

    init(transportRef: TSSHTransportRef, config: PortForwardConfig) {
        self.transportRef = transportRef
        self.config = config

        // Build lookup maps
        for forward in config.forwards where forward.enabled {
            let idString = forward.id.uuidString
            forwardIDMap[idString] = forward.id
            forwardConfigMap[forward.id] = forward
        }
    }

    // MARK: - Public Methods

    func startAllForwards() async {
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
        self.forwarderRef = fRef

        for forward in config.forwards where forward.enabled {
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
                targetPort: forward.targetPort
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
        Self.logger.info("Stopping all TSSH port forwards")

        let priorForwarder = forwarderRef
        forwarderRef = nil
        callbackBridge = nil

        for forward in config.forwards {
            updateStatus(forward, .stopped)
            if forward.direction == .dynamic {
                SOCKSPortRegistry.shared.release(port: forward.bindPort, forwardID: forward.id)
            }
        }

        // Use the gate's emergency close path so a wedged transport call on
        // the serial executor cannot prevent the forwarder from being torn
        // down. PortForwarder.Close() is documented as safe to call
        // independently of any in-flight transport call.
        if let priorForwarder {
            TSSHCallGate.shared.emergencyClosePortForwarder(priorForwarder)
        }
    }

    func status(for forward: PortForwardConfig.PortForward) -> PortForwardStatus {
        forwardStatus[forward.id] ?? .pending
    }

    // MARK: - Callback Routing (called from TrzszGoForwardCallbackBridge)

    func handleCallbackEvent(_ event: ForwardCallbackEvent) {
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

