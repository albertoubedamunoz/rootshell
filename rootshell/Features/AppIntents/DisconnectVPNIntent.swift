//
//  DisconnectVPNIntent.swift
//  rootshell
//
//  Shortcuts action that disconnects the active VPN.
//

import AppIntents
import NetworkExtension
import WidgetKit

/// Shortcuts action: disconnect the currently active VPN tunnel.
struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect VPN"
    static var description: IntentDescription = "Disconnects the currently active VPN tunnel."
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first else {
            return .result(
                value: "No VPN connected",
                dialog: "No VPN is currently connected."
            )
        }

        let status = manager.connection.status
        guard status == .connected || status == .connecting || status == .reasserting else {
            return .result(
                value: "No VPN connected",
                dialog: "No VPN is currently connected."
            )
        }

        let profileName = VPNWidgetState.read()?.profileName ?? "VPN"

        manager.connection.stopVPNTunnel()

        // Write disconnecting state so widget picks it up
        VPNConnectionPoller.writeDisconnectingState()
        reloadWidgets()

        // Poll until disconnected (writes the disconnected state on success)
        let outcome = await VPNConnectionPoller.pollForDisconnection(
            manager: manager,
            checkSharedState: false
        )
        let didDisconnect = outcome == .disconnected
        reloadWidgets()

        if didDisconnect {
            return .result(
                value: "Disconnected",
                dialog: "Disconnected from \(profileName)."
            )
        } else {
            return .result(
                value: "Disconnecting",
                dialog: "Disconnecting from \(profileName)…"
            )
        }
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif
    }
}
