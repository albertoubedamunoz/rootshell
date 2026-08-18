//
//  SoundManager.swift
//  rootshell
//
//  Manages audio playback for terminal bell sounds and notification sound selection.
//

import AVFoundation
import Combine
import os.log
import UserNotifications

@MainActor
class SoundManager: ObservableObject {
    static let shared = SoundManager()

    nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SoundManager")

    // MARK: - UserDefaults Keys

    private static let bellPresetKey = "bellSoundPreset"
    private static let bellVolumeKey = "bellSoundVolume"
    private static let notificationPresetKey = "notificationSoundPreset"

    // MARK: - Published Properties

    @Published var bellPreset: BellSoundPreset {
        didSet {
            UserDefaults.standard.set(bellPreset.rawValue, forKey: Self.bellPresetKey)
            prepareBellPlayer()
        }
    }

    @Published var bellVolume: Float {
        didSet {
            UserDefaults.standard.set(bellVolume, forKey: Self.bellVolumeKey)
            bellPlayer?.volume = bellVolume
        }
    }

    @Published var notificationPreset: NotificationSoundPreset {
        didSet {
            UserDefaults.standard.set(notificationPreset.rawValue, forKey: Self.notificationPresetKey)
        }
    }

    // MARK: - Audio Player

    private var bellPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    // MARK: - Computed Properties

    /// The UNNotificationSound to use when scheduling OS notifications.
    var currentNotificationSound: UNNotificationSound? {
        notificationPreset.notificationSound
    }

    // MARK: - Init

    private init() {
        // Load persisted preferences
        if let raw = UserDefaults.standard.string(forKey: Self.bellPresetKey),
           let preset = BellSoundPreset(rawValue: raw) {
            self.bellPreset = preset
        } else {
            self.bellPreset = .hapticOnly
        }

        if UserDefaults.standard.object(forKey: Self.bellVolumeKey) != nil {
            self.bellVolume = UserDefaults.standard.float(forKey: Self.bellVolumeKey)
        } else {
            self.bellVolume = 0.7
        }

        if let raw = UserDefaults.standard.string(forKey: Self.notificationPresetKey),
           let preset = NotificationSoundPreset(rawValue: raw) {
            self.notificationPreset = preset
        } else {
            self.notificationPreset = .systemDefault
        }

        configurAudioSession()
        prepareBellPlayer()
    }

    // MARK: - Audio Session

    private func configurAudioSession() {
        #if !targetEnvironment(macCatalyst)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: .mixWithOthers)
        } catch {
            Self.logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Bell Playback

    /// Pre-loads the selected bell sound for zero-latency playback.
    private func prepareBellPlayer() {
        bellPlayer?.stop()
        bellPlayer = nil

        guard let filename = bellPreset.filename else { return }
        guard let player = loadPlayer(for: filename) else { return }

        player.volume = bellVolume
        player.prepareToPlay()
        bellPlayer = player
    }

    /// Plays the selected bell sound. Rewinds to handle rapid successive bells.
    func playBellSound() {
        guard let player = bellPlayer else { return }
        player.currentTime = 0
        player.volume = bellVolume
        player.play()
    }

    // MARK: - Preview Playback

    /// Plays a preview of the given bell sound preset (for the Settings picker).
    func previewBellSound(_ preset: BellSoundPreset) {
        previewPlayer?.stop()
        previewPlayer = nil

        guard let filename = preset.filename else { return }
        guard let player = loadPlayer(for: filename) else { return }

        player.volume = bellVolume
        player.play()
        previewPlayer = player
    }

    /// Plays a preview of the given notification sound preset (for the Settings picker).
    func previewNotificationSound(_ preset: NotificationSoundPreset) {
        previewPlayer?.stop()
        previewPlayer = nil

        guard let filename = preset.filename else { return }
        guard let player = loadPlayer(for: filename) else { return }

        player.volume = 1.0
        player.play()
        previewPlayer = player
    }

    // MARK: - Helpers

    private func loadPlayer(for filename: String) -> AVAudioPlayer? {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            Self.logger.warning("Sound file not found in bundle: \(filename)")
            return nil
        }

        do {
            return try AVAudioPlayer(contentsOf: url)
        } catch {
            Self.logger.error("Failed to load sound \(filename): \(error.localizedDescription)")
            return nil
        }
    }
}
