//
//  VideoBackgroundUIView.swift
//  rootshell
//
//  UIKit view for video background playback with seamless looping
//

import UIKit
import AVFoundation
import CoreImage
import os

/// Thread-safe holder for the current theme-tint state used by the
/// AVVideoComposition handler, which runs off the main actor.
final class VideoTintState: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled: Bool
    private var _amount: Double
    private var _themeColors: EffectThemeColors

    init(enabled: Bool, amount: Double, themeColors: EffectThemeColors) {
        self._enabled = enabled
        self._amount = amount
        self._themeColors = themeColors
    }

    func update(enabled: Bool, amount: Double, themeColors: EffectThemeColors) {
        lock.lock()
        _enabled = enabled
        _amount = amount
        _themeColors = themeColors
        lock.unlock()
    }

    func snapshot() -> (enabled: Bool, amount: Double, themeColors: EffectThemeColors) {
        lock.lock()
        defer { lock.unlock() }
        return (_enabled, _amount, _themeColors)
    }
}

/// UIView that displays a looping video background using AVPlayer
class VideoBackgroundUIView: UIView {

    // MARK: - Properties

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VideoBackgroundUIView"
    )

    private let videoURL: URL
    private let aspectMode: VideoAspectMode
    private let aspectAlignment: VideoAspectAlignment
    private let seamlessLoop: Bool
    private let crossfadeDuration: TimeInterval

    // Seamless looping components
    private var queuePlayer: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?

    // Crossfade looping components (for non-seamless videos)
    private var primaryPlayer: AVPlayer?
    private var primaryPlayerLayer: AVPlayerLayer?
    private var secondaryPlayer: AVPlayer?
    private var secondaryPlayerLayer: AVPlayerLayer?
    private var endTimeObserver: Any?
    private var isCrossfading = false

    // Lifecycle observers
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // Audio session observers
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioRouteChangeObserver: NSObjectProtocol?

    // Current playback rate
    private var currentRate: Float = 1.0

    // Theme-tint state (shared with AVVideoComposition handler thread)
    private let tintState: VideoTintState

    // Generation counter to invalidate in-flight async setup tasks
    // when cleanupPlayers/recreatePlayer is called mid-setup.
    private var setupGeneration: Int = 0

    // MARK: - Initialization

    init(
        videoURL: URL,
        aspectMode: VideoAspectMode,
        aspectAlignment: VideoAspectAlignment,
        seamlessLoop: Bool,
        crossfadeDuration: TimeInterval,
        playbackRate: Double,
        themeTintEnabled: Bool,
        themeTintAmount: Double,
        themeColors: EffectThemeColors
    ) {
        self.videoURL = videoURL
        self.aspectMode = aspectMode
        self.aspectAlignment = aspectAlignment
        self.seamlessLoop = seamlessLoop
        self.crossfadeDuration = crossfadeDuration
        self.currentRate = Float(playbackRate)
        self.tintState = VideoTintState(
            enabled: themeTintEnabled,
            amount: themeTintAmount,
            themeColors: themeColors
        )

        super.init(frame: .zero)

        backgroundColor = .clear
        isUserInteractionEnabled = false

        setupLifecycleObservers()
        setupVideo()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cleanup()
    }

    // MARK: - Setup

    private func setupVideo() {
        setupGeneration += 1
        let generation = setupGeneration
        let asset = AVURLAsset(url: videoURL)

        // Only pay the AVVideoComposition cost when the tint is actually on.
        // Toggling the tint later triggers a rebuild via updateThemeTint.
        let needsComposition = tintState.snapshot().enabled

        if !needsComposition {
            completeSetup(asset: asset, composition: nil)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let composition = await self.buildVideoComposition(for: asset)
            // Drop if another setup started while we were awaiting.
            guard self.setupGeneration == generation else { return }
            self.completeSetup(asset: asset, composition: composition)
        }
    }

    private func completeSetup(asset: AVURLAsset, composition: AVMutableVideoComposition?) {
        if seamlessLoop {
            completeSeamlessLoopSetup(asset: asset, composition: composition)
        } else {
            completeCrossfadeLoopSetup(asset: asset, composition: composition)
        }
    }

    /// Build a CIFilter video composition that applies the theme tint to each
    /// frame. Only called when the tint is enabled — the handler still reads
    /// `tintState` every frame so amount/color changes take effect without
    /// rebuilding. Toggling the enabled flag, however, triggers a full player
    /// rebuild so we can detach the composition and skip the CI cost.
    private func buildVideoComposition(for asset: AVURLAsset) async -> AVMutableVideoComposition? {
        let tintState = self.tintState
        do {
            return try await AVMutableVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: { request in
                    let snapshot = tintState.snapshot()

                    guard snapshot.enabled,
                          let filter = ThemePaletteCube.makeFilter(
                            themeColors: snapshot.themeColors,
                            amount: snapshot.amount
                          )
                    else {
                        request.finish(with: request.sourceImage, context: nil)
                        return
                    }

                    filter.setValue(request.sourceImage, forKey: kCIInputImageKey)
                    let output = (filter.outputImage ?? request.sourceImage)
                        .cropped(to: request.sourceImage.extent)
                    request.finish(with: output, context: nil)
                }
            )
        } catch {
            Self.logger.error("Failed to build video composition: \(error.localizedDescription)")
            return nil
        }
    }

    /// Setup seamless looping using AVQueuePlayer + AVPlayerLooper.
    /// Composition must be attached to the template item BEFORE AVPlayerLooper
    /// is created — the looper clones the template internally.
    private func completeSeamlessLoopSetup(
        asset: AVURLAsset,
        composition: AVMutableVideoComposition?
    ) {
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.videoComposition = composition

        // Disable audio tracks to prevent any audio processing
        disableAudioTracks(for: playerItem)

        queuePlayer = AVQueuePlayer()
        queuePlayer?.isMuted = true

        // Create looper for gapless playback
        looper = AVPlayerLooper(player: queuePlayer!, templateItem: playerItem)

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer?.videoGravity = videoGravity
        playerLayer?.frame = bounds

        if let playerLayer = playerLayer {
            layer.addSublayer(playerLayer)
        }

        queuePlayer?.rate = currentRate

        Self.logger.debug("Setup seamless loop for video: \(self.videoURL.lastPathComponent)")
    }

    /// Setup crossfade looping for non-seamless videos.
    private func completeCrossfadeLoopSetup(
        asset: AVURLAsset,
        composition: AVMutableVideoComposition?
    ) {
        // Create primary player
        let primaryItem = AVPlayerItem(asset: asset)
        primaryItem.videoComposition = composition
        disableAudioTracks(for: primaryItem)
        primaryPlayer = AVPlayer(playerItem: primaryItem)
        primaryPlayer?.isMuted = true

        primaryPlayerLayer = AVPlayerLayer(player: primaryPlayer)
        primaryPlayerLayer?.videoGravity = videoGravity
        primaryPlayerLayer?.frame = bounds

        // Create secondary player for crossfade
        let secondaryItem = AVPlayerItem(asset: asset)
        secondaryItem.videoComposition = composition
        disableAudioTracks(for: secondaryItem)
        secondaryPlayer = AVPlayer(playerItem: secondaryItem)
        secondaryPlayer?.isMuted = true

        secondaryPlayerLayer = AVPlayerLayer(player: secondaryPlayer)
        secondaryPlayerLayer?.videoGravity = videoGravity
        secondaryPlayerLayer?.frame = bounds
        secondaryPlayerLayer?.opacity = 0

        // Add layers (secondary underneath primary)
        if let secondaryPlayerLayer = secondaryPlayerLayer {
            layer.addSublayer(secondaryPlayerLayer)
        }
        if let primaryPlayerLayer = primaryPlayerLayer {
            layer.addSublayer(primaryPlayerLayer)
        }

        // Setup end-time observer for crossfade
        setupCrossfadeObserver()

        primaryPlayer?.rate = currentRate

        Self.logger.debug("Setup crossfade loop for video: \(self.videoURL.lastPathComponent)")
    }

    private func setupCrossfadeObserver() {
        guard let player = primaryPlayer,
              let item = player.currentItem else { return }

        // Capture the generation so we can abandon this task if cleanupPlayers
        // tears down the player while we're awaiting duration.
        let generation = setupGeneration

        // Load duration asynchronously
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let duration = try await item.asset.load(.duration)
                guard duration.isValid && !duration.isIndefinite else { return }

                // Bail if the player we targeted is no longer the current one.
                guard self.setupGeneration == generation,
                      self.primaryPlayer === player else {
                    return
                }

                let durationSeconds = CMTimeGetSeconds(duration)
                let triggerTime = max(0, durationSeconds - self.crossfadeDuration)

                let triggerCMTime = CMTime(seconds: triggerTime, preferredTimescale: 600)
                let times = [NSValue(time: triggerCMTime)]

                self.endTimeObserver = player.addBoundaryTimeObserver(
                    forTimes: times,
                    queue: .main
                ) { [weak self] in
                    self?.startCrossfade()
                }
            } catch {
                Self.logger.error("Failed to load video duration: \(error.localizedDescription)")
            }
        }
    }

    private func startCrossfade() {
        guard !isCrossfading else { return }
        isCrossfading = true

        // Prepare secondary player at start
        secondaryPlayer?.seek(to: .zero)
        secondaryPlayer?.rate = currentRate

        // Animate crossfade
        CATransaction.begin()
        CATransaction.setAnimationDuration(crossfadeDuration)
        CATransaction.setCompletionBlock { [weak self] in
            self?.completeCrossfade()
        }

        primaryPlayerLayer?.opacity = 0
        secondaryPlayerLayer?.opacity = 1

        CATransaction.commit()
    }

    private func completeCrossfade() {
        // Swap players
        swap(&primaryPlayer, &secondaryPlayer)
        swap(&primaryPlayerLayer, &secondaryPlayerLayer)

        // Reset opacities
        primaryPlayerLayer?.opacity = 1
        secondaryPlayerLayer?.opacity = 0

        // Pause secondary (now former primary)
        secondaryPlayer?.pause()

        // Setup observer on new primary
        if let observer = endTimeObserver {
            secondaryPlayer?.removeTimeObserver(observer)
        }
        setupCrossfadeObserver()

        isCrossfading = false
    }

    // MARK: - Lifecycle Management

    private func setupLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pause()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumeAfterForegroundQuietWindow()
            }
        }

        // Audio session interruption (AirPods switching, phone calls)
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }

        // Audio route changes (device disconnections)
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            Self.logger.debug("Audio interruption began")
        case .ended:
            Self.logger.debug("Audio interruption ended, resuming video")
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // Device disconnected - system may have paused playback
            Self.logger.debug("Audio device disconnected, ensuring video continues")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.resume()
            }
        case .categoryChange:
            Self.logger.debug("Audio category changed, ensuring video continues")
            resume()
        default:
            break
        }
    }

    private func cleanup() {
        // Remove lifecycle observers
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Remove audio session observers
        if let observer = audioInterruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        cleanupPlayers()
    }

    /// Clean up player resources without removing lifecycle observers
    private func cleanupPlayers() {
        // Invalidate any in-flight async setup task.
        setupGeneration += 1

        // Remove time observer
        if let observer = endTimeObserver {
            primaryPlayer?.removeTimeObserver(observer)
            endTimeObserver = nil
        }

        // Disable and clear looper
        looper?.disableLooping()
        looper = nil

        // Pause and clear players
        queuePlayer?.pause()
        queuePlayer = nil

        primaryPlayer?.pause()
        primaryPlayer = nil

        secondaryPlayer?.pause()
        secondaryPlayer = nil

        // Remove layers
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        primaryPlayerLayer?.removeFromSuperlayer()
        primaryPlayerLayer = nil
        secondaryPlayerLayer?.removeFromSuperlayer()
        secondaryPlayerLayer = nil

        isCrossfading = false
    }

    /// Check if player needs to be recreated due to failed state
    private func needsRecreation() -> Bool {
        if seamlessLoop {
            // Check queue player and looper health
            guard let player = queuePlayer,
                  let item = player.currentItem,
                  item.status == .readyToPlay else {
                return true
            }
            return false
        } else {
            // Check primary player health
            guard let player = primaryPlayer,
                  let item = player.currentItem,
                  item.status == .readyToPlay else {
                return true
            }
            return false
        }
    }

    /// Recreate the player when it's in a failed state
    private func recreatePlayer() {
        cleanupPlayers()
        setupVideo()
    }

    // MARK: - Playback Control

    func pause() {
        queuePlayer?.pause()
        primaryPlayer?.pause()
        secondaryPlayer?.pause()
    }

    func resume() {
        Self.logger.debug("Resuming video playback...")

        // Check if player needs recreation
        if needsRecreation() {
            Self.logger.info("Player needs recreation, rebuilding...")
            recreatePlayer()
            return
        }

        // Use play() followed by rate for more reliable resume
        if seamlessLoop {
            queuePlayer?.play()
            queuePlayer?.rate = currentRate
        } else {
            primaryPlayer?.play()
            primaryPlayer?.rate = currentRate
            if isCrossfading {
                secondaryPlayer?.play()
                secondaryPlayer?.rate = currentRate
            }
        }

        Self.logger.debug("Video playback resumed")
    }

    func updatePlaybackRate(_ rate: Double) {
        currentRate = Float(rate)

        if seamlessLoop {
            queuePlayer?.rate = currentRate
        } else {
            primaryPlayer?.rate = currentRate
            if isCrossfading {
                secondaryPlayer?.rate = currentRate
            }
        }
    }

    private func resumeAfterForegroundQuietWindow(attempt: Int = 0) {
        guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
            LifecycleDebugLogger.shared.checkpoint("Video.resume.deferred", ms: nil, [
                ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                ("attempt", attempt),
            ])
            guard attempt < 25 else {
                LifecycleDebugLogger.shared.checkpoint("Video.resume.deferred.gaveUp")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.resumeAfterForegroundQuietWindow(attempt: attempt + 1)
            }
            return
        }

        LifecycleDebugLogger.shared.checkpoint("Video.resume")
        resume()
    }

    /// Update the theme-tint parameters for the video composition handler.
    /// Amount/color changes apply to the next rendered frame without player
    /// disruption. Toggling `enabled` requires rebuilding the player because
    /// the AVVideoComposition is attached/detached (we avoid the per-frame
    /// Core Image cost when the tint is off).
    func updateThemeTint(
        enabled: Bool,
        amount: Double,
        themeColors: EffectThemeColors
    ) {
        let previous = tintState.snapshot()
        tintState.update(
            enabled: enabled,
            amount: amount,
            themeColors: themeColors
        )
        if previous.enabled != enabled {
            cleanupPlayers()
            setupVideo()
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        playerLayer?.frame = frameForAspectMode()
        primaryPlayerLayer?.frame = frameForAspectMode()
        secondaryPlayerLayer?.frame = frameForAspectMode()
    }

    /// Calculate frame based on aspect mode and alignment
    private func frameForAspectMode() -> CGRect {
        // For fill and stretch, just use bounds
        guard aspectMode == .fit else {
            return bounds
        }

        // For fit mode, we need to handle alignment
        // AVLayerVideoGravity.resizeAspect centers by default
        // We adjust the layer position for different alignments
        return bounds
    }

    // MARK: - Audio Track Management

    /// Disable audio tracks on a player item to prevent any audio processing.
    /// This provides defense in depth alongside the audio session configuration.
    private func disableAudioTracks(for playerItem: AVPlayerItem) {
        Task {
            guard let asset = playerItem.asset as? AVURLAsset else { return }
            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if !audioTracks.isEmpty {
                    await MainActor.run {
                        for track in playerItem.tracks where track.assetTrack?.mediaType == .audio {
                            track.isEnabled = false
                        }
                    }
                }
            } catch {
                // Video has no audio tracks - this is fine
            }
        }
    }

    // MARK: - Video Gravity

    private var videoGravity: AVLayerVideoGravity {
        switch aspectMode {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }

}
