//
//  VPNWidgetIntents.swift
//  SessionActivityWidget
//
//  Standalone AppIntents for the VPN Control Widget.
//  Connect and disconnect both run in background.
//

import AppIntents
import NetworkExtension
import os.log
import WidgetKit

private nonisolated let controlCenterToggleKind = "VPNControlCenterToggle"

// MARK: - Connect VPN (background)

/// Starts VPN directly from the widget without opening the app.
struct ConnectVPNWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VPN"
    static var description: IntentDescription = "Connects VPN using the selected profile."
    static var openAppWhenRun = false

    private static let logger = Logger(subsystem: "com.rootshell", category: "ConnectVPNWidgetIntent")

    @Parameter(title: "Profile ID")
    var profileID: String

    init() {}

    init(profileID: String) {
        self.profileID = profileID
    }

    func perform() async throws -> some IntentResult {
        guard let profileID = UUID(uuidString: profileID) else {
            Self.logger.error("ConnectVPNWidgetIntent: invalid profile ID")
            return .result()
        }

        guard let snapshot = VPNSharedProfileStore.profile(id: profileID) else {
            Self.logger.error("ConnectVPNWidgetIntent: missing snapshot for \(profileID.uuidString)")
            return .result()
        }

        do {
            let result = try await VPNStartController.start(profileID: profileID)
            switch result {
            case .alreadyActive:
                Self.logger.info("ConnectVPNWidgetIntent: already active \(profileID.uuidString)")
            case .started:
                Self.logger.info("ConnectVPNWidgetIntent: started \(profileID.uuidString)")
            }
        } catch {
            Self.logger.error("ConnectVPNWidgetIntent failed: \(error.localizedDescription)")
            WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
            ControlCenter.shared.reloadControls(ofKind: controlCenterToggleKind)
            return .result()
        }

        // Request a timeline rebuild now. The shared state already says
        // "connecting" (written by VPNStartController), so WidgetKit may
        // process this in parallel and show "Connecting…" with a spinner.
        // Views marked with .invalidatableContent() also dim immediately
        // on tap to signal the interaction was received.
        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        ControlCenter.shared.reloadControls(ofKind: controlCenterToggleKind)
        await VPNLiveActivityUpdater.syncFromWidgetState()

        // Poll inline until connected or failed, then rebuild the
        // timeline with the final state. The shared state is the most
        // reliable signal (the extension writes "connected" at the end of
        // startTunnel); the system status is the fast path and fallback.
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
            // Still connecting → shared state stays "connecting";
            // timeline shows it
            break
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        ControlCenter.shared.reloadControls(ofKind: controlCenterToggleKind)
        await VPNLiveActivityUpdater.syncFromWidgetState()
        return .result()
    }
}

// MARK: - Disconnect VPN (background)

/// Stops VPN directly from the widget without opening the app.
struct DisconnectVPNWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect VPN"
    static var description: IntentDescription = "Disconnects the active VPN."
    static var openAppWhenRun = false

    private static let logger = Logger(subsystem: "com.rootshell", category: "DisconnectVPNWidgetIntent")

    init() {}

    func perform() async throws -> some IntentResult {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else {
                Self.logger.error("DisconnectVPNWidgetIntent: no manager found")
                return .result()
            }

            manager.connection.stopVPNTunnel()

            VPNConnectionPoller.writeDisconnectingState()
            await VPNLiveActivityUpdater.syncFromWidgetState()

            // Intermediate reload so the *other* surface (CC toggle) updates promptly
            WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
            ControlCenter.shared.reloadControls(ofKind: controlCenterToggleKind)

            Self.logger.info("DisconnectVPNWidgetIntent: stopping")

            // Poll inline until disconnected. WidgetKit shows its
            // built-in button spinner while perform() is running. If still
            // disconnecting after the timeout, state is left as-is;
            // resolvedStatus in the timeline provider times it out after 10s.
            let outcome = await VPNConnectionPoller.pollForDisconnection(
                manager: manager,
                checkSharedState: true
            )
            if outcome == .disconnected {
                await VPNLiveActivityUpdater.clearVPNState()
            }
        } catch {
            Self.logger.error("DisconnectVPNWidgetIntent failed: \(error.localizedDescription)")
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        ControlCenter.shared.reloadControls(ofKind: controlCenterToggleKind)
        await VPNLiveActivityUpdater.syncFromWidgetState()
        return .result()
    }
}

// MARK: - Widget Configuration Intent

/// Configuration intent for the VPN Control Widget, allowing users to
/// select which VPN profile the widget controls.
struct VPNProfileSelectionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select VPN Profile"
    static var description: IntentDescription = "Choose which VPN profile to control from the widget."

    @Parameter(title: "VPN Profile")
    var profile: VPNWidgetProfileEntity?
}
