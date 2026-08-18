//
//  TunnelProfileRow.swift
//  rootshell
//
//  Row component for displaying a tunnel profile with status
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Row displaying a tunnel profile with its current state and stats
struct TunnelProfileRow: View {
    let profileName: String
    let host: String
    let state: TunnelState
    let statistics: TunnelStatistics?
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            TunnelStatusBadge(state: state)

            // Profile info
            VStack(alignment: .leading, spacing: 2) {
                Text(profileName)
                    .lineLimit(1)

                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Stats when connected
                if let stats = statistics, state.isConnected {
                    HStack(spacing: 8) {
                        Label(stats.bytesInFormatted, systemImage: "arrow.down")
                        Label(stats.bytesOutFormatted, systemImage: "arrow.up")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Toggle
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Tunnel Status Badge

/// Visual indicator for tunnel connection state
struct TunnelStatusBadge: View {
    let state: TunnelState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            if showStatusText {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }

    private var statusText: String {
        switch state {
        case .connected:
            return String(localized: "Connected", comment: "VPN tunnel status")
        case .connecting:
            return String(localized: "Connecting", comment: "VPN tunnel status")
        case .reconnecting(let attempt):
            return String(localized: "Reconnecting (\(attempt))", comment: "VPN tunnel status")
        case .disconnected:
            return "Stopped"
        case .failed(let reason):
            return reason
        }
    }

    private var showStatusText: Bool {
        switch state {
        case .connected, .disconnected:
            return false
        case .connecting, .reconnecting, .failed:
            return true
        }
    }
}

// MARK: - Compact Status Badge

/// Smaller status indicator for inline use
struct TunnelStatusDot: View {
    let state: TunnelState

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }
}

// MARK: - Preview

#Preview("Connected") {
    TunnelProfileRow(
        profileName: "Production Server",
        host: "prod.example.com",
        state: .connected,
        statistics: {
            var stats = TunnelStatistics(tunnelID: UUID())
            stats.bytesIn = 1024 * 1024 * 5
            stats.bytesOut = 1024 * 512
            return stats
        }(),
        isEnabled: .constant(true)
    )
    .padding()
}

#Preview("Connecting") {
    TunnelProfileRow(
        profileName: "Dev Server",
        host: "dev.example.com",
        state: .connecting,
        statistics: nil,
        isEnabled: .constant(true)
    )
    .padding()
}

#Preview("Status Badges") {
    VStack(spacing: 20) {
        TunnelStatusBadge(state: .connected)
        TunnelStatusBadge(state: .connecting)
        TunnelStatusBadge(state: .reconnecting(attempt: 2))
        TunnelStatusBadge(state: .disconnected)
        TunnelStatusBadge(state: .failed("Auth failed"))
    }
    .padding()
}
