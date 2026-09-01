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

    // MARK: - Settings keys

    private static let ownedKeys: Set<String> = [
        Settings.Sounds.bellPreset.name, Settings.Sounds.bellVolume.name, Settings.Sounds.notificationPreset.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    // MARK: - Published Properties

    @Published var bellPreset: BellSoundPreset {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Sounds.bellPreset, bellPreset) }
            prepareBellPlayer()
        }
    }

    @Published var bellVolume: Float {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Sounds.bellVolume, bellVolume) }
            bellPlayer?.volume = bellVolume
        }
    }

    @Published var notificationPreset: NotificationSoundPreset {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Sounds.notificationPreset, notificationPreset) }
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
        let store = SettingsStore.shared
        self.bellPreset = store.get(Settings.Sounds.bellPreset)
        self.bellVolume = store.get(Settings.Sounds.bellVolume)
        self.notificationPreset = store.get(Settings.Sounds.notificationPreset)

        configurAudioSession()
        prepareBellPlayer()

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Sounds.bellPreset.name) { bellPreset = store.get(Settings.Sounds.bellPreset) }
        if keys.contains(Settings.Sounds.bellVolume.name) { bellVolume = store.get(Settings.Sounds.bellVolume) }
        if keys.contains(Settings.Sounds.notificationPreset.name) {
            notificationPreset = store.get(Settings.Sounds.notificationPreset)
        }
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
