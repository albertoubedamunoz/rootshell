//
//  VPNConnectionPoller.swift
//  rootshell
//
//  Shared VPN connect/disconnect polling for the app's Shortcuts intents
//  and the widget extension's button/Control Center intents. Watches the
//  shared widget-state file (written by the tunnel extension) plus the
//  system VPN status until a terminal state or timeout. Live Activity
//  syncing stays in the widget-side callers — this file compiles into both
//  targets and depends only on the shared VPN state types.
//

import Foundation
import NetworkExtension

nonisolated enum VPNConnectionPoller {

    enum ConnectOutcome {
        case connected, failed, timeout
        /// Tailscale came up but wants a login only the app can show.
        case needsSignIn
    }

    enum DisconnectOutcome {
        case disconnected, timeout
    }

    /// Polls until the tunnel reports connected, fails, or `deadline` passes.
    ///
    /// - Parameters:
    ///   - writeConnectedState: write the connected snapshot to the shared
    ///     state file when the *system* status reports connected first (the
    ///     extension normally writes it; widget surfaces want the fallback).
    ///   - treatUnknownFinalStatusAsFailed: on timeout with an unreadable
    ///     system status, report failure (widget surfaces) instead of
    ///     leaving the "connecting" state visible (app Shortcut).
    static func pollForConnection(
        snapshot: VPNSharedProfileSnapshot,
        writeConnectedState: Bool,
        treatUnknownFinalStatusAsFailed: Bool,
        seconds: Int64 = 15
    ) async -> ConnectOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)

        while clock.now < deadline, !Task.isCancelled {
            if let state = VPNWidgetState.read(),
               state.profileID == snapshot.id,
               state.status == "connected",
               let outcome = readiness(of: snapshot) {
                return outcome
            }

            let status = await systemVPNStatus()
            if status == .connected, let outcome = readiness(of: snapshot) {
                if writeConnectedState, outcome == .connected {
                    self.writeConnectedState(snapshot: snapshot)
                }
                return outcome
            }
            if status == .disconnected || status == .invalid {
                writeDisconnectedState()
                return .failed
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        // Timeout: check one last time
        var tunnelUp = false
        if let state = VPNWidgetState.read(),
           state.profileID == snapshot.id,
           state.status == "connected" {
            if let outcome = readiness(of: snapshot) { return outcome }
            tunnelUp = true
        }
        let finalStatus = await systemVPNStatus()
        if finalStatus == .connected {
            // Up, but Tailscale may still be starting: report it as connecting.
            guard let outcome = readiness(of: snapshot) else { return .timeout }
            if writeConnectedState, outcome == .connected {
                self.writeConnectedState(snapshot: snapshot)
            }
            return outcome
        }
        // Tailscale is still starting in a running tunnel; the extension
        // refreshes widgets when it decides, so keep the connected state.
        if tunnelUp, finalStatus != .disconnected, finalStatus != .invalid {
            return .timeout
        }
        if finalStatus == .disconnected || finalStatus == .invalid
            || (finalStatus == nil && treatUnknownFinalStatusAsFailed) {
            writeDisconnectedState()
            return .failed
        }
        // Still connecting → shared state stays "connecting"
        return .timeout
    }

    /// Polls until the tunnel finishes disconnecting or `deadline` passes.
    /// Writes the disconnected state when the manager reports a terminal
    /// status. `checkSharedState` also accepts the extension's own
    /// "disconnected" write as the completion signal (widget surfaces).
    static func pollForDisconnection(
        manager: NETunnelProviderManager,
        checkSharedState: Bool,
        seconds: Int64 = 5
    ) async -> DisconnectOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)

        while clock.now < deadline, !Task.isCancelled {
            if checkSharedState,
               let state = VPNWidgetState.read(),
               state.status == "disconnected" {
                return .disconnected
            }

            let status = manager.connection.status
            if status == .disconnected || status == .invalid {
                writeDisconnectedState()
                return .disconnected
            }

            try? await Task.sleep(for: .milliseconds(300))
        }

        // Timeout: settle on the final status as best guess
        let finalStatus = manager.connection.status
        if finalStatus == .disconnected || finalStatus == .invalid {
            writeDisconnectedState()
            return .disconnected
        }
        // Still disconnecting; the timeline provider times the state out.
        return .timeout
    }

    // MARK: - Helpers

    /// `.connected` once the tunnel is usable. Tailscale waits for this session
    /// to reach Running (nil until then) or to ask for a login.
    private static func readiness(of snapshot: VPNSharedProfileSnapshot) -> ConnectOutcome? {
        guard snapshot.transportType == .tailscale else { return .connected }
        let login = VPNTailnetProfile.loginState()
        if login.state == "Running" { return .connected }
        return login.needsLogin ? .needsSignIn : nil
    }

    static func systemVPNStatus() async -> NEVPNStatus? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            return managers.first?.connection.status
        } catch {
            return nil
        }
    }

    static func writeConnectedState(snapshot: VPNSharedProfileSnapshot) {
        VPNWidgetState.write(
            VPNWidgetState(
                status: "connected",
                profileID: snapshot.id,
                profileName: snapshot.name,
                host: snapshot.host,
                connectedSince: Date(),
                lastUpdated: Date()
            )
        )
    }

    static func writeDisconnectedState() {
        VPNWidgetState.write(
            VPNWidgetState(
                status: "disconnected",
                profileID: nil,
                profileName: nil,
                host: nil,
                connectedSince: nil,
                lastUpdated: Date()
            )
        )
    }

    /// Marks the shared state "disconnecting", preserving profile fields.
    static func writeDisconnectingState() {
        var state = VPNWidgetState.read() ?? VPNWidgetState(
            status: "disconnecting",
            profileID: nil,
            profileName: nil,
            host: nil,
            connectedSince: nil,
            lastUpdated: Date()
        )
        state.status = "disconnecting"
        state.connectedSince = nil
        state.lastUpdated = Date()
        VPNWidgetState.write(state)
    }
}
