#if !targetEnvironment(macCatalyst)

import Foundation
import UIKit

extension LocalShellSession {
    /// Handle an `imgcat` command — display an image inline using the Kitty graphics protocol
    func handleImgcatCommand(_ command: String) {
        let args = parseImgcatArguments(command)

        guard !args.filePatterns.isEmpty else {
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayImgcatHelp()
            return
        }

        // Expand all patterns into resolved file paths (cheap, needs session state)
        var resolvedFiles: [(display: String, path: String)] = []
        for fp in args.filePatterns {
            if fp.isLiteral {
                // Quoted/escaped token — treat as literal path, no glob expansion
                let resolved = resolvePath(fp.text, relativeTo: sessionCurrentDirectory)
                resolvedFiles.append((display: fp.text, path: resolved))
            } else {
                let expanded = expandGlob(fp.text, relativeTo: sessionCurrentDirectory)
                if expanded.isEmpty {
                    onOutput?("imgcat: \(fp.text): no matches found\r\n")
                } else {
                    for path in expanded {
                        resolvedFiles.append((display: fp.text, path: path))
                    }
                }
            }
        }

        guard !resolvedFiles.isEmpty else {
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            displayPrompt()
            return
        }

        let showFilenames = resolvedFiles.count > 1
        let termCols = Int(pty.windowSize.cols)
        let displayCols = args.cols ?? termCols
        let displayRows = args.rows

        // Capture thread-safe output sink and move heavy work off MainActor
        let sink = outputSink
        imgcatTask = Task.detached { [weak self] in
            var allSucceeded = true
            for (display, resolvedPath) in resolvedFiles {
                guard !Task.isCancelled else { return }
                let succeeded = Self.processImageFile(
                    display: display,
                    resolvedPath: resolvedPath,
                    showFilename: showFilenames,
                    cols: displayCols,
                    rows: displayRows,
                    output: sink.emitString
                )
                allSucceeded = allSucceeded && succeeded
            }
            guard !Task.isCancelled else { return }
            let succeeded = allSucceeded
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = succeeded
                self.scriptCommandExitCode = succeeded ? 0 : 1
                self.displayPrompt()
            }
        }
    }

    /// Process a single image file: load, encode, and emit via Kitty graphics protocol.
    /// All parameters are value types + a @Sendable closure, so this is safe to call from any thread.
    private nonisolated static func processImageFile(
        display: String,
        resolvedPath: String,
        showFilename: Bool,
        cols: Int?,
        rows: Int?,
        output: @Sendable (String) -> Void
    ) -> Bool {
        // Validate file exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            output("imgcat: \(display): No such file or directory\r\n")
            return false
        }

        // Load image (UIImage is thread-safe for loading/encoding)
        guard let image = UIImage(contentsOfFile: resolvedPath) else {
            let displayName = (resolvedPath as NSString).lastPathComponent
            output("imgcat: \(displayName): Not a valid image file\r\n")
            return false
        }

        // Convert to PNG data
        guard let pngData = image.pngData() else {
            let displayName = (resolvedPath as NSString).lastPathComponent
            output("imgcat: \(displayName): Failed to encode image\r\n")
            return false
        }

        // Show filename when displaying multiple images
        if showFilename {
            let displayName = (resolvedPath as NSString).lastPathComponent
            output("\r\n\u{1b}[1m\(displayName)\u{1b}[0m\r\n")
        }

        // Emit Kitty graphics protocol escape sequences
        emitKittyGraphics(pngData: pngData, cols: cols, rows: rows, output: output)
        output("\r\n")
        return true
    }

    // MARK: - Argument Parsing

    private struct FilePattern {
        let text: String
        let isLiteral: Bool  // true when token was quoted or escaped — skip glob expansion
    }

    private struct ImgcatArgs {
        var filePatterns: [FilePattern] = []
        var cols: Int?
        var rows: Int?
    }

    private func parseImgcatArguments(_ command: String) -> ImgcatArgs {
        var args = ImgcatArgs()
        let tokens = tokenize(command)

        // Skip "imgcat" command name
        guard tokens.count > 1 else { return args }

        var i = 1
        while i < tokens.count {
            let token = tokens[i]
            switch token.text {
            case "-w":
                i += 1
                if i < tokens.count, let value = Int(tokens[i].text), value > 0 {
                    args.cols = value
                }
            case "-r":
                i += 1
                if i < tokens.count, let value = Int(tokens[i].text), value > 0 {
                    args.rows = value
                }
            case "-h", "--help":
                return args  // Empty filePatterns means help will be shown
            default:
                args.filePatterns.append(FilePattern(text: token.text, isLiteral: token.wasQuoted))
            }
            i += 1
        }

        return args
    }

    /// Simple tokenizer that handles quoted arguments.
    /// Returns each token's text and whether it was quoted/escaped (meaning glob metacharacters are literal).
    private func tokenize(_ command: String) -> [(text: String, wasQuoted: Bool)] {
        var tokens: [(text: String, wasQuoted: Bool)] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var currentWasQuoted = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                escaped = true
                currentWasQuoted = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                currentWasQuoted = true
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                currentWasQuoted = true
                continue
            }

            if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append((text: current, wasQuoted: currentWasQuoted))
                    current = ""
                    currentWasQuoted = false
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append((text: current, wasQuoted: currentWasQuoted))
        }

        return tokens
    }

    // MARK: - Path Resolution & Glob Expansion

    /// Resolve a path relative to a directory, expanding tilde
    private func resolvePath(_ path: String, relativeTo dir: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return (dir as NSString).appendingPathComponent(path)
    }

    /// Expand a shell glob pattern into matching file paths using POSIX `glob()`
    private func expandGlob(_ pattern: String, relativeTo dir: String) -> [String] {
        let resolvedPattern = resolvePath(pattern, relativeTo: dir)

        // If no glob characters, return as-is for better error messages
        let hasGlob = pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
        guard hasGlob else {
            return [resolvedPattern]
        }

        var gt = Darwin.glob_t()
        defer { globfree(&gt) }

        let result = Darwin.glob(resolvedPattern, GLOB_TILDE | GLOB_BRACE, nil, &gt)
        guard result == 0 else { return [] }

        var paths: [String] = []
        for i in 0..<Int(gt.gl_matchc) {
            if let cStr = gt.gl_pathv[i] {
                paths.append(String(cString: cStr))
            }
        }
        return paths.sorted()
    }

    // MARK: - Kitty Graphics Protocol

    /// Emit a PNG image using the Kitty graphics protocol.
    /// Static so it can be called safely from a detached task without capturing `self`.
    /// Protocol format: ESC_G<key=value>;<base64 payload>ESC\
    nonisolated static func emitKittyGraphics(pngData: Data, cols: Int?, rows: Int?, output: (String) -> Void) {
        // Use base64EncodedData() to get Data (O(1) slicing) instead of String (O(n) indexing)
        let base64Data = pngData.base64EncodedData()
        let chunkSize = 4096

        // Build key-value header for the first chunk
        // f=100: PNG format, a=T: transmit and display, q=2: suppress responses
        var firstChunkKeys = "f=100,a=T,q=2"
        if let c = cols {
            firstChunkKeys += ",c=\(c)"
        }
        if let r = rows {
            firstChunkKeys += ",r=\(r)"
        }

        let totalChunks = (base64Data.count + chunkSize - 1) / chunkSize
        guard totalChunks > 0 else { return }

        for i in 0..<totalChunks {
            let offset = i * chunkSize
            let end = min(offset + chunkSize, base64Data.count)
            let chunkString = String(decoding: base64Data[offset..<end], as: UTF8.self)

            let isLast = (i == totalChunks - 1)
            let moreFlag = isLast ? "0" : "1"

            if i == 0 {
                output("\u{1b}_G\(firstChunkKeys),m=\(moreFlag);\(chunkString)\u{1b}\\")
            } else {
                output("\u{1b}_Gm=\(moreFlag);\(chunkString)\u{1b}\\")
            }
        }
    }

    // MARK: - Help

    func displayImgcatHelp() {
        let helpText = """
        usage: imgcat [-w cols] [-r rows] <file> [file ...]

        Display images inline in the terminal using the Kitty graphics protocol.
        Supports shell wildcards/globs to match multiple files.

        Options:
          -w cols     Display width in columns (default: terminal width)
          -r rows     Display height in rows
          -h, --help  Show this help message

        Supported formats: PNG, JPEG, HEIC, GIF, BMP, TIFF, WebP

        Examples:
          imgcat photo.png              Display a single image
          imgcat *.png                  Display all PNG files in current directory
          imgcat photo?.jpg             Match photo1.jpg, photo2.jpg, etc.
          imgcat images/[abc]*.png      Match images starting with a, b, or c
          imgcat -w 40 *.jpg            Display all JPEGs at 40 columns wide
          imgcat file1.png file2.jpg    Display multiple explicit files
          imgcat ~/Documents/*.png      Tilde expansion with glob

        """
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastCommandSucceeded = true
            self.scriptCommandExitCode = 0
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
