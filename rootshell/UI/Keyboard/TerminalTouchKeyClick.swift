#if !os(visionOS) && !targetEnvironment(macCatalyst)
import AudioToolbox
import Foundation
import os

/// Per-style key clicks, synthesized once into Caches and played as system
/// sounds: they obey the silent switch and mix with other audio.
@MainActor
final class TerminalTouchKeyClick {
    static let shared = TerminalTouchKeyClick()

    enum Profile: String, CaseIterable {
        case tick, thock, strike, clack, blip, zap, chirp
    }

    private static let version = 1
    private static let sampleRate = 44_100.0
    private var sounds: [Profile: SystemSoundID] = [:]
    private var failed: Set<Profile> = []

    func play(_ profile: Profile) {
        if let sound = sounds[profile] { AudioServicesPlaySystemSound(sound); return }
        guard !failed.contains(profile) else { return }
        guard let sound = load(profile) else { failed.insert(profile); return }
        sounds[profile] = sound
        AudioServicesPlaySystemSound(sound)
    }

    private func load(_ profile: Profile) -> SystemSoundID? {
        do {
            let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("KeyClicks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(profile.rawValue)-v\(Self.version).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Self.wav(Self.samples(profile)).write(to: url, options: .atomic)
            }
            var sound: SystemSoundID = 0
            let status = AudioServicesCreateSystemSoundID(url as CFURL, &sound)
            guard status == kAudioServicesNoError else {
                Logger(subsystem: "com.rootshell", category: "KeyClick").warning("Key click load failed: \(status)")
                return nil
            }
            return sound
        } catch {
            Logger(subsystem: "com.rootshell", category: "KeyClick").warning("Key click write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Synthesis

    private static func samples(_ profile: Profile) -> [Float] {
        let duration: Double = switch profile {
        case .tick: 0.03
        case .thock: 0.07
        case .strike: 0.12
        case .clack: 0.09
        case .blip: 0.05
        case .zap: 0.08
        case .chirp: 0.05
        }
        var noise = Noise()
        var lowpass: Float = 0
        return (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            func tone(_ frequency: Double, decay: Double) -> Double { sin(2 * .pi * frequency * t) * exp(-t / decay) }
            let n = Double(noise.next())
            let value: Double
            switch profile {
            case .tick:
                value = 0.5 * n * exp(-t / 0.002) + 0.35 * tone(3200, decay: 0.006)
            case .thock:
                // Low body plus a dull, low-passed contact.
                lowpass += 0.18 * (Float(n) - lowpass)
                value = 0.7 * tone(170, decay: 0.022) + 0.25 * tone(420, decay: 0.01) + 0.8 * Double(lowpass) * exp(-t / 0.006)
            case .strike:
                lowpass += 0.3 * (Float(n) - lowpass)
                value = 0.9 * Double(lowpass) * exp(-t / 0.008) + 0.25 * tone(1150, decay: 0.035) + 0.12 * tone(2310, decay: 0.02)
            case .clack:
                // Buckling spring: a sharp snap, then the spring's metallic ring.
                value = 0.6 * n * exp(-t / 0.0025) + 0.22 * tone(2450, decay: 0.03) * (1 + 0.3 * sin(2 * .pi * 90 * t))
                    + 0.14 * tone(4100, decay: 0.018) + 0.3 * n * (t > 0.012 ? exp(-(t - 0.012) / 0.003) : 0)
            case .blip:
                value = 0.4 * sin(2 * .pi * 1000 * t) * min(1, t / 0.002) * exp(-t / 0.014)
            case .zap:
                let phase = 2 * .pi * (600 * t + 5000 * t * t)
                value = 0.3 * (2 * (phase / (2 * .pi)).truncatingRemainder(dividingBy: 1) - 1) * min(1, t / 0.002) * exp(-t / 0.02)
            case .chirp:
                let square: Double = sin(2 * .pi * (t < 0.015 ? 1800 : 2700) * t) >= 0 ? 1 : -1
                value = 0.18 * square * min(1, t / 0.001) * exp(-t / 0.012)
            }
            return Float(max(-1, min(1, value)))
        }
    }

    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(sample * Float(Int16.max))) }
        return data
    }

    /// Deterministic noise so every install hears the same click.
    private struct Noise {
        var state: UInt32 = 0x1234_5678
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) * 2 - 1
        }
    }
}

extension TerminalTouchKeyboardModel.Style {
    var clickProfile: TerminalTouchKeyClick.Profile {
        switch self {
        case .flat: .tick
        case .sculpted: .thock
        case .steampunk: .strike
        case .beigeBox: .clack
        case .phosphor: .blip
        case .neonGrid: .zap
        case .circuitBoard: .chirp
        }
    }
}
#endif
