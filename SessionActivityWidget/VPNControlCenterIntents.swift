//
//  VPNControlCenterIntents.swift
//  SessionActivityWidget
//
//  AppIntents for the Control Center VPN toggle:
//  - Configuration intent for profile selection
//  - SetValueIntent for toggling the VPN on/off
//

import AppIntents
import NetworkExtension
import os.log
import WidgetKit

// MARK: - Configuration Intent

/// Lets the user pick which VPN profile the Control Center toggle controls.
struct VPNControlCenterConfigurationIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select VPN Profile"
    static var description: IntentDescription = "Choose which VPN profile to toggle from Control Center."

    @Parameter(title: "VPN Profile")
    var profile: VPNWidgetProfileEntity?
}

// MARK: - Toggle Intent

/// Handles toggling the VPN on or off from Control Center.
struct ToggleVPNIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Toggle VPN"
    static var description: IntentDescription = "Connects or disconnects the VPN."

    private static let logger = Logger(subsystem: "com.rootshell", category: "ToggleVPNIntent")
    private static let controlKind = "VPNControlCenterToggle"
    private static let widgetKind = "VPNControlWidget"

    @Parameter(title: "VPN On")
    var value: Bool

    @Parameter(title: "Profile ID")
    var profileID: String

    init() {}

    init(profileID: String) {
        self.profileID = profileID
    }

    func perform() async throws -> some IntentResult {
        if value {
            try await connectVPN()
        } else {
            await disconnectVPN()
        }

        ControlCenter.shared.reloadControls(ofKind: Self.controlKind)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        await VPNLiveActivityUpdater.syncFromWidgetState()
        return .result()
    }

    // MARK: - Connect

    private func connectVPN() async throws {
        guard let uuid = UUID(uuidString: profileID) else {
            Self.logger.error("ToggleVPNIntent: invalid profile ID")
            return
        }

        guard let snapshot = VPNSharedProfileStore.profile(id: uuid) else {
            Self.logger.error("ToggleVPNIntent: missing snapshot for \(profileID)")
            return
        }

        do {
            let result = try await VPNStartController.start(profileID: uuid)
            switch result {
            case .alreadyActive:
                Self.logger.info("ToggleVPNIntent: already active \(profileID)")
            case .started:
                Self.logger.info("ToggleVPNIntent: started \(profileID)")
            }
        } catch {
            Self.logger.error("ToggleVPNIntent connect failed: \(error.localizedDescription)")
            ControlCenter.shared.reloadControls(ofKind: Self.controlKind)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
            return
        }

        // Reload immediately to show connecting state
        ControlCenter.shared.reloadControls(ofKind: Self.controlKind)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        await VPNLiveActivityUpdater.syncFromWidgetState()

        // Poll until connected or failed (up to 15s)
        let outcome = await VPNConnectionPoller.pollForConnection(
            snapshot: snapshot,
            writeConnectedState: true,
            treatUnknownFinalStatusAsFailed: true
        )
        switch outcome {
        case .connected:
            await VPNLiveActivityUpdater.syncFromWidgetState()
        case .failed:
            await VPNLiveActivityUpdater.clearVPNState()
        case .timeout:
            break
        }
    }

    // MARK: - Disconnect

    private func disconnectVPN() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else {
                Self.logger.error("ToggleVPNIntent: no manager found")
                return
            }

            manager.connection.stopVPNTunnel()

            VPNConnectionPoller.writeDisconnectingState()
            await VPNLiveActivityUpdater.syncFromWidgetState()

            // Intermediate reload so the *other* surface (widget) updates promptly
            ControlCenter.shared.reloadControls(ofKind: Self.controlKind)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)

            Self.logger.info("ToggleVPNIntent: stopping")

            // Poll until disconnected (up to 5s)
            let outcome = await VPNConnectionPoller.pollForDisconnection(
                manager: manager,
                checkSharedState: true
            )
            if outcome == .disconnected {
                await VPNLiveActivityUpdater.clearVPNState()
            }
        } catch {
            Self.logger.error("ToggleVPNIntent disconnect failed: \(error.localizedDescription)")
        }
    }
}
