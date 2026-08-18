//
//  VisorSettingsView.swift
//  rootshell
//
//  Settings UI for the Quake-style visor terminal (Standalone Mac Catalyst).
//

#if STANDALONE && targetEnvironment(macCatalyst)

import SwiftUI

struct VisorSettingsView: View {
    @StateObject private var settings = VisorSettings.shared
    @StateObject private var hotkey = VisorHotkeyManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Visor", isOn: $settings.enabled)
                    .themedRow()
            } footer: {
                Text("Slide a terminal down from a screen edge with a global hotkey, from anywhere in macOS.")
            }

            Section("Hotkey") {
                HStack {
                    Text("Combination")
                    Spacer()
                    Text(settings.hotkeyConfigured ? formattedHotkey() : "Not set")
                        .foregroundStyle(settings.hotkeyConfigured ? .primary : .secondary)
                }
                .themedRow()
                ModifierTogglesRow(modifiers: $settings.hotkeyModifiers)
                    .themedRow()
                Picker("Key", selection: $settings.hotkeyKeyCode) {
                    Text("None").tag(-1)
                    ForEach(VisorKeyChoice.all) { choice in
                        Text(choice.displayName).tag(choice.keyCode)
                    }
                }
                .themedRow()
            }

            Section("Position") {
                Picker("Edge", selection: $settings.position) {
                    ForEach(VisorPosition.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .themedRow()
                Picker("Screen", selection: $settings.screen) {
                    ForEach(VisorScreenChoice.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .themedRow()
                HStack {
                    Text("Space behavior")
                    Spacer()
                    Picker("", selection: $settings.spaceBehavior) {
                        ForEach(VisorSpaceBehavior.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                }
                .themedRow()
            }

            Section {
                VisorSizeSettingRow(
                    title: "Slide size",
                    defaultTitle: "Default",
                    value: $settings.primarySize
                )
                .themedRow()
                VisorSizeSettingRow(
                    title: "Cross axis",
                    defaultTitle: "Fill",
                    value: $settings.secondarySize
                )
                .themedRow()
            } header: {
                Text("Size")
            } footer: {
                Text("Slide size is height for top or bottom edges and width for left or right edges. Cross axis is the perpendicular dimension.")
            }

            Section("Behavior") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Animation duration")
                        Spacer()
                        Text("\(settings.animationDurationMs)ms").foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.animationDurationMs) },
                            set: { settings.animationDurationMs = Int($0) }
                        ),
                        in: 50...500,
                        step: 10
                    )
                }
                .themedRow()
                Toggle("Auto-hide when focus moves to another app", isOn: $settings.autohide)
                    .themedRow()
            }

            Section {
                Toggle("Use event tap (requires Accessibility permission)", isOn: $settings.useEventTap)
                    .themedRow()
                if settings.useEventTap, hotkey.lastError != nil {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        Link("Open System Settings → Accessibility", destination: url)
                            .themedRow()
                    }
                    if let err = hotkey.lastError {
                        Text(err.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .themedRow()
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Event tap allows more exotic key combinations but requires Accessibility permission. If denied, the visor falls back to a Carbon hotkey automatically.")
            }
        }
        .themedList()
        .navigationTitle("Visor")
    }

    private func formattedHotkey() -> String {
        var glyphs = ""
        let m = settings.hotkeyModifiers
        if m & visorControlKey != 0 { glyphs += "⌃" }
        if m & visorOptionKey != 0 { glyphs += "⌥" }
        if m & visorShiftKey != 0 { glyphs += "⇧" }
        if m & visorCmdKey != 0 { glyphs += "⌘" }
        let label = VisorKeyChoice.all.first(where: { $0.keyCode == settings.hotkeyKeyCode })?.displayName ?? "?"
        return glyphs + label
    }
}

// MARK: - Size settings

private enum VisorSizeUnit: String, CaseIterable, Identifiable {
    case defaultSize
    case percent
    case pixels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultSize: return "Default"
        case .percent: return "Percent"
        case .pixels: return "Pixels"
        }
    }
}

private struct VisorSizeSettingRow: View {
    let title: String
    let defaultTitle: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Picker("", selection: unitBinding) {
                    Text(defaultTitle).tag(VisorSizeUnit.defaultSize)
                    Text("Percent").tag(VisorSizeUnit.percent)
                    Text("Pixels").tag(VisorSizeUnit.pixels)
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
            }

