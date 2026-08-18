#if !CHINA_BUILD
//
//  AudioSessionManager.swift
//  rootshell
//
//  Manages AVAudioSession category switching for voice agent mode.
//  Switches from .playback to .playAndRecord when voice mode activates,
//  and restores the previous category on exit.
//

@preconcurrency import AVFoundation
import os.log

@MainActor
final class AudioSessionManager {

    @ObservationIgnored
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AudioSessionManager")

    #if os(iOS) || os(visionOS)
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?
    private var previousOptions: AVAudioSession.CategoryOptions?
    #endif
    private var isActivated = false

    /// Activate audio session for voice agent (mic + speaker).
    func activateForVoice() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()

        // Save current state for restoration
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setMode(.voiceChat)
        try session.setActive(true, options: [])
        isActivated = true

        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let routeOutputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        if session.mode != .voiceChat {
            Self.logger.error("Voice audio session active without voiceChat mode. category=\(category) mode=\(mode) outputs=\(routeOutputs)")
        } else {
            Self.logger.info("Audio session activated for voice agent category=\(category) mode=\(mode) outputs=\(routeOutputs)")
        }
        #endif
    }

    /// Deactivate and restore previous audio session state.
    func deactivate() {
        guard isActivated else { return }

        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if let category = previousCategory {
                try session.setCategory(
                    category,
                    mode: previousMode ?? .default,
                    options: previousOptions ?? []
                )
            }
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            Self.logger.info("Audio session deactivated, restored previous state")
        } catch {
            Self.logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }

        previousCategory = nil
        previousMode = nil
        previousOptions = nil
        #endif

        isActivated = false
    }
}
#endif
