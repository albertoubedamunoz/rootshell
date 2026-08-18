import SwiftUI

// MARK: - Manual AP Add View

/// Sheet for manually associating a BSSID with a vendor and AP name.
/// Auto-detects vendor from OUI database when a BSSID is entered.
struct ManualAPAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @ObservedObject private var manualAPManager = ManualAPManager.shared
    @ObservedObject private var wifiService = WiFiInfoService.shared

    // MARK: - Form State

    @State private var bssid = ""
    @State private var apName = ""
    @State private var model = ""
    @State private var siteName = ""

    // Vendor state
    @State private var vendorName = ""
    @State private var vendorDomain = ""
    @State private var isAutoDetected = false
    @State private var showingVendorSearch = false

    // BSSID fetch state
    @State private var isLoadingBSSID = false

    // Validation
    @State private var showDuplicateAlert = false

    var body: some View {
        Form {
            bssidSection
            vendorSection
            apDetailsSection
        }
        .themedList()
        .navigationTitle("Add Manual AP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(!isFormValid)
            }
        }
        .sheet(isPresented: $showingVendorSearch) {
            NavigationView {
                OUIVendorSearchView { name, domain in
                    vendorName = name
                    vendorDomain = domain ?? ""
                    isAutoDetected = false
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { showingVendorSearch = false }
                    }
                }
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Duplicate BSSID", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A manual AP with this BSSID already exists.")
        }
    }

    // MARK: - BSSID Section

    private var bssidSection: some View {
        Section {
            TextField("BSSID (e.g., AA:BB:CC:DD:EE:FF)", text: $bssid)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))
                .onChange(of: bssid) {
                    autoDetectVendor()
                }
                .themedRow()

            Button {
                useCurrentBSSID()
            } label: {
                HStack {
                    if isLoadingBSSID {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "wifi")
                    }
                    Text("Use Current BSSID")
                }
            }
            .disabled(isLoadingBSSID)
            .themedRow()
        } header: {
            Text("BSSID")
        } footer: {
            if let parsed = MACAddress(bssid) {
                Text("Normalized: \(parsed.canonicalString)")
            } else if !bssid.isEmpty {
                Text("Enter a valid MAC address")
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Vendor Section

    private var vendorSection: some View {
        Section {
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
                            if isAutoDetected {
                                Text("detected")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
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

                Button {
                    showingVendorSearch = true
                } label: {
                    Label("Override Vendor", systemImage: "magnifyingglass")
                }
                .themedRow()
            } else {
                Button {
                    showingVendorSearch = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text(bssid.isEmpty ? "Select Vendor" : "No vendor detected — Search")
                    }
                }
                .themedRow()
            }

            TextField("Domain (for favicon)", text: $vendorDomain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .themedRow()
        } header: {
            Text("Vendor")
        } footer: {
            Text("The domain is used to fetch a favicon for display in the bssid command and Live Activity.")
        }
    }

    // MARK: - AP Details Section

    private var apDetailsSection: some View {
        Section {
            TextField("AP Name (required)", text: $apName)
                .themedRow()

            TextField("Model (optional)", text: $model)
                .themedRow()

            TextField("Site / Location (optional)", text: $siteName)
                .themedRow()
        } header: {
            Text("Access Point Details")
        }
    }

    // MARK: - Computed

    /// Sanitized domain for display (favicon, subtitle). The raw text field
    /// may contain a URL or whitespace that would break FaviconImage.
    private var displayDomain: String {
        ManualAPManager.sanitizeDomain(vendorDomain) ?? ""
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        MACAddress(bssid) != nil &&
        !apName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func useCurrentBSSID() {
        isLoadingBSSID = true
        Task {
            await wifiService.fetch()
            if let currentBSSID = wifiService.bssid {
                bssid = currentBSSID
                autoDetectVendor()
            }
            isLoadingBSSID = false
        }
    }

    private func autoDetectVendor() {
        guard MACAddress(bssid) != nil else {
            // Invalid MAC — clear any previously auto-detected state
            if isAutoDetected {
                vendorName = ""
                vendorDomain = ""
                isAutoDetected = false
            }
            return
        }

        if let vendor = OUILookup.lookup(bssid: bssid) {
            vendorName = vendor.name
            vendorDomain = vendor.website.flatMap { FaviconFetcher.extractDomain(from: $0) } ?? ""
            isAutoDetected = true
        } else {
            // Valid MAC but no OUI match — clear auto-detected state
            if isAutoDetected {
                vendorName = ""
                vendorDomain = ""
                isAutoDetected = false
            }
        }
    }

    private func save() {
        let trimmedName = apName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let canonical = MACAddress(bssid)?.canonicalString ?? bssid
        if manualAPManager.manualAPs.contains(where: { $0.mac == canonical }) {
            showDuplicateAlert = true
            return
        }

        manualAPManager.addManualAP(
            bssid: bssid,
            name: trimmedName,
            vendorName: vendorName.isEmpty ? nil : vendorName,
            vendorDomain: vendorDomain.isEmpty ? nil : vendorDomain,
            model: model.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.trimmingCharacters(in: .whitespaces),
            siteName: siteName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : siteName.trimmingCharacters(in: .whitespaces)
        )

        dismiss()
    }
}
