#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Sender-side transfer logic.
/// Port of Go's `Client.Send()`, `Client.sendData()`, and `Client.sendCollectFiles()`.
nonisolated enum CrocSender {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocSender")

    /// Collect file info for files/folders to send.
    /// Matches Go's `croc.GetFilesInfo()`.
    static func collectFilesInfo(
        paths: [String],
        hashAlgorithm: String,
        zipFolder: Bool,
        gitIgnore: Bool,
        exclude: [String]
    ) throws -> (files: [CrocFileInfo], emptyFolders: [CrocFileInfo], totalFolders: Int) {
        var files: [CrocFileInfo] = []
        var emptyFolders: [CrocFileInfo] = []
        var totalFolders = 0
        let fm = FileManager.default
        let lowerExcludes = exclude.map { $0.lowercased() }
        let rootGitignorePatterns = gitIgnore ? CrocFileUtils.loadGitignore(at: fm.currentDirectoryPath) : []
        var nestedGitignoreCache: [String: [String]] = [:]

        func shouldExclude(_ relativePath: String) -> Bool {
            let normalized = relativePath.lowercased()
            return lowerExcludes.contains(where: { normalized.contains($0) })
        }

        func gitignorePatterns(for directory: String) -> [String] {
            if let cached = nestedGitignoreCache[directory] {
                return cached
            }
            let patterns = CrocFileUtils.loadGitignore(at: directory)
            nestedGitignoreCache[directory] = patterns
            return patterns
        }

        func isGitIgnored(path: String, rootPath: String) -> Bool {
            guard gitIgnore else { return false }

            let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
            let rootAbsolutePath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
            let cwdRelative = absolutePath.replacingOccurrences(of: fm.currentDirectoryPath + "/", with: "")
            if CrocFileUtils.matchesGitignore(path: cwdRelative, patterns: rootGitignorePatterns) {
                return true
            }

            var directory = URL(fileURLWithPath: absolutePath).deletingLastPathComponent().path
            while directory.hasPrefix(rootAbsolutePath) {
                let relativePath = absolutePath.replacingOccurrences(of: directory + "/", with: "")
                if CrocFileUtils.matchesGitignore(path: relativePath, patterns: gitignorePatterns(for: directory)) {
                    return true
                }
                if directory == rootAbsolutePath { break }
                directory = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            }

            return false
        }

        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                throw CrocError.fileNotFound(path)
            }

            if isDir.boolValue && zipFolder {
                totalFolders += 1
                let absPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let zipPath = try CrocFileUtils.zipDirectory(source: path) { absolutePath, relativePath in
                    if shouldExclude(relativePath) { return false }
                    if isGitIgnored(path: absolutePath, rootPath: absPath) { return false }
                    return true
                }
                let attrs = try fm.attributesOfItem(atPath: zipPath)
                files.append(CrocFileInfo(
                    name: (zipPath as NSString).lastPathComponent,
                    folderRemote: ".",
                    folderSource: (zipPath as NSString).deletingLastPathComponent,
                    hash: try CrocHasher.hashFile(at: zipPath, algorithm: hashAlgorithm),
                    size: (attrs[.size] as? Int64) ?? 0,
                    modTime: attrs[.modificationDate] as? Date,
                    isCompressed: false,
                    isEncrypted: false,
                    symlink: "",
                    mode: (attrs[.posixPermissions] as? UInt32) ?? 0o644,
                    tempFile: true,
                    isIgnored: false
                ))
                continue
            }

            if isDir.boolValue {
                totalFolders += 1
                // Match Go: absPath is the absolute path of the directory
                // Use resolvingSymlinksInPath so absPath matches what FileManager.enumerator returns
                // (on iOS, /var -> /private/var and the enumerator returns resolved paths)
                let absPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                // Match Go: absPathWithSeparator = filepath.Dir(absPath) + "/"
                // This is the PARENT directory with trailing separator
                var absPathWithSeparator = (absPath as NSString).deletingLastPathComponent
                if !absPathWithSeparator.hasSuffix("/") {
                    absPathWithSeparator += "/"
                }

                let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: absPath),
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                var hasFiles = false
                while let fileURL = enumerator?.nextObject() as? URL {
                    // Normalize to match absPath's symlink resolution
                    // (on iOS, /var -> /private/var and enumerator may return either form)
                    let pathName = fileURL.resolvingSymlinksInPath().path
                    // Match Go: remoteFolder = TrimPrefix(filepath.Dir(pathName), absPathWithSeparator)
                    let pathDir = (pathName as NSString).deletingLastPathComponent
                    let remoteFolder: String
                    if pathDir.hasPrefix(absPathWithSeparator) {
                        remoteFolder = String(pathDir.dropFirst(absPathWithSeparator.count))
                    } else {
                        remoteFolder = pathDir
                    }
                    // relativePath for exclude/gitignore checks: strip absPath + "/" prefix
                    let relativePath: String
                    if pathName.hasPrefix(absPath + "/") {
                        relativePath = String(pathName.dropFirst(absPath.count + 1))
                    } else {
                        relativePath = (pathName as NSString).lastPathComponent
                    }

                    // Check exclude patterns
                    if shouldExclude(relativePath) { continue }
                    if isGitIgnored(path: pathName, rootPath: absPath) { continue }

                    let attrs = try fm.attributesOfItem(atPath: pathName)
                    let fileType = attrs[.type] as? FileAttributeType

                    if fileType == .typeDirectory {
                        totalFolders += 1
                        // Check if empty directory
                        let contents = try fm.contentsOfDirectory(atPath: pathName)
                        if contents.isEmpty {
                            // Match Go: TrimPrefix(pathName, filepath.Dir(absPath) + "/")
                            let emptyRelative: String
                            if pathName.hasPrefix(absPathWithSeparator) {
                                emptyRelative = String(pathName.dropFirst(absPathWithSeparator.count))
                            } else {
                                emptyRelative = (pathName as NSString).lastPathComponent
                            }
                            emptyFolders.append(CrocFileInfo(
                                name: "",
                                folderRemote: emptyRelative
                            ))
                        }
                        continue
                    }

                    hasFiles = true
                    var info = CrocFileInfo()
                    // Match Go: info.Name = info.Name() (just the filename)
                    info.name = (pathName as NSString).lastPathComponent
                    // Match Go: FolderRemote = remoteFolder + "/"
                    info.folderRemote = remoteFolder + "/"
                    // Match Go: FolderSource = filepath.Dir(pathName)
                    info.folderSource = (pathName as NSString).deletingLastPathComponent

                    if fileType == .typeSymbolicLink {
                        let target = try fm.destinationOfSymbolicLink(atPath: pathName)
                        info.symlink = target
                        info.size = 0
                    } else {
                        info.size = (attrs[.size] as? Int64) ?? 0
                        info.hash = try CrocHasher.hashFile(at: pathName, algorithm: hashAlgorithm)
                    }
                    info.modTime = attrs[.modificationDate] as? Date
                    info.mode = (attrs[.posixPermissions] as? UInt32) ?? 0o644

                    files.append(info)
                }

                if !hasFiles && emptyFolders.isEmpty {
                    let baseName = (absPath as NSString).lastPathComponent
                    emptyFolders.append(CrocFileInfo(
                        name: "",
                        folderRemote: baseName
                    ))
                }
            } else {
                // Single file
                let attrs = try fm.attributesOfItem(atPath: path)
                if isGitIgnored(path: path, rootPath: (path as NSString).deletingLastPathComponent) {
                    continue
                }
                if shouldExclude(path) { continue }
                var info = CrocFileInfo()
                info.name = (path as NSString).lastPathComponent
                info.folderSource = (path as NSString).deletingLastPathComponent
                info.size = (attrs[.size] as? Int64) ?? 0
                info.modTime = attrs[.modificationDate] as? Date
                info.mode = (attrs[.posixPermissions] as? UInt32) ?? 0o644

                let fileType = attrs[.type] as? FileAttributeType
                if fileType == .typeSymbolicLink {
                    let target = try fm.destinationOfSymbolicLink(atPath: path)
                    info.symlink = target
                    info.size = 0
                } else {
                    info.hash = try CrocHasher.hashFile(at: path, algorithm: hashAlgorithm)
                }

                files.append(info)
            }
        }

        return (files, emptyFolders, totalFolders)
    }

    /// Send file data over multiplexed connections.
    /// Launches one task per data port, matching Go's `go c.sendData(i)` goroutines.
    /// Each task handles its slice of chunk positions via modular assignment.
    static func sendFileData(
        file: CrocFileInfo,
        connections: [CrocComm],
        key: Data,
        chunkMap: Set<UInt64>,
        noCompress: Bool,
        throttleBytesPerSecond: Int64?,
        onProgress: @escaping @Sendable (Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let filePath: String
        if file.folderSource.isEmpty {
            filePath = file.name
        } else {
            filePath = (file.folderSource as NSString).appendingPathComponent(file.name)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw CrocError.fileNotFound(filePath)
        }

        let chunkSize = CrocConstants.chunkSize
        let numPorts = connections.count

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<numPorts {
                let conn = connections[i]
                group.addTask {
                    // Each task gets its own file handle for concurrent ReadAt
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { handle.closeFile() }

                    var readingPos: Int64 = 0
                    var pos: UInt64 = 0
                    var curi = 0

                    while !isCancelled() {
                        // Only this task's turn when curi % numPorts == i (matches Go)
                        if curi % numPorts == i {
                            handle.seek(toFileOffset: UInt64(readingPos))
                            let data = handle.readData(ofLength: chunkSize)

                            let n = data.count
                            if n > 0 {
                                let usableChunk = chunkMap.isEmpty || chunkMap.contains(pos)
                                if usableChunk {
                                    // Build chunk: [position u64 LE][file data]
                                    var posLE = pos.littleEndian
                                    var payload = Data(bytes: &posLE, count: 8)
                                    payload.append(data)

                                    if !noCompress {
                                        payload = CrocCompression.compress(payload)
                                    }
                                    payload = try CrocEncryption.encrypt(payload, key: key)

                                    try await conn.send(payload)
                                    onProgress(Int64(n))
                                    if let throttleBytesPerSecond, throttleBytesPerSecond > 0 {
                                        let seconds = Double(n) / Double(throttleBytesPerSecond)
                                        if seconds > 0 {
                                            try await Task.sleep(for: .seconds(seconds))
                                        }
                                    }
                                }

                                readingPos += Int64(n)
                                pos += UInt64(n)
                            } else {
                                // EOF
                                break
                            }
                        } else {
                            // Not our turn — advance position by chunkSize (matches Go's n=TCP_BUFFER_SIZE/2)
                            readingPos += Int64(chunkSize)
                            pos += UInt64(chunkSize)
                        }

                        curi += 1
                    }
                }
            }

            try await group.waitForAll()
        }
    }
}

#endif
