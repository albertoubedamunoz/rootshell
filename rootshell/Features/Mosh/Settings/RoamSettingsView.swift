//
//  RoamSettingsView.swift
//  rootshell
//
//  Settings for Roam protocols (mosh-server, tsshd, and MPTCP)
//

import SwiftUI

struct RoamSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @AppStorage(HolePunchConfig.roamEnabledKey) private var roamEnabled: Bool = false
    @AppStorage(MoshConfig.defaultPredictionModeKey) private var defaultPredictionMode: String = MoshConfig.PredictionMode.adaptive.rawValue
    @AppStorage(MoshConfig.altScreenEnabledKey) private var moshAltScreenEnabled: Bool = true
    @AppStorage(TrzszConfig.TransportMode.defaultTransportModeKey) private var defaultTransportMode: String = TrzszConfig.TransportMode.kcp.rawValue
    @AppStorage(TrzszConfig.keepPendingInputKey) private var keepPendingInput: Bool = false
    @State private var trzszPortMin: String = ""
    @State private var trzszPortMax: String = ""
    @AppStorage("roamMultipathTCPEnabled") private var multipathTCPEnabled: Bool = false

    private enum Field: Hashable { case portMin, portMax }
    @FocusState private var focusedField: Field?

    var body: some View {
        List {
            // MARK: - About Roam
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Roam provides mobile-friendly terminal connections that survive network changes and high latency.")
                        .font(.subheadline)
                    Text("Supports mosh-server (local echo), tsshd (QUIC/KCP with NAT traversal), and Multipath TCP for seamless WiFi/cellular handover.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            // MARK: - Mosh Settings
            Section {
                Toggle("Enable Hole-Punch", isOn: $roamEnabled)
                    .themedRow()

                Picker("Default Prediction Mode", selection: $defaultPredictionMode) {
                    ForEach(MoshConfig.PredictionMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .themedRow()

                Toggle("Use Alternate Screen", isOn: $moshAltScreenEnabled)
                    .themedRow()

                NavigationLink {
                    MoshHolePunchGuideView()
                } label: {
                    Label("Hole-Punch Setup Guide", systemImage: "questionmark.circle")
                }
                .themedRow()
            } header: {
                Text("Mosh Settings")
            } footer: {
                Text("Hole-punch uses STUN discovery and UDP hole-punching to traverse firewalls. Prediction mode controls local echo for latency compensation. Alternate screen isolates mosh's rendering from the rest of the terminal; turn off to fall back to legacy primary-screen rendering.")
            }

            // MARK: - tssh Settings
            Section {
                Picker("Default Transport", selection: $defaultTransportMode) {
                    ForEach(TrzszConfig.TransportMode.allCases, id: \.rawValue) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }
                        .tag(mode.rawValue)
                    }
                }
                .themedRow()

                Toggle(
                    "Discard Input While Offline",
                    isOn: Binding(
                        get: { !keepPendingInput },
                        set: { keepPendingInput = !$0 }
                    )
                )
                    .themedRow()

                HStack {
                    Text("Port Range Min")
                    Spacer()
                    TextField("61000", text: $trzszPortMin)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($focusedField, equals: .portMin)
                        .onChange(of: trzszPortMin) { _, newValue in
                            syncPortToDefaults(key: TrzszConfig.defaultUDPPortMinKey, value: newValue)
                        }
                }
                .themedRow()

                HStack {
                    Text("Port Range Max")
                    Spacer()
                    TextField("61999", text: $trzszPortMax)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($focusedField, equals: .portMax)
                        .onChange(of: trzszPortMax) { _, newValue in
                            syncPortToDefaults(key: TrzszConfig.defaultUDPPortMaxKey, value: newValue)
                        }
                }
                .themedRow()

                if !isPortRangeValid {
                    Label(portRangeValidationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .themedRow()
                }

                NavigationLink {
                    TsshdSetupGuideView()
                } label: {
                    Label("tsshd Setup Guide", systemImage: "questionmark.circle")
                }
                .themedRow()
            } header: {
                Text("tssh Settings")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transportModeFooterText)
                    Text(keepPendingInputFooterText)
                }
            }

            // MARK: - SSH Settings
            Section {
                Toggle("Multipath TCP", isOn: $multipathTCPEnabled)
                    .themedRow()

                NavigationLink {
                    MPTCPSetupGuideView()
                } label: {
                    Label("Server Setup Guide", systemImage: "questionmark.circle")
                }
                .themedRow()
            } header: {
                Text("SSH Settings")
            } footer: {
                Text("Enables seamless handover between WiFi and cellular. Falls back to regular TCP when unavailable. The server must also support MPTCP.")
            }

            // MARK: - UDP Port Requirements
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    portRangeRow(
                        protocol: "mosh-server",
                        range: "60000–61000",
                        note: "1,001 ports. The server picks one port per session from this range."
                    )

                    Divider()

                    portRangeRow(
                        protocol: "tsshd",
                        range: "\(resolvedPortMin)–\(resolvedPortMax)",
                        note: "\(max(resolvedPortMax - resolvedPortMin + 1, 0)) ports. The server picks one port per session from this range."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("UDP Port Requirements")
            } footer: {
                Text("Open these UDP port ranges inbound on your server firewall. Each active session consumes one port. The ranges are non-overlapping by default so both protocols can run on the same host.")
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        #endif
        .onAppear {
            let minVal = UserDefaults.standard.integer(forKey: TrzszConfig.defaultUDPPortMinKey)
            trzszPortMin = minVal != 0 ? String(minVal) : ""
            let maxVal = UserDefaults.standard.integer(forKey: TrzszConfig.defaultUDPPortMaxKey)
            trzszPortMax = maxVal != 0 ? String(maxVal) : ""
        }
        .navigationTitle("Roam")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    private var transportModeFooterText: String {
        let mode = TrzszConfig.TransportMode(rawValue: defaultTransportMode) ?? .kcp
        return mode.descriptionText
    }

    private var keepPendingInputFooterText: String {
        if keepPendingInput {
            return String(localized: "Typed input is queued while tssh is offline and delivered after reconnect.", comment: "tssh keep pending input enabled footer")
        }
        return String(localized: "Typed input while tssh is offline is discarded by default to avoid replaying stale commands.", comment: "tssh keep pending input disabled footer")
    }

    private var resolvedPortMin: Int {
        let trimmed = trzszPortMin.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 61000 }
        return Int(trimmed) ?? 61000
    }

    private var resolvedPortMax: Int {
        let trimmed = trzszPortMax.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 61999 }
        return Int(trimmed) ?? 61999
    }

    private var hasNonNumericInput: Bool {
        let minTrimmed = trzszPortMin.trimmingCharacters(in: .whitespaces)
        let maxTrimmed = trzszPortMax.trimmingCharacters(in: .whitespaces)
        return (!minTrimmed.isEmpty && Int(minTrimmed) == nil)
            || (!maxTrimmed.isEmpty && Int(maxTrimmed) == nil)
    }

    private var isPortRangeValid: Bool {
        !hasNonNumericInput
            && resolvedPortMin >= 1024 && resolvedPortMax <= 65535
            && resolvedPortMin <= resolvedPortMax
    }

    private var portRangeValidationMessage: String {
        if hasNonNumericInput {
            return String(localized: "Port values must be numbers", comment: "Roam port range validation")
        }
        if resolvedPortMin < 1024 || resolvedPortMax < 1024 {
            return String(localized: "Ports must be 1024 or higher", comment: "Roam port range validation")
        }
        if resolvedPortMin > 65535 || resolvedPortMax > 65535 {
            return String(localized: "Ports must be 65535 or lower", comment: "Roam port range validation")
        }
        if resolvedPortMin > resolvedPortMax {
            return String(localized: "Min port must be less than or equal to max port", comment: "Roam port range validation")
        }
        return ""
    }

    private func syncPortToDefaults(key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let intValue = Int(trimmed), intValue >= 1024, intValue <= 65535 {
            UserDefaults.standard.set(intValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func portRangeRow(protocol name: String, range: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("UDP \(range)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

}

#Preview {
    NavigationView {
        RoamSettingsView()
    }
}
