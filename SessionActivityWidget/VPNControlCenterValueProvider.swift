//
//  VPNControlCenterValueProvider.swift
//  SessionActivityWidget
//
//  Value provider for the Control Center VPN toggle.
//  Reads VPNWidgetState from the shared app group to determine
//  the current on/off state.
//

import WidgetKit

/// Value passed to the Control Center toggle template.
struct VPNControlCenterValue {
    var isOn: Bool
    var profileID: String?
    var profileName: String?
}

/// Reads VPN state from the shared app group and returns a boolean value.
struct VPNControlCenterValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: VPNControlCenterConfigurationIntent) -> VPNControlCenterValue {
        VPNControlCenterValue(
            isOn: false,
            profileID: configuration.profile?.id.uuidString,
            profileName: configuration.profile?.name ?? "VPN"
        )
    }

    func currentValue(configuration: VPNControlCenterConfigurationIntent) async throws -> VPNControlCenterValue {
        guard let profile = configuration.profile else {
            return VPNControlCenterValue(isOn: false, profileID: nil, profileName: "VPN")
        }

        let profileID = profile.id
        let widgetState = VPNWidgetState.read()

        let isOn: Bool
        if let state = widgetState, state.profileID == profileID {
            isOn = resolvedIsOn(from: state)
        } else {
            isOn = false
        }

        return VPNControlCenterValue(
            isOn: isOn,
            profileID: profileID.uuidString,
            profileName: profile.name
        )
    }

    /// Derive a boolean on/off from the shared state, applying staleness timeouts.
    private func resolvedIsOn(from state: VPNWidgetState) -> Bool {
        let age = Date().timeIntervalSince(state.lastUpdated)

        switch state.status {
        case "connected":
            return age < 600
        case "connecting", "reconnecting":
            // Optimistic: show as on while transitioning
            return age < 30
        default:
            return false
        }
    }
}
