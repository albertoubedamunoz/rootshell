//
//  ScreenSharingSettingsView.swift
//  rootshell
//
//  Defaults for newly opened Screen Sharing sessions.
//

import SwiftUI

struct ScreenSharingSettingsView: View {
    @Setting(Settings.ScreenSharing.clipboardSyncDefault) private var clipboardSyncDefault
    @Setting(Settings.ScreenSharing.panningDefault) private var panningDefault

    private var resolvedClipboardSyncDefault: ScreenSharingClipboardSyncDefault {
        clipboardSyncDefault
    }

    var body: some View {
        List {
            Section {
                Picker(selection: $clipboardSyncDefault) {
                    ForEach(ScreenSharingClipboardSyncDefault.allCases, id: \.rawValue) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.triangle.2.circlepath")
                        Text("Default Clipboard Sync")
                    }
                }
                .themedRow()
            } header: {
                Text("Shared Clipboard")
            } footer: {
                Text(clipboardFooterText)
            }

            Section {
                Picker(selection: $panningDefault) {
                    ForEach(ScreenSharingPanningDefault.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cursorarrow.motionlines")
                        Text("Default Mode")
                    }
                }
                .themedRow()
            } header: {
                Text("Screen Panning")
            } footer: {
                Text("Sets the initial panning mode for new Screen Sharing sessions. You can change it for the current session from the Screen Sharing menu.")
            }
        }
        .themedList()
        .navigationTitle("Screen Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var clipboardFooterText: String {
        switch resolvedClipboardSyncDefault {
        case .automatic:
            return String(localized: "Auto enables Shared Clipboard only when the connection is protected by an SSH or tssh tunnel, VeNCrypt TLS, or Apple ComCryption. You can override it for the current session from the Screen Sharing menu.")
        case .off:
            return String(localized: "New Screen Sharing sessions start with Shared Clipboard off. You can enable it for the current session from the Screen Sharing menu.")
        case .alwaysOn:
            return String(localized: "New Screen Sharing sessions start with Shared Clipboard on, including unencrypted direct VNC connections. Clipboard contents may be exposed on untrusted networks.")
        }
    }
}
