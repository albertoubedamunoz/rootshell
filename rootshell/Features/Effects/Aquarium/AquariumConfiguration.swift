// AquariumConfiguration.swift
// rootshell
// Pure value types: also compiled by scripts/test-aquarium-core.sh without an Apple SDK.

import Foundation
import CoreFoundation

struct AquariumConfiguration: Equatable, Sendable {
    enum Lighting: String, CaseIterable, Sendable {
        case theme, tropical, moonlight, amber, custom
    }

    enum Quality: String, CaseIterable, Sendable {
        case economical, balanced, cinematic
        var pixelBudget: Double {
            switch self {
            case .economical: return 700_000
            case .balanced: return 1_400_000
            case .cinematic: return 2_800_000
            }
        }
        var shadowSize: Int {
            switch self {
            case .economical: return 512
            case .balanced: return 1024
            case .cinematic: return 1536
            }
        }
        var framesPerSecond: Int { self == .cinematic ? 60 : 30 }
    }

    var intensity: Double = 0.30
    var speed: Double = 1.0
    var fishCount: Int = 8
    var kelpDensity: Double = 0.75
    var currentStrength: Double = 0.45
    var lighting: Lighting = .theme
    var lightColor: String = "#91E7ED"
    var lightIntensity: Double = 1.1
    var lightAngle: Double = -0.35
    var warmth: Double = 0.0
    var exposure: Double = 0.0
    var saturation: Double = 1.0
    var caustics: Double = 0.65
    var haze: Double = 0.45
    var bloom: Double = 0.25
    var readingProtection: Double = 0.45
    var bubbles: Bool = true
    var particles: Bool = true
    var paused: Bool = false
    var quality: Quality = .balanced

