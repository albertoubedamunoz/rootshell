//
//  AddPortForwardSheet.swift
//  rootshell
//
//  Sheet for adding a new port forward configuration
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Sheet for adding a new port forward configuration
struct AddPortForwardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var locationDiaryManager = LocationDiaryManager.shared

    @State private var direction: PortForwardConfig.PortForward.Direction = .local
    @State private var bindAddress: String = ""
    @State private var bindPort: String = ""
    @State private var targetHost: String = "localhost"
    @State private var targetPort: String = ""

    var onAdd: (PortForwardConfig.PortForward) -> Void

    private var isValid: Bool {
        guard let bind = Int(bindPort), bind > 0, bind <= 65535 else { return false }
        if direction == .dynamic { return true }
        guard let target = Int(targetPort), target > 0, target <= 65535 else { return false }
        return !targetHost.isEmpty
    }

    private var bindPortPlaceholder: String {
        switch direction {
        case .local: return String(localized: "Local port", comment: "Port forward field placeholder")
        case .remote: return String(localized: "Remote port", comment: "Port forward field placeholder")
        case .dynamic: return String(localized: "SOCKS port", comment: "Port forward field placeholder")
        }
    }

    private var targetPortPlaceholder: String {
        direction == .local ? String(localized: "Remote port", comment: "Port forward field placeholder") : String(localized: "Local port", comment: "Port forward field placeholder")
    }

    private var listenSectionHeader: String {
        switch direction {
        case .local: return String(localized: "Listen On (Local)", comment: "Port forward section header")
        case .remote: return String(localized: "Listen On (Remote)", comment: "Port forward section header")
        case .dynamic: return String(localized: "SOCKS5 Proxy", comment: "Port forward section header")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $direction.animation()) {
                        ForEach(PortForwardConfig.PortForward.Direction.allCases, id: \.self) { dir in
                            Text(dir.displayName).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()

                    Text(direction.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedRow()
                } header: {
                    Text("Direction")
                }

                Section {
                    TextField("Address (optional)", text: $bindAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .themedRow()

                    TextField(bindPortPlaceholder, text: $bindPort)
                        .keyboardType(.numberPad)
                        .themedRow()
                } header: {
                    Text(listenSectionHeader)
                } footer: {
                    switch direction {
                    case .local:
                        Text("Leave address empty to listen on localhost only")
                    case .remote:
                        Text("Leave address empty for the server to choose (usually 0.0.0.0)")
                    case .dynamic:
                        Text("Leave address empty to listen on localhost only")
                    }
                }

                if direction != .dynamic {
                    Section {
                        TextField("Host", text: $targetHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .themedRow()

                        TextField(targetPortPlaceholder, text: $targetPort)
                            .keyboardType(.numberPad)
                            .themedRow()
                    } header: {
                        Text(direction == .local ? String(localized: "Forward To (Remote)", comment: "Port forward: remote destination") : String(localized: "Forward To (Local)", comment: "Port forward: local destination"))
                    }
                }

                Section {
                    previewRow
                        .themedRow()
                } header: {
                    Text("Preview")
                } footer: {
                    #if !targetEnvironment(macCatalyst)
                    if !locationDiaryManager.isConfigured {
                        Text("Port forwards stop when the app is suspended. Enable Location Diary (Auto mode) in Privacy settings, or use iPad Split View.")
                    }
                    #endif
                }
            }
            .themedList()
            .navigationTitle("Add Port Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addForward()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if isValid {
            let forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: Int(bindPort)!,
                targetHost: direction == .dynamic ? "" : targetHost,
                targetPort: direction == .dynamic ? 0 : Int(targetPort)!
            )
            HStack {
                Image(systemName: directionIcon)
                    .foregroundColor(directionColor)
                Text(forward.displayString)
                    .font(.body.monospaced())
            }
        } else {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                Text("Fill in the fields above")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var directionIcon: String {
        switch direction {
        case .local: return "arrow.right.circle.fill"
        case .remote: return "arrow.left.circle.fill"
        case .dynamic: return "globe"
        }
    }

    private var directionColor: Color {
        switch direction {
        case .local: return .blue
        case .remote: return .green
        case .dynamic: return .orange
        }
    }

    private func addForward() {
        guard let bindPortInt = Int(bindPort) else { return }

        let forward: PortForwardConfig.PortForward
        if direction == .dynamic {
            forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: bindPortInt,
                targetHost: "",
                targetPort: 0
            )
        } else {
            guard let targetPortInt = Int(targetPort) else { return }
            forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: bindPortInt,
                targetHost: targetHost,
                targetPort: targetPortInt
            )
        }

        onAdd(forward)
        dismiss()
    }
}

/// View for adding a port forward, designed for NavigationLink push (no nested NavigationStack)
struct AddPortForwardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var locationDiaryManager = LocationDiaryManager.shared

    @State private var direction: PortForwardConfig.PortForward.Direction = .local
    @State private var bindAddress: String = ""
    @State private var bindPort: String = ""
    @State private var targetHost: String = "localhost"
    @State private var targetPort: String = ""

    var onAdd: (PortForwardConfig.PortForward) -> Void

    private var isValid: Bool {
        guard let bind = Int(bindPort), bind > 0, bind <= 65535 else { return false }
        if direction == .dynamic { return true }
        guard let target = Int(targetPort), target > 0, target <= 65535 else { return false }
        return !targetHost.isEmpty
    }

    private var bindPortPlaceholder: String {
        switch direction {
        case .local: return String(localized: "Local port", comment: "Port forward field placeholder")
        case .remote: return String(localized: "Remote port", comment: "Port forward field placeholder")
        case .dynamic: return String(localized: "SOCKS port", comment: "Port forward field placeholder")
        }
    }

    private var targetPortPlaceholder: String {
        direction == .local ? String(localized: "Remote port", comment: "Port forward field placeholder") : String(localized: "Local port", comment: "Port forward field placeholder")
    }

    private var listenSectionHeader: String {
        switch direction {
        case .local: return String(localized: "Listen On (Local)", comment: "Port forward section header")
        case .remote: return String(localized: "Listen On (Remote)", comment: "Port forward section header")
        case .dynamic: return String(localized: "SOCKS5 Proxy", comment: "Port forward section header")
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Direction", selection: $direction.animation()) {
                    ForEach(PortForwardConfig.PortForward.Direction.allCases, id: \.self) { dir in
                        Text(dir.displayName).tag(dir)
                    }
                }
                .pickerStyle(.segmented)
                .themedRow()

                Text(direction.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedRow()
            } header: {
                Text("Direction")
            }

            Section {
                TextField("Address (optional)", text: $bindAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .themedRow()

                TextField(bindPortPlaceholder, text: $bindPort)
                    .keyboardType(.numberPad)
                    .themedRow()
            } header: {
                Text(listenSectionHeader)
            } footer: {
                switch direction {
                case .local:
                    Text("Leave address empty to listen on localhost only")
                case .remote:
                    Text("Leave address empty for the server to choose (usually 0.0.0.0)")
                case .dynamic:
                    Text("Leave address empty to listen on localhost only")
                }
            }

            if direction != .dynamic {
                Section {
                    TextField("Host", text: $targetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .themedRow()

                    TextField(targetPortPlaceholder, text: $targetPort)
                        .keyboardType(.numberPad)
                        .themedRow()
                } header: {
                    Text(direction == .local ? String(localized: "Forward To (Remote)", comment: "Port forward: remote destination") : String(localized: "Forward To (Local)", comment: "Port forward: local destination"))
                }
            }

            Section {
                previewRow
                    .themedRow()
            } header: {
                Text("Preview")
            } footer: {
                #if !targetEnvironment(macCatalyst)
                if !locationDiaryManager.isConfigured {
                    Text("Port forwards stop when the app is suspended. Enable Location Diary (Auto mode) in Privacy settings, or use iPad Split View.")
                }
                #endif
            }
        }
        .themedList()
        .navigationTitle("Add Port Forward")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    addForward()
                }
                .disabled(!isValid)
            }
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if isValid {
            let forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: Int(bindPort)!,
                targetHost: direction == .dynamic ? "" : targetHost,
                targetPort: direction == .dynamic ? 0 : Int(targetPort)!
            )
            HStack {
                Image(systemName: directionIcon)
                    .foregroundColor(directionColor)
                Text(forward.displayString)
                    .font(.body.monospaced())
            }
        } else {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                Text("Fill in the fields above")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var directionIcon: String {
        switch direction {
        case .local: return "arrow.right.circle.fill"
        case .remote: return "arrow.left.circle.fill"
        case .dynamic: return "globe"
        }
    }

    private var directionColor: Color {
        switch direction {
        case .local: return .blue
        case .remote: return .green
        case .dynamic: return .orange
        }
    }

    private func addForward() {
        guard let bindPortInt = Int(bindPort) else { return }

        let forward: PortForwardConfig.PortForward
        if direction == .dynamic {
            forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: bindPortInt,
                targetHost: "",
                targetPort: 0
            )
        } else {
            guard let targetPortInt = Int(targetPort) else { return }
            forward = PortForwardConfig.PortForward(
                direction: direction,
                bindAddress: bindAddress,
                bindPort: bindPortInt,
                targetHost: targetHost,
                targetPort: targetPortInt
            )
        }

        onAdd(forward)
        dismiss()
    }
}

#Preview {
    AddPortForwardSheet { forward in
        print("Added: \(forward.displayString)")
    }
}
