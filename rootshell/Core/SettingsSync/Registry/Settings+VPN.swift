//
//  Settings+VPN.swift
//  rootshell
//
//  VPN keys. Profiles and Tailscale settings live in the app group, not here.
//

#if !CHINA_BUILD

import Foundation

nonisolated extension Settings {
    enum VPN {
        static let autoRecovery = SettingKey(
            "vpnAutoRecovery", default: true, group: .connections, configKey: "vpn-auto-recovery",
            title: String(localized: "Auto Recovery", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            autoRecovery.erased,
        ]
    }
}

#endif