    static func finite(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    func sanitized() -> Self {
        var c = self
        c.intensity = Self.finite(c.intensity, 0...1, fallback: 0.30)
        c.speed = Self.finite(c.speed, 0...2, fallback: 1)
        c.fishCount = min(max(c.fishCount, 0), 64)
        c.kelpDensity = Self.finite(c.kelpDensity, 0...1, fallback: 0.75)
        c.currentStrength = Self.finite(c.currentStrength, 0...1, fallback: 0.45)
        c.lightColor = AquariumRGB(hex: c.lightColor)?.hex ?? "#91E7ED"
        c.lightIntensity = Self.finite(c.lightIntensity, 0...3, fallback: 1.1)
        c.lightAngle = Self.finite(c.lightAngle, -1...1, fallback: -0.35)
        c.warmth = Self.finite(c.warmth, -1...1, fallback: 0)
        c.exposure = Self.finite(c.exposure, -2...2, fallback: 0)
        c.saturation = Self.finite(c.saturation, 0...1.5, fallback: 1)
        c.caustics = Self.finite(c.caustics, 0...1, fallback: 0.65)
        c.haze = Self.finite(c.haze, 0...1, fallback: 0.45)
        c.bloom = Self.finite(c.bloom, 0...1, fallback: 0.25)
        c.readingProtection = Self.finite(c.readingProtection, 0...1, fallback: 0.45)
        return c
    }

    var dictionary: [String: Any] {
        let c = sanitized()
        return [
            "version": 1, "intensity": c.intensity, "speed": c.speed,
            "fishCount": c.fishCount, "kelpDensity": c.kelpDensity,
            "currentStrength": c.currentStrength, "lighting": c.lighting.rawValue,
            "lightColor": c.lightColor, "lightIntensity": c.lightIntensity,
            "lightAngle": c.lightAngle, "warmth": c.warmth,
            "exposure": c.exposure, "saturation": c.saturation,
            "caustics": c.caustics, "haze": c.haze, "bloom": c.bloom,
            "readingProtection": c.readingProtection, "bubbles": c.bubbles,
            "particles": c.particles, "paused": c.paused, "quality": c.quality.rawValue
        ]
    }

    /// Partial/older dictionaries retain defaults. Unknown future keys are ignored.
    static func decode(_ data: [String: Any], defaults: Self = Self()) -> Self {
        var c = defaults
        func number(_ key: String, _ fallback: Double) -> Double {
            // Native dictionaries contain Int; JSONSerialization produces NSNumber.
            // CFBoolean also bridges to NSNumber, but is not a valid numeric setting.
            guard let value = data[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return fallback }
            return value.doubleValue
        }
        c.intensity = number("intensity", c.intensity)
        c.speed = number("speed", c.speed)
        // Clamp before integer conversion: JSON numbers may be huge or nonfinite.
        c.fishCount = Int(finite(number("fishCount", Double(c.fishCount)), 0...64, fallback: Double(c.fishCount)))
        c.kelpDensity = number("kelpDensity", c.kelpDensity)
        c.currentStrength = number("currentStrength", c.currentStrength)
        c.lightIntensity = number("lightIntensity", c.lightIntensity)
        c.lightAngle = number("lightAngle", c.lightAngle)
        c.warmth = number("warmth", c.warmth)
        c.exposure = number("exposure", c.exposure)
        c.saturation = number("saturation", c.saturation)
        c.caustics = number("caustics", c.caustics)
        c.haze = number("haze", c.haze)
        c.bloom = number("bloom", c.bloom)
        c.readingProtection = number("readingProtection", c.readingProtection)
        c.lightColor = data["lightColor"] as? String ?? c.lightColor
        c.bubbles = data["bubbles"] as? Bool ?? c.bubbles
        c.particles = data["particles"] as? Bool ?? c.particles
        c.paused = data["paused"] as? Bool ?? c.paused
        if let raw = data["lighting"] as? String, let mode = Lighting(rawValue: raw) { c.lighting = mode }
        if let raw = data["quality"] as? String, let quality = Quality(rawValue: raw) { c.quality = quality }
        return c.sanitized()
    }
}

struct AquariumRGB: Equatable, Sendable {
    var r: Float
    var g: Float
    var b: Float
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let bits = UInt32(digits, radix: 16) else { return nil }
        self.init(Float((bits >> 16) & 255) / 255, Float((bits >> 8) & 255) / 255, Float(bits & 255) / 255)
    }
    var hex: String {
        func byte(_ f: Float) -> Int { Int((min(max(f.isFinite ? f : 0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
    var vector: SIMD3<Float> { SIMD3(r, g, b) }
    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    func mixed(with other: Self, amount: Float) -> Self {
        Self(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }
    var linear: SIMD3<Float> {
        func channel(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD3(channel(r), channel(g), channel(b))
    }
}

struct AquariumPalette: Equatable, Sendable {
    var water: SIMD3<Float>
    var light: SIMD3<Float>
    var fill: SIMD3<Float>
    var isLight: Bool

    static func make(configuration: AquariumConfiguration, background: String, palette: [String]) -> Self {
        let c = configuration.sanitized()
        let bg = AquariumRGB(hex: background) ?? AquariumRGB(0.07, 0.09, 0.14)
        let cyan = palette.count > 6 ? AquariumRGB(hex: palette[6]) : nil
        let blue = palette.count > 4 ? AquariumRGB(hex: palette[4]) : nil
        let water: AquariumRGB
        let key: AquariumRGB
        switch c.lighting {
        case .theme:
            water = bg.mixed(with: blue ?? AquariumRGB(0.12, 0.30, 0.44), amount: 0.30)
            key = (cyan ?? AquariumRGB(0.45, 0.88, 0.93)).mixed(with: AquariumRGB(0.72, 0.91, 0.90), amount: 0.4)
        case .tropical:
            water = AquariumRGB(0.03, 0.23, 0.29); key = AquariumRGB(0.73, 0.96, 0.88)
        case .moonlight:
            water = AquariumRGB(0.035, 0.075, 0.19); key = AquariumRGB(0.43, 0.63, 1)
        case .amber:
            water = AquariumRGB(0.11, 0.15, 0.15); key = AquariumRGB(1, 0.76, 0.42)
        case .custom:
            key = AquariumRGB(hex: c.lightColor) ?? AquariumRGB(0.57, 0.91, 0.93)
            water = bg.mixed(with: key, amount: 0.22)
        }
        let temperature = c.warmth < 0 ? AquariumRGB(0.39, 0.66, 1) : AquariumRGB(1, 0.65, 0.30)
        let warmed = key.mixed(with: temperature, amount: Float(abs(c.warmth)) * 0.65)
        return Self(water: water.linear, light: warmed.linear,
                    fill: AquariumRGB(0.22, 0.42, 0.49).mixed(with: water, amount: 0.4).linear,
                    isLight: bg.luminance > 0.5)
    }
}
