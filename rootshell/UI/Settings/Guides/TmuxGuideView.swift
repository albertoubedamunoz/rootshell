//
//  TmuxGuideView.swift
//  rootshell
//
//  Explains tmux -CC control mode (gateway tab, auto-hide, tab shortcuts)
//  and shows the recommended ~/.tmux.conf lines, so the Multiplexers screen
//  can keep its footers short.
//

import SwiftUI

struct TmuxGuideView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var configCopied = false

    private static let recommendedConfig = """
        set -g mouse on
        set -g set-titles on
        set -g set-titles-string '#T'
        """

    var body: some View {
        List {
            // MARK: - Control Mode
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    guideRow(
                        icon: "rectangle.stack",
                        title: "Gateway Tab",
                        description: "Attaching with tmux -CC keeps a gateway tab for the tmux client itself. Each tmux window opens as its own tab."
                    )

                    Divider()

                    guideRow(
                        icon: "eye.slash",
                        title: "Auto-hide Gateway",
                        description: "When enabled, the gateway tab hides once the session's windows appear and returns when you detach. A hidden gateway always keeps at least one visible window tab."
                    )

                    Divider()

                    guideRow(
                        icon: "command",
                        title: "Tab Shortcuts",
                        description: "Close Tab Action sets what ⌘W or the tab's ✕ does on a tmux -CC tab. New Tab Action sets what ⌘T does while attached. Outside tmux, ⌘T always opens a local shell."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Control Mode")
            }

            // MARK: - Recommended Configuration
            Section {
                Text("Add these lines to enable mouse support and pass window titles through to rootshell tab titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()

                HStack(alignment: .top) {
                    Text(Self.recommendedConfig)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = Self.recommendedConfig
                        configCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            configCopied = false
                        }
                    } label: {
                        Image(systemName: configCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(configCopied ? .green : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                }
                .themedRow()
            } header: {
                Text("Recommended Configuration")
            } footer: {
                Text("Add to ~/.tmux.conf on the remote host.")
            }
        }
        .themedList()
        .navigationTitle("tmux Tips")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    private func guideRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        TmuxGuideView()
    }
}
