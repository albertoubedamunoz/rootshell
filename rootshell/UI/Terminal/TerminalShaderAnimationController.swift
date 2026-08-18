//
//  TerminalShaderAnimationController.swift
//  rootshell
//
//  Owns per-terminal shader display-link animation on behalf of TerminalView.
//

import UIKit
import GhosttyKit
import os

@MainActor
protocol TerminalShaderAnimationHost: AnyObject {
    var shaderSurface: ghostty_surface_t? { get }
    var shaderGhosttyApp: Ghostty.App? { get }
    var shaderIsLogicallyFocused: Bool { get }
    var shaderKeyboardDismissedSuppressed: Bool { get }

    func shaderSyncSelectionAfterAppTick()
}

@MainActor
final class TerminalShaderAnimationController {
    private weak var host: TerminalShaderAnimationHost?

    /// CADisplayLink for vsync-synchronized shader animation.
    private var displayLink: CADisplayLink?

    /// Observer for shader activation changes.
    private var activationObserver: NSObjectProtocol?

    /// Observer for power-tier changes (battery saver throttling).
    private var powerObserver: NSObjectProtocol?

    /// Timestamp of last terminal output for idle detection.
    private var lastTerminalActivityTime: CFTimeInterval = 0

    /// Timer to pause shader animation after cursor animation completes.
    private var pauseTimer: Timer?

    /// Whether shader animation is currently paused due to idle terminal.
    private var isPaused = false

    /// Whether shader animation is gracefully stopping.
    private var isGracefullyStopping = false

    init(host: TerminalShaderAnimationHost) {
        self.host = host
    }

    deinit {
        displayLink?.invalidate()
        pauseTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
        }
    }

    func setupActivationObserver() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: .shaderActivationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isActive = notification.userInfo?["isActive"] as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !Ghostty.isAppBackgroundedAtomic,
                      !Ghostty.isSecureDrawProhibitedAtomic else { return }
                Ghostty.logger.debug("Shader activation changed: \(isActive)")
                if isActive && self.host?.shaderIsLogicallyFocused == true {
                    self.start()
                } else if !isActive {
                    self.stop()
                }
            }
        }

        if ShaderManager.shared.hasAnyShadersActive,
           host?.shaderIsLogicallyFocused == true {
            start()
        }

        // Retarget a live link when the power tier changes (battery saver
        // drops shader animation to 15fps; back to 30fps on restore).
        powerObserver = NotificationCenter.default.addObserver(
            forName: .powerTierChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let displayLink = self.displayLink else { return }
                displayLink.preferredFrameRateRange = PowerManager.shared.shaderFrameRange
            }
        }
    }

    func tearDown() {
        stop()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func update(focused: Bool) {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else {
            stop()
            return
        }

        let shaderManager = ShaderManager.shared
        let hasShaders = shaderManager.hasAnyShadersActive
        let animationMode = shaderManager.animationMode

        let shouldAnimate: Bool
        switch animationMode {
        case .disabled:
            shouldAnimate = false
        case .whenFocused:
            shouldAnimate = focused && hasShaders
        case .always:
            shouldAnimate = hasShaders
        }

        if shouldAnimate {
            isGracefullyStopping = false
            start()
        } else {
            stop(graceful: true)
        }
    }

    func stop(graceful: Bool = false) {
        guard let displayLink else {
            clearStopState()
            return
        }

        if graceful && ShaderManager.shared.isCursorOnlyShader {
            let timeSinceActivity = CACurrentMediaTime() - lastTerminalActivityTime
            let maxDuration = ShaderManager.shared.maxCursorAnimationDuration

            if timeSinceActivity < maxDuration {
                let remainingTime = maxDuration - timeSinceActivity + 0.05
                isGracefullyStopping = true

                DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isGracefullyStopping else { return }
                        self.stop(graceful: false)
                    }
                }
                return
            }
        }

        clearStopState()
        displayLink.invalidate()
        self.displayLink = nil
    }

    func notifyTerminalActivity() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }

        lastTerminalActivityTime = CACurrentMediaTime()

        if isPaused {
            resume()
        } else if displayLink != nil {
            schedulePauseTimer()
        }

        #if !targetEnvironment(macCatalyst)
        host?.shaderSyncSelectionAfterAppTick()
        #endif
    }

    private func start() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }
        isGracefullyStopping = false
        guard host?.shaderKeyboardDismissedSuppressed != true else { return }
        guard displayLink == nil else { return }
        guard host?.shaderSurface != nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(animationTick))

        link.preferredFrameRateRange = PowerManager.shared.shaderFrameRange

        link.add(to: .main, forMode: .common)
        displayLink = link
        isPaused = false
        lastTerminalActivityTime = CACurrentMediaTime()
        schedulePauseTimer()
    }

    private func pause() {
        guard !isPaused else { return }
        guard let displayLink else { return }

        displayLink.isPaused = true
        isPaused = true
    }

    private func resume() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard isPaused else { return }

        displayLink?.isPaused = false
        isPaused = false
        lastTerminalActivityTime = CACurrentMediaTime()
        schedulePauseTimer()
    }

    private func schedulePauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil

        guard ShaderManager.shared.isCursorOnlyShader else { return }

        let pauseDelay = ShaderManager.shared.maxCursorAnimationDuration + 0.3
        pauseTimer = Timer.scheduledTimer(
            withTimeInterval: pauseDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }

    private func clearStopState() {
        isGracefullyStopping = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        isPaused = false
    }

    @objc private func animationTick(_ link: CADisplayLink) {
        // The secure-draw latch matters here: this tick keeps firing through
        // the inactive lock edge and ends in an un-occluded surface draw.
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else {
            stop()
            return
        }

        guard let surface = host?.shaderSurface else {
            stop()
            return
        }

        host?.shaderGhosttyApp?.appTick()

        #if !targetEnvironment(macCatalyst)
        host?.shaderSyncSelectionAfterAppTick()
        #endif

        ghostty_surface_draw(surface)
    }
}
