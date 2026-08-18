import SwiftUI

// MARK: - Manual AP Detail View

/// Detail/edit view for a manually associated WiFi access point.
struct ManualAPDetailView: View {
    let accessPoint: WiFiAccessPoint

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @ObservedObject private var manualAPManager = ManualAPManager.shared

    // Editable fields
    @State private var apName = ""
    @State private var model = ""
    @State private var siteName = ""
    @State private var vendorName = ""
    @State private var vendorDomain = ""
    @State private var didLoadInitial = false

    // What OUI auto-detection found (nil if no match)
    @State private var ouiDetectedName: String?

    @State private var showingVendorSearch = false
    @State private var showDeleteAlert = false

    /// Whether the current vendorName differs from what OUI would auto-detect.
    private var isVendorOverridden: Bool {
        guard let detected = ouiDetectedName else { return !vendorName.isEmpty }
        return vendorName != detected
    }

    var body: some View {
        List {
            bssidSection
            vendorSection
            apDetailsSection
            deleteSection
        }
        .themedList()
        .navigationTitle("Edit AP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(!hasChanges || !isFormValid)
            }
        }
        .onAppear {
            if !didLoadInitial {
                didLoadInitial = true
                apName = accessPoint.name
                model = accessPoint.model ?? ""
                siteName = accessPoint.siteName ?? ""
                vendorName = accessPoint.productLine ?? ""
                vendorDomain = manualAPManager.vendorDomain(forMAC: accessPoint.mac) ?? ""
            }
            // Run OUI detection to know what the "detected" baseline is
            if let vendor = OUILookup.lookup(bssid: accessPoint.mac) {
                ouiDetectedName = vendor.name
            }
        }
        .sheet(isPresented: $showingVendorSearch) {
            NavigationView {
                OUIVendorSearchView { name, domain in
                    vendorName = name
                    vendorDomain = domain ?? ""
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { showingVendorSearch = false }
                    }
                }
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Delete Manual AP", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                manualAPManager.deleteManualAP(mac: accessPoint.mac)
                dismiss()
            }
        } message: {
            Text("Remove the manual association for this BSSID?")
        }
    }

    // MARK: - BSSID Section

    private var bssidSection: some View {
        Section {
            HStack {
                Text("BSSID")
                Spacer()
                Text(accessPoint.mac)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .themedRow()
        } header: {
            Text("Identifier")
        }
    }

    // MARK: - Vendor Section

    private var vendorSection: some View {
        Section {
            // Always show vendor row if there's a name (saved, detected, or overridden)
            if !vendorName.isEmpty {
                HStack(spacing: 12) {
                    if !displayDomain.isEmpty {
                        FaviconImage(domain: displayDomain, size: 28)
                    } else {
                        Image(systemName: "building.2")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(vendorName)
                                .font(.body)
                            if !isVendorOverridden, ouiDetectedName != nil {
                                Text("detected")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
                                    .cornerRadius(3)
                            } else if isVendorOverridden {
                                Text("custom")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(3)
                            }
                        }
                        if !displayDomain.isEmpty {
                            Text(displayDomain)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .themedRow()
            }

            Button {
                showingVendorSearch = true
            } label: {
                Label(
                    vendorName.isEmpty ? "Select Vendor" : "Change Vendor",
                    systemImage: "magnifyingglass"
                )
            }
            .themedRow()

            TextField("Domain (for favicon)", text: $vendorDomain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .themedRow()
        } header: {
            Text("Vendor")
        }
    }

    // MARK: - AP Details Section

    private var apDetailsSection: some View {
        Section {
            TextField("AP Name", text: $apName)
                .themedRow()

            TextField("Model (optional)", text: $model)
                .themedRow()

            TextField("Site / Location (optional)", text: $siteName)
                .themedRow()
        } header: {
            Text("Access Point Details")
        }
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Manual AP")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    // MARK: - Computed

    /// Sanitized domain for display (favicon, subtitle).
    private var displayDomain: String {
        ManualAPManager.sanitizeDomain(vendorDomain) ?? ""
    }

    // MARK: - Helpers

    private var isFormValid: Bool {
        !apName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasChanges: Bool {
        let originalDomain = manualAPManager.vendorDomain(forMAC: accessPoint.mac) ?? ""
        let originalVendor = accessPoint.productLine ?? ""
        return apName != accessPoint.name ||
               model != (accessPoint.model ?? "") ||
               siteName != (accessPoint.siteName ?? "") ||
               vendorDomain != originalDomain ||
               vendorName != originalVendor
    }

    private func save() {
        manualAPManager.updateManualAP(
            mac: accessPoint.mac,
            name: apName.trimmingCharacters(in: .whitespaces),
            vendorName: vendorName.isEmpty ? nil : vendorName,
            vendorDomain: vendorDomain.isEmpty ? nil : vendorDomain,
            model: model.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.trimmingCharacters(in: .whitespaces),
            siteName: siteName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : siteName.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
    }
}
