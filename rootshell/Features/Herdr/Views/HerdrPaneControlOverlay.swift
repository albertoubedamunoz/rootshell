// Copyright (c) 2026 Kit Knox / Rootshell LLC

import SwiftUI

/// Dimmed card over a pane whose terminal another herdr client holds.
struct HerdrPaneControlOverlay: View {
    let state: HerdrPaneControlState
    let offersUpgrade: Bool
    let takeControl: () -> Void
    let showUpgrade: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(state == .takenOver
                     ? String(localized: "Another client took control of this pane")
                     : String(localized: "Controlled by another client"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Its shell keeps running on the host.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Take Control", action: takeControl)
                        .buttonStyle(.borderedProminent)
                    if offersUpgrade {
                        Button("Upgrade herdr…", action: showUpgrade)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(16)
        }
        .transaction { $0.animation = nil }
    }
}
