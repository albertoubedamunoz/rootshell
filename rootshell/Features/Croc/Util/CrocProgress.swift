#if !targetEnvironment(macCatalyst)

import Foundation

/// Terminal progress bar for croc transfers using TerminalStyle.
/// Matches Go croc metrics: bytes transferred/total, speed, ETA, file count.
nonisolated final class CrocProgress: @unchecked Sendable {

    private let output: @Sendable (String) -> Void
    private let totalBytes: Int64
    private let filename: String
    private let fileIndex: Int
    private let fileCount: Int
    private var bytesTransferred: Int64 = 0
    private let startTime: Date
    private var lastUpdateTime: Date
    private let minUpdateInterval: TimeInterval = 0.1

    init(
        filename: String,
        totalBytes: Int64,
        fileIndex: Int,
        fileCount: Int,
        output: @escaping @Sendable (String) -> Void
    ) {
        // Pad filename to align multi-file transfers (matches Go's longestFilename)
        self.filename = String(filename.prefix(24))
        self.totalBytes = totalBytes
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.output = output
        self.startTime = Date()
        self.lastUpdateTime = Date.distantPast
    }

    /// Update progress with additional bytes.
    func update(bytesAdded: Int64) {
        bytesTransferred += bytesAdded

        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= minUpdateInterval else { return }
        lastUpdateTime = now

        render()
    }

    /// Render the final progress (100%) and newline with file count.
    func finish() {
        bytesTransferred = totalBytes
        render()
        // File count suffix after the bar (matches Go's fmtPrintUpdate)
        if fileCount > 1 {
            output(" \(fileIndex + 1)/\(fileCount)\r\n")
        } else {
            output("\r\n")
        }
    }

    private func render() {
        let percent: Double
        if totalBytes > 0 {
            percent = Swift.min(Double(bytesTransferred) / Double(totalBytes), 1.0)
        } else {
            percent = 1.0
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let speed = elapsed > 0 ? Double(bytesTransferred) / elapsed : 0
        let eta: String
        if speed > 0 && percent < 1.0 {
            let remaining = Double(totalBytes - bytesTransferred) / speed
            eta = formatDuration(remaining)
        } else {
            eta = "0s"
        }

        // Bar: colored blocks matching git's style
        let barWidth = 20
        let filledCount = Int(percent * Double(barWidth))
        let emptyCount = barWidth - filledCount
        let filledStr = String(repeating: "█", count: filledCount)
        let emptyStr = String(repeating: "░", count: emptyCount)
        let bar = TerminalStyle.fg(TerminalStyle.success, filledStr)
                + TerminalStyle.fg(TerminalStyle.dim, emptyStr)

        let percentStr = String(format: "%3.0f%%", percent * 100)
        let transferred = CrocUtils.byteCountDecimal(bytesTransferred)
        let total = CrocUtils.byteCountDecimal(totalBytes)
        let speedStr = CrocUtils.byteCountDecimal(Int64(speed)) + "/s"

        // DECAWM off → render → DECAWM on: prevents long lines from wrapping
        let label = TerminalStyle.fg(TerminalStyle.info, filename)
        let stats = TerminalStyle.fg(TerminalStyle.dim,
            "\(transferred)/\(total)  \(speedStr)  ETA: \(eta)")
        let line = "\u{1B}[?7l\r\(TerminalStyle.clearLine)\(label) \(bar) \(percentStr) \(stats)\u{1B}[?7h"
        output(line)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            return String(format: "%.0fm%.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
        } else {
            return String(format: "%.0fh%.0fm", seconds / 3600, (seconds / 60).truncatingRemainder(dividingBy: 60))
        }
    }
}

#endif
