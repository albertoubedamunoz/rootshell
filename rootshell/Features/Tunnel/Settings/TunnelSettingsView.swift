//
//  TunnelSettingsView.swift
//  rootshell
//
//  Settings view for managing background port forward tunnels
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Main settings view for background tunnels
struct TunnelSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var tunnelManager = BackgroundTunnelManager.shared
    @State private var profileManager = ConnectionProfileManager.shared
    @ObservedObject private var locationDiaryManager = LocationDiaryManager.shared
    @State private var showingAddProfile = false
    @State private var hostKeyPrompt = HostKeyPrompt()

    var body: some View {
        List {
            overviewSection
            activeTunnelsSection
            availableProfilesSection
            actionsSection
        }
        .themedList()
        .navigationTitle("Background Tunnels")
        .navigationBarTitleDisplayMode(.inline)
        .hostKeyPromptAlerts(hostKeyPrompt)
        .sheet(isPresented: $showingAddProfile) {
            ProfilesBrowseSheet { selection in
                showingAddProfile = false
                // Enable the selected profile as a tunnel
                tunnelManager.setEnabled(true, for: selection.profile.id)
                Task {
                    try? await tunnelManager.startTunnel(for: selection.profile, onHostKeyValidation: hostKeyPrompt.validate)
                }
            }
            .themedSubSheet(sheetThemeColors)
        }
    }

    // MARK: - Overview Section

    private var overviewSection: some View {
        Section {
            HStack {
                Text("Active Tunnels")
                Spacer()
                Text("\(tunnelManager.runningCount)")
                    .foregroundStyle(.secondary)
            }
            .themedRow()

            if tunnelManager.isAnyTunnelRunning {
                let stats = tunnelManager.totalStatistics
                HStack {
                    Text("Total Transfer")
                    Spacer()
                    Text("\(stats.totalBytesFormatted)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .themedRow()
            }
        } header: {
            Text("Overview")
        } footer: {
            #if targetEnvironment(macCatalyst)
            Text("Background tunnels maintain SSH port forwards without an active terminal session.")
            #else
            if locationDiaryManager.isConfigured {
                Text("Background tunnels maintain SSH port forwards without an active terminal session.")
            } else {
                Text("Background tunnels maintain SSH port forwards without an active terminal session. Enable Location Diary (Auto mode) in Privacy settings to keep tunnels alive when the app is in the background.")
            }
            #endif
        }
    }

    // MARK: - Active Tunnels Section

    private var activeTunnelsSection: some View {
        Section {
            if tunnelManager.activeTunnels.isEmpty {
                Text("No active tunnels")
                    .foregroundStyle(.secondary)
                    .themedRow()
            } else {
                ForEach(Array(tunnelManager.activeTunnels.values), id: \.profileID) { tunnel in
                    NavigationLink {
                        TunnelDetailView(profileID: tunnel.profileID)
                    } label: {
                        TunnelProfileRow(
                            profileName: tunnel.profileName,
                            host: tunnel.sshConfig.host,
                            state: tunnel.state,
                            statistics: tunnel.statistics,
                            isEnabled: Binding(
                                get: { tunnelManager.isEnabled(tunnel.profileID) },
                                set: { enabled in
                                    tunnelManager.setEnabled(enabled, for: tunnel.profileID)
                                    if !enabled {
                                        Task {
                                            await tunnelManager.stopTunnel(for: tunnel.profileID)
                                        }
                                    }
                                }
                            )
                        )
                    }
                    .hostAddressCopyMenu(hostname: tunnel.sshConfig.host)
                    .themedRow()
                }
            }
        } header: {
            Text("Active (\(tunnelManager.activeTunnels.count))")
        }
    }

    // MARK: - Available Profiles Section

    private var availableProfilesSection: some View {
        Section {
            let tunnelCapable = profileManager.tunnelCapableProfiles
                .filter { !tunnelManager.activeTunnels.keys.contains($0.id) }

            if tunnelCapable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No profiles with port forwards")
                        .foregroundStyle(.secondary)
                    Text("Configure port forwards in a profile to use it as a background tunnel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .themedRow()
            } else {
                ForEach(tunnelCapable) { profile in
                    AvailableTunnelProfileRow(
                        profile: profile,
                        isEnabled: tunnelManager.isEnabled(profile.id),
                        onToggle: { enabled in
                            tunnelManager.setEnabled(enabled, for: profile.id)
                            if enabled {
                                Task {
                                    try? await tunnelManager.startTunnel(for: profile, onHostKeyValidation: hostKeyPrompt.validate)
                                }
                            } else {
                                Task {
                                    await tunnelManager.stopTunnel(for: profile.id)
                                }
                            }
                        }
                    )
                    .hostAddressCopyMenu(hostname: profile.sshConfig.host)
                    .themedRow()
                }
            }
        } header: {
            Text("Available Profiles")
        } footer: {
            Text("Enable a profile to start its port forwards in the background. Enabled tunnels auto-start when the app launches.")
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            if tunnelManager.isAnyTunnelActive {
                Button(role: .destructive) {
                    Task {
                        await tunnelManager.stopAllTunnels()
                    }
                } label: {
                    Text("Stop All Tunnels")
                }
                .themedRow()
            }

            if !tunnelManager.eventHistory.isEmpty {
                Button(role: .destructive) {
                    tunnelManager.clearAllEvents()
                } label: {
                    Text("Clear Event History")
                }
                .themedRow()
            }
        } header: {
            if tunnelManager.isAnyTunnelActive || !tunnelManager.eventHistory.isEmpty {
                Text("Actions")
            }
        }
    }
}

// MARK: - Available Tunnel Profile Row

private struct AvailableTunnelProfileRow: View {
    let profile: ConnectionProfile
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)

                Text(profile.sshConfig.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let summary = profile.sshConfig.portForwardConfig.summaryString {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TunnelSettingsView()
    }
}
