//
//  ConnectVPNIntent.swift
//  rootshell
//
//  Shortcuts action that connects VPN to a saved profile.
//

import AppIntents
import NetworkExtension
import WidgetKit

/// Shortcuts action: connect VPN using a saved connection profile.
struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VPN"
    static var description: IntentDescription = "Connects VPN to a saved connection profile."
    static var openAppWhenRun = false

    @Parameter(title: "VPN Profile")
    var profile: VPNProfileEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let snapshot = VPNSharedProfileStore.profile(id: profile.id),
              snapshot.isBackgroundStartable else {
            throw IntentError.profileNotFound
        }

        do {
            let result = try await VPNStartController.start(profileID: snapshot.id)
            switch result {
            case .alreadyActive:
                reloadWidgets()
                return .result(
                    value: "Already connected",
                    dialog: "VPN is already connected to \(snapshot.name)."
                )
            case .started:
                // Reload immediately to show "connecting" state
                reloadWidgets()

                // Poll until connected or failed (up to 15s). The extension
                // writes the connected state itself, and an unreadable final
                // status stays "connecting" so the dialog reports progress.
                let outcome = await VPNConnectionPoller.pollForConnection(
                    snapshot: snapshot,
                    writeConnectedState: false,
                    treatUnknownFinalStatusAsFailed: false
                )
                reloadWidgets()

                switch outcome {
                case .connected:
                    return .result(
                        value: "Connected",
                        dialog: "VPN connected to \(snapshot.name)."
                    )
                case .failed:
                    throw IntentError.connectionFailed("Tunnel failed to start")
                case .timeout:
                    return .result(
                        value: "Connecting",
                        dialog: "VPN is connecting to \(snapshot.name)."
                    )
                }
            }
        } catch let intentError as IntentError {
            reloadWidgets()
            throw intentError
        } catch {
            reloadWidgets()
            throw IntentError.connectionFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "VPNControlWidget")
        #if !os(visionOS)
        ControlCenter.shared.reloadControls(ofKind: "VPNControlCenterToggle")
        #endif
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case profileNotFound
        case connectionFailed(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .profileNotFound:
                return "VPN profile not found or not available for background start."
            case .connectionFailed(let reason):
                return "VPN connection failed: \(reason)"
            }
        }
    }
}
