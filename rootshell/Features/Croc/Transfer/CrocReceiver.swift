#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Receiver-side transfer logic.
/// Port of Go's `Client.Receive()`, `Client.receiveData()`, etc.
nonisolated enum CrocReceiver {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocReceiver")

    /// Calculate missing chunks for resume support.
    /// Matches Go's `utils.MissingChunks()`.
    /// Returns chunk ranges: [chunkSize, startPos1, count1, startPos2, count2, ...]
    static func missingChunks(at path: String, fileSize: Int64, chunkSize: Int) -> [Int64] {
        // Match Go: return empty when file doesn't exist or size differs.
        // Empty ranges → empty chunkMap on sender → sender sends all chunks.
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return []
        }
        defer { handle.closeFile() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let actualSize = (attrs?[.size] as? Int64) ?? 0
        guard actualSize == fileSize else {
            return []
        }

        var ranges: [Int64] = [Int64(chunkSize)]
        var pos: Int64 = 0
        var consecutiveEmpty: Int64 = 0
        var rangeStart: Int64 = -1

        while pos < fileSize {
            let readSize = min(Int(Int64(chunkSize)), Int(fileSize - pos))
            let data = handle.readData(ofLength: readSize)

            let isEmpty = data.allSatisfy { $0 == 0 }

            if isEmpty {
                if rangeStart < 0 {
                    rangeStart = pos
                    consecutiveEmpty = 0
                }
                consecutiveEmpty += 1
            } else {
                if rangeStart >= 0 {
                    ranges.append(rangeStart)
                    ranges.append(consecutiveEmpty)
                    rangeStart = -1
                }
            }

            pos += Int64(readSize)
        }

        if rangeStart >= 0 {
            ranges.append(rangeStart)
            ranges.append(consecutiveEmpty)
        }

        return ranges
    }

    /// Convert chunk ranges to individual chunk positions.
    /// Matches Go's `utils.ChunkRangesToChunks()`.
    static func chunkRangesToChunks(_ ranges: [Int64]) -> Set<UInt64> {
        guard ranges.count >= 3 else { return [] }

        let chunkSize = ranges[0]
        var chunks = Set<UInt64>()

        var i = 1
        while i + 1 < ranges.count {
            let start = ranges[i]
            let count = ranges[i + 1]
            for j in 0..<count {
                chunks.insert(UInt64(start + j * chunkSize))
            }
            i += 2
        }

        return chunks
    }

    /// Validate file info for security.
    /// Matches Go's filepath.Clean + .ssh check + ValidFileName (IsGraphic, IsAbs, IsLocal).
    static func validateFileInfo(_ files: [CrocFileInfo]) throws {
        for file in files {
            // Go cleans FolderRemote before validation (croc.go:1330)
            let cleanedFolder = cleanPath(file.folderRemote)
            let fullPath = cleanedFolder.isEmpty ? file.name : cleanedFolder + "/" + file.name

            // Check for .ssh directory (Go: croc.go:1332)
            if fullPath.contains(".ssh") {
                throw CrocError.pathTraversalDetected(fullPath)
            }

            // Check for non-graphic unicode characters (Go: utils.go:768 — unicode.IsGraphic)
            for scalar in fullPath.unicodeScalars {
                if !scalar.properties.isEmoji && !isGraphic(scalar) {
                    throw CrocError.invalidFilename(file.name)
                }
            }

            // Check for absolute path (Go: utils.go:784 — filepath.IsAbs)
            if fullPath.hasPrefix("/") {
                throw CrocError.pathTraversalDetected(fullPath)
            }

            // Check filepath.IsLocal equivalent (Go: utils.go:788)
            // A path is "local" if it doesn't escape the base directory.
            // Reject if any component is exactly ".." and the resolved path escapes root.
            if !isLocalPath(fullPath) {
                throw CrocError.pathTraversalDetected(fullPath)
            }
        }
    }

    /// Equivalent of Go's filepath.Clean — normalize path separators and resolve . and ..
    private static func cleanPath(_ path: String) -> String {
        guard !path.isEmpty else { return "." }
        return (path as NSString).standardizingPath
    }

    /// Equivalent of Go's filepath.IsLocal — path must not escape the current directory.
    /// Allows "hi..txt" and "rel/..txt" (.. not a standalone component).
    /// Rejects "..", "a/../../../b", etc.
    private static func isLocalPath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        let cleaned = cleanPath(path)
        // After cleaning, check if any component is ".." that would escape
        if cleaned == ".." { return false }
        if cleaned.hasPrefix("../") || cleaned.hasPrefix("..\\") { return false }
        if cleaned.contains("/../") || cleaned.contains("\\..\\") { return false }
        if cleaned.hasSuffix("/..") || cleaned.hasSuffix("\\..") { return false }
        // Absolute paths are not local
        if cleaned.hasPrefix("/") { return false }
        return true
    }

    /// Equivalent of Go's unicode.IsGraphic — checks if a scalar is graphic (printable).
    private static func isGraphic(_ scalar: Unicode.Scalar) -> Bool {
        // Control characters are not graphic
        if scalar.value < 32 { return false }
        // DEL is not graphic
        if scalar.value == 0x7F { return false }
        // C1 control characters
        if scalar.value >= 0x80 && scalar.value <= 0x9F { return false }
        // Unicode category check: graphic = Letter | Mark | Number | Punctuation | Symbol | Space
        // Non-graphic includes format chars, surrogates, private use, unassigned
        // For safety, reject characters in Unicode general categories Cf (format), Cc (control)
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }

    /// Initialize the destination file for receiving.
    static func prepareFile(at path: String, size: Int64, mode: UInt32) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: mode])
        }
    }
}

#endif
