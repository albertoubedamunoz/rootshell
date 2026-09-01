//
//  SettingPinTag.swift
//  rootshell
//
//  Provenance tag for a settings row or group header: kept on this device,
//  set by the config file, or nothing. Renders as EmptyView when there is
//  nothing to say so it drops into any HStack without spacing artifacts.
//

import SwiftUI

struct SettingPinTag: View {
    private enum Subject {
        case key(String)
        case group(SettingGroup)
    }

    private let subject: Subject
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var syncManager = CloudKitSyncManager.shared

    init(_ definition: AnySettingDefinition) {
        subject = .key(definition.name)
    }

    init(key: String) {
        subject = .key(key)
    }

    init(group: SettingGroup) {
        subject = .group(group)
    }

    var body: some View {
        if syncManager.isAppSettingsSyncEnabled {
            switch subject {
            case .key(let name):
                keyTag(coordinator.pinState(for: name))
            case .group(let group):
                groupTag(coordinator.pinState(for: group))
            }
        }
    }

    @ViewBuilder
    private func keyTag(_ state: SettingPinState) -> some View {
        switch state {
        case .key:
            tag(String(localized: "This Device", comment: "Pinned setting tag"), symbol: "pin.fill", tint: .blue)
                .accessibilityLabel(Text("Kept on this device"))
        case .group:
            tag(String(localized: "This Device", comment: "Pinned setting tag"), symbol: "pin", tint: .secondary)
                .accessibilityLabel(Text("Kept on this device with its group"))
        case .configFile:
            tag(String(localized: "Config File", comment: "Config-file setting tag"), symbol: "doc.text", tint: .orange)
                .accessibilityLabel(Text("Set by config file"))
        case .none, .deviceOnly:
            EmptyView()
        }
    }

    @ViewBuilder
    private func groupTag(_ state: GroupPinState) -> some View {
        switch state {
        case .all:
            tag(String(localized: "This Device", comment: "Pinned setting tag"), symbol: "pin.fill", tint: .blue)
        case .partial(let pinned, let total):
            tag(String(localized: "\(pinned) of \(total) on This Device", comment: "Partially pinned group tag"),
                symbol: "pin", tint: .secondary)
        case .none:
            EmptyView()
        }
    }

    private func tag(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.1))
        .cornerRadius(4)
        .fixedSize()
    }
}
