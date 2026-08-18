//
//  MoshHolePunchGuideView.swift
//  rootshell
//
//  Setup guide for mosh hole-punch server requirements and configuration.
//

import SwiftUI

struct MoshHolePunchGuideView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

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
                    instructionStep(
                        number: 1,
                        title: "Install hping3",
                        code: "sudo apt install hping3",
                        note: "Or: dnf install hping3, brew install hping"
                    )

                    Divider()

                    instructionStep(
                        number: 2,
                        title: "Configure passwordless sudo",
                        code: "sudo visudo",
                        note: nil
                    )

                    Divider()

                    instructionStep(
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
                    howItWorksRow(
                        icon: "network",
                        title: "1. STUN Discovery",
                        description: "Client discovers its public IP:port via STUN servers (Google, Cloudflare)"
                    )

                    Divider()

                    howItWorksRow(
                        icon: "lock.shield",
                        title: "2. SSH Command (TCP)",
                        description: "Client sends hping3 command over the existing SSH connection to the server"
                    )

                    Divider()

                    howItWorksRow(
                        icon: "arrow.up.arrow.down",
                        title: "3. Server Punch (UDP)",
                        description: "Server runs hping3 to send UDP packet to client's public address, creating the return NAT mapping"
                    )

                    Divider()

                    howItWorksRow(
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
                    Text("Verify hping3 installation:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    codeBlock("which hping3")

                    Text("Test sudo access:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.top, 4)

                    codeBlock("sudo hping3 --version")
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

    // MARK: - Helper Views

    private func codeBlock(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                UIPasteboard.general.string = code
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func instructionStep(number: Int, title: String, code: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            codeBlock(code)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func howItWorksRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        MoshHolePunchGuideView()
    }
}
