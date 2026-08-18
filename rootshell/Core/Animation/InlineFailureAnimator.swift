import Foundation

/// Animates ASCII art failure scenes with error messages and quips using in-place rendering.
/// Uses save/restore cursor position to preserve terminal history above the animation.
/// Suitable for use within local shell sessions where full-screen clearing is not desired.
@MainActor
final class InlineFailureAnimator {

    // MARK: - Types

    /// Completion handler called when animation finishes
    typealias CompletionHandler = () -> Void

    // MARK: - ANSI Escape Sequences

    private enum ANSI {
        static let reset = "\u{1B}[0m"
        static let bold = "\u{1B}[1m"
        static let dim = "\u{1B}[2m"

        // Cursor visibility
        static let hideCursor = "\u{1B}[?25l"
        static let showCursor = "\u{1B}[?25h"

        // Erase operations
        static let clearToEndOfScreen = "\u{1B}[J"

        // Synchronized output (prevents flicker)
        static let syncOutputStart = "\u{1B}[?2026h"
        static let syncOutputEnd = "\u{1B}[?2026l"

        // Auto-wrap control (DECAWM) - prevents line wrapping at right margin
        static let disableAutoWrap = "\u{1B}[?7l"
        static let enableAutoWrap = "\u{1B}[?7h"

        /// Move cursor up N lines (relative positioning)
        static func cursorUp(_ n: Int) -> String {
            n > 0 ? "\u{1B}[\(n)A" : ""
        }

        /// True color (24-bit) foreground
        static func fg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            return "\u{1B}[38;2;\(r);\(g);\(b)m"
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

    /// Whether the first frame has been emitted
    private var isFirstFrame: Bool = true

    /// Number of lines in the last emitted frame (for cursor-up positioning)
    private var lastLineCount: Int = 0

    /// Whether currently animating
    var isAnimating: Bool { timer != nil }

    // MARK: - Public API

    /// Returns the ANSI sequence needed to clear all animation content.
    func getCleanupSequence() -> String {
        guard lastLineCount > 0 else { return "" }

        // Cursor is at end of last line. Move up (lineCount-1) to reach first line,
        // then clear everything from there down.
        var sequence = ANSI.showCursor + ANSI.syncOutputStart
        if lastLineCount > 1 {
            sequence += ANSI.cursorUp(lastLineCount - 1)
        }
        sequence += "\r"
        sequence += ANSI.clearToEndOfScreen
        sequence += ANSI.syncOutputEnd
        return sequence
    }

    /// Play failure animation for the given error
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
        self.isFirstFrame = true
        self.lastLineCount = 0

        // Hide cursor during animation
        onFrame(ANSI.hideCursor)

        // Emit first frame immediately
        emitFrame()

        // Start animation timer
        timer = Timer.scheduledTimer(withTimeInterval: animation.frameDelay, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.advanceFrame()
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
        isFirstFrame = true
        lastLineCount = 0
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
                guard let self = self else { return }
                Task { @MainActor [weak self] in
                    self?.finishAnimation()
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

        // Build content
        var lines: [String] = []

        // Add a blank line at top for spacing
        lines.append("")

        // Render ASCII art centered
        for line in frame.lines {
            let padding = max(0, (terminalWidth - line.count) / 2)
            let paddedLine = ANSI.disableAutoWrap + String(repeating: " ", count: padding) + artColor + line + ANSI.reset + ANSI.enableAutoWrap
            lines.append(paddedLine)
        }

        // Add empty line then quip (dimmed, centered)
        lines.append("")
        let quipPadding = max(0, (terminalWidth - currentQuip.count) / 2)
        let quipLine = ANSI.disableAutoWrap + String(repeating: " ", count: quipPadding) + dimColor + ANSI.dim + currentQuip + ANSI.reset + ANSI.enableAutoWrap
        lines.append(quipLine)

        let content = lines.joined(separator: "\r\n")
        let lineCount = lines.count

        var output = ANSI.syncOutputStart

        if isFirstFrame {
            // First frame: pre-allocate space by outputting newlines, then move back up
            // This forces any necessary scrolling to happen before we render content
            output += String(repeating: "\n", count: lineCount)
            output += ANSI.cursorUp(lineCount)
            output += "\r"
            output += content
            isFirstFrame = false
        } else {
            // Subsequent frames: cursor is at end of last line of previous frame.
            // Move up (lastLineCount-1) lines to reach the first line, clear, output new content.
            if lastLineCount > 1 {
                output += ANSI.cursorUp(lastLineCount - 1)
            }
            output += "\r"
            output += ANSI.clearToEndOfScreen
            output += content
        }

        output += ANSI.syncOutputEnd

        lastLineCount = lineCount
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
