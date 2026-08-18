//
//  VPNTunnelController.swift
//  rootshellvpn (VPN host)
//
//  Owns the NETunnelProviderManager for the packet-tunnel system extension.
//  The host carries the packet-tunnel-provider entitlement as a native app, so
//  it can legally configure/start the tunnel (the Catalyst app cannot). The
//  Catalyst app resolves the profile + secrets and hands us a ready
//  `VPNResolvedConfig` blob, which we forward to the sysext via startTunnel
//  options (ephemeral, not persisted).
//

import Foundation
import NetworkExtension
import os
import os.log

@MainActor
final class VPNTunnelController {
    static let shared = VPNTunnelController()
    static let providerBundleID = "com.kk2.rootshellvpn.tunnel"
    static let serverAddress = "rootshell VPN"

    private let log = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "manager")

    private func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first ?? NETunnelProviderManager()
    }

    /// Configure + start the tunnel. `resolvedConfig` is the opaque
    /// JSON-encoded `VPNResolvedConfig` from the Catalyst app.
    /// `usesAgentSigning` runs the agent signing broker loop alongside the
    /// tunnel (agent-backed SSH key; the sysext asks us for signatures).
    func start(profileID: UUID, transportType: String, resolvedConfig: Data, usesAgentSigning: Bool = false) async throws {
        var manager = try await loadManager()

        // Idempotent start: calling startVPNTunnel on a live session throws, and
        // the app can legitimately re-issue a start it believes was lost (e.g.
        // after an app relaunch). Same profile → already done. Different profile
        // → stop the old tunnel and wait for it to wind down before starting.
        let status = manager.connection.status
        if status == .connected || status == .connecting || status == .reasserting {
            let activeProfile = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration?["profileID"] as? String
            if activeProfile == profileID.uuidString {
                log.info("start: tunnel already \(String(describing: status.rawValue), privacy: .public) for this profile; no-op")
                // Still reconcile the signing broker: the loop may have
                // exited (e.g. host launched while the tunnel looked down,
                // or the loop gave up during a long outage) and without it
                // agent-backed reauth is impossible.
                if usesAgentSigning {
                    VPNAgentBrokerLoop.shared.start()
                } else {
                    VPNAgentBrokerLoop.shared.stop()
                }
                return
            }
            log.info("start: stopping active tunnel for profile switch")
            manager.connection.stopVPNTunnel()
            for _ in 0..<50 {   // ~10s
                try? await Task.sleep(for: .milliseconds(200))
                manager = try await loadManager()
                let s = manager.connection.status
                if s == .disconnected || s == .invalid { break }
            }
        }

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = Self.serverAddress
        proto.providerConfiguration = [
            "profileID": profileID.uuidString as NSString,
            "transportType": transportType as NSString,
            // Persisted (non-secret) so a relaunched host knows to resume
            // the agent broker loop for a still-running tunnel.
            "usesAgentSigning": NSNumber(value: usesAgentSigning),
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.serverAddress
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        // Secrets travel through options (not persisted), unlike providerConfiguration.
        try manager.connection.startVPNTunnel(options: [
            "profileID": profileID.uuidString as NSString,
            "transportType": transportType as NSString,
            "resolvedConfig": resolvedConfig as NSData,
        ])
        log.info("startVPNTunnel issued for profile \(profileID.uuidString.prefix(8), privacy: .public)")

        if usesAgentSigning {
            VPNAgentBrokerLoop.shared.start()
        } else {
            VPNAgentBrokerLoop.shared.stop()
        }
    }

    func stop() async throws {
        let manager = try await loadManager()
        manager.connection.stopVPNTunnel()
        VPNAgentBrokerLoop.shared.stop()
        log.info("stopVPNTunnel issued")
    }

    /// Resume the agent broker after a host relaunch when the persisted
    /// configuration says the live tunnel signs via an agent. Called at
    /// startup; harmless when no tunnel is up (the loop exits on its own).
    func resumeAgentBrokerIfNeeded() async {
        guard let manager = try? await loadManager(),
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let flag = proto.providerConfiguration?["usesAgentSigning"] as? NSNumber,
              flag.boolValue else { return }
        let status = manager.connection.status
        guard status == .connected || status == .connecting || status == .reasserting else { return }
        log.info("resuming agent broker loop for live tunnel after host launch")
        VPNAgentBrokerLoop.shared.start()
    }

    /// Profile the current NE configuration was started for. Drives app-side
    /// session restore after an app relaunch (the app can't read our config).
    func activeProfileID() async -> UUID? {
        guard let manager = try? await loadManager(),
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let raw = proto.providerConfiguration?["profileID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    func statusString() async -> String {
        guard let manager = try? await loadManager() else { return "invalid" }
        switch manager.connection.status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    /// Ask the provider for its rich status/stats JSON (same `getStatus` message
    /// the iOS appex answers), to relay to the app. nil unless connected.
    ///
    /// Guarded by a hard timeout: if the provider reply never arrives the
    /// request must still complete, or the app's status call (and its stats
    /// polling) wedges indefinitely.
    func providerStatusJSON() async -> String? {
        guard let manager = try? await loadManager() else {
            log.error("providerStatusJSON: loadManager failed")
            return nil
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            log.error("providerStatusJSON: connection is not NETunnelProviderSession")
            return nil
        }
        guard session.status == .connected || session.status == .reasserting else {
            let raw = session.status.rawValue
            log.info("providerStatusJSON: session status \(raw), skipping")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            // Returns true only for the first caller; exactly one resume.
            let finish: @Sendable (String?) -> Bool = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
                return first
            }
            do {
                try session.sendProviderMessage(Data("getStatus".utf8)) { data in
                    if data == nil {
                        Self.timeoutLog.error("provider getStatus completion delivered nil data")
                    }
                    _ = finish(data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                self.log.error("sendProviderMessage failed: \(error.localizedDescription, privacy: .public)")
                _ = finish(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if finish(nil) {
                    Self.timeoutLog.error("provider getStatus reply timed out after 5s")
                }
            }
        }
    }

    // Reachable from the timeout closure without hopping to the main actor.
    nonisolated private static let timeoutLog = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "manager")
}
