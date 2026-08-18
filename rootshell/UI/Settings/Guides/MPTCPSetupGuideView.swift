//
//  MPTCPSetupGuideView.swift
//  rootshell
//
//  Setup guide for enabling Multipath TCP on SSH servers.
//

import SwiftUI

struct MPTCPSetupGuideView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            // MARK: - Overview
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Multipath TCP (MPTCP) lets a single TCP connection use multiple network paths simultaneously. When your device switches from WiFi to cellular, the SSH connection migrates seamlessly instead of dropping.")
                        .font(.subheadline)
                    Text("Both the client and the server must support MPTCP. The toggle in Roam Settings enables the client side — this guide covers configuring your server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            // MARK: - Prerequisites
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Linux kernel 5.6 or later is required for MPTCP v1 support.")
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 4) {
                        distroVersionRow(distro: "Ubuntu", version: "20.10+")
                        distroVersionRow(distro: "Debian", version: "11 (Bullseye)+")
                        distroVersionRow(distro: "Fedora", version: "33+")
                        distroVersionRow(distro: "RHEL / CentOS", version: "9+")
                        distroVersionRow(distro: "Arch Linux", version: "Rolling (kernel 5.6+)")
                    }
                    .padding(.vertical, 4)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Prerequisites")
            }

            // MARK: - Check MPTCP Support
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verify that your kernel has MPTCP enabled:")
                        .font(.subheadline)

                    codeBlock("sysctl net.mptcp.enabled")

                    Text("Should return: net.mptcp.enabled = 1")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("If it returns 0, enable it temporarily:")
                        .font(.subheadline)
                        .padding(.top, 4)

                    codeBlock("sudo sysctl -w net.mptcp.enabled=1")

                    Text("To persist across reboots, add to /etc/sysctl.conf:")
                        .font(.subheadline)
                        .padding(.top, 4)

                    codeBlock("net.mptcp.enabled=1")
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Check MPTCP Support")
            }

            // MARK: - Ubuntu / Debian
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    instructionStep(
                        number: 1,
                        title: "Install mptcpize",
                        code: "sudo apt install mptcpd",
                        note: "Provides the mptcpize wrapper for converting TCP services to MPTCP."
                    )

                    Divider()

                    Text("Choose one method based on your systemd version:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)

                    // Method A
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Method A: systemd 257+ (Ubuntu 25.04+)")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        instructionStep(
                            number: 2,
                            title: "Override ssh.socket to use MPTCP",
                            code: "sudo systemctl edit ssh.socket",
                            note: "Add the following in the editor that opens:"
                        )

                        codeBlock("[Socket]\nSocketProtocol=mptcp")

                        instructionStep(
                            number: 3,
                            title: "Restart the socket",
                            code: "sudo systemctl restart ssh.socket",
                            note: nil
                        )
                    }

                    Divider()

                    // Method B
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Method B: Older systemd (Ubuntu 20.10–24.10, Debian 11+)")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        instructionStep(
                            number: 2,
                            title: "Disable socket activation, enable service",
                            code: "sudo systemctl disable --now ssh.socket\nsudo systemctl enable --now ssh.service",
                            note: "Switches from socket-activated to service-managed SSH."
                        )

                        instructionStep(
                            number: 3,
                            title: "Wrap sshd with mptcpize",
                            code: "sudo mptcpize enable ssh.service",
                            note: "Creates a systemd override that launches sshd under the mptcpize wrapper."
                        )

                        instructionStep(
                            number: 4,
                            title: "Restart SSH",
                            code: "sudo systemctl restart ssh.service",
                            note: nil
                        )
                    }
                }
                .padding(.vertical, 8)
                .themedRow()
            } header: {
                Text("Ubuntu / Debian")
            }

            // MARK: - Fedora / RHEL
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    instructionStep(
                        number: 1,
                        title: "Install mptcpd and mptcpize",
                        code: "sudo dnf install mptcpd mptcpize",
                        note: nil
                    )

                    Divider()

                    instructionStep(
                        number: 2,
                        title: "Wrap sshd with mptcpize",
                        code: "sudo mptcpize enable sshd.service",
                        note: nil
                    )

                    Divider()

                    instructionStep(
                        number: 3,
                        title: "Restart SSH",
                        code: "sudo systemctl restart sshd.service",
                        note: "Fedora/RHEL use sshd.service (not ssh.service)."
                    )
                }
                .padding(.vertical, 8)
                .themedRow()
            } header: {
                Text("Fedora / RHEL / CentOS / Rocky / Alma")
            }

            // MARK: - Arch Linux
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    instructionStep(
                        number: 1,
                        title: "Install mptcpd",
                        code: "sudo pacman -S mptcpd",
                        note: nil
                    )

                    Divider()

                    instructionStep(
                        number: 2,
                        title: "Wrap sshd with mptcpize",
                        code: "sudo mptcpize enable sshd.service",
                        note: nil
                    )

                    Divider()

                    instructionStep(
                        number: 3,
                        title: "Restart SSH",
                        code: "sudo systemctl restart sshd.service",
                        note: nil
                    )
                }
                .padding(.vertical, 8)
                .themedRow()
            } header: {
                Text("Arch Linux")
            }

            // MARK: - Verify
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("After restarting SSH, connect with the MPTCP toggle enabled, then run on the server:")
                        .font(.subheadline)

                    codeBlock("ss -nti | grep mptcp")

                    Text("You should see mptcp listed in the connection info for your SSH session. If no output appears, the server is not accepting MPTCP connections.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Verify")
            } footer: {
                Text("MPTCP is backward-compatible — if the server doesn't support it, the connection automatically falls back to regular TCP.")
            }
        }
        .themedList()
        .navigationTitle("MPTCP Server Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    private func distroVersionRow(distro: String, version: String) -> some View {
        HStack {
            Text(distro)
                .font(.caption)
                .frame(width: 110, alignment: .leading)
            Text(version)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

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
}

#Preview {
    NavigationView {
        MPTCPSetupGuideView()
    }
}
