#if !os(visionOS) && !targetEnvironment(macCatalyst)
import SwiftUI

struct TerminalTouchKeyboardSettingsView: View {
    @Setting(Settings.Keyboard.touchStyle) private var keyboardStyle
    @Setting(Settings.Keyboard.touchThemeAware) private var themeAware
    @Setting(Settings.Keyboard.touchPhosphorColor) private var phosphorColor
    @Setting(Settings.Keyboard.touchFloatingGlassStyle) private var floatingGlassStyle
    @Setting(Settings.Keyboard.touchFloatingGlassTintOpacity) private var floatingGlassTintOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sample = ""
    @State private var previewHeight: CGFloat = 280
    @State private var previewFloating = false

    private var tintOpacity: Binding<Double> {
        Binding(
            get: { TerminalTouchKeyboardModel.floatingGlassTintOpacity(floatingGlassTintOpacity) },
            set: { floatingGlassTintOpacity = $0 }
        )
    }

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Keyboard.touchEnabled, title: "Terminal Keyboard", icon: "keyboard.badge.ellipsis")
                    .themedRow()
            } footer: {
                Text("An optional English QWERTY keyboard for terminal sessions. Switch to Apple's keyboard for other languages, swipe typing, emoji, or dictation.")
            }
            Section {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Picker("Preview Placement", selection: $previewFloating) {
                        Text("Docked").tag(false)
                        Text("Detached").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("❯").foregroundStyle(.secondary)
                        Text(sample.isEmpty ? "Type a command or prompt…" : sample)
                            .foregroundStyle(sample.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { sample = "" } label: { Image(systemName: "arrow.counterclockwise") }
                            .accessibilityLabel("Clear keyboard preview")
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(minHeight: 58)
                    TerminalTouchKeyboardPreview(sample: $sample, height: $previewHeight, floating: previewFloating)
                        .frame(height: previewHeight)
                        .frame(maxWidth: previewFloating ? 320 : .infinity)
                        .padding(previewFloating ? 12 : 0)
                        .frame(maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Try it")
            } footer: {
                Text("This preview stays on your device and sends nothing to a terminal. Hold Space to move the cursor; tap a modifier for one key, double-tap to lock, or hold it while typing.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchStatePerTab, title: "Separate State per Tab", icon: "square.on.square")
                    .themedRow()
            } footer: {
                Text("Off by default. Keep the keyboard’s page, shortcuts, drawers, sticky modifiers, and keyboard choice as you switch tabs. Turn this on to remember a separate state for each tab. Split panes in the same tab share their keyboard state.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchLetterPrediction, title: "Letter Prediction", icon: "textformat.abc")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchSuggestions, title: "Suggestions", icon: "textformat.abc")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchHaptics, title: "Haptic Feedback", icon: "hand.tap")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchClickSound, title: "Key Click Sounds", icon: "speaker.wave.2")
                    .themedRow()
            } header: {
                Text("Typing")
            } footer: {
                Text("Letter Prediction uses recent English typing to help choose between nearby letters. Turn it off for literal key targeting. Suggestions are local spelling guesses and completions; tap to apply one. Words are never automatically replaced. The double-space period shortcut follows your Terminal keyboard setting. Key Click Sounds match the keyboard style and are muted in Silent Mode.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchCompactHeight, title: "Compact Height", icon: "arrow.down.to.line")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchGlyphs, title: "Key Glyphs", icon: "command")
                    .themedRow()
            } header: {
                Text("Layout")
            } footer: {
                Text("Compact Height moves every row, including Space, down into the bottom safe area without reducing key height. The bottom corners adapt to your iPhone. Key Glyphs shows symbols for Escape, Tab, and modifiers; turn it off to show their names.")
            }
            Section {
                Picker("Keyboard Style", selection: $keyboardStyle) {
                    ForEach(TerminalTouchKeyboardModel.Style.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .settingContextMenu(Settings.Keyboard.touchStyle)
                .themedRow()
                SettingToggle(Settings.Keyboard.touchThemeAware, title: "Follow Terminal Theme", icon: "paintpalette")
                    .themedRow()
                if keyboardStyle == .steampunk {
                    SettingToggle(Settings.Keyboard.touchSteampunkThemeAwareKeycaps, title: "Theme-Aware Keycaps", icon: "keyboard")
                        .disabled(!themeAware)
                        .themedRow()
                }
                if keyboardStyle == .phosphor {
                    Picker("Phosphor Color", selection: $phosphorColor) {
                        ForEach(TerminalTouchKeyboardModel.PhosphorColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(color)
                        }
                    }
                    .settingContextMenu(Settings.Keyboard.touchPhosphorColor)
                    .themedRow()
                }
                KeyboardBackgroundEffectPicker()
                    .themedRow()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Flat is the original keyboard style. Sculpted adds raised keycaps and depth. Steampunk adds brass-rimmed instrument keys and a mechanical drive that responds to touch. Phosphor draws glowing keys on a dark CRT screen. Beige Box has tall keys like a classic office keyboard. Neon Grid puts glowing keys over a synthwave horizon whose grid moves as you type. Circuit Board sends a pulse along the board’s traces with each key press. Animations stop when idle, with Reduce Motion, or in Low Power Mode. Follow Terminal Theme matches the active terminal’s colors, including tab and window themes. Key labels keep their contrast in every mode.")
                if keyboardStyle == .steampunk {
                    Text("Steampunk uses matching ivory and dark enamel keycaps by default. With Follow Terminal Theme on, enable Theme-Aware Keycaps to also match the keycaps to your terminal’s colors.")
                }
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section {
                    SettingToggle(Settings.Keyboard.touchSystemFloating, title: "Use System Detached Keyboard", icon: "keyboard")
                        .themedRow()
                } footer: {
                    Text("Use iPadOS’s floating keyboard container so the keyboard can move beyond the app window. To float or dock in this mode, switch to Apple’s keyboard, change its placement, then switch back using the toolbar’s keyboard button. Turn this off to keep the detached keyboard inside rootshell and use pinch gestures on our keyboard.")
                }
                Section {
                    Picker("Glass Style", selection: $floatingGlassStyle) {
                        ForEach(TerminalTouchKeyboardModel.FloatingGlassStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .settingContextMenu(Settings.Keyboard.touchFloatingGlassStyle)
                    .themedRow()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tint Strength")
                                .settingRow(Settings.Keyboard.touchFloatingGlassTintOpacity)
                            Spacer()
                            Text(tintOpacity.wrappedValue, format: .wholePercent)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: tintOpacity, in: 0...1, step: 0.05) {
                            Text("Tint Strength")
                        }
                    }
                    .disabled(floatingGlassStyle == .solid || reduceTransparency)
                    .themedRow()
                    Button {
                        _floatingGlassStyle.reset()
                        _floatingGlassTintOpacity.reset()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .themedRow()
                } header: {
                    Text("Detached Keyboard")
                } footer: {
                    Text("Customize the detached keyboard’s background. Clear reveals more content; Solid removes transparency. Tint Strength adjusts how much of the keyboard’s background color is added. Older iPadOS versions use blur. Reduce Transparency always uses a solid background.")
                }
            }
            Section("Terminal tools") {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Text("With Use System Detached Keyboard off, pinch inward to float the keyboard. Drag the … handle to move it. Spread two fingers or double-tap the handle to dock. Docking hides the keys when a hardware keyboard is connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
                NavigationLink(value: SettingsSearchDestination.toolbarKeys) {
                    Label("Customize Toolbar", systemImage: "command")
                }
                .themedRow()
                Text("Swipe left or right across the keys to reach Symbols, Navigation, and Shortcuts. A temporary overlay shows your position. The toolbar follows your customized button layout. Tap … to open your custom drawer rows, using the same stack or cycle setting as the regular keyboard toolbar. Choose Agent, Shell, Vim, Emacs, or Nano on the Shortcuts page. Shortcuts use each application's standard bindings; customized bindings may behave differently.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Terminal Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TerminalTouchKeyboardPreview: UIViewRepresentable {
    @Binding var sample: String
    @Binding var height: CGFloat
    var floating: Bool

    final class Coordinator: TerminalTouchKeyboardHost {
        var parent: TerminalTouchKeyboardPreview
        var predictionContext = TerminalTouchKeyboardModel.PredictionContext()
        var lastSample = ""
        init(_ parent: TerminalTouchKeyboardPreview) { self.parent = parent }
        var touchKeyboardCanSend: Bool { true }
        var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }
        var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { predictionContext.snapshot }
        func touchKeyboardInsert(_ text: String) {
            parent.sample = String((parent.sample + text).suffix(180))
            lastSample = parent.sample
            predictionContext.append(text)
        }
        func touchKeyboardSend(_ key: String, modifiers: KeyModifiers) {
            if key == "\u{7f}", modifiers.isEmpty {
                if !parent.sample.isEmpty { parent.sample.removeLast() }
                lastSample = parent.sample
                predictionContext.backspace()
                return
            }
            if modifiers.isEmpty, key == "\r" { touchKeyboardInsert("\n"); return }
            if modifiers.isEmpty, key == "\t" { touchKeyboardInsert("    "); return }
            let label = ["\u{1b}": "Esc", "\u{1b}[A": "↑", "\u{1b}[B": "↓", "\u{1b}[C": "→", "\u{1b}[D": "←", "\r": "Return", "\t": "Tab"][key] ?? key
            touchKeyboardInsert("⟨" + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.alt) ? "⌥" : "")
                                + (modifiers.contains(.shift) ? "⇧" : "") + label + "⟩")
            predictionContext.reset()
        }
        func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
        func touchKeyboardInvalidateSuggestions() { predictionContext.reset() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TerminalTouchKeyboardView {
        let view = TerminalTouchKeyboardView()
        view.host = context.coordinator
        view.setFloating(floating)
        view.onHeightChanged = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.parent.height = view.intrinsicContentSize.height
        }
        return view
    }
    func updateUIView(_ view: TerminalTouchKeyboardView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.setFloating(floating)
        if coordinator.lastSample != sample {
            coordinator.predictionContext.reset()
            coordinator.lastSample = sample
        }
        view.updatePrediction()
    }
    static func dismantleUIView(_ view: TerminalTouchKeyboardView, coordinator: Coordinator) { view.cancelInteraction() }
}

#endif
