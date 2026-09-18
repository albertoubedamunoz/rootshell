//
//  TerminalEffectView.swift
//  rootshell
//
//  Container view that displays the active terminal background effect
//

import SwiftUI

private struct TerminalEffectAvoidsKeyboardKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// A surface inside the keyboard already has the correct drawing bounds.
    var terminalEffectAvoidsKeyboard: Bool {
        get { self[TerminalEffectAvoidsKeyboardKey.self] }
        set { self[TerminalEffectAvoidsKeyboardKey.self] = newValue }
    }
}

private struct BackgroundEffectSelectionPicker: View {
    let title: LocalizedStringKey
    @Binding var effectID: String
    private var effectManager = EffectManager.shared

    var body: some View {
        Group {
            Picker(title, selection: $effectID) {
                Text("Same as Terminal").tag(BackgroundEffectSelection.followTerminalID)
                Text("None").tag("")
                ForEach(effectManager.availableEffects) { effect in
                    Text(effect.displayName).tag(effect.id)
                }
                if !effectID.isEmpty, effectID != BackgroundEffectSelection.followTerminalID,
                   effectManager.effect(withId: effectID) == nil {
                    Text("Unavailable Effect").tag(effectID)
                }
            }
            if let effect = effectManager.selectedEffect(id: effectID) {
                NavigationLink {
                    EffectSettingsView(configurationEffect: effect)
                } label: {
                    Text("Configure Effect")
                }
            }
        }
        .onChange(of: effectID) { _, _ in
            if let solar = effectManager.selectedEffect(id: effectID)?.asEffect(SolarGraphEffect.self) {
                Task { await solar.onActivated() }
            }
        }
    }
}

struct SidebarBackgroundEffectPicker: View {
    @Setting(Settings.Shaders.sidebarEffectId) private var effectID
    @Setting(Settings.Shaders.effectIncludesPinnedSidebar) private var includesSidebar

    private var selection: Binding<String> {
        Binding(get: {
            // Preserve the old Include Pinned Sidebar preference.
            effectID == BackgroundEffectSelection.followTerminalID && !includesSidebar ? "" : effectID
        }, set: {
            effectID = $0
            if $0 == BackgroundEffectSelection.followTerminalID { includesSidebar = true }
        })
    }

    var body: some View {
        Group {
            BackgroundEffectSelectionPicker(title: "Sidebar Effect", effectID: selection)
                .settingContextMenu(Settings.Shaders.sidebarEffectId)
            Text("Choose an effect for the pinned tab sidebar. Set the terminal effect to None to show effects only in the sidebar. Same as Terminal extends the terminal's effect across both areas. Settings are shared when areas use the same effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if !os(visionOS) && !targetEnvironment(macCatalyst)
struct KeyboardBackgroundEffectPicker: View {
    @Setting(Settings.Shaders.keyboardBackgroundEffect) private var placement
    @Setting(Settings.Shaders.keyboardEffectId) private var effectID

    var body: some View {
        Group {
            Picker("Keyboard Effect Area", selection: $placement) {
                ForEach(TerminalTouchKeyboardModel.BackgroundEffectPlacement.allCases, id: \.self) { placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            .settingContextMenu(Settings.Shaders.keyboardBackgroundEffect)
            BackgroundEffectSelectionPicker(title: "Keyboard Effect", effectID: $effectID)
                .settingContextMenu(Settings.Shaders.keyboardEffectId)
            Text("Choose a keyboard effect independently of the terminal. Set the terminal effect to None for effects only in the keyboard. Photos and downloaded videos are also available. Settings are shared when areas use the same effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

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
