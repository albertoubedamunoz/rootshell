import SwiftUI

// MARK: - OUI Vendor Search View

/// Searchable vendor picker from the IEEE OUI database (~20K unique vendors).
/// Requires at least 2 characters before showing results to avoid rendering
/// the entire dataset in SwiftUI's List.
struct OUIVendorSearchView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String, String?) -> Void  // (vendorName, domain?)

    @State private var searchText = ""
    @State private var results: [OUILookup.VendorEntry] = []

    private static let maxResults = 50

    var body: some View {
        List {
            if searchText.count < 2 {
                Section {
                    Text("Type at least 2 characters to search \(OUILookup.uniqueVendorCount) vendors")
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            } else if results.isEmpty {
                Section {
                    Text("No vendors matching \"\(searchText)\"")
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            } else {
                Section {
                    ForEach(results) { vendor in
                        Button {
                            onSelect(vendor.name, vendor.domain)
                            dismiss()
                        } label: {
                            VendorRowView(vendor: vendor)
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    if results.count >= Self.maxResults {
                        Text("Showing first \(Self.maxResults) results — refine your search")
                    } else {
                        Text("\(results.count) vendor\(results.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .themedList()
        .searchable(text: $searchText, prompt: "Search vendors...")
        .onChange(of: searchText) {
            updateResults()
        }
        .navigationTitle("Select Vendor")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func updateResults() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            results = []
            return
        }
        results = OUILookup.searchVendors(query: query, limit: Self.maxResults)
    }
}

// MARK: - Vendor Row

private struct VendorRowView: View {
    let vendor: OUILookup.VendorEntry

    var body: some View {
        HStack(spacing: 12) {
            // Only show favicon for vendors with a known domain — avoids
            // triggering network fetches for rows that will never succeed.
            if let domain = vendor.domain {
                FaviconImage(domain: domain, size: 28)
            } else {
                Image(systemName: "building.2")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(vendor.name)
                    .font(.body)
                    .lineLimit(2)

                if let domain = vendor.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
