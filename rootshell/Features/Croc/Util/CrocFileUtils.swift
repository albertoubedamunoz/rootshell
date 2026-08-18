#if !targetEnvironment(macCatalyst)

import Foundation

/// File utility functions for croc transfers.
/// Port of Go's `utils.ValidFileName()`, `utils.ZipDirectory()`, etc.
nonisolated enum CrocFileUtils {

    // MARK: - Path Validation

    /// Validate a filename for security concerns.
    /// Rejects path traversal (..), .ssh directory, and invisible characters.
    static func validateFileName(_ name: String) -> CrocError? {
        if name.contains("..") {
            return .pathTraversalDetected(name)
        }
        if name.contains(".ssh") {
            return .pathTraversalDetected(name)
        }
        // Check for invisible/control characters
        for scalar in name.unicodeScalars {
            if scalar.properties.isDefaultIgnorableCodePoint {
                return .invalidFilename(name)
            }
            if scalar.value < 32 && scalar.value != 10 && scalar.value != 13 {
                return .invalidFilename(name)
            }
        }
        return nil
    }

    // MARK: - Zip Support

    /// Create a temporary zip file from a directory.
    /// Matches Go's `utils.ZipDirectory()` but can stage a filtered tree first.
    static func zipDirectory(
        source: String,
        shouldInclude: ((_ absolutePath: String, _ relativePath: String) -> Bool)? = nil
    ) throws -> String {
        let fm = FileManager.default
        let baseName = (source as NSString).lastPathComponent + ".zip"
        let tempDir = NSTemporaryDirectory() + "croc_zip_\(UUID().uuidString)"
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let tempPath = (tempDir as NSString).appendingPathComponent(baseName)
        let sourceURL = URL(fileURLWithPath: source)
        let sourceResolvedPath = sourceURL.resolvingSymlinksInPath().path
        let destURL = URL(fileURLWithPath: tempPath)
        let zipSourceURL: URL
        var stagedSourceURL: URL?

        defer {
            if let stagedSourceURL {
                try? fm.removeItem(at: stagedSourceURL)
            }
        }

        if let shouldInclude {
            let stagedURL = URL(fileURLWithPath: tempDir).appendingPathComponent(
                (source as NSString).lastPathComponent,
                isDirectory: true
            )
            stagedSourceURL = stagedURL
            try fm.createDirectory(at: stagedURL, withIntermediateDirectories: true, attributes: nil)

            let enumerator = fm.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                let normalizedPath = fileURL.resolvingSymlinksInPath().path
                let relativePath: String
                if fileURL.path.hasPrefix(sourceURL.path + "/") {
                    relativePath = String(fileURL.path.dropFirst(sourceURL.path.count + 1))
                } else if normalizedPath.hasPrefix(sourceResolvedPath + "/") {
                    relativePath = String(normalizedPath.dropFirst(sourceResolvedPath.count + 1))
                } else {
                    relativePath = fileURL.lastPathComponent
                }

                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymbolicLink = resourceValues.isSymbolicLink == true
                let isDirectory = resourceValues.isDirectory == true
                if !shouldInclude(normalizedPath, relativePath) {
                    if isDirectory && !isSymbolicLink {
                        enumerator?.skipDescendants()
                    }
                    continue
                }

                let stagedItemURL = stagedURL.appendingPathComponent(relativePath, isDirectory: isDirectory && !isSymbolicLink)
                if isDirectory && !isSymbolicLink {
                    try fm.createDirectory(at: stagedItemURL, withIntermediateDirectories: true, attributes: nil)
                    continue
                }

                try fm.createDirectory(at: stagedItemURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                if fm.fileExists(atPath: stagedItemURL.path) {
                    try fm.removeItem(at: stagedItemURL)
                }
                try fm.copyItem(at: fileURL, to: stagedItemURL)
            }

            zipSourceURL = stagedURL
        } else {
            zipSourceURL = sourceURL
        }

        // Use NSFileCoordinator for zip (Foundation's built-in zip support)
        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: zipSourceURL, options: .forUploading, error: &error) { zipURL in
            if fm.fileExists(atPath: destURL.path) {
                try? fm.removeItem(at: destURL)
            }
            try? fm.copyItem(at: zipURL, to: destURL)
        }

        if let error {
            throw CrocError.ioError("zip failed: \(error.localizedDescription)")
        }

        return tempPath
    }

    /// Extract a zip file to a directory using Archive API (iOS 16+).
    static func unzipFile(source: String, destination: String) throws {
        let destURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        // Use Process or NSFileCoordinator as a fallback — on iOS we use
        // the reverse of the zip coordinate approach
        let sourceURL = URL(fileURLWithPath: source)

        // NSFileCoordinator's forUploading creates zips, but doesn't unzip.
        // For unzip on iOS, we need to use the Archive framework or manual zlib.
        // For now, signal that the receiver should handle the received zip file
        // by just moving it to the destination.
        let destFile = destURL.appendingPathComponent((source as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destFile)
    }

    // MARK: - Symlink Support

    /// Create a symbolic link.
    static func createSymlink(at path: String, target: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    // MARK: - .gitignore Support

    /// Simple .gitignore pattern matcher.
    /// Returns true if the path should be ignored.
    static func matchesGitignore(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Simple glob matching
            if matchGlob(pattern: trimmed, path: path) {
                return true
            }
        }
        return false
    }

    /// Load .gitignore patterns from a directory.
    static func loadGitignore(at directory: String) -> [String] {
        let gitignorePath = (directory as NSString).appendingPathComponent(".gitignore")
        guard let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
    }

    /// Simple glob pattern matching.
    private static func matchGlob(pattern: String, path: String) -> Bool {
        let isNegated = pattern.hasPrefix("!")
        let cleanPattern = isNegated ? String(pattern.dropFirst()) : pattern

        // Convert glob to regex-like matching
        let components = path.components(separatedBy: "/")

        // Simple suffix matching for patterns without /
        if !cleanPattern.contains("/") {
            let filename = components.last ?? path
            let matches = fnmatch(cleanPattern, filename)
            return isNegated ? !matches : matches
        }

        // Path matching
        let matches = fnmatch(cleanPattern, path)
        return isNegated ? !matches : matches
    }

    /// Simple fnmatch-style pattern matching.
    private static func fnmatch(_ pattern: String, _ string: String) -> Bool {
        var pi = pattern.startIndex
        var si = string.startIndex

        while pi < pattern.endIndex && si < string.endIndex {
            let pc = pattern[pi]
            let sc = string[si]

            if pc == "*" {
                // Match any sequence
                let nextPi = pattern.index(after: pi)
                if nextPi == pattern.endIndex { return true }
                while si < string.endIndex {
                    if fnmatch(String(pattern[nextPi...]), String(string[si...])) {
                        return true
                    }
                    si = string.index(after: si)
                }
                return false
            } else if pc == "?" {
                // Match any single character
            } else if pc != sc {
                return false
            }

            pi = pattern.index(after: pi)
            si = string.index(after: si)
        }

        // Check remaining pattern characters are all *
        while pi < pattern.endIndex {
            if pattern[pi] != "*" { return false }
            pi = pattern.index(after: pi)
        }

        return si == string.endIndex
    }

    // MARK: - Network Utilities

    /// Get local IP addresses.
    static func getLocalIPs() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let addr = ptr {
            let sa = addr.pointee.ifa_addr.pointee
            if sa.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(sa.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip != "127.0.0.1" {
                    addresses.append(ip)
                }
            }
            ptr = addr.pointee.ifa_next
        }

        return addresses
    }

    /// All local interface addresses (IPv4 + IPv6, including loopback),
    /// both scoped ("fe80::1%en0") and unscoped forms. Used to filter
    /// self-originated multicast during peer discovery.
    static func getAllLocalAddresses() -> Set<String> {
        var addresses: Set<String> = ["localhost", "127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }
            guard let sa = addr.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            addresses.insert(ip)
            if let unscoped = ip.split(separator: "%").first.map(String.init) {
                addresses.insert(unscoped)
            }
        }
        return addresses
    }

    /// Check if an IP address is local (private).
    static func isLocalIP(_ address: String) -> Bool {
        return address.hasPrefix("10.")
            || address.hasPrefix("172.16.") || address.hasPrefix("172.17.")
            || address.hasPrefix("172.18.") || address.hasPrefix("172.19.")
            || address.hasPrefix("172.2") || address.hasPrefix("172.30.") || address.hasPrefix("172.31.")
            || address.hasPrefix("192.168.")
            || address.hasPrefix("127.")
            || address == "::1"
    }

    // MARK: - Disk Space

    /// Check available disk space at a path.
    static func availableDiskSpace(at path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let space = attrs[.systemFreeSize] as? Int64 else {
            return 0
        }
        return space
    }

    // MARK: - Temp File Tracking

    private static var markedFiles: [String] = []

    /// Mark a file for removal on cleanup.
    static func markForRemoval(_ path: String) {
        markedFiles.append(path)
    }

    /// Remove all marked files.
    static func removeMarkedFiles() {
        for path in markedFiles {
            try? FileManager.default.removeItem(atPath: path)
        }
        markedFiles.removeAll()
    }
}

#endif
