//
//  VPNDNSSettingsView.swift
//  rootshell
//
//  DNS server configuration for VPN tunnel.
//

import SwiftUI

struct VPNDNSSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Binding var dnsServers: [String]
    @State private var newServer: String = ""

    var body: some View {
        List {
            Section {
                ForEach(dnsServers, id: \.self) { server in
                    Text(server)
                        .font(.body.monospaced())
                        .themedRow()
                }
                .onDelete(perform: deleteServer)
            } header: {
                Text("DNS Servers")
            } footer: {
                Text("Leave empty to use system DNS. Custom DNS queries will be resolved through the VPN tunnel.")
            }

            Section("Add Server") {
                HStack {
                    TextField("IP Address (e.g., 8.8.8.8)", text: $newServer)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { addServer() }

                    Button("Add") {
                        addServer()
                    }
                    .disabled(newServer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .themedRow()
            }

            Section("Preset DNS Providers") {
                presetButton(name: "Google DNS", servers: ["8.8.8.8", "8.8.4.4"])
                    .themedRow()
                presetButton(name: "Cloudflare DNS", servers: ["1.1.1.1", "1.0.0.1"])
                    .themedRow()
                presetButton(name: "Quad9 DNS", servers: ["9.9.9.9", "149.112.112.112"])
                    .themedRow()
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("DNS Settings")
    }

    private func addServer() {
        let trimmed = newServer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !dnsServers.contains(trimmed) else { return }
        dnsServers.append(trimmed)
        newServer = ""
    }

    private func deleteServer(at offsets: IndexSet) {
        dnsServers.remove(atOffsets: offsets)
    }

    @ViewBuilder
    private func presetButton(name: String, servers: [String]) -> some View {
        let isActive = dnsServers == servers
        Button {
            dnsServers = servers
        } label: {
            LabeledContent {
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(servers.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}
