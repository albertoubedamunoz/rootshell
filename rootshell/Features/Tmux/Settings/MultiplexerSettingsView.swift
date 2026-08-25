import SwiftUI

struct MultiplexerSettingsView: View {
    @AppStorage("tmuxSessionDiscoveryEnabled") private var tmuxDiscoveryEnabled = true
    @AppStorage("zellijSessionDiscoveryEnabled") private var zellijDiscoveryEnabled = true
    @AppStorage("herdrSessionDiscoveryEnabled") private var herdrDiscoveryEnabled = true
    @AppStorage("localSessionDiscoveryEnabled") private var localDiscoveryEnabled = true
    @AppStorage(SessionDiscoverySortOrder.storageKey) private var sortOrder = SessionDiscoverySortOrder.attachedFirst.rawValue
    @AppStorage(TabExposeSettings.multiplexerEnabledKey) private var exposeMultiplexerEnabled = true
    @AppStorage("tmuxSessionName") private var sessionName = ""
    @AppStorage("tmuxCustomCommand") private var customCommand = ""
    @AppStorage("herdrSessionName") private var herdrSessionName = ""
    @AppStorage("herdrCustomCommand") private var herdrCustomCommand = ""
    @AppStorage(TmuxController.autoHideGatewayOnAttachDefaultsKey)
    private var autoHideGatewayOnAttach = false
    @AppStorage(TmuxTabCloseAction.storageKey)
    private var tabCloseAction = TmuxTabCloseAction.closeWindow.rawValue
    @AppStorage(TmuxNewTabAction.storageKey)
    private var newTabAction = TmuxNewTabAction.localShell.rawValue

    private var hasCustomCommand: Bool {
        !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var autoStartCommandSummary: String {
        if hasCustomCommand {
            return "Custom"
        }
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    private var herdrAutoStartCommandSummary: String {
        if !herdrCustomCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Custom"
        }
        let name = herdrSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "default" : name
    }

    private var discoveryFooterText: String {
        let base = "Checks for active sessions after an SSH connection. Skipped for connections with multiplexer auto-start enabled."
        #if targetEnvironment(macCatalyst)
        return base + " Discover Local Sessions also scans when opening a local macOS shell tab."
        #else
        return base
        #endif
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $tmuxDiscoveryEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.split.2x1")
                        Text("Discover tmux Sessions")
                    }
                }
                .themedRow()

                Toggle(isOn: $zellijDiscoveryEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.split.3x1")
                        Text("Discover zellij Sessions")
                    }
                }
                .themedRow()

                Toggle(isOn: $herdrDiscoveryEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "square.grid.2x2")
                        Text("Discover herdr Sessions")
                    }
                }
                .themedRow()

                #if targetEnvironment(macCatalyst)
                Toggle(isOn: $localDiscoveryEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "desktopcomputer")
                        Text("Discover Local Sessions")
                    }
                }
                .themedRow()
                #endif

                Picker(selection: $sortOrder) {
                    ForEach(SessionDiscoverySortOrder.allCases, id: \.rawValue) { order in
                        Text(order.displayName).tag(order.rawValue)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.up.arrow.down")
                        Text("Sort Order")
                    }
                }
                .themedRow()
            } header: {
                Text("Session Discovery")
            } footer: {
                Text(discoveryFooterText)
            }

            Section {
                Toggle(isOn: $exposeMultiplexerEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.grid.2x2")
                        Text("Show Multiplexer Tabs")
                    }
                }
                .themedRow()
            } header: {
                Text("Tab Exposé")
            } footer: {
                Text("On a tab attached to tmux, zellij, or herdr, Tab Exposé opens on that session's own tabs with live previews, and swiping sideways returns to your app tabs. Reads the session's layout and pane contents over the connection the tab already holds while the exposé is open.")
            }

            Section {
                Toggle(isOn: $autoHideGatewayOnAttach) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "eye.slash")
                        Text("Auto-hide Gateway on Attach")
                    }
                }
                .themedRow()

                NavigationLink {
                    TmuxTabCloseActionPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "xmark.rectangle")
                        Text("Close Tab Action")
                        Spacer()
                        Text((TmuxTabCloseAction(rawValue: tabCloseAction) ?? .closeWindow).displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                NavigationLink {
                    TmuxNewTabActionPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "plus.rectangle.on.rectangle")
                        Text("New Tab Action")
                        Spacer()
                        Text((TmuxNewTabAction(rawValue: newTabAction) ?? .localShell).displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                Text("tmux Control Mode")
            } footer: {
                Text("These settings apply while attached with tmux -CC control mode, where each tmux window is its own tab.")
            }

            Section {
                NavigationLink {
                    TmuxAutoStartCommandView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "play.rectangle")
                        Text("Auto-Start Command")
                        Spacer()
                        Text(autoStartCommandSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                Text("tmux Auto-Start")
            } footer: {
                Text("The tmux command used when auto-start is enabled on a connection.")
            }

            Section {
                NavigationLink {
                    HerdrAutoStartCommandView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "play.rectangle")
                        Text("Auto-Start Command")
                        Spacer()
                        Text(herdrAutoStartCommandSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                Text("herdr Auto-Start")
            } footer: {
                Text("The herdr command used when auto-start is enabled on a connection.")
            }

            Section {
                NavigationLink {
                    TmuxGuideView()
                } label: {
                    Label("tmux Tips", systemImage: "questionmark.circle")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Multiplexers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pushed list for choosing the tmux -CC tab-close action. Each option gets a
/// title, leading icon, and a full-width description below it — so the
/// explanations have room instead of piling into the Multiplexers form footer
/// as a wall of text. Mirrors the SSH key security picker. (id=tmux-tab-close-action)
struct TmuxTabCloseActionPickerView: View {
    @AppStorage(TmuxTabCloseAction.storageKey)
    private var tabCloseAction = TmuxTabCloseAction.closeWindow.rawValue

    var body: some View {
        List {
            Section {
                ForEach(TmuxTabCloseAction.allCases, id: \.rawValue) { action in
                    Button {
                        tabCloseAction = action.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.iconName)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.displayName)
                                    .foregroundColor(.primary)
                                Text(action.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if tabCloseAction == action.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Controls what ⌘W or the tab's ✕ does on a tmux -CC tab.")
            }
        }
        .themedList()
        .navigationTitle("Close Tab Action")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pushed list for choosing what ⌘T does while attached to a tmux -CC session.
/// Same layout as the close-action picker: per-option icon + description.
/// (id=tmux-new-tab-action)
struct TmuxNewTabActionPickerView: View {
    @AppStorage(TmuxNewTabAction.storageKey)
    private var newTabAction = TmuxNewTabAction.localShell.rawValue

    var body: some View {
        List {
            Section {
                ForEach(TmuxNewTabAction.allCases, id: \.rawValue) { action in
                    Button {
                        newTabAction = action.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.iconName)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.displayName)
                                    .foregroundColor(.primary)
                                Text(action.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if newTabAction == action.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Controls what ⌘T does while attached to a tmux -CC session. Outside tmux it always opens a local shell.")
            }
        }
        .themedList()
        .navigationTitle("New Tab Action")
        .navigationBarTitleDisplayMode(.inline)
    }
}
