//
//  VPNQuickConnectCard.swift
//  rootshell
//
//  One-tap reconnect to the last VPN used, at the top of VPN settings.
//

#if !CHINA_BUILD

import NetworkExtension
import SwiftUI

struct VPNQuickConnectCard: View {
    enum Target {
        case profile(ConnectionProfile)
        case tailscale
    }

    let target: Target
    @State private var vpnManager = VPNManager.shared
    @State private var isStarting = false
    @State private var errorMessage: String?

    /// The last VPN used, if it can still be started here.
    @MainActor
    static func lastTarget() -> Target? {
        guard let id = VPNManager.shared.lastVPNProfileID else { return nil }
        if id == VPNTailnetProfile.id {
            return tailscaleAvailable ? .tailscale : nil
        }
        return ConnectionProfileManager.shared.profiles
            .first { $0.id == id && $0.isVPNCapable }
            .map(Target.profile)
    }

    private static var tailscaleAvailable: Bool {
        #if os(iOS) && (!targetEnvironment(macCatalyst) || STANDALONE)
        true
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Last Used", comment: "VPN quick connect: caption above the last VPN's name"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Button(action: connect) {
                HStack(spacing: 8) {
                    if isStarting {
                        ProgressView()
                    } else {
                        Image(systemName: "power")
                    }
                    Text(isStarting
                         ? String(localized: "Connecting…", comment: "VPN quick connect button while starting")
                         : String(localized: "Connect", comment: "VPN quick connect button"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting || vpnManager.status == .disconnecting)
            .accessibilityHint(Text(String(localized: "Reconnects to \(name)", comment: "VPN quick connect accessibility hint")))
        }
        .padding(.vertical, 6)
        .alert(
            String(localized: "VPN Error", comment: "VPN quick connect error alert title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Content

    private var name: String {
        switch target {
        case .profile(let profile): profile.name
        case .tailscale: String(localized: "Tailscale", comment: "Name of the Tailscale VPN")
        }
    }

    private var detail: String {
        switch target {
        case .profile(let profile):
            return "\(profile.displayString) · \(profile.vpnTransportName)"
        case .tailscale:
            return VPNTailnetProfile.summary()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch target {
        case .profile(let profile):
            Image(systemName: profile.connectionProtocol.iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .tailscale:
            Image("TailscaleLogo")
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - Actions

    private func connect() {
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                switch target {
                case .profile(let profile):
                    try await vpnManager.startVPN(for: profile)
                case .tailscale:
                    try await vpnManager.startTailnetVPN()
                    // Outlives this card, which hides once the tunnel starts.
                    TailnetLoginCoordinator.shared.watch()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
