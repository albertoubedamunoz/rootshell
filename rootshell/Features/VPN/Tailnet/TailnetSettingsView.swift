//
//  TailnetSettingsView.swift
//  rootshell
//
//  Tailscale VPN: sign-in, device settings, SSH egress and routing rules.
//

#if !CHINA_BUILD

import NetworkExtension
import SwiftUI
import UIKit

struct TailnetSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var settings = VPNTailnetProfile.settings()
    /// Settings the running tunnel started with (written by the extension).
    @State private var appliedSettings = VPNTailnetProfile.appliedSettings()
    @State private var status: TailnetStatus?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var login = TailnetLoginCoordinator.shared
    @State private var showSignOutConfirmation = false

    private var isActive: Bool { vpnManager.isVPNActive(for: VPNTailnetProfile.id) }
    private var isConnected: Bool { isActive && vpnManager.isTunnelUp }
    private var needsRestart: Bool {
        guard isConnected, let appliedSettings else { return false }
        return settings != appliedSettings
    }

    var body: some View {
        List {
            statusSection
            deviceSection
            egressSection
            if let peers = status?.peers, !peers.isEmpty {
                peersSection(peers)
            }
            accountSection
        }
        .themedList()
        .navigationTitle(String(localized: "Tailscale", comment: "Tailscale VPN settings title"))
        .onAppear {
            if settings.hostname.isEmpty {
                #if targetEnvironment(macCatalyst)
                settings.hostname = "rootshell-mac"
                #else
                settings.hostname = "rootshell-" + UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "-")
                #endif
            }
        }
        .onChange(of: settings) { old, new in
            VPNTailnetProfile.store(new)
            if old.sshEgressProfileID != new.sshEgressProfileID {
                profileManager.refreshVPNSharedProfiles()
            }
        }
        .task(id: isConnected) { await pollStatus() }
        .alert(
            String(localized: "Tailscale", comment: "Tailscale error alert title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent(String(localized: "Status", comment: "Tailscale status row")) {
                Text(statusText).foregroundStyle(.secondary)
            }
            .themedRow()

            if let node = status?.selfNode, status?.isRunning == true {
                LabeledContent(node.displayName) {
                    Text(node.ips?.first ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
                }
                .hostAddressCopyMenu(name: node.displayName, hostname: node.dnsName, ipAddress: node.ips?.first)
                .themedRow()
            }
            if let tailnet = status?.tailnet, !tailnet.isEmpty {
                LabeledContent(String(localized: "Tailnet", comment: "Tailscale tailnet name row"), value: tailnet)
                    .themedRow()
            }
            if let egress = status?.egress {
                LabeledContent(String(localized: "SSH Egress", comment: "Tailscale SSH egress status row")) {
                    Text(egressText(egress)).foregroundStyle(egress.state == "failed" ? .orange : .secondary)
                }
                .themedRow()
            }

            if isActive {
                if status?.needsLogin == true {
                    Button(String(localized: "Sign In", comment: "Tailscale sign-in button")) { signIn() }
                        .disabled(isWorking || login.isSigningIn)
                        .themedRow()
                }
                if needsRestart {
                    Button(String(localized: "Apply Changes", comment: "Tailscale: reconnect so changed settings apply")) {
                        connect(restart: true)
                    }
                    .disabled(isWorking)
                    .themedRow()
                }
                Button(String(localized: "Disconnect", comment: "Tailscale disconnect button"), role: .destructive) {
                    Task { try? await vpnManager.stopVPN() }
                }
                .themedRow()
            } else {
                Button(String(localized: "Connect", comment: "Tailscale connect button")) { connect(restart: false) }
                    .disabled(isWorking)
                    .themedRow()
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Use this instead of the Tailscale app. Only one VPN can be on at a time, so with the Tailscale app connected, HTTP capture can't run. Connected here, capture works on tailnet and internet traffic alike. MagicDNS names and tailnet addresses work in every app.")
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent(String(localized: "Device Name", comment: "Tailscale hostname row")) {
                TextField(String(localized: "Device Name", comment: "Tailscale hostname row"), text: $settings.hostname)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .themedRow()
            Toggle(String(localized: "Use Subnet Routes", comment: "Tailscale accept-routes toggle"), isOn: $settings.acceptRoutes)
                .themedRow()
        } header: {
            Text("Device")
        } footer: {
            Text("Subnet routes let this device reach networks that other tailnet machines advertise.")
        }
    }

    private var egressSection: some View {
        Section {
            Picker(String(localized: "SSH Host", comment: "Tailscale SSH egress profile picker"), selection: $settings.sshEgressProfileID) {
                Text(String(localized: "None", comment: "Tailscale SSH egress: none")).tag(UUID?.none)
                ForEach(sshProfiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .themedRow()

            Toggle(String(localized: "Send Other Traffic Through SSH", comment: "Tailscale: full tunnel through the SSH host"), isOn: $settings.sendAllViaSSH)
                .disabled(settings.sshEgressProfileID == nil)
                .themedRow()

            NavigationLink {
                VPNRoutingRulesEditor(rules: $settings.rules)
            } label: {
                LabeledContent(String(localized: "Routing Rules", comment: "Tailscale routing rules row")) {
                    Text("\(settings.rules.count)").foregroundStyle(.secondary)
                }
            }
            .disabled(settings.sshEgressProfileID == nil)
            .themedRow()

            NavigationLink {
                VPNDNSSettingsView(dnsServers: $settings.dnsServers)
            } label: {
                LabeledContent(String(localized: "DNS Servers", comment: "Tailscale fallback DNS row")) {
                    Text(settings.dnsServers.isEmpty
                         ? String(localized: "Default", comment: "Tailscale fallback DNS: default")
                         : settings.dnsServers.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()
        } header: {
            Text("SSH Egress")
        } footer: {
            Text("Routing rules send matching domains or networks out through the SSH host, which can itself be on your tailnet. Names with an SSH rule are resolved on that host. Turn on Send Other Traffic Through SSH to route everything except the tailnet that way. The host's key must already be trusted from a terminal session.")
        }
    }

    private func peersSection(_ peers: [TailnetStatus.Peer]) -> some View {
        Section {
            ForEach(peers) { peer in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(peer.online ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(peer.displayName)
                            Spacer(minLength: 8)
                            if let os = peer.os, !os.isEmpty {
                                Text(os).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Group {
                            if let dnsName = peer.dnsName, !dnsName.isEmpty {
                                Text(dnsName).truncationMode(.middle)
                            }
                            if let ip = peer.ips?.first {
                                Text(ip)
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .hostAddressCopyMenu(name: peer.displayName, hostname: peer.dnsName, ipAddress: peer.ips?.first)
                .themedRow()
            }
        } header: {
            if let total = status?.peersTotal, total > peers.count {
                Text("Devices (\(peers.count) of \(total))")
            } else {
                Text("Devices")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if status?.isRunning == true {
                Button(String(localized: "Sign Out", comment: "Tailscale sign-out button"), role: .destructive) {
                    showSignOutConfirmation = true
                }
                .confirmationDialog(
                    String(localized: "Sign out of Tailscale?", comment: "Tailscale sign-out confirmation"),
                    isPresented: $showSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Sign Out", comment: "Tailscale sign-out button"), role: .destructive) { signOut() }
                }
                .themedRow()
            } else if !isActive && Self.canForgetDevice {
                Button(String(localized: "Forget This Device", comment: "Tailscale: delete stored node keys"), role: .destructive) {
                    TailnetKeychain.deleteAll()
                }
                .themedRow()
            }
        } footer: {
            if !isActive && Self.canForgetDevice {
                Text("Forgetting the device deletes its Tailscale keys here; the next connect signs in as a new device.")
            }
        }
    }

    /// On the Mac the keys live in the VPN system extension, out of the app's
    /// reach; Sign Out (while connected) forgets them there.
    private static var canForgetDevice: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }

    // MARK: - Helpers

    private var sshProfiles: [ConnectionProfile] {
        profileManager.profiles.filter { !$0.isDeleted && ($0.connectionProtocol == .ssh || $0.connectionProtocol == .trzsz) }
    }

    private var statusText: String {
        guard isActive else { return String(localized: "Off", comment: "Tailscale state") }
        guard let status else { return String(localized: "Connecting…", comment: "Tailscale state") }
        switch status.state {
        case "Running": return String(localized: "Connected", comment: "Tailscale state")
        case "NeedsLogin": return String(localized: "Needs Sign-In", comment: "Tailscale state")
        case "NeedsMachineAuth": return String(localized: "Waiting for Admin Approval", comment: "Tailscale state")
        case "Starting": return String(localized: "Starting…", comment: "Tailscale state")
        default: return String(localized: "Connecting…", comment: "Tailscale state")
        }
    }

    private func egressText(_ egress: TailnetStatus.Egress) -> String {
        switch egress.state {
        case "connected": return String(localized: "Connected", comment: "Tailscale SSH egress state")
        case "connecting": return String(localized: "Connecting…", comment: "Tailscale SSH egress state")
        case "waitingForTailnet": return String(localized: "Waiting for Tailscale", comment: "Tailscale SSH egress state")
        case "failed": return egress.error ?? String(localized: "Failed", comment: "Tailscale SSH egress state")
        default: return String(localized: "Off", comment: "Tailscale SSH egress state")
        }
    }

    // MARK: - Actions

    private func connect(restart: Bool) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await vpnManager.startTailnetVPN(restart: restart)
                login.watch()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func signIn() {
        isWorking = true
        Task {
            defer { isWorking = false }
            if let error = await login.signIn() {
                errorMessage = error
            }
        }
    }

    private func signOut() {
        login.cancel()
        Task {
            if let error = await vpnManager.tailnetLogout() {
                errorMessage = error
            }
        }
    }

    /// Polls the extension for display while connected; the login
    /// coordinator owns the login page.
    private func pollStatus() async {
        guard isConnected else {
            status = nil
            return
        }
        while !Task.isCancelled {
            status = await vpnManager.tailnetStatus()
            appliedSettings = VPNTailnetProfile.appliedSettings()
            try? await Task.sleep(for: .seconds(login.isSigningIn ? 1 : 3))
        }
    }
}

#endif
