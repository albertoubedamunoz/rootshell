import Foundation

/// Animates ASCII art failure scenes with error messages and quips.
/// Displays a whimsical animation for 2-3 seconds before showing the actual error.
@MainActor
final class FailureAnimator {

    // MARK: - Types

    /// Completion handler called when animation finishes
    typealias CompletionHandler = () -> Void

    // MARK: - ANSI Escape Sequences

    private enum ANSI {
        static let reset = "\u{1B}[0m"
        static let bold = "\u{1B}[1m"
        static let dim = "\u{1B}[2m"

        // Cursor control
        static let cursorHome = "\u{1B}[H"
        static let hideCursor = "\u{1B}[?25l"
        static let showCursor = "\u{1B}[?25h"

        // Erase operations
        static let clearToEndOfScreen = "\u{1B}[J"
        static let clearToEndOfLine = "\u{1B}[K"

        // Synchronized output (prevents flicker)
        static let syncOutputStart = "\u{1B}[?2026h"
        static let syncOutputEnd = "\u{1B}[?2026l"

        /// True color (24-bit) foreground
        static func fg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            return "\u{1B}[38;2;\(r);\(g);\(b)m"
        }

        /// Cursor to specific position (1-indexed)
        static func cursorTo(row: Int, col: Int) -> String {
            return "\u{1B}[\(row);\(col)H"
        }
    }

    // MARK: - Properties

    private var timer: Timer?
    private var currentFrameIndex: Int = 0
    private var currentAnimation: FailureAnimation?
    private var onFrame: ((String) -> Void)?
    private var onComplete: CompletionHandler?

    /// Theme colors (reuse SpinnerAnimator's ThemeColors)
    private var themeColors: SpinnerAnimator.ThemeColors = .default

    /// Terminal width for centering
    private var terminalWidth: Int = 80

    /// Current quip being displayed
    private var currentQuip: String = ""

    /// Whether currently animating
    var isAnimating: Bool { timer != nil }

    // MARK: - Public API

    /// Play failure animation for the given error
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - terminalWidth: Current terminal width for centering
    ///   - onFrame: Callback for each animation frame output
    ///   - onComplete: Called when animation finishes
    func play(
        for error: Error,
        terminalWidth: Int = 80,
        onFrame: @escaping (String) -> Void,
        onComplete: @escaping CompletionHandler
    ) {
        stop()

        // Refresh theme colors
        themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()

        // Select animation and quip based on error
        let category = FailureAnimationRegistry.categorize(error)
        let animation = FailureAnimationRegistry.animation(for: category)
        let quipCategory = FailureQuips.category(for: category)

        self.currentAnimation = animation
        self.terminalWidth = max(40, terminalWidth)
        self.currentQuip = FailureQuips.random(for: quipCategory)
        self.onFrame = onFrame
        self.onComplete = onComplete
        self.currentFrameIndex = 0

        // Hide cursor during animation
        onFrame(ANSI.hideCursor)

        // Emit first frame immediately
        emitFrame()

        // Start animation timer
        timer = Timer.scheduledTimer(withTimeInterval: animation.frameDelay, repeats: true) { [weak self] _ in
            let animator = self
            Task { @MainActor in
                animator?.advanceFrame()
            }
        }
    }

    /// Stop animation immediately without calling completion
    func stop() {
        timer?.invalidate()
        timer = nil
        currentAnimation = nil
        onFrame = nil
        onComplete = nil
        currentFrameIndex = 0
        currentQuip = ""
    }

    /// Get cleanup sequence for clearing animation area
    func getCleanupSequence() -> String {
        ANSI.showCursor +
        ANSI.syncOutputStart +
        ANSI.cursorHome +
        ANSI.clearToEndOfScreen +
        ANSI.syncOutputEnd
    }

    // MARK: - Private Methods

    private func advanceFrame() {
        guard let animation = currentAnimation else { return }

        currentFrameIndex += 1

        if currentFrameIndex >= animation.frames.count {
            // Animation complete - hold final frame then finish
            timer?.invalidate()
            timer = nil

            // Schedule completion after hold time
            Timer.scheduledTimer(withTimeInterval: animation.finalHoldTime, repeats: false) { [weak self] _ in
                let animator = self
                Task { @MainActor in
                    animator?.finishAnimation()
                }
            }
            return
        }

        emitFrame()
    }

    private func emitFrame() {
        guard let animation = currentAnimation,
              currentFrameIndex < animation.frames.count else { return }

        let frame = animation.frames[currentFrameIndex]

        // Use error color (red) from theme
        let rgb = themeColors.colorFor(style: .error)
        let dimRGB = themeColors.dimmedForeground

        let artColor = ANSI.fg(rgb.0, rgb.1, rgb.2)
        let dimColor = ANSI.fg(dimRGB.0, dimRGB.1, dimRGB.2)

        // Build output with synchronized updates
        var output = ANSI.syncOutputStart
        output += ANSI.cursorHome
        output += ANSI.clearToEndOfScreen

        // Add a blank line at top for spacing
        output += "\r\n"

        // Render ASCII art centered
        for line in frame.lines {
            let padding = max(0, (terminalWidth - line.count) / 2)
            output += String(repeating: " ", count: padding)
            output += artColor + line + ANSI.reset + "\r\n"
        }

        // Add empty line then quip (dimmed, centered)
        output += "\r\n"
        let quipPadding = max(0, (terminalWidth - currentQuip.count) / 2)
        output += String(repeating: " ", count: quipPadding)
        output += dimColor + ANSI.dim + currentQuip + ANSI.reset

        output += ANSI.syncOutputEnd

        onFrame?(output)
    }

    private func finishAnimation() {
        // Restore cursor before completing
        onFrame?(ANSI.showCursor)

        let completion = onComplete
        onComplete = nil
        onFrame = nil
        currentAnimation = nil

        completion?()
    }

    deinit {
        timer?.invalidate()
    }
}
