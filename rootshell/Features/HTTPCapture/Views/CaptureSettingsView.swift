//
//  CaptureSettingsView.swift
//  rootshell
//
//  Capture settings: certificate, decrypted hosts, rewrite rules, options,
//  and storage. Changes are pushed to a running capture immediately.
//

#if !CHINA_BUILD

import SwiftUI
import UniformTypeIdentifiers

struct CaptureSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openHTTPCapture) private var openHTTPCapture
    @Setting(Settings.HTTPCapture.enableHTTP2) private var enableHTTP2
    @Setting(Settings.HTTPCapture.autoBypassPinned) private var autoBypassPinned
    @Setting(Settings.HTTPCapture.skipUpstreamVerify) private var skipUpstreamVerify
    @Setting(Settings.HTTPCapture.recordPackets) private var recordPackets
    @Setting(Settings.HTTPCapture.lookUpServerLocation) private var lookUpServerLocation
    @Setting(Settings.HTTPCapture.showFavicons) private var showFavicons
    @Setting(Settings.HTTPCapture.maxBodyMB) private var maxBodyMB
    @Setting(Settings.HTTPCapture.maxSessionMB) private var maxSessionMB
    @Setting(Settings.HTTPCapture.retainedSessions) private var retainedSessions
    @Setting(Settings.HTTPCapture.mitmHosts) private var mitmHosts
    @Setting(Settings.HTTPCapture.directDNSServers) private var directDNSServers

    @State private var dnsText = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        Form {
            if let openHTTPCapture {
                Section {
                    Button(String(localized: "Open HTTP Capture", comment: "VPN settings action: close Settings and show the capture panel")) {
                        saveDNS()
                        openHTTPCapture()
                    }
                }
                .themedRow()
            }

            Section {
                NavigationLink {
                    CATrustGuideView()
                } label: {
                    LabeledContent(String(localized: "Certificate", comment: "HTTP capture settings row")) {
                        CATrustBadge(state: CaptureCAManager.shared.trust)
                    }
                }
            } footer: {
                Text("HTTPS can only be decrypted for apps that trust the rootshell capture certificate.")
            }
            .themedRow()

            Section {
                NavigationLink {
                    HostRulesEditor(rules: mitmHosts)
                } label: {
                    LabeledContent(String(localized: "Decrypted Hosts", comment: "HTTP capture settings row")) {
                        Text(hostSummary).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    RewriteRulesList()
                } label: {
                    LabeledContent(String(localized: "Rewrite Rules", comment: "HTTP capture settings row")) {
                        Text("\(CaptureController.rewriteRules().filter(\.enabled).count)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Plain HTTP is always recorded. HTTPS is decrypted only for matching hosts; everything else is listed as a connection.")
            }
            .themedRow()

            Section {
                Toggle(String(localized: "Decrypt HTTP/2", comment: "HTTP capture option"), isOn: pushing($enableHTTP2))
                Toggle(String(localized: "Skip Hosts That Reject the Certificate", comment: "HTTP capture option"), isOn: pushing($autoBypassPinned))
                Toggle(String(localized: "Skip Server Certificate Verification", comment: "HTTP capture option"), isOn: pushing($skipUpstreamVerify))
                Toggle(String(localized: "Record Packets for pcap", comment: "HTTP capture option"), isOn: $recordPackets)
            } header: {
                Text("Options")
            } footer: {
                Text("Apps that pin certificates refuse decrypted connections; skipping them keeps those apps working. Packet recording applies to new sessions and makes a pcapng that Wireshark can decrypt.")
            }
            .themedRow()

            Section {
                Toggle(String(localized: "Look Up Server Locations", comment: "HTTP capture option"), isOn: $lookUpServerLocation)
                Toggle(String(localized: "Show Network Favicons", comment: "HTTP capture option"), isOn: $showFavicons)
                    .disabled(!lookUpServerLocation)
            } header: {
                Text("Server Info")
            } footer: {
                Text("Server addresses are looked up with the location provider chosen in Settings. Favicons are downloaded from the server network's website.")
            }
            .themedRow()

            Section {
                Stepper(value: pushing($maxBodyMB), in: 1...200) {
                    LabeledContent(String(localized: "Maximum Body Size", comment: "HTTP capture option"), value: "\(maxBodyMB) MB")
                }
                Stepper(value: pushing($maxSessionMB), in: 50...10000, step: 50) {
                    LabeledContent(String(localized: "Maximum Session Size", comment: "HTTP capture option"), value: "\(maxSessionMB) MB")
                }
                Stepper(value: $retainedSessions, in: 1...1000) {
                    LabeledContent(String(localized: "Sessions to Keep", comment: "HTTP capture option"), value: "\(retainedSessions)")
                }
                Button(String(localized: "Delete All Sessions…", comment: "HTTP capture action"), role: .destructive) {
                    confirmDeleteAll = true
                }
            } header: {
                Text("Storage")
            }
            .themedRow()

            Section {
                TextField(String(localized: "8.8.8.8, 1.1.1.1", comment: "HTTP capture DNS placeholder"), text: $dnsText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit(saveDNS)
            } header: {
                Text("Local Capture DNS")
            } footer: {
                Text("Comma-separated DNS servers for the Local Capture VPN. Leave empty to use 8.8.8.8 and 1.1.1.1.")
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedList()
        .navigationTitle(String(localized: "Capture Settings", comment: "HTTP capture settings title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done", comment: "Done button")) {
                    saveDNS()
                    dismiss()
                }
            }
        }
        .confirmationDialog(String(localized: "Delete all finished sessions?", comment: "HTTP capture delete-all confirmation"),
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button(String(localized: "Delete All", comment: "HTTP capture delete-all button"), role: .destructive) {
                Task { await CaptureSessionStore.shared.deleteAll() }
            }
        }
        .onAppear {
            dnsText = directDNSServers.joined(separator: ", ")
            CaptureCAManager.shared.refreshTrust()
        }
    }

    private var hostSummary: String {
        let includes = mitmHosts.filter { !$0.hasPrefix("-") && !$0.hasPrefix("#") && !$0.isEmpty }
        if includes.contains("*") { return String(localized: "All", comment: "HTTP capture: every host decrypted") }
        if includes.isEmpty { return String(localized: "None", comment: "HTTP capture: no host decrypted") }
        return includes.prefix(2).joined(separator: ", ") + (includes.count > 2 ? " +\(includes.count - 2)" : "")
    }

    private func saveDNS() {
        let servers = dnsText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        if servers != directDNSServers { directDNSServers = servers }
    }

    /// A binding that also re-sends the engine config after a change.
    private func pushing<V>(_ binding: Binding<V>) -> Binding<V> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            Task { await CaptureController.shared.pushConfig() }
        })
    }
}