            switch unit {
            case .defaultSize:
                EmptyView()
            case .percent:
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: numericBinding, in: 10...100, step: 1)
                    HStack {
                        Stepper("", value: numericBinding, in: 10...100, step: 1)
                            .labelsHidden()
                        Spacer()
                        Text(Int(numericValue.rounded()), format: .percent)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            case .pixels:
                HStack {
                    Stepper("", value: numericBinding, in: 200...2400, step: 20)
                        .labelsHidden()
                    Spacer()
                    Text("\(Int(numericValue.rounded())) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var unit: VisorSizeUnit {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .defaultSize }
        if VisorPosition.parseSize(trimmed) == nil { return .defaultSize }
        if trimmed.localizedCaseInsensitiveContains("px") { return .pixels }
        if trimmed.contains("%") { return .percent }
        return .pixels
    }

    private var numericValue: Double {
        switch VisorPosition.parseSize(value) {
        case .percentage(let number): return number
        case .pixels(let number): return number
        case nil:
            return unit == .pixels ? 400 : 30
        }
    }

    private var unitBinding: Binding<VisorSizeUnit> {
        Binding(
            get: { unit },
            set: { newUnit in
                switch newUnit {
                case .defaultSize:
                    value = ""
                case .percent:
                    value = "\(Int(defaultPercentValue.rounded()))%"
                case .pixels:
                    value = "\(Int(defaultPixelValue.rounded()))px"
                }
            }
        )
    }

    private var numericBinding: Binding<Double> {
        Binding(
            get: { numericValue },
            set: { newValue in
                switch unit {
                case .defaultSize:
                    break
                case .percent:
                    value = "\(Int(newValue.rounded()))%"
                case .pixels:
                    value = "\(Int(newValue.rounded()))px"
                }
            }
        )
    }

    private var defaultPercentValue: Double {
        switch VisorPosition.parseSize(value) {
        case .percentage(let number): return number
        default: return 30
        }
    }

    private var defaultPixelValue: Double {
        switch VisorPosition.parseSize(value) {
        case .pixels(let number): return number
        default: return 400
        }
    }
}

// MARK: - Modifier toggles

private struct ModifierTogglesRow: View {
    @Binding var modifiers: UInt32

    private struct ModifierOption: Identifiable {
        let id = UUID()
        let mask: UInt32
        let glyph: String
        let name: String
    }

    private let options: [ModifierOption] = [
        .init(mask: visorControlKey, glyph: "⌃", name: "Control"),
        .init(mask: visorOptionKey,  glyph: "⌥", name: "Option"),
        .init(mask: visorShiftKey,   glyph: "⇧", name: "Shift"),
        .init(mask: visorCmdKey,     glyph: "⌘", name: "Command")
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options) { opt in
                Button {
                    if modifiers & opt.mask != 0 {
                        modifiers &= ~opt.mask
                    } else {
                        modifiers |= opt.mask
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(opt.glyph).font(.title3)
                        Text(opt.name).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        (modifiers & opt.mask) != 0
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke((modifiers & opt.mask) != 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Key choices

/// Curated set of keys offered to the user. We pin to Carbon virtual key
/// codes so registration is deterministic regardless of input source.
struct VisorKeyChoice: Identifiable {
    let id: String
    let keyCode: Int
    let displayName: String

    init(_ name: String, _ code: Int) {
        self.id = name
        self.displayName = name
        self.keyCode = code
    }

    static let all: [VisorKeyChoice] = {
        var items: [VisorKeyChoice] = []
        // Common terminal-summon keys first.
        items.append(.init("`", VK.ansi_Grave))
        items.append(.init("Space", VK.space))
        items.append(.init("Return", VK.return))
        items.append(.init("Escape", VK.escape))
        items.append(.init("Tab", VK.tab))
        items.append(.init("\\", VK.ansi_Backslash))
        items.append(.init("/", VK.ansi_Slash))
        items.append(.init("Delete", VK.delete))
        // F-keys.
        let fKeys: [(Int, Int)] = [
            (1, VK.f1), (2, VK.f2), (3, VK.f3), (4, VK.f4),
            (5, VK.f5), (6, VK.f6), (7, VK.f7), (8, VK.f8),
            (9, VK.f9), (10, VK.f10), (11, VK.f11), (12, VK.f12)
        ]
        for (n, code) in fKeys {
            items.append(.init("F\(n)", code))
        }
        // Letters
        let letters: [(Character, Int)] = [
            ("A", VK.ansi_A), ("B", VK.ansi_B), ("C", VK.ansi_C), ("D", VK.ansi_D),
            ("E", VK.ansi_E), ("F", VK.ansi_F), ("G", VK.ansi_G), ("H", VK.ansi_H),
            ("I", VK.ansi_I), ("J", VK.ansi_J), ("K", VK.ansi_K), ("L", VK.ansi_L),
            ("M", VK.ansi_M), ("N", VK.ansi_N), ("O", VK.ansi_O), ("P", VK.ansi_P),
            ("Q", VK.ansi_Q), ("R", VK.ansi_R), ("S", VK.ansi_S), ("T", VK.ansi_T),
            ("U", VK.ansi_U), ("V", VK.ansi_V), ("W", VK.ansi_W), ("X", VK.ansi_X),
            ("Y", VK.ansi_Y), ("Z", VK.ansi_Z)
        ]
        for (ch, code) in letters {
            items.append(.init(String(ch), code))
        }
        // Digits
        let digits: [(Character, Int)] = [
            ("1", VK.ansi_1), ("2", VK.ansi_2), ("3", VK.ansi_3), ("4", VK.ansi_4),
            ("5", VK.ansi_5), ("6", VK.ansi_6), ("7", VK.ansi_7), ("8", VK.ansi_8),
            ("9", VK.ansi_9), ("0", VK.ansi_0)
        ]
        for (ch, code) in digits {
            items.append(.init(String(ch), code))
        }
        return items
    }()
}

#endif
