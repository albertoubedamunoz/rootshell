//
//  VPNStatusRow.swift
//  rootshell
//
//  Status indicator with colored dot and text for VPN state.
//

import SwiftUI
import NetworkExtension

struct VPNStatusRow: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared

    var body: some View {
        HStack(spacing: 12) {
            #if !CHINA_BUILD
            if isTailnet {
                tailscaleIcon
            } else {
                statusDot
            }
            #else
            statusDot
            #endif

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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
    }

    #if !CHINA_BUILD
    private var isTailnet: Bool {
        vpnManager.status.isActive && vpnManager.activeProfileID == VPNTailnetProfile.id
    }

    /// Matches the quick connect card tile, with the status dot as a badge.
    private var tailscaleIcon: some View {
        Image("TailscaleLogo")
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                statusDot
                    .overlay(Circle().stroke(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
    #endif

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
