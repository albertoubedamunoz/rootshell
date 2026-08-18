//
//  TunnelDetailView.swift
//  rootshell
//
//  Detail view showing tunnel statistics and event history
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Detailed view for a single background tunnel
struct TunnelDetailView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let profileID: UUID

    @State private var tunnelManager = BackgroundTunnelManager.shared
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var hostKeyPrompt = HostKeyPrompt()

    /// Get the tunnel if active
    private var tunnel: BackgroundTunnel? {
        tunnelManager.tunnel(for: profileID)
    }

    /// Get the profile
    private var profile: ConnectionProfile? {
        profileManager.profile(for: profileID)
    }

    var body: some View {
        List {
            statusSection
            forwardsSection
            statisticsSection
            eventHistorySection
            actionsSection
        }
        .themedList()
        .navigationTitle(profile?.name ?? "Tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .hostKeyPromptAlerts(hostKeyPrompt)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            if let tunnel = tunnelManager.tunnel(for: profileID) {
                HStack {
                    Text("Status")
                    Spacer()
                    TunnelStatusBadge(state: tunnel.state)
                }
                .themedRow()

                if let nextRetryAt = tunnel.nextRetryAt {
                    LabeledContent("Next Attempt In") {
                        Text(nextRetryAt, style: .timer)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .themedRow()
                }

                if let startedAt = tunnel.statistics.startedAt {
                    LabeledContent("Uptime") {
                        Text(startedAt, style: .timer)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
            } else {
                HStack {
                    Text("Status")
                    Spacer()
                    Text("Not Running")
                        .foregroundStyle(.secondary)
                }
                .themedRow()
            }

            if let profile = profile {
                HStack {
                    Text("Host")
                    Spacer()
                    Text(profile.sshConfig.host)
                        .foregroundStyle(.secondary)
                }
                .themedRow()

                if let jumpHost = profile.sshConfig.jumpHost {
                    HStack {
                        Text("Jump Host")
                        Spacer()
                        Text(jumpHost.host)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
            }
        } header: {
            Text("Connection")
        }
    }

    // MARK: - Port Forwards Section

    private var forwardsSection: some View {
        Section {
            if let profile = profile {
                let forwards = profile.sshConfig.portForwardConfig.forwards
                if forwards.isEmpty {
                    Text("No port forwards configured")
                        .foregroundStyle(.secondary)
                        .themedRow()
                } else {
                    ForEach(forwards) { forward in
                        PortForwardDetailRow(forward: forward, tunnel: tunnel)
                            .themedRow()
                    }
                }
            }
        } header: {
            Text("Port Forwards")
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        Section {
            if let tunnel = tunnelManager.tunnel(for: profileID), tunnel.state.isConnected {
                let stats = tunnel.statistics

                HStack {
                    Label("Downloaded", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(stats.bytesInFormatted)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .themedRow()

                HStack {
                    Label("Uploaded", systemImage: "arrow.up.circle")
                    Spacer()
                    Text(stats.bytesOutFormatted)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .themedRow()

                HStack {
                    Label("Connections", systemImage: "network")
                    Spacer()
                    Text("\(stats.connectionCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .themedRow()

                if stats.totalActiveConnections > 0 {
                    HStack {
                        Label("Active", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        Text("\(stats.totalActiveConnections)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .themedRow()
                }
            } else {
                Text("Statistics available when tunnel is running")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        } header: {
            Text("Statistics")
        }
    }

    // MARK: - Event History Section

    private var eventHistorySection: some View {
        Section {
            let events = tunnelManager.events(for: profileID, limit: 50)

            if events.isEmpty {
                Text("No events recorded")
                    .foregroundStyle(.secondary)
                    .themedRow()
            } else {
                ForEach(events.reversed()) { event in
                    TunnelEventRow(event: event)
                        .themedRow()
                }
            }
        } header: {
            Text("Recent Events")
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            if let tunnel = tunnel {
                if tunnel.state.isConnected {
                    Button {
                        Task {
                            await tunnel.reconnect()
                        }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .themedRow()

                    Button(role: .destructive) {
                        tunnelManager.setEnabled(false, for: profileID)
                        Task {
                            await tunnelManager.stopTunnel(for: profileID)
                        }
                    } label: {
                        Label("Stop Tunnel", systemImage: "stop.fill")
                    }
                    .themedRow()
                } else if case .reconnecting = tunnel.state {
                    Button(role: .destructive) {
                        tunnelManager.setEnabled(false, for: profileID)
                        Task {
                            await tunnelManager.stopTunnel(for: profileID)
                        }
                    } label: {
                        Label("Cancel Reconnection", systemImage: "xmark.circle")
                    }
                    .themedRow()
                } else if case .connecting = tunnel.state {
                    Button(role: .destructive) {
                        tunnelManager.setEnabled(false, for: profileID)
                        Task {
                            await tunnelManager.stopTunnel(for: profileID)
                        }
                    } label: {
                        Label("Cancel Connection", systemImage: "xmark.circle")
                    }
                    .themedRow()
                } else if case .failed = tunnel.state {
                    Button {
                        Task {
                            // Restart through the manager so a host-key prompt
                            // can show; tunnel.reconnect() reuses the tunnel's
                            // cleared callback and would strict-reject forever.
                            if let profile {
                                try? await tunnelManager.startTunnel(for: profile, onHostKeyValidation: hostKeyPrompt.validate)
                            } else {
                                await tunnel.reconnect()
                            }
                        }
                    } label: {
                        Label("Retry Connection", systemImage: "arrow.clockwise")
                    }
                    .themedRow()
                }
            } else if let profile = profile {
                Button {
                    Task {
                        try? await tunnelManager.startTunnel(for: profile, onHostKeyValidation: hostKeyPrompt.validate)
                    }
                } label: {
                    Label("Start Tunnel", systemImage: "play.fill")
                }
                .themedRow()
            }

            if !tunnelManager.events(for: profileID).isEmpty {
                Button(role: .destructive) {
                    tunnelManager.clearEvents(for: profileID)
                } label: {
                    Label("Clear Event History", systemImage: "trash")
                }
                .themedRow()
            }
        }
    }
}

// MARK: - Port Forward Detail Row

private struct PortForwardDetailRow: View {
    let forward: PortForwardConfig.PortForward
    let tunnel: BackgroundTunnel?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(forward.displayString)
                    .font(.system(.body, design: .monospaced))

                Text(forward.direction.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Show status if tunnel is running
            if let tunnel = tunnel,
               let forwardStats = tunnel.statistics.forwardStats[forward.id] {
                if forwardStats.activeConnections > 0 {
                    Label("\(forwardStats.activeConnections)", systemImage: "bolt.horizontal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var statusColor: Color {
        guard let tunnel = tunnel else { return .gray }

        if tunnel.state.isConnected {
            return forward.enabled ? .green : .gray
        }
        return .gray
    }
}

// MARK: - Tunnel Event Row

private struct TunnelEventRow: View {
    let event: TunnelEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.type.iconName)
                .foregroundStyle(event.type.iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.displayName)
                    .font(.subheadline)

                if let message = event.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(event.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TunnelDetailView(profileID: UUID())
    }
}
