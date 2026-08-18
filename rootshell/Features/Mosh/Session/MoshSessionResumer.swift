//
//  MoshSessionResumer.swift
//  rootshell
//
//  Validates saved Mosh session credentials for resume
//

import Foundation
import OSLog

/// Validates saved Mosh session credentials for potential resume
///
/// When the app relaunches with saved Mosh credentials, this class checks
/// if we have valid, non-expired credentials that can be used to attempt
/// a direct UDP reconnection without spawning a new mosh-server.
///
/// Note: This class does NOT probe the server. The actual connection attempt
/// serves as the validation - if the server is alive and accepts our key,
/// we're connected; if not, we fall back to SSH spawn.
@MainActor
final class MoshSessionResumer {

    // MARK: - Types

    /// Result of checking for resumable credentials
    enum ResumeResult: Sendable {
        /// Valid credentials found - can attempt direct connection
        case success(credentials: MoshSessionCredentials)

        /// Credentials have expired (>72 hours old)
        case credentialsExpired

        /// No credentials found for this terminal
        case noCredentials

        /// Credentials were corrupted or unreadable
        case credentialsCorrupted(reason: String)
    }

    // MARK: - Properties

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshSessionResumer"
    )

    // MARK: - Resume

    /// Checks for valid resumable credentials for the given terminal
    /// - Parameter terminalId: The terminal UUID to check
    /// - Returns: Resume result with credentials if available
    func checkCredentials(terminalId: UUID) -> ResumeResult {
        Self.logger.info("Checking for saved Mosh credentials for terminal \(terminalId.uuidString)")

        // Step 1: Load credentials from Keychain
        let credentials: MoshSessionCredentials
        do {
            credentials = try KeychainManager.shared.loadMoshSessionCredentials(terminalId: terminalId)
        } catch KeychainManager.KeychainError.itemNotFound {
            Self.logger.info("No saved credentials for terminal \(terminalId.uuidString)")
            return .noCredentials
        } catch {
            Self.logger.error("Failed to load credentials: \(error.localizedDescription)")
            return .credentialsCorrupted(reason: error.localizedDescription)
        }

        Self.logger.info("Loaded credentials: \(credentials.description)")

        // Step 2: Check TTL expiration
        if credentials.isExpired {
            Self.logger.info("Credentials expired (age: \(credentials.age))")
            // Clean up expired credentials
            try? KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
            return .credentialsExpired
        }

        // Step 3: Validate the key can be parsed
        do {
            _ = try credentials.toKey()
        } catch {
            Self.logger.error("Stored key is invalid: \(error.localizedDescription)")
            try? KeychainManager.shared.deleteMoshSessionCredentials(terminalId: terminalId)
            return .credentialsCorrupted(reason: "Invalid session key")
        }

        Self.logger.info("Credentials are valid, can attempt resume")
        return .success(credentials: credentials)
    }
}
