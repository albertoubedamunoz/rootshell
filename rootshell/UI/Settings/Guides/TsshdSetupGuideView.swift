//
//  TsshdSetupGuideView.swift
//  rootshell
//
//  Setup guide for tsshd installation and overview of its advantages.
//

import SwiftUI

struct TsshdSetupGuideView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            // MARK: - Overview
            Section {
                Link(destination: URL(string: "https://github.com/trzsz/tsshd")!) {
                    HStack {
                        Label("tsshd Installation Guide", systemImage: "arrow.up.right.square")
                        Spacer()
                    }
                }
                .themedRow()
            } header: {
                Text("tsshd Setup")
            } footer: {
                Text("tsshd uses QUIC or KCP transport. No additional firewall configuration is required as both protocols handle NAT traversal automatically.")
            }

            // MARK: - Advantages
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    howItWorksRow(
                        icon: "bolt.shield",
                        title: "Built-in NAT Traversal",
                        description: "QUIC and KCP handle NAT hole-punching automatically, no hping3 setup required"
                    )

                    Divider()

                    howItWorksRow(
                        icon: "lock.shield",
                        title: "Modern Encryption",
                        description: "QUIC uses TLS 1.3; KCP uses AES-GCM-256"
                    )

                    Divider()

                    howItWorksRow(
                        icon: "waveform.path.ecg",
                        title: "Better Roaming",
                        description: "QUIC's connection migration provides seamless network transitions"
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Why tsshd?")
            }
        }
        .themedList()
        .navigationTitle("tsshd Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

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
        TsshdSetupGuideView()
    }
}
