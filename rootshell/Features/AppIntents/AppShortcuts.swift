//
//  AppShortcuts.swift
//  rootshell
//
//  Registers Shortcuts phrases for the app.
//

import AppIntents

struct RootshellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConnectionProfileIntent(),
            phrases: [
                "Open \(\.$profile) in \(.applicationName)",
                "Connect to \(\.$profile) with \(.applicationName)",
            ],
            shortTitle: "Open Connection",
            systemImageName: "terminal"
        )

        AppShortcut(
            intent: OpenLocalShellIntent(),
            phrases: [
                "Open a shell in \(.applicationName)",
                "Open a local shell in \(.applicationName)",
            ],
            shortTitle: "Local Shell",
            systemImageName: "apple.terminal"
        )

        AppShortcut(
            intent: RunSSHCommandIntent(),
            phrases: [
                "Run a command on \(\.$profile) in \(.applicationName)",
                "Run a command over SSH with \(.applicationName)",
            ],
            shortTitle: "Run Command",
            systemImageName: "terminal.fill"
        )

        AppShortcut(
            intent: SetAppIconIntent(),
            phrases: [
                "Change app icon to \(\.$variant) in \(.applicationName)",
                "Set \(.applicationName) icon to \(\.$variant)",
            ],
            shortTitle: "Change App Icon",
            systemImageName: "app.gift"
        )

        #if !CHINA_BUILD
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect VPN \(\.$profile) in \(.applicationName)",
                "Start VPN \(\.$profile) with \(.applicationName)",
            ],
            shortTitle: "Connect VPN",
            systemImageName: "network.badge.shield.half.filled"
        )

        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect VPN in \(.applicationName)",
                "Stop VPN in \(.applicationName)",
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "network.slash"
        )
        #endif
    }
}
