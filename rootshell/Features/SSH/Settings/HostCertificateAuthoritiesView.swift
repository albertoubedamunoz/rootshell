import SwiftUI
import UniformTypeIdentifiers

/// View for managing trusted OpenSSH host certificate authorities.
///
/// A server presenting a host certificate signed by one of these CAs (whose
/// patterns match the hostname) is validated automatically, without the
/// host-key prompt — the fix for "host key changed" fatigue on hosts that
/// rotate keys behind a CA.
struct HostCertificateAuthoritiesView: View {
    @StateObject private var manager = HostCAManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var showingClearAllAlert = false

    var body: some View {
        List {
            Section {
                Text("Trust a certificate authority once and hosts presenting a matching, CA-signed certificate connect without a host-key prompt — even when their keys rotate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }

            if filteredCAs.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        if searchText.isEmpty {
                            Text("No Certificate Authorities")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Add a CA public key to auto-validate hosts that present certificates it signed.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        } else {
                            Text("No matching authorities")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .themedRow()
                }
            } else {
                ForEach(filteredCAs) { ca in
                    NavigationLink(destination: HostCertificateAuthorityDetailView(ca: ca)) {
                        HostCARow(ca: ca)
                    }
                }
                .onDelete(perform: deleteCAs)
                .themedRow()
            }

            // Kept out of the navigation bar: a leading "Clear All" button plus
            // the trailing add/search items leaves no room for the inline title.
            if !manager.allCAs.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showingClearAllAlert = true
                    } label: {
                        Text("Clear All")
                    }
                    .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Certificate Authorities")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search authorities")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddHostCertificateAuthorityView()
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Remove All Authorities?", isPresented: $showingClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove All", role: .destructive) {
                manager.removeAll()
            }
        } message: {
            Text("Hosts that relied on these CAs will prompt for host-key verification again.")
        }
    }

    private var filteredCAs: [HostCertificateAuthority] {
        if searchText.isEmpty {
            return manager.allCAs
        }
        return manager.allCAs.filter { ca in
            ca.name.localizedCaseInsensitiveContains(searchText) ||
            ca.patternsDisplay.localizedCaseInsensitiveContains(searchText) ||
            ca.fingerprint.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func deleteCAs(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredCAs[$0] }
        for ca in toDelete {
            manager.removeCA(id: ca.id)
        }
    }
}

/// Row view for a host CA entry.
struct HostCARow: View {
    let ca: HostCertificateAuthority

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(ca.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(ca.keyType.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.18))
                    .cornerRadius(4)
                    .fixedSize()
            }

            Text(ca.patternsDisplay)
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationView {
        HostCertificateAuthoritiesView()
    }
}
