//
//  VPNControlCenterToggle.swift
//  SessionActivityWidget
//
//  Control Center toggle for connecting/disconnecting VPN.
//  Appears in Control Center, Lock Screen, and Action Button.
//

import SwiftUI
import WidgetKit

struct VPNControlCenterToggle: ControlWidget {
    static let kind = "VPNControlCenterToggle"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: VPNControlCenterValueProvider()
        ) { value in
            ControlWidgetToggle(
                value.profileName ?? "VPN",
                isOn: value.isOn,
                action: ToggleVPNIntent(profileID: value.profileID ?? "")
            ) { toggledOn in
                Label(
                    toggledOn ? "Connected" : "Disconnected",
                    systemImage: toggledOn ? "shield.lefthalf.filled" : "shield.slash"
                )
                .controlWidgetActionHint(toggledOn ? "Disconnect VPN" : "Connect VPN")
            }
        }
        .displayName("VPN Toggle")
        .description("Connect or disconnect your VPN.")
        .promptsForUserConfiguration()
    }
}
