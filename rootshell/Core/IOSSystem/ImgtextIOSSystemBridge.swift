#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import OSLog
import UIKit
import Vision

// MARK: - ios_system entry point

/// Entry point for `imgtext` when invoked via ios_system.
/// Extracts text from images using Apple Vision framework OCR.
///
/// Runs directly on the ios_system background thread so that piping and
/// redirection work natively via `thread_stdout`. Ctrl-C cancellation uses
/// a global atomic flag (`imgtextCancelFlag`) that `LocalShellSession.interrupt()`
/// sets — checked between each image and after each OCR call.
@_cdecl("imgtext_main")
func imgtext_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return imgtextEntry(argc: argc, argv: argv)
}

// MARK: - Cancellation

/// Global cancel flag for cooperative Ctrl-C support.
/// Set to `true` by `LocalShellSession.interrupt()`, checked between images.
/// Reset to `false` at the start of each invocation.
nonisolated(unsafe) var imgtextCancelFlag = false

// MARK: - Implementation

private let logger = Logger(subsystem: "com.kk2.rootshell", category: "imgtext-bridge")

private func outputStreamForCurrentThread() -> UnsafeMutablePointer<FILE>? {
    if let stream = ios_get_thread_stdout() {
        return stream
    }
    if let stream = ios_get_thread_stderr() {
        return stream
    }
    return Darwin.stdout
}

private func writeToOutput(_ text: String) {
    guard let stream = outputStreamForCurrentThread() else {
        logger.error("No output stream available for imgtext ios_system bridge")
        return
    }
    fputs(text, stream)
    fflush(stream)
}

private func imgtextEntry(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    imgtextCancelFlag = false

    let args = extractImgtextArgs(argc: argc, argv: argv)

    if args.isEmpty {
        writeToOutput(imgtextHelpText)
        return 1
    }

    let argSet = Set(args.map { $0.lowercased() })
    if argSet.contains("-h") || argSet.contains("--help") {
        writeToOutput(imgtextHelpText)
        return 0
    }

    // Collect all file paths, expanding globs for any arg with metacharacters
    var filePaths: [String] = []
    for arg in args {
        if arg.hasPrefix("-") { continue }
        if arg.contains("*") || arg.contains("?") || arg.contains("[") {
            let expanded = expandImgtextGlob(arg)
            if expanded.isEmpty {
                writeToOutput("imgtext: \(arg): no matches found\n")
            } else {
                filePaths.append(contentsOf: expanded)
            }
        } else {
            filePaths.append(arg)
        }
    }

    guard !filePaths.isEmpty else {
        writeToOutput("imgtext: no files to process\n")
        return 1
    }

    let showFilenames = filePaths.count > 1
    var anyFailed = false

    for path in filePaths {
        if imgtextCancelFlag { break }

        let success = processImageForOCR(path: path, showFilename: showFilenames)
        if !success && !imgtextCancelFlag {
            anyFailed = true
        }
    }

    return imgtextCancelFlag ? 130 : (anyFailed ? 1 : 0)
}

// MARK: - OCR Processing

/// Process a single image file with Vision OCR.
/// Runs on the ios_system background thread — no MainActor involvement.
private func processImageForOCR(path: String, showFilename: Bool) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else {
        writeToOutput("imgtext: \(path): No such file or directory\n")
        return false
    }

    guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
        let name = (path as NSString).lastPathComponent
        writeToOutput("imgtext: \(name): Not a valid image file\n")
        return false
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    do {
        try handler.perform([request])
    } catch {
        if imgtextCancelFlag { return false }
        let name = (path as NSString).lastPathComponent
        writeToOutput("imgtext: \(name): OCR failed: \(error.localizedDescription)\n")
        return false
    }

    if imgtextCancelFlag { return false }

    guard let observations = request.results, !observations.isEmpty else {
        if showFilename {
            let name = (path as NSString).lastPathComponent
            writeToOutput("imgtext: \(name): no text found\n")
        }
        return true
    }

    if showFilename {
        let name = (path as NSString).lastPathComponent
        writeToOutput("==> \(name) <==\n")
    }

    for observation in observations {
        if imgtextCancelFlag { return false }
        if let candidate = observation.topCandidates(1).first {
            writeToOutput(candidate.string + "\n")
        }
    }

    return true
}

// MARK: - Glob Expansion

private func expandImgtextGlob(_ pattern: String) -> [String] {
    var gt = Darwin.glob_t()
    defer { globfree(&gt) }

    let result = Darwin.glob(pattern, GLOB_TILDE | GLOB_BRACE, nil, &gt)
    guard result == 0 else { return [] }

    var paths: [String] = []
    for i in 0..<Int(gt.gl_matchc) {
        if let cStr = gt.gl_pathv[i] {
            paths.append(String(cString: cStr))
        }
    }
    return paths.sorted()
}

// MARK: - Helpers

private func extractImgtextArgs(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    let safeArgc = max(0, Int(argc))
    guard safeArgc > 1, let argv else { return [] }

    var args: [String] = []
    args.reserveCapacity(safeArgc - 1)

    for i in 1..<safeArgc {
        if let arg = argv[i], let decoded = String(validatingUTF8: arg) {
            args.append(decoded)
        }
    }

    return args
}

private let imgtextHelpText = """
usage: imgtext [-h] <file> [file ...]

Extract text from images using OCR (Apple Vision framework).
Supports shell wildcards/globs to match multiple files.

Output is plain text, one recognized line per output line,
suitable for piping and redirection.

When processing multiple files, each file's output is preceded
by a header (==> filename <==), similar to head/tail.

Options:
  -h, --help  Show this help message

Supported formats: PNG, JPEG, HEIC, GIF, BMP, TIFF, WebP

Examples:
  imgtext photo.png               Extract text from a single image
  imgtext *.png                   Extract text from all PNGs
  imgtext screenshot.png | grep "error"
                                  Search for text in an image
  imgtext *.jpg > extracted.txt   Save extracted text to a file
  imgtext doc1.png doc2.png       Process multiple files

"""

#endif // !targetEnvironment(macCatalyst)
