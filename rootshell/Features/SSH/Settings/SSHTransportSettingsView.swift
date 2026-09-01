//
//  SSHTransportSettingsView.swift
//  rootshell
//
//  Settings for SSH transport-layer behavior: connection health monitoring
//  (keepalive probes + RTT/loss tracking) and security warnings such as the
//  post-quantum key-exchange banner.
//

import SwiftUI

struct SSHTransportSettingsView: View {
    @Setting(Settings.Connections.healthMonitoring) private var sshHealthMonitoringEnabled
    @Setting(Settings.Connections.healthProbeInterval) private var sshHealthProbeInterval

    private var networkFooterText: String {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        return String(localized: "Force IPv4 makes SSH TCP connections prefer IPv4 for hostnames and IPv4 addresses; IPv6 addresses are still allowed. Background keepalive requests a short grace period for active TCP SSH connections and interactive local commands. It does not apply to tssh or mosh.", comment: "SSH transport settings explanation")
        #else
        return String(localized: "Force IPv4 makes SSH TCP connections prefer IPv4 for hostnames and IPv4 addresses. IPv6 addresses are still allowed.", comment: "SSH transport settings explanation")
        #endif
    }

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Connections.forceIPv4, title: "Force IPv4", icon: "network")
                    .themedRow()

                #if !targetEnvironment(macCatalyst) && !os(visionOS)
                SettingToggle(Settings.Connections.backgroundKeepalive, title: "Keep TCP SSH Alive in Background", icon: "bolt.horizontal")
                    .themedRow()
                #endif
            } header: {
                SettingGroupHeader("Network", group: .connections)
            } footer: {
                Text(networkFooterText)
            }

            Section {
                SettingToggle(Settings.Connections.healthMonitoring, title: "Connection Health Monitoring", icon: "heart.text.square") { newValue in
                    NotificationCenter.default.post(
                        name: .sshHealthMonitoringToggled,
                        object: nil,
                        userInfo: ["enabled": newValue]
                    )
                }
                .themedRow()

                if sshHealthMonitoringEnabled {
                    Picker(selection: Binding(
                        get: { sshHealthProbeInterval },
                        set: { newValue in
                            sshHealthProbeInterval = newValue
                            NotificationCenter.default.post(
                                name: .sshHealthProbeIntervalChanged,
                                object: nil,
                                userInfo: ["interval": newValue]
                            )
                        }
                    )) {
                        Text("1 second").tag(1)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "timer")
                            Text("Probe Interval")
                        }
                        .settingRow(Settings.Connections.healthProbeInterval)
                    }
                    .themedRow()
                }
            } header: {
                SettingGroupHeader("Health Monitoring", group: .connections)
            } footer: {
                Text("Periodically pings the SSH server to track round-trip time and packet loss. Shorter intervals react faster to network changes but use more data.")
            }

            Section {
                SettingToggle(Settings.Connections.publicKeyAuthProbe, title: "OpenSSH Public Key Compatibility", icon: "key")
                    .themedRow()
            } header: {
                SettingGroupHeader("Authentication", group: .connections)
            } footer: {
                Text("When enabled, SSH connections use the OpenSSH/libssh2 public-key flow: offer the public key first, then sign after the server accepts it. This can improve compatibility with some routers and embedded SSH servers, but adds one authentication round trip.")
            }

            Section {
                SettingToggle(Settings.Connections.hideNonPQKexWarning, title: "Post-Quantum Warning", icon: "shield.lefthalf.filled", inverted: true)
                    .themedRow()
            } header: {
                SettingGroupHeader("Security Warnings", group: .connections)
            } footer: {
                Text("Shows a banner after connecting when the SSH session negotiated a classical (non post-quantum) key exchange, which is vulnerable to harvest-now-decrypt-later attacks. See openssh.com/pq.html.")
            }
        }
        .themedList()
        .navigationTitle("SSH Transport")
        .navigationBarTitleDisplayMode(.inline)
    }
}
