#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog
import UIKit

/// Dedicated ios_system session for file-browser tool invocations (bat/rg/jq).
///
/// These tools set the session's stream fields via ios_setStreams from a
/// background thread. Sharing the shell tab's session raced its stream state
/// while a command was running in the same tab — so the file browser gets its
/// own session, and all invocations serialize on one queue (the tools aren't
/// re-entrant against shared stream setup). Never closed: one tiny session
/// struct for the app's lifetime.
nonisolated enum RFToolSession {
    static let sessionID = UUID()
    static var key: UnsafeRawPointer { IOSSystemSessionKey.key(for: sessionID) }
    static let queue = DispatchQueue(label: "rf.tools", qos: .userInitiated)
}

/// Preview controller for the rf file browser.
/// Manages text (via bat), image (via kitty), directory, and binary previews.
@MainActor
final class RFPreview {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-preview")

    /// Maximum file size for bat syntax highlighting (1 MB).
    /// Larger files get plain text only — bat's syntax parser (syntect) processes
    /// sequentially from the start even with --line-range, making large files slow.
    nonisolated static let maxBatFileSize: Int64 = 1_024 * 1_024

    /// Maximum file size for jq JSON pretty-printing (2 MB).
    /// jq must parse the entire file into memory. Larger JSON files get
    /// bat syntax highlighting instead (which can use --line-range).
    static let maxJqFileSize: Int64 = 2 * 1_024 * 1_024

    /// Load a syntax-highlighted text preview for a specific line range using bat.
    /// Uses --line-range to limit bat's processing to only the visible window.
    ///
    /// Cancellation: the `cancelFlag`'s byte pointer is passed directly to bat_main.
    /// bat's CancellableWriter checks it on every write() call and returns BrokenPipe
    /// when set, causing bat to exit cleanly within one line of output.
    /// No SIGPIPE, no pipe closing, no serial queue needed.
    nonisolated static func loadBatPreviewRange(
        path: String,
        width: Int,
        startLine: Int,
        endLine: Int
    ) async -> [[TUICell]] {
        // CancelFlag byte is shared with bat_main's CancellableWriter.
        // withTaskCancellationHandler bridges Swift Task.cancel() into the byte —
        // bat sees it on the next write() and returns BrokenPipe immediately.
        let cancelFlag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                RFToolSession.queue.async {
                    // Check before doing any work — skip stale invocations instantly
                    guard !cancelFlag.isCancelled else {
                    continuation.resume(returning: [])
                    return
                }

                var outPipe: [Int32] = [0, 0]
                var inPipe: [Int32] = [0, 0]
                guard pipe(&outPipe) == 0, pipe(&inPipe) == 0 else {
                    continuation.resume(returning: [])
                    return
                }
                let readFd = outPipe[0]
                let writeFd = outPipe[1]
                close(inPipe[1])

                guard let stdinFile = fdopen(inPipe[0], "r"),
                      let stdoutFile = fdopen(writeFd, "w") else {
                    close(outPipe[0]); close(outPipe[1])
                    close(inPipe[0])
                    continuation.resume(returning: [])
                    return
                }

                ios_switchSession(RFToolSession.key)
                ios_setStreams(stdinFile, stdoutFile, stdoutFile)

                var outputData = Data()
                let readerQueue = DispatchQueue(label: "rf.bat.reader")
                let readerDone = DispatchSemaphore(value: 0)

                readerQueue.async {
                    let bufSize = 16384
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { buf.deallocate() }
                    while true {
                        let n = read(readFd, buf, bufSize)
                        if n <= 0 { break }
                        outputData.append(buf, count: n)
                    }
                    close(readFd)
                    readerDone.signal()
                }

                var args = ["bat", "--color=always", "--style=numbers", "--paging=never",
                            "--terminal-width=\(width)"]
                let rangeStr = "\(max(1, startLine)):\(endLine)"
                args.append("--line-range=\(rangeStr)")
                args.append(path)

                let cArgs = args.map { strdup($0) }
                defer { cArgs.forEach { free($0) } }
                var argv: [UnsafePointer<CChar>?] = cArgs.map { $0.flatMap { UnsafePointer($0) } }

                // Pass the cancel flag pointer directly to bat_main.
                // bat's CancellableWriter checks this on every write() call.
                _ = bat_main_cancellable(Int32(args.count), &argv, cancelFlag.pointer)

                fflush(stdoutFile)
                fclose(stdoutFile)
                fclose(stdinFile)
                ios_setStreams(stdin, stdout, stderr)

                readerDone.wait()

                guard let text = String(data: outputData, encoding: .utf8), !text.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                continuation.resume(returning: RFAnsiParser.parse(text, maxWidth: width))
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    /// Pretty-print a JSON file using jq with colorized output.
    /// Returns parsed cells on success, or nil if jq fails (malformed JSON).
    ///
    /// Unlike bat, jq has no cancel flag and processes the whole file.
    /// File size should be capped by the caller (maxJqFileSize).
    nonisolated static func loadJqPreview(
        path: String,
        width: Int
    ) async -> [[TUICell]]? {
        await withCheckedContinuation { continuation in
            RFToolSession.queue.async {
                var outPipe: [Int32] = [0, 0]
                var inPipe: [Int32] = [0, 0]
                guard pipe(&outPipe) == 0, pipe(&inPipe) == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let readFd = outPipe[0]
                let writeFd = outPipe[1]
                close(inPipe[1])

                guard let stdinFile = fdopen(inPipe[0], "r"),
                      let stdoutFile = fdopen(writeFd, "w") else {
                    close(outPipe[0]); close(outPipe[1])
                    close(inPipe[0])
                    continuation.resume(returning: nil)
                    return
                }

                ios_switchSession(RFToolSession.key)
                ios_setStreams(stdinFile, stdoutFile, stdoutFile)

                var outputData = Data()
                let readerQueue = DispatchQueue(label: "rf.jq.reader")
                let readerDone = DispatchSemaphore(value: 0)

                readerQueue.async {
                    let bufSize = 16384
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { buf.deallocate() }
                    while true {
                        let n = read(readFd, buf, bufSize)
                        if n <= 0 { break }
                        outputData.append(buf, count: n)
                    }
                    close(readFd)
                    readerDone.signal()
                }

                // jq -C --indent 2 . <path>  — colorize + pretty-print
                let args = ["jq", "-C", "--indent", "2", ".", path]

                let cArgs = args.map { strdup($0) }
                defer { cArgs.forEach { free($0) } }
                // jq_main takes char* argv[] (mutable), not const char* const*
                var argv: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 }

                let result = jq_main(Int32(args.count), &argv)

                fflush(stdoutFile)
                fclose(stdoutFile)
                fclose(stdinFile)
                ios_setStreams(stdin, stdout, stderr)

                readerDone.wait()

                // jq returns non-zero for parse errors, malformed JSON, etc.
                guard result == 0,
                      let text = String(data: outputData, encoding: .utf8),
                      !text.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: RFAnsiParser.parse(text, maxWidth: width))
            }
        }
    }

