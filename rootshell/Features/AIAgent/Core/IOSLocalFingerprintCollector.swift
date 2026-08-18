#if !CHINA_BUILD
//
//  IOSLocalFingerprintCollector.swift
//  rootshell
//
//  System fingerprinting for iOS/visionOS AI Agent local sessions
//  iOS and visionOS only
//

#if !targetEnvironment(macCatalyst)

import Foundation
import UIKit
import os.log

/// Collects system fingerprint for the local iOS/visionOS device
/// Used by AI Agent when running locally (not SSH)
@MainActor
final class IOSLocalFingerprintCollector {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "IOSLocalFingerprintCollector")

    /// Cache duration in seconds (2 hours)
    private static let cacheDuration: TimeInterval = 2 * 60 * 60

    private let executor: IOSLocalExecutor
    private var cachedFingerprint: (fingerprint: HostFingerprint, expires: Date)?

    init(executor: IOSLocalExecutor) {
        self.executor = executor
    }

    /// Collect fingerprint for the local iOS device
    func collect(forceRefresh: Bool = false) async throws -> HostFingerprint {
        // Check cache unless forcing refresh
        if !forceRefresh, let cached = cachedFingerprint, Date() < cached.expires {
            Self.logger.debug("Using cached iOS local fingerprint")
            return cached.fingerprint
        }

        Self.logger.info("Collecting iOS device fingerprint")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let deviceName = UIDevice.current.name
        let osName = UIDevice.current.systemName
        let osVersion = UIDevice.current.systemVersion
        let username = UserPreferences.effectiveUsername

        // Known available tools from ios_system (no discovery needed)
        let availableTools: Set<String> = [
            // File operations
            "ls", "pwd", "cd", "cat", "cp", "mv", "rm", "ln", "mkdir", "rmdir",
            "touch", "find", "du", "stat", "chmod", "chown", "chflags", "readlink",
            // Text processing
            "grep", "egrep", "fgrep", "rg", "sed", "awk", "wc", "sort", "uniq",
            "diff", "head", "tail", "tr", "md5",
            // Archives
            "tar", "gzip", "gunzip", "compress", "uncompress",
            // Network
            "curl", "nc", "dig", "host", "nslookup", "whois", "ifconfig",
            // Developer tools
            "git", "bat", "jq", "gix",
            // Shell utilities
            "echo", "env", "printenv", "date", "uname", "whoami", "tee",
            "uptime", "pbcopy", "pbpaste",
            // Extra commands
            "chgrp", "df", "id", "w"
        ]

        let fingerprint = HostFingerprint(
            hostname: deviceName,
            os: osName,
            distro: "\(osName) \(osVersion)",
            arch: "arm64",
            shell: "ios_system",
            username: username,
            homeDirectory: documentsPath,
            kernelVersion: nil,
            hasSudo: false,
            currentDirectory: documentsPath,
            timestamp: Date(),
            path: nil,
            environment: [:],
            availableTools: availableTools,
            languageRuntimes: [:]
        )

        // Cache the result
        let expires = Date().addingTimeInterval(Self.cacheDuration)
        cachedFingerprint = (fingerprint, expires)

        let toolCount = availableTools.count
        Self.logger.info("iOS fingerprint collected: \(osName) arm64, \(toolCount) tools available")

        return fingerprint
    }

    /// Clear cached fingerprint
    func clearCache() {
        cachedFingerprint = nil
    }
}

#endif // !targetEnvironment(macCatalyst)
#endif
