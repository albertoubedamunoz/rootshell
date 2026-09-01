//
//  CursorSettingsView.swift
//  rootshell
//
//  Cursor settings.
//

import SwiftUI

struct CursorSettingsView: View {
    @Bindable private var cursorManager = CursorManager.shared
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @State private var cursorSwiftColor: Color = .white
    @State private var cursorTextSwiftColor: Color = .black
    @State private var hasCursorColor = false
    @State private var hasCursorTextColor = false

    var body: some View {
        List {
            Section {
                ForEach(CursorStyle.allCases, id: \.self) { style in
                    Button {
                        cursorManager.cursorStyle = style
                    } label: {
                        CursorStyleRow(style: style, isSelected: cursorManager.cursorStyle == style)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } header: {
                Text("Style")
            } footer: {
                Text("Choose how the insertion point appears inside each character cell.")
            }

            Section {
                if cursorManager.cursorEffect != .none {
                    CursorEffectPreviewContainer(effect: cursorManager.cursorEffect)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .themedRow()
                }

                Picker(selection: $cursorManager.cursorEffect) {
                    ForEach(CursorEffect.allCases, id: \.self) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                } label: {
                    Text("Cursor Effect")
                        .settingRow(Settings.Cursor.effect)
                }
                .themedRow()
            } header: {
                Text("Effect")
            } footer: {
                Text(cursorManager.cursorEffect.description)
            }

            Section {
                SettingToggle(Settings.Cursor.blinkEnabled, isOn: $cursorManager.cursorBlinkEnabled, title: "Blinking")
                    .themedRow()

                if cursorManager.cursorBlinkEnabled {
                    Picker(selection: $cursorManager.cursorBlinkMode) {
                        ForEach(CursorBlinkMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        Text("Blink Style")
                            .settingRow(Settings.Cursor.blinkMode)
                    }
                    .themedRow()
                }
            } header: {
                Text("Animation")
            } footer: {
                if cursorManager.cursorBlinkEnabled && cursorManager.cursorBlinkMode != .normal {
                    Text(cursorManager.cursorBlinkMode.description)
                }
            }

            Section {
                Toggle(isOn: $hasCursorColor) {
                    HStack(spacing: 6) {
                        Text("Custom Cursor Color")
                        SettingPinTag(Settings.Cursor.color.erased)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Cursor.color)
                if hasCursorColor {
                    ColorPicker(selection: $cursorSwiftColor, supportsOpacity: false) {
                        Text("Cursor Color")
                            .settingRow(Settings.Cursor.color)
                    }
                    .onChange(of: cursorSwiftColor) { _, newValue in
                        cursorManager.cursorColor = newValue.hexString
                    }
                    .themedRow()
                }

                Toggle(isOn: $hasCursorTextColor) {
                    HStack(spacing: 6) {
                        Text("Custom Text Color")
                        SettingPinTag(Settings.Cursor.textColor.erased)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Cursor.textColor)
                if hasCursorTextColor {
                    ColorPicker(selection: $cursorTextSwiftColor, supportsOpacity: false) {
                        Text("Text Under Cursor")
                            .settingRow(Settings.Cursor.textColor)
                    }
                    .onChange(of: cursorTextSwiftColor) { _, newValue in
                        cursorManager.cursorTextColor = newValue.hexString
                    }
                    .themedRow()
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("Customize the cursor and text-under-cursor colors. When disabled, the theme defaults are used.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                            .settingRow(Settings.Cursor.opacity)
                        Spacer()
                        Text(cursorManager.cursorOpacity, format: .wholePercent)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $cursorManager.cursorOpacity, in: 0.0...1.0, step: 0.05)
                }
                .themedRow()
            } header: {
                Text("Opacity")
            } footer: {
                Text("Controls cursor transparency. \(1.0.formatted(.wholePercent)) is fully opaque.")
            }

            Section {
                Stepper(value: $cursorManager.cursorThickness, in: -4...10) {
                    Text("Thickness: \(cursorThicknessLabel)")
                        .settingRow(Settings.Cursor.thickness)
                }
                .themedRow()
                Stepper(value: $cursorManager.cursorHeight, in: -4...10) {
                    Text("Height: \(cursorHeightLabel)")
                        .settingRow(Settings.Cursor.height)
                }
                .themedRow()
            } header: {
                Text("Size Adjustments")
            } footer: {
                Text("Pixel adjustments for cursor dimensions. 0 uses the default size.")
            }

        }
        .themedList()
        .navigationTitle("Cursor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.cursor]) }
        .onAppear {
            hasCursorColor = cursorManager.cursorColor != nil
            hasCursorTextColor = cursorManager.cursorTextColor != nil
            if let hex = cursorManager.cursorColor, let color = Color(hex: hex) {
                cursorSwiftColor = color
            }
            if let hex = cursorManager.cursorTextColor, let color = Color(hex: hex) {
                cursorTextSwiftColor = color
            }
        }
        .onChange(of: hasCursorColor) { _, enabled in
            if enabled {
                cursorManager.cursorColor = cursorSwiftColor.hexString
            } else {
                cursorManager.cursorColor = nil
            }
        }
        .onChange(of: hasCursorTextColor) { _, enabled in
            if enabled {
                cursorManager.cursorTextColor = cursorTextSwiftColor.hexString
            } else {
                cursorManager.cursorTextColor = nil
            }
        }
    }

    private var cursorThicknessLabel: String {
        cursorManager.cursorThickness == 0 ? "Default" : "\(cursorManager.cursorThickness)px"
    }

    private var cursorHeightLabel: String {
        cursorManager.cursorHeight == 0 ? "Default" : "\(cursorManager.cursorHeight)px"
    }
}

private struct CursorStyleRow: View {
    let style: CursorStyle
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            CursorStylePreview(style: style, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(style.displayName)
                    .foregroundStyle(.primary)

                Text(style.previewDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }
}

private struct CursorStylePreview: View {
    let style: CursorStyle
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tileBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tileBorder, lineWidth: 1)

                ZStack {
                    cursorShape

                    Text("A")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(glyphColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
    }

    private var tileBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.05)
    }

    private var tileBorder: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    private var cursorColor: Color {
        isSelected ? .accentColor : Color.primary.opacity(colorScheme == .dark ? 0.85 : 0.72)
    }

    private var glyphColor: Color {
        switch style {
        case .block:
            return Color(uiColor: .systemBackground)
        case .bar, .underline, .blockHollow:
            return .primary
        }
    }

    @ViewBuilder
    private var cursorShape: some View {
        switch style {
        case .block:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(cursorColor)
                .frame(width: 22, height: 24)

        case .bar:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(cursorColor)
                .frame(width: 4, height: 24)
                .offset(x: -9)

        case .underline:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(cursorColor)
                .frame(width: 22, height: 4)
                .offset(y: 12)

        case .blockHollow:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(cursorColor, lineWidth: 2)
                .frame(width: 22, height: 24)
        }
    }
}

private extension CursorStyle {
    var previewDescription: String {
        switch self {
        case .block:
            return String(localized: "Fills the full character cell", comment: "Cursor style preview description")
        case .bar:
            return String(localized: "Shows a slim vertical beam", comment: "Cursor style preview description")
        case .underline:
            return String(localized: "Drawn along the bottom edge", comment: "Cursor style preview description")
        case .blockHollow:
            return String(localized: "Outlines the character cell", comment: "Cursor style preview description")
        }
    }
}

// MARK: - AI Agent Font Settings

