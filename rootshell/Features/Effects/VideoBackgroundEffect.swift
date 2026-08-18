//
//  VideoBackgroundEffect.swift
//  rootshell
//
//  Video background effect implementation conforming to TerminalEffect protocol
//

import SwiftUI
import Combine

/// Video background visual effect using looping video playback
final class VideoBackgroundEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    /// Unique ID includes video ID to allow multiple video effects
    var id: String { "videoBackground_\(videoInfo.id)" }

    let displayName: String
    let previewIcon: String
    let effectDescription: String

    var intensity: Double {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    /// Playback speed (0.5 = half speed, 2.0 = double speed)
    var speed: Double = 1.0 {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeTintEnabled: Bool = false {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeTintAmount: Double = 0.6 {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Video-Specific Properties

    /// The video information from VideoBackgroundManager
    let videoInfo: VideoBackgroundInfo

    // MARK: - Initialization

    init(videoInfo: VideoBackgroundInfo) {
        self.videoInfo = videoInfo
        self.displayName = videoInfo.displayName
        self.previewIcon = videoInfo.previewIcon
        self.effectDescription = videoInfo.description
        self.intensity = videoInfo.defaultIntensity
    }

    // MARK: - TerminalEffect Methods

    func createEffectView() -> AnyView {
        AnyView(VideoBackgroundView(effect: self))
    }

    func resetToDefaults() {
        intensity = videoInfo.defaultIntensity
        speed = 1.0
        themeTintEnabled = false
        themeTintAmount = 0.6
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "videoId": videoInfo.id,
            "themeTintEnabled": themeTintEnabled,
            "themeTintAmount": themeTintAmount
        ]
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = max(0, min(1, intensity))
        }
        if let speed = data["speed"] as? Double {
            self.speed = max(0.25, min(4.0, speed))
        }
        if let tintAmount = data["themeTintAmount"] as? Double {
            self.themeTintAmount = max(0, min(1, tintAmount))
        }
        if let tintEnabled = data["themeTintEnabled"] as? Bool {
            self.themeTintEnabled = tintEnabled
        }
    }
}