    /// Read a file directly and parse all lines into cells.
    /// No subprocess, no bat — just file I/O and string processing.
    /// Capped at maxBytes to avoid memory issues on huge files.
    nonisolated static func loadFilePreview(
        path: String,
        width: Int
    ) -> (cells: [[TUICell]], totalLines: Int) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], 0) }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: RFPreviewCache.maxBytes)
        return loadPreviewFromData(data, width: width)
    }

    /// Parse raw file data into cells for preview display.
    /// Used by both local (loadFilePreview) and remote (SFTP) preview paths.
    nonisolated static func loadPreviewFromData(
        _ data: Data,
        width: Int
    ) -> (cells: [[TUICell]], totalLines: Int) {
        guard let text = String(data: data, encoding: .utf8) else { return ([], 0) }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [[TUICell]] = []
        result.reserveCapacity(lines.count)
        let style = TUIStyle.plain

        for line in lines {
            var cellLine: [TUICell] = []
            var col = 0
            for char in line {
                guard col < width else { break }
                if char == "\t" {
                    let spaces = 4 - (col % 4)
                    for _ in 0..<spaces {
                        guard col < width else { break }
                        cellLine.append(TUICell(character: " ", style: style))
                        col += 1
                    }
                } else if char == "\r" {
                    continue
                } else {
                    let w = RFWidth.width(of: char)
                    // Stop if this glyph (incl. its trailing half) won't fit.
                    guard col + w <= width else { break }
                    cellLine.append(TUICell(character: char, style: style))
                    if w == 2 {
                        cellLine.append(TUICell.continuation(style: style))
                    }
                    col += w
                }
            }
            result.append(cellLine)
        }
        return (result, lines.count)
    }

    /// Load an image, scale it to fit the preview pane preserving aspect ratio,
    /// and emit kitty graphics protocol escape sequences.
    nonisolated static func loadImagePreview(
        path: String,
        cols: Int,
        rows: Int
    ) -> String? {
        guard let image = UIImage(contentsOfFile: path) else { return nil }

        let cellW = 8
        let cellH = 16
        let panePixelW = cols * cellW
        let panePixelH = rows * cellH

        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return nil }

        let scaleX = Double(panePixelW) / imgW
        let scaleY = Double(panePixelH) / imgH
        let scale = min(scaleX, scaleY, 1.0)

        let scaledW = Int(imgW * scale)
        let scaledH = Int(imgH * scale)
        guard scaledW > 0, scaledH > 0 else { return nil }

        let displayCols = max(1, (scaledW + cellW - 1) / cellW)
        let displayRows = max(1, (scaledH + cellH - 1) / cellH)

        let scaledImage: UIImage
        if scale < 1.0 {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: scaledW, height: scaledH))
            scaledImage = renderer.image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: scaledW, height: scaledH))
            }
        } else {
            scaledImage = image
        }

        guard let pngData = scaledImage.pngData() else { return nil }

        var output = ""
        let base64Data = pngData.base64EncodedData()
        let chunkSize = 4096

        var firstChunkKeys = "f=100,a=T,q=2,i=31"
        firstChunkKeys += ",c=\(displayCols)"
        firstChunkKeys += ",r=\(displayRows)"

        let totalChunks = (base64Data.count + chunkSize - 1) / chunkSize
        guard totalChunks > 0 else { return nil }

        for i in 0..<totalChunks {
            let offset = i * chunkSize
            let end = min(offset + chunkSize, base64Data.count)
            let chunkString = String(decoding: base64Data[offset..<end], as: UTF8.self)

            let isLast = (i == totalChunks - 1)
            let moreFlag = isLast ? "0" : "1"

            if i == 0 {
                output += "\u{1b}_G\(firstChunkKeys),m=\(moreFlag);\(chunkString)\u{1b}\\"
            } else {
                output += "\u{1b}_Gm=\(moreFlag);\(chunkString)\u{1b}\\"
            }
        }

        return output
    }

    // MARK: - ios_system Command Capture

    /// Run a command via ios_system and capture its stdout.
    nonisolated private static func runCommandCapture(command: String) async -> String {
        await withCheckedContinuation { continuation in
            RFToolSession.queue.async {
                var stdoutPipe: [Int32] = [0, 0]
                var stdinPipe: [Int32] = [0, 0]
                guard pipe(&stdoutPipe) == 0, pipe(&stdinPipe) == 0 else {
                    continuation.resume(returning: "")
                    return
                }

                let readFd = stdoutPipe[0]
                let writeFd = stdoutPipe[1]

                guard let stdinFile = fdopen(stdinPipe[0], "r"),
                      let stdoutFile = fdopen(writeFd, "w") else {
                    close(stdoutPipe[0]); close(stdoutPipe[1])
                    close(stdinPipe[0]); close(stdinPipe[1])
                    continuation.resume(returning: "")
                    return
                }
                close(stdinPipe[1])

                ios_switchSession(RFToolSession.key)
                ios_setStreams(stdinFile, stdoutFile, stdoutFile)

                var options = ios_async_default_options()
                options.input = stdinFile
                options.output = stdoutFile
                options.error = stdoutFile
                options.session = UnsafeMutableRawPointer(mutating: RFToolSession.key)

                var outputData = Data()
                let readerQueue = DispatchQueue(label: "rf.preview.reader")
                let readerDone = DispatchSemaphore(value: 0)

                readerQueue.async {
                    let bufferSize = 16384
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }

                    while true {
                        let bytesRead = read(readFd, buffer, bufferSize)
                        if bytesRead <= 0 { break }
                        outputData.append(buffer, count: bytesRead)
                    }
                    close(readFd)
                    readerDone.signal()
                }

                let handle = ios_system_async(command, &options)

                if let handle {
                    _ = ios_command_wait(handle)
                    ios_command_release(handle)
                }

                ios_setStreams(stdin, stdout, stderr)
                fflush(stdoutFile)
                fclose(stdoutFile)
                fclose(stdinFile)

                readerDone.wait()

                let result = String(data: outputData, encoding: .utf8) ?? ""
                continuation.resume(returning: result)
            }
        }
    }
}

/// Cancellation flag shared between Swift and bat_main's CancellableWriter.
///
/// Allocates a single byte that Swift sets to 1 via withTaskCancellationHandler.
/// bat_main reads it via read_volatile on every write() call and exits cleanly
/// within one line of output — no SIGPIPE, no pipe closing, no state corruption.
nonisolated final class CancelFlag: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>

    var isCancelled: Bool {
        pointer.pointee != 0
    }

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    func cancel() {
        pointer.pointee = 1
    }

    deinit {
        pointer.deallocate()
    }
}

#endif
