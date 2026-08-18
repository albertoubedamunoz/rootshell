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
    @AppStorage("sshHealthMonitoringEnabled") private var sshHealthMonitoringEnabled: Bool = true
    @AppStorage("sshHealthProbeInterval") private var sshHealthProbeInterval: Int = 15
    @AppStorage("hideNonPQKexWarning") private var hideNonPQKexWarning: Bool = false
    @AppStorage("sshPublicKeyAuthProbeEnabled") private var sshPublicKeyAuthProbeEnabled: Bool = false
    @AppStorage("sshForceIPv4Enabled") private var sshForceIPv4Enabled: Bool = false
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @AppStorage(UserPreferences.backgroundSessionKeepaliveEnabledKey) private var backgroundSessionKeepaliveEnabled: Bool = true
    #endif

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
                Toggle(isOn: $sshForceIPv4Enabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "network")
                        Text("Force IPv4")
                    }
                }
                .themedRow()

                #if !targetEnvironment(macCatalyst) && !os(visionOS)
                Toggle(isOn: $backgroundSessionKeepaliveEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "bolt.horizontal")
                        Text("Keep TCP SSH Alive in Background")
                    }
                }
                .themedRow()
                #endif
            } header: {
                Text("Network")
            } footer: {
                Text(networkFooterText)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { sshHealthMonitoringEnabled },
                    set: { newValue in
                        sshHealthMonitoringEnabled = newValue
                        NotificationCenter.default.post(
                            name: .sshHealthMonitoringToggled,
                            object: nil,
                            userInfo: ["enabled": newValue]
                        )
                    }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "heart.text.square")
                        Text("Connection Health Monitoring")
                    }
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
                    }
                    .themedRow()
                }
            } header: {
                Text("Health Monitoring")
            } footer: {
                Text("Periodically pings the SSH server to track round-trip time and packet loss. Shorter intervals react faster to network changes but use more data.")
            }

            Section {
                Toggle(isOn: $sshPublicKeyAuthProbeEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "key")
                        Text("OpenSSH Public Key Compatibility")
                    }
                }
                .themedRow()
            } header: {
                Text("Authentication")
            } footer: {
                Text("When enabled, SSH connections use the OpenSSH/libssh2 public-key flow: offer the public key first, then sign after the server accepts it. This can improve compatibility with some routers and embedded SSH servers, but adds one authentication round trip.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { !hideNonPQKexWarning },
                    set: { hideNonPQKexWarning = !$0 }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "shield.lefthalf.filled")
                        Text("Post-Quantum Warning")
                    }
                }
                .themedRow()
            } header: {
                Text("Security Warnings")
            } footer: {
                Text("Shows a banner after connecting when the SSH session negotiated a classical (non post-quantum) key exchange, which is vulnerable to harvest-now-decrypt-later attacks. See openssh.com/pq.html.")
            }
        }
        .themedList()
        .navigationTitle("SSH Transport")
        .navigationBarTitleDisplayMode(.inline)
    }
}
