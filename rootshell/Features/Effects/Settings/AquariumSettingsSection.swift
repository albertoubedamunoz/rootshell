// AquariumSettingsSection.swift
// rootshell

import SwiftUI
import UIKit

extension AquariumConfiguration.Lighting {
    var displayName: String {
        switch self {
        case .theme: return String(localized: "Follow Terminal Theme", comment: "Aquarium lighting preset")
        case .tropical: return String(localized: "Tropical Daylight", comment: "Aquarium lighting preset")
        case .moonlight: return String(localized: "Moonlit Reef", comment: "Aquarium lighting preset")
        case .amber: return String(localized: "Amber Lagoon", comment: "Aquarium lighting preset")
        case .custom: return String(localized: "Custom Light", comment: "Aquarium lighting preset")
        }
    }
}
extension AquariumConfiguration.Quality {
    var displayName: String {
        switch self {
        case .economical: return String(localized: "Economical", comment: "Aquarium render quality")
        case .balanced: return String(localized: "Balanced", comment: "Aquarium render quality")
        case .cinematic: return String(localized: "Cinematic", comment: "Aquarium render quality")
        }
    }
}

struct AquariumSettingsSection: View {
    @ObservedObject var effect: AquariumEffect
    let onShowcase: () -> Void
    let onReset: () -> Void

    private func binding<Value>(_ key: WritableKeyPath<AquariumConfiguration, Value>) -> Binding<Value> {
        Binding(get: { effect.configuration[keyPath: key] }, set: { effect.configuration[keyPath: key] = $0 })
    }

    var body: some View {
        Section("Aquarium Life") {
            Stepper(value: binding(\.fishCount), in: 0...64, step: 1) {
                HStack {
                    Text("Fish Population")
                    Spacer()
                    Text(effect.configuration.fishCount, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .themedRow()
            Text("Clownfish, blue tangs, butterflyfish, angelfish, and neon tetras swim in a decorative mixed-species scene.")
                .font(.caption).foregroundStyle(.secondary).themedRow()
            AquariumSettingSlider(title: "Kelp Density", value: binding(\.kelpDensity), range: 0...1)
                .themedRow()
            AquariumSettingSlider(title: "Water Current", value: binding(\.currentStrength), range: 0...1)
                .themedRow()
            Toggle("Bubbles", isOn: binding(\.bubbles)).themedRow()
            Toggle("Suspended Particles", isOn: binding(\.particles)).themedRow()
            Toggle("Pause Aquarium", isOn: binding(\.paused)).themedRow()
        }
        Section("Aquarium Lighting") {
            Picker("Lighting", selection: binding(\.lighting)) {
                ForEach(AquariumConfiguration.Lighting.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .themedRow()
            if effect.configuration.lighting == .custom {
                ColorPicker("Light Color", selection: lightColor, supportsOpacity: false).themedRow()
            }
            AquariumSettingSlider(title: "Light Strength", value: binding(\.lightIntensity), range: 0...3, percentage: false).themedRow()
            AquariumSettingSlider(title: "Light Direction", value: binding(\.lightAngle), range: -1...1, percentage: false).themedRow()
            AquariumSettingSlider(title: "Warmth", value: binding(\.warmth), range: -1...1, percentage: false).themedRow()
            AquariumSettingSlider(title: "Exposure", value: binding(\.exposure), range: -2...2, percentage: false).themedRow()
            AquariumSettingSlider(title: "Saturation", value: binding(\.saturation), range: 0...1.5).themedRow()
            AquariumSettingSlider(title: "Caustic Light", value: binding(\.caustics), range: 0...1).themedRow()
            AquariumSettingSlider(title: "Water Haze", value: binding(\.haze), range: 0...1).themedRow()
            AquariumSettingSlider(title: "Bloom", value: binding(\.bloom), range: 0...1).themedRow()
        }
        Section {
            AquariumSettingSlider(title: "Reading Protection", value: binding(\.readingProtection), range: 0...1).themedRow()
            Picker("Render Quality", selection: binding(\.quality)) {
                ForEach(AquariumConfiguration.Quality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .themedRow()
            Button(action: onShowcase) {
                Label("Full-screen Aquarium Preview", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .themedRow()
        } header: {
            Text("Aquarium Presentation")
        } footer: {
            Text("Reading Protection softens the effect behind central text. Cinematic targets 60 fps; other modes target 30 fps. Battery Saver lowers quality automatically. Reduce Motion shows a still aquarium.")
        }
        Section {
            Button(action: onReset) {
                Label("Reset Aquarium to Defaults", systemImage: "arrow.counterclockwise")
            }
            .themedRow()
        } footer: {
            Text("Restores all aquarium settings, including intensity, speed, and a population of 3 fish on iPhone or 8 on other devices.")
        }
    }

    private var lightColor: Binding<Color> {
        Binding(get: {
            let rgb = AquariumRGB(hex: effect.configuration.lightColor) ?? AquariumRGB(0.57, 0.91, 0.93)
            return Color(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b))
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            effect.configuration.lightColor = AquariumRGB(Float(r), Float(g), Float(b)).hex
        })
    }
}

/// Keep interactive slider motion local; persist and rebuild only on release.
/// External reset/sync updates are still reflected when the slider isn't being dragged.
private struct AquariumSettingSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var percentage = true
    @State private var draft: Double = 0
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if percentage {
                    Text(draft, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(draft, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Slider(value: $draft, in: range) { isEditing in
                editing = isEditing
                if !isEditing { value = draft }
            }
            .accessibilityLabel(Text(title))
        }
        .padding(.vertical, 4)
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in if !editing { draft = newValue } }
    }
}