// MARK: - Certificate

struct CATrustBadge: View {
    let state: CaptureCAManager.TrustState

    var body: some View {
        switch state {
        case .trusted:
            CaptureStatusText(text: String(localized: "Trusted", comment: "HTTP capture CA state"), systemImage: "checkmark.seal.fill", color: .green)
        case .untrusted:
            CaptureStatusText(text: String(localized: "Not Trusted", comment: "HTTP capture CA state"), systemImage: "exclamationmark.shield", color: .orange)
        case .checking:
            ProgressView().controlSize(.small)
        case .missing:
            CaptureStatusText(text: String(localized: "Created on First Use", comment: "HTTP capture CA state"), systemImage: "seal", color: .secondary)
        }
    }
}

/// One-line icon + text status for trailing row values.
struct CaptureStatusText: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }
}

struct CATrustGuideView: View {
    /// Set when presented as its own sheet rather than pushed from Capture Settings.
    var showsDone = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorMessage: String?
    @State private var exportItem: CaptureShareItem?
    @State private var p12Passphrase = ""
    @State private var askP12Passphrase = false
    @State private var importing = false
    @State private var importData: Data?
    @State private var importPassphrase = ""
    @State private var confirmRegenerate = false
    @State private var isWorking = false

    private var ca: CaptureCAManager { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Status", comment: "HTTP capture CA field")) { CATrustBadge(state: ca.trust) }
                if let name = ca.commonName {
                    LabeledContent(String(localized: "Name", comment: "HTTP capture CA field"), value: name)
                }
                if let expiry = ca.notAfter {
                    LabeledContent(String(localized: "Expires", comment: "HTTP capture CA field"), value: expiry.formatted(date: .abbreviated, time: .omitted))
                }
                if let fingerprint = ca.fingerprint {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                if !ca.hasCA {
                    Button(String(localized: "Create Certificate", comment: "HTTP capture CA action")) {
                        run { try ca.generate() }
                    }
                }
            } footer: {
                Text("This certificate is unique to this device. Its private key never leaves the keychain unless you export a .p12.")
            }
            .themedRow()

            if ca.hasCA && ca.trust != .trusted {
                installSteps
                    .themedRow()
            }

            if ca.hasCA {
                Section(String(localized: "Export", comment: "HTTP capture CA section")) {
                    ForEach(CaptureCAManager.ExportKind.allCases) { kind in
                        Button(kind.title) {
                            if kind == .p12 {
                                p12Passphrase = ""
                                askP12Passphrase = true
                            } else {
                                export(kind)
                            }
                        }
                    }
                }
                .themedRow()
            }

            Section {
                Button(String(localized: "Import from .p12…", comment: "HTTP capture CA action")) { importing = true }
                if ca.hasCA {
                    Button(String(localized: "Create New Certificate…", comment: "HTTP capture CA action"), role: .destructive) {
                        confirmRegenerate = true
                    }
                }
            } footer: {
                Text("Import the .p12 exported from another device to use the same certificate everywhere. A new certificate must be trusted again.")
            }
            .themedRow()

            Section {
                Text("Firefox uses its own certificate store; enable security.enterprise_roots.enabled in about:config to trust system certificates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedList()
        .disabled(isWorking)
        .navigationTitle(String(localized: "Capture Certificate", comment: "HTTP capture CA title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
        }
        .onAppear { ca.refreshTrust() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ca.refreshTrust() }
        }
        .sheet(item: $exportItem) { item in CaptureShareSheet(items: [item.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importData = try? Data(contentsOf: url)
            importPassphrase = ""
        }
        .alert(String(localized: ".p12 Passphrase", comment: "HTTP capture p12 export passphrase title"), isPresented: $askP12Passphrase) {
            SecureField(String(localized: "Passphrase", comment: "HTTP capture passphrase field"), text: $p12Passphrase)
            Button(String(localized: "Export", comment: "Export button")) { export(.p12) }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text("The .p12 contains the private key. Anyone with it and the passphrase can decrypt traffic from devices that trust this certificate.")
        }
        .alert(String(localized: "Import Certificate", comment: "HTTP capture p12 import title"), isPresented: importBinding) {
            SecureField(String(localized: "Passphrase", comment: "HTTP capture passphrase field"), text: $importPassphrase)
            Button(String(localized: "Import", comment: "Import button")) {
                if let data = importData {
                    run { try ca.importP12(data, passphrase: importPassphrase) }
                }
                importData = nil
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { importData = nil }
        }
        .confirmationDialog(String(localized: "Replace the capture certificate?", comment: "HTTP capture CA regenerate confirmation"),
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button(String(localized: "Create New Certificate", comment: "HTTP capture CA action"), role: .destructive) {
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        try await ca.regenerate()
                        await CaptureController.shared.pushConfig()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Devices that trusted the old certificate must trust the new one. On iOS, remove the old profile in Settings › General › VPN & Device Management.")
        }
        .alert(String(localized: "Certificate", comment: "HTTP capture CA error title"), isPresented: errorBinding) {
            Button(String(localized: "OK", comment: "OK button")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var installSteps: some View {
        #if STANDALONE && targetEnvironment(macCatalyst)
        Section {
            Button(String(localized: "Install and Trust…", comment: "HTTP capture CA action (macOS)")) {
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do { try await ca.installTrustOnMac() } catch { errorMessage = error.localizedDescription }
                }
            }
        } header: {
            Text("Trust on This Mac")
        } footer: {
            Text("Adds the certificate to your login keychain and trusts it for SSL. macOS asks for your password.")
        }
        #else
        Section {
            stepRow(1, String(localized: "Download the profile", comment: "HTTP capture CA install step")) {
                Button(String(localized: "Download Profile", comment: "HTTP capture CA action")) { downloadProfile() }
                    .buttonStyle(.borderedProminent)
            }
            stepRow(2, String(localized: "Install it in Settings › General › VPN & Device Management (or Profile Downloaded at the top of Settings).", comment: "HTTP capture CA install step")) {
                Button(String(localized: "Open Settings", comment: "HTTP capture CA action")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            stepRow(3, String(localized: "Turn on full trust in Settings › General › About › Certificate Trust Settings.", comment: "HTTP capture CA install step")) {
                Button(String(localized: "Check Again", comment: "HTTP capture CA action")) { ca.refreshTrust() }
            }
        } header: {
            Text("Trust on This Device")
        }
        #endif
    }

    private func stepRow<Action: View>(_ number: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout)
                action()
            }
        }
        .padding(.vertical, 2)
    }

    private func downloadProfile() {
        // Through the VPN the engine serves the profile at the tunnel gateway;
        // otherwise a short-lived loopback server does it.
        if VPNManager.shared.isTunnelUp, let url = URL(string: "http://10.0.0.1/ca.mobileconfig") {
            openURL(url)
            return
        }
        guard let profile = ca.mobileconfig() else { return }
        Task {
            do {
                let url = try await CAProfileServer.shared.serve(profile)
                openURL(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(_ kind: CaptureCAManager.ExportKind) {
        do {
            let url = try ca.exportFile(kind, passphrase: p12Passphrase)
            exportItem = CaptureShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            Task { await CaptureController.shared.pushConfig() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var importBinding: Binding<Bool> {
        Binding(get: { importData != nil }, set: { if !$0 { importData = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

#endif
