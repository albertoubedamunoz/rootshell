//
//  TmuxGuideView.swift
//  rootshell
//
//  Explains tmux -CC control mode (gateway tab, auto-hide, tab shortcuts)
//  and zmx's detach key and attach-or-create behaviour, and shows the
//  recommended ~/.tmux.conf lines, so the Multiplexers screen can keep its
//  footers short.
//

import SwiftUI

struct TmuxGuideView: View {
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
                    GuideRow(
                        icon: "rectangle.stack",
                        title: "Gateway Tab",
                        description: "Attaching with tmux -CC keeps a gateway tab for the tmux client itself. Each tmux window opens as its own tab."
                    )

                    Divider()

                    GuideRow(
                        icon: "eye.slash",
                        title: "Auto-hide Gateway",
                        description: "When enabled, the gateway tab hides once the session's windows appear and returns when you detach. A hidden gateway always keeps at least one visible window tab."
                    )

                    Divider()

                    GuideRow(
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

            // MARK: - zmx
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(
                        icon: "arrow.right.square",
                        title: "Detaching",
                        description: "Press ctrl+\\ to detach from a zmx session and return to the shell. Set ZMX_NO_DETACH_KEY=1 on the host to disable that key if it conflicts with something you use."
                    )

                    Divider()

                    GuideRow(
                        icon: "plus.square.on.square",
                        title: "Attach or Create",
                        description: "zmx attach joins the session if it exists and creates it otherwise, so auto-start never fails on a fresh host. There is no unnamed default session, so a name is always used — \"main\" unless you set another."
                    )

                    Divider()

                    GuideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Resizing",
                        description: "A zmx session has one size shared by every attached client, and the last client to type sets it. Attaching from rootshell will reflow the session for anyone else attached as soon as you type. This is how zmx works, not a rootshell limitation."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("zmx")
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
        .navigationTitle("Multiplexer Tips")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        TmuxGuideView()
    }
}
