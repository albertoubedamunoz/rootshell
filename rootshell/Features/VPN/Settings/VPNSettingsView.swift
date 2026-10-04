//
//  VPNSettingsView.swift
//  rootshell
//
//  Main VPN management screen in Settings.
//  Mirrors TunnelSettingsView pattern.
//

import SwiftUI
import NetworkExtension
import UIKit

struct VPNSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var showDisconnectConfirmation = false
    @Environment(\.openHTTPCapture) private var openHTTPCapture

    var body: some View {
        List {
            #if !CHINA_BUILD
            quickConnectSection
            #endif
            statusSection
            disconnectSection
            vpnProfilesSection
            #if !CHINA_BUILD && os(iOS) && (!targetEnvironment(macCatalyst) || STANDALONE)
            tailscaleSection
            #endif
            #if !CHINA_BUILD
            autoRecoverySection
            httpCaptureSection
            #endif
            eventHistorySection
            debugSection
        }
        .themedList()
        .navigationTitle("VPN")
        #if !CHINA_BUILD
        .onAppear { vpnManager.reloadLastVPN() }
        #endif
        #if STANDALONE && targetEnvironment(macCatalyst)
        // The launch-time check misses a host that was still rebinding its socket.
        .task { await vpnManager.refreshStatusFromSystem() }
        #endif
    }

    #if !CHINA_BUILD
    // MARK: - Quick Connect

    /// One-tap reconnect to the last VPN, while nothing is connected.
    @ViewBuilder
    private var quickConnectSection: some View {
        if !vpnManager.status.isActive, let target = VPNQuickConnectCard.lastTarget() {
            Section {
                VPNQuickConnectCard(target: target)
                    .themedRow()
            }
        }
    }
    #endif

    #if !CHINA_BUILD && os(iOS) && (!targetEnvironment(macCatalyst) || STANDALONE)
    // MARK: - Tailscale Section

    private var tailscaleSection: some View {
        Section {
            NavigationLink {
                TailnetSettingsView()
            } label: {
                HStack {
                    Label {
                        Text(String(localized: "Tailscale", comment: "VPN settings row"))
                    } icon: {
                        Image("TailscaleLogo")
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    }
                    Spacer(minLength: 8)
                    if vpnManager.isVPNActive(for: VPNTailnetProfile.id) {
                        Text(String(localized: "On", comment: "Tailscale VPN is active"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedRow()
        } footer: {
            Text("Use this instead of the Tailscale app to reach your tailnet and still use HTTP capture and SSH routing. Only one VPN can be on at a time.")
        }
    }
    #endif

    #if !CHINA_BUILD
    // MARK: - Auto Recovery Section

    private var autoRecoverySection: some View {
        Section {
            SettingToggle(Settings.VPN.autoRecovery, title: "Auto Recovery")
                .themedRow()
        } footer: {
            Text("When rootshell opens, reconnect the VPN or Tailscale that was on when it last ran, such as after a restart or an app update. Skipped if another VPN app is connected.")
        }
    }

    // MARK: - HTTP Capture Section

    private var httpCaptureSection: some View {
        Section {
            if let openHTTPCapture {
                Button(String(localized: "Open HTTP Capture", comment: "VPN settings action: close Settings and show the capture panel")) {
                    openHTTPCapture()
                }
                .themedRow()
            }
            NavigationLink {
                CaptureSettingsView()
            } label: {
                HStack {
                    Text(String(localized: "Capture Settings", comment: "VPN settings row"))
                    Spacer(minLength: 8)
                    if CaptureController.shared.isRecording {
                        CaptureStatusText(
                            text: String(localized: "Recording", comment: "HTTP capture session state"),
                            systemImage: "record.circle", color: .red)
                    } else if CaptureCAManager.shared.hasCA {
                        CATrustBadge(state: CaptureCAManager.shared.trust)
                    }
                }
            }
            .themedRow()
            if vpnManager.status != .connected {
                Button(String(localized: "Connect Local Capture VPN", comment: "VPN settings action")) {
                    Task {
                        try? await vpnManager.startDirectVPN(
                            dnsServers: SettingsStore.shared.value(Settings.HTTPCapture.directDNSServers))
                    }
                }
                .themedRow()
            }
        } header: {
            Text("HTTP Capture")
        } footer: {
            Text("Inspect HTTP and HTTPS traffic through the VPN. Open the capture panel here, from the File menu, the keyboard toolbar, or with its keyboard shortcut. Local Capture is a VPN without a server, for capturing only.")
        }
    }
    #endif

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Status") {
            VPNStatusRow()
                .themedRow()

            if vpnManager.extensionApprovalPending {
                Label(
                    "Approve the VPN system extension in System Settings → Login Items & Extensions to finish connecting.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .themedRow()
            }

            if vpnManager.status.isActive {
                if let since = vpnManager.connectedSince {
                    LabeledContent("Uptime") {
                        Text(since, style: .timer)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
                if let stats = vpnManager.statistics {
                    VPNStatsGrid(stats: stats)
                        .themedRow()
                }

                if vpnManager.trafficHistory.count >= 2 {
                    VPNTrafficChart(snapshots: vpnManager.trafficHistory)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Disconnect Section

    @ViewBuilder
    private var disconnectSection: some View {
        if vpnManager.status.isActive {
            Section {
                Button("Disconnect VPN", role: .destructive) {
                    showDisconnectConfirmation = true
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
                    let name = vpnManager.activeProfileName ?? "the active profile"
                    Text("This will end your connection to \(name).")
                }
                .themedRow()
            }
        }
    }

    // MARK: - VPN Profiles Section

    private var vpnProfilesSection: some View {
        Section("VPN Profiles") {
            let profiles = vpnCapableProfiles
            if profiles.isEmpty {
                ContentUnavailableView(
                    "No VPN Profiles",
                    systemImage: "network.slash",
                    description: Text("Enable VPN in a connection profile's settings")
                )
                .themedRow()
            } else {
                ForEach(profiles) { profile in
                    VPNProfileRow(profile: profile)
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Event History Section

    @ViewBuilder
    private var eventHistorySection: some View {
        if !vpnManager.eventHistory.isEmpty {
            Section("Recent Events") {
                ForEach(vpnManager.eventHistory.suffix(20).reversed()) { event in
                    VPNEventRow(event: event)
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Debug Link

    private var debugSection: some View {
        Section {
            NavigationLink("Debug") {
                VPNDebugView()
            }
            .themedRow()
        }
    }

    // MARK: - Helpers

    private var vpnCapableProfiles: [ConnectionProfile] {
        profileManager.profiles.filter(\.isVPNCapable)
    }
}

// MARK: - VPN Stats Grid (compact single-row layout)

private struct VPNStatsGrid: View {
    let stats: VPNStatistics

    var body: some View {
        VStack(spacing: 6) {
            if let mode = stats.tsshMode {
                statRow("Transport", mode)
                if let mtu = stats.tsshMTU, mtu > 0 {
                    statRow("TSSH MTU", "\(mtu)")
                }
                if let tunMTU = stats.tunMTU, tunMTU > 0 {
                    statRow("TUN MTU", "\(tunMTU)")
                }
                if let port = stats.tsshPort {
                    statRow("Port", "\(port)")
                }
            }
            statRow("Downloaded", stats.formattedBytesIn)
            statRow("Uploaded", stats.formattedBytesOut)
            statRow("Active Flows", "\(stats.activeConnections)")
            if stats.activeTCPConnections > 0 || stats.activeUDPConnections > 0 {
                statRow("TCP / UDP", "\(stats.activeTCPConnections) / \(stats.activeUDPConnections)")
            }
            if stats.tcpCapacityDrops + stats.udpCapacityDrops > 0 {
                statRow("Flow Drops", "TCP \(stats.tcpCapacityDrops), UDP \(stats.udpCapacityDrops)", valueColor: .orange)
            }
            if stats.extensionPhysFootprintBytes > 0 {
                statRow("Ext Memory", stats.formattedExtensionMemory)
            }
            if stats.extensionMemoryBudgetBytes > 0 {
                let usagePercent = stats.effectiveMemoryUsagePercent
                let color: Color = usagePercent >= 90 ? .red : (usagePercent >= 75 ? .orange : .secondary)
                statRow("Mem Budget", stats.formattedMemoryBudgetUsage, valueColor: color)
            }
            if stats.goHeapAllocBytes > 0 {
                statRow("Go Heap", stats.formattedGoHeapAlloc)
            }
        }
        .padding(.vertical, 2)
    }

    private func statRow(_ label: String, _ value: String, valueColor: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
    }
}

// MARK: - VPN Debug View

struct VPNDebugView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var vpnManager = VPNManager.shared

    var body: some View {
        List {
            if let statusJSON = vpnManager.latestStatusJSON, !statusJSON.isEmpty {
                Section("Status JSON") {
                    Button("Copy Status JSON") {
                        UIPasteboard.general.string = statusJSON
                    }
                    .themedRow()

                    ScrollView(.vertical) {
                        Text(statusJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 400)
                    .themedRow()
                }
            }

            Section("Time-Series Log") {
                Button("Copy Time-Series Log") {
                    if let log = readTimeSeriesLog() {
                        UIPasteboard.general.string = log
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("VPN Debug")
    }

    private func readTimeSeriesLog() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.defaultAppGroupID
        ) else { return nil }
        let fileURL = containerURL.appendingPathComponent("vpn_ssh_timeseries.log")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}
