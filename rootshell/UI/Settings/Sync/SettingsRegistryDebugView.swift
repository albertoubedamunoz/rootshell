//
//  SettingsRegistryDebugView.swift
//  rootshell
//
//  Debug audit of the settings registry against the live defaults domain.
//

import SwiftUI

struct SettingsRegistryDebugView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var unregistered: [(key: String, typeDescription: String)] = []
    @State private var mismatches: [(key: String, expected: CodableValue.ValueType, actual: String)] = []
    @State private var violations: [String] = []
    @State private var showRegistered = false

    private let registry = SettingsRegistry.shared

    var body: some View {
        List {
            Section {
                if unregistered.isEmpty {
                    NoResultsRow(icon: "checkmark.circle", message: "All stored keys are registered")
                        .themedRow()
                } else {
                    ForEach(unregistered, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                                .font(.system(.body, design: .monospaced))
                            Text(entry.typeDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                    Button("Copy Unregistered Keys") {
                        UIPasteboard.general.string = unregistered.map(\.key).joined(separator: "\n")
                    }
                    .themedRow()
                }
            } header: {
                Text("Unregistered Keys (\(unregistered.count))")
            } footer: {
                Text("Keys in the app's defaults domain that no SettingKey declares. These never sync.")
            }

            Section {
                if mismatches.isEmpty {
                    NoResultsRow(icon: "checkmark.circle", message: "All stored values match their declared types")
                        .themedRow()
                } else {
                    ForEach(mismatches, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                                .font(.system(.body, design: .monospaced))
                            Text("expected \(entry.expected.rawValue), stored \(entry.actual)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .themedRow()
                    }
                }
            } header: {
                Text("Type Mismatches (\(mismatches.count))")
            }

            if !violations.isEmpty {
                Section {
                    ForEach(violations, id: \.self) { problem in
                        Text(problem)
                            .font(.caption)
                            .foregroundColor(.red)
                            .themedRow()
                    }
                } header: {
                    Text("Invariant Violations (\(violations.count))")
                }
            }

            Section {
                DisclosureGroup("Registered Keys (\(registry.definitions.count))", isExpanded: $showRegistered) {
                    ForEach(registry.groupsInUse, id: \.self) { group in
                        ForEach(registry.keys(in: group).sorted { $0.name < $1.name }) { def in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(def.name)
                                        .font(.system(.caption, design: .monospaced))
                                    Text(def.title)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(policyLabel(def.policy))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .themedRow()
            } header: {
                Text("Registry")
            } footer: {
                Text("\(registry.syncableKeys.count) syncable, \(registry.definitions.count - registry.syncableKeys.count) device-only, \(registry.prefixRules.count) prefix rules.")
            }
        }
        .themedList()
        .navigationTitle("Settings Registry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .refreshable { refresh() }
    }

    private func refresh() {
        unregistered = registry.unregisteredKeys()
        mismatches = registry.typeMismatches()
        violations = registry.invariantViolations()
    }

    private func policyLabel(_ policy: SyncPolicy) -> String {
        switch policy {
        case .synced: String(localized: "synced", comment: "Debug registry policy label")
        case .localByDefault: String(localized: "local by default", comment: "Debug registry policy label")
        case .deviceOnly: String(localized: "device only", comment: "Debug registry policy label")
        }
    }
}
