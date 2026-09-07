import AVFoundation
import Foundation
import os

/// Prepare the playback policy alongside UI startup, without making a silent
/// terminal wait for the audio service. Swift's static initialization serializes
/// concurrent callers; consumers can join the same setup before using audio.
nonisolated enum AppAudioSession {
    private static let configuration: Void = {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            // AVPlayer/AVAudioPlayer activate on playback. Voice and remote
            // audio explicitly activate their own sessions when needed.
        } catch {
            Logger(subsystem: "com.rootshell", category: "AppAudioSession")
                .warning("Failed to configure audio session: \(error.localizedDescription)")
        }
    }()

    static func prepare() {
        DispatchQueue.global(qos: .userInitiated).async {
            ensureConfigured()
        }
    }

    /// Call before creating a player or overriding the initial category.
    /// Later calls never overwrite a category selected by voice or bell audio.
    static func ensureConfigured() {
        _ = configuration
    }
}
