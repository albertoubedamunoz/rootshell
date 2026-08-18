//
//  TerminalEffectView.swift
//  rootshell
//
//  Container view that displays the active terminal background effect
//

import SwiftUI

/// Container view that renders the currently active terminal effect
struct TerminalEffectView: View {
    var effectManager = EffectManager.shared

    var body: some View {
        Group {
            if let effect = effectManager.activeEffect {
                effect.createEffectView()
                    .allowsHitTesting(false)
                    // Force view recreation when effect changes
                    .id(effect.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ZStack {
        // Simulated terminal background
        Color.black

        // Effect layer
        TerminalEffectView()

        // Simulated terminal text
        VStack(alignment: .leading, spacing: 4) {
            Text("user@host ~ $")
            Text("ls -la")
            Text("total 42")
        }
        .font(.system(.body, design: .monospaced))
        .foregroundColor(.green)
        .padding()
    }
}
