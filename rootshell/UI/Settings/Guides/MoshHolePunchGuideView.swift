//
//  MoshHolePunchGuideView.swift
//  rootshell
//
//  Setup guide for mosh hole-punch server requirements and configuration.
//

import SwiftUI

struct MoshHolePunchGuideView: View {
    var body: some View {
        List {
            // MARK: - Server Requirements
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("hping3 with sudo access", systemImage: "checkmark.circle")
                        .foregroundColor(.primary)
                    Text("Roam sends an SSH command to run hping3 on the server. This sends a UDP packet from the mosh-server port to your public IP, punching through the firewall.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Server Requirements")
            } footer: {
                Text("hping3 requires raw socket access to set the correct source port. Alternatives: nping (from nmap) or scapy.")
            }

            // MARK: - Setup Instructions
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GuideInstructionStep(
                        number: 1,
                        title: "Install hping3",
                        code: "sudo apt install hping3",
                        note: "Or: dnf install hping3, brew install hping"
                    )

                    Divider()

                    GuideInstructionStep(
                        number: 2,
                        title: "Configure passwordless sudo",
                        code: "sudo visudo"
                    )

                    Divider()

                    GuideInstructionStep(
                        number: 3,
                        title: "Add this line (replace 'username')",
                        code: "username ALL=(ALL) NOPASSWD: /usr/sbin/hping3",
                        note: "Path may vary: /usr/bin/hping3 on some systems"
                    )
                }
                .padding(.vertical, 8)
                .themedRow()
            } header: {
                Text("Setup Instructions")
            }

            // MARK: - How It Works
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(
                        icon: "network",
                        title: "1. STUN Discovery",
                        description: "Client discovers its public IP:port via STUN servers (Google, Cloudflare)"
                    )

                    Divider()

                    GuideRow(
                        icon: "lock.shield",
                        title: "2. SSH Command (TCP)",
                        description: "Client sends hping3 command over the existing SSH connection to the server"
                    )

                    Divider()

                    GuideRow(
                        icon: "arrow.up.arrow.down",
                        title: "3. Server Punch (UDP)",
                        description: "Server runs hping3 to send UDP packet to client's public address, creating the return NAT mapping"
                    )

                    Divider()

                    GuideRow(
                        icon: "wifi.exclamationmark",
                        title: "4. Network Recovery",
                        description: "On WiFi/Cellular switch, client re-discovers STUN and re-punches via SSH"
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("How It Works")
            } footer: {
                Text("The SSH connection (TCP) is used to orchestrate the UDP hole-punch. This works because firewalls typically allow established TCP connections while blocking unsolicited inbound UDP.")
            }

            // MARK: - Troubleshooting
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    GuideCodeBlock(title: "Verify hping3 installation", code: "which hping3")

                    GuideCodeBlock(title: "Test sudo access", code: "sudo hping3 --version")
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("If sudo prompts for a password, the NOPASSWD rule is not configured correctly.")
            }
        }
        .themedList()
        .navigationTitle("Mosh Hole-Punch")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        MoshHolePunchGuideView()
    }
}
