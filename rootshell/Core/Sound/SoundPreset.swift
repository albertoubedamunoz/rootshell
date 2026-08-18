//
//  SoundPreset.swift
//  rootshell
//
//  Configurable sound presets for terminal bell and notification sounds.
//

import Foundation
import UserNotifications

// MARK: - Bell Sound Preset

/// Sound presets for the terminal bell (BEL character / \a).
/// Bell sounds are short (0.1–0.5s) and played in-app via AVAudioPlayer.
enum BellSoundPreset: String, CaseIterable, Identifiable {
    case hapticOnly = "hapticOnly"
    case classicBell = "classicBell"
    case softChime = "softChime"
    case typewriterDing = "typewriterDing"
    case digitalBeep = "digitalBeep"
    case glassTap = "glassTap"
    case mutedThud = "mutedThud"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hapticOnly: return String(localized: "Haptic Only", comment: "Bell sound: haptic feedback only")
        case .classicBell: return String(localized: "Classic Bell", comment: "Bell sound: traditional metal bell")
        case .softChime: return String(localized: "Soft Chime", comment: "Bell sound: gentle wind chime")
        case .typewriterDing: return String(localized: "Typewriter Ding", comment: "Bell sound: typewriter carriage return")
        case .digitalBeep: return String(localized: "Digital Glitch", comment: "Bell sound: UI glitch beep")
        case .glassTap: return String(localized: "Glass Tap", comment: "Bell sound: glass clink")
        case .mutedThud: return String(localized: "Muted Thud", comment: "Bell sound: subtle low thud")
        case .none: return String(localized: "None", comment: "Bell sound: completely silent")
        }
    }

    /// The bundle resource filename for this preset, or nil if no audio file.
    var filename: String? {
        switch self {
        case .hapticOnly, .none: return nil
        case .classicBell: return "bell_classic.caf"
        case .softChime: return "bell_soft_chime.caf"
        case .typewriterDing: return "bell_typewriter_ding.caf"
        case .digitalBeep: return "bell_digital_beep.caf"
        case .glassTap: return "bell_glass_tap.caf"
        case .mutedThud: return "bell_muted_thud.caf"
        }
    }

    /// Whether this preset should also trigger haptic feedback.
    var includesHaptic: Bool {
        switch self {
        case .none: return false
        default: return true
        }
    }
}

// MARK: - Notification Sound Preset

/// Sound presets for OS notifications (OSC 9, SSH reminders, etc.).
/// Notification sounds are longer (1–3s) and played by the system via UNNotificationSound.
enum NotificationSoundPreset: String, CaseIterable, Identifiable {
    case systemDefault = "systemDefault"
    case crystalChime = "crystalChime"
    case gentlePing = "gentlePing"
    case warmTone = "warmTone"
    case brightAlert = "brightAlert"
    case softMarimba = "softMarimba"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: return String(localized: "System Default", comment: "Notification sound: system default")
        case .crystalChime: return String(localized: "Crystal Chime", comment: "Notification sound: ascending sparkly tones")
        case .gentlePing: return String(localized: "Gentle Ping", comment: "Notification sound: soft single tone")
        case .warmTone: return String(localized: "Warm Tone", comment: "Notification sound: rich mid-range")
        case .brightAlert: return String(localized: "Bright Alert", comment: "Notification sound: two-tone ascending")
        case .softMarimba: return String(localized: "Soft Marimba", comment: "Notification sound: wooden mallet")
        case .none: return String(localized: "None", comment: "Notification sound: silent")
        }
    }

    /// The bundle resource filename for this preset, or nil if using system default or none.
    var filename: String? {
        switch self {
        case .systemDefault, .none: return nil
        case .crystalChime: return "notif_crystal_chime.caf"
        case .gentlePing: return "notif_gentle_ping.caf"
        case .warmTone: return "notif_warm_tone.caf"
        case .brightAlert: return "notif_bright_alert.caf"
        case .softMarimba: return "notif_soft_marimba.caf"
        }
    }

    /// The UNNotificationSound for this preset, used when scheduling OS notifications.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .systemDefault: return .default
        case .none: return nil
        case .crystalChime, .gentlePing, .warmTone, .brightAlert, .softMarimba:
            guard let name = filename else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }
}
