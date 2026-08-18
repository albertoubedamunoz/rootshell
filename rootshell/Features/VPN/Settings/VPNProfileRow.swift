//
//  VPNProfileRow.swift
//  rootshell
//
//  Profile row with connect/disconnect button for VPN.
//

import SwiftUI
import NetworkExtension

struct VPNProfileRow: View {
    let profile: ConnectionProfile
    @State private var vpnManager = VPNManager.shared
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showDisconnectConfirmation = false
    @State private var showSwitchConfirmation = false

    var body: some View {
        Button {
            if vpnManager.isVPNActive(for: profile.id) {
                showDisconnectConfirmation = true
            } else if vpnManager.status.isActive {
                showSwitchConfirmation = true
            } else {
                startVPN()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.body)
                    Text(profile.displayString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: profile.connectionProtocol.iconName)
                        Text(profile.connectionProtocol == .trzsz ? "TSSH" : "SSH")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                if vpnManager.isVPNActive(for: profile.id) {
                    VPNConnectionBadge(status: vpnManager.status)
                }

                Image(systemName: vpnManager.isVPNActive(for: profile.id) ? "stop.circle" : "play.circle")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.title2)
                    .foregroundStyle(vpnManager.isVPNActive(for: profile.id) ? .red : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .alert("VPN Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
        }
        .confirmationDialog(
            "Disconnect VPN?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task {
                    try? await vpnManager.stopVPN()
                }
            }
        } message: {
            Text("This will end your connection to \(profile.name).")
        }
        .confirmationDialog(
            "Switch VPN Profile?",
            isPresented: $showSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                switchToProfile()
            }
        } message: {
            let currentName = vpnManager.activeProfileName ?? "the current profile"
            Text("This will disconnect from \(currentName) and connect to \(profile.name).")
        }
    }

    // MARK: - Actions

    private func startVPN() {
        Task {
            do {
                try await vpnManager.startVPN(for: profile)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func switchToProfile() {
        Task {
            do {
                try await vpnManager.stopVPN()

                // Wait for status to reach disconnected before starting new connection
                for _ in 0..<50 {
                    if vpnManager.status == .disconnected || vpnManager.status == .invalid {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }

                guard vpnManager.status == .disconnected || vpnManager.status == .invalid else {
                    errorMessage = "Timed out waiting for VPN to disconnect"
                    showError = true
                    return
                }

                try await vpnManager.startVPN(for: profile)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - VPN Connection Badge

struct VPNConnectionBadge: View {
    let status: NEVPNStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(status.displayString)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var badgeColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .orange
        case .disconnecting:
            return .yellow
        default:
            return .gray
        }
    }
}
