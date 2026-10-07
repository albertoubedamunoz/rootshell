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
    #if !CHINA_BUILD
    @State private var engine = TailnetInAppEngine.shared
    #endif

    var body: some View {
        HStack(spacing: 12) {
            #if !CHINA_BUILD
            if isTailnet || showsInAppTailnet {
                tailscaleIcon
            } else {
                statusDot
            }
            #else
            statusDot
            #endif

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isBusy {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .symbolEffect(.rotate, isActive: true)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        #if !CHINA_BUILD
        if showsInAppTailnet { return inAppTitle }
        #endif
        return vpnManager.status.displayString
    }

    private var subtitle: String? {
        #if !CHINA_BUILD
        if showsInAppTailnet {
            return String(localized: "Tailscale inside rootshell, no VPN", comment: "VPN status subtitle when Tailscale runs in-app")
        }
        #endif
        guard vpnManager.status.isActive else { return nil }
        return vpnManager.activeProfileName
    }

    private var isBusy: Bool {
        #if !CHINA_BUILD
        if showsInAppTailnet { return engine.isStarted && engine.status?.isRunning != true && engine.status?.needsLogin != true }
        #endif
        return vpnManager.status == .connecting || vpnManager.status == .reasserting
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 12, height: 12)
    }

    #if !CHINA_BUILD
    private var isTailnet: Bool {
        vpnManager.status.isActive && vpnManager.activeProfileID == VPNTailnetProfile.id
    }

    /// No VPN is up, but Tailscale runs inside rootshell; show that instead of
    /// a bare "Disconnected".
    private var showsInAppTailnet: Bool {
        guard !vpnManager.status.isActive else { return false }
        let mode = TailnetModeSettings.load()
        return mode.effectiveMode == .rootshellOnly && (mode.inAppEnabled || engine.isStarted)
    }

    private var inAppTitle: String {
        guard engine.isStarted else {
            return String(localized: "Tailscale on, starts when needed", comment: "VPN status: in-app Tailscale waiting for first use")
        }
        switch engine.status?.state {
        case "Running": return String(localized: "Tailscale connected", comment: "VPN status: in-app Tailscale running")
        case "NeedsLogin": return String(localized: "Tailscale needs sign-in", comment: "VPN status: in-app Tailscale needs login")
        case "NeedsMachineAuth": return String(localized: "Tailscale waiting for approval", comment: "VPN status: in-app Tailscale awaiting admin")
        default: return String(localized: "Tailscale connecting…", comment: "VPN status: in-app Tailscale starting")
        }
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

    private var dotColor: Color {
        #if !CHINA_BUILD
        if showsInAppTailnet {
            guard engine.isStarted else { return .gray }
            if engine.status?.isRunning == true { return .green }
            return .orange
        }
        #endif
        return statusColor
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
