//
//  VPNStatusRow.swift
//  rootshell
//
//  Status indicator with colored dot and text for VPN state.
//

import SwiftUI
import NetworkExtension

struct VPNStatusRow: View {
    @State private var vpnManager = VPNManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(vpnManager.status.displayString)
                    .font(.headline)
                if let name = vpnManager.activeProfileName, vpnManager.status.isActive {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if vpnManager.status == .connecting || vpnManager.status == .reasserting {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .symbolEffect(.rotate, isActive: true)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch vpnManager.status {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .orange
        case .disconnecting:
            return .yellow
        case .disconnected, .invalid:
            return .gray
        @unknown default:
            return .gray
        }
    }
}
