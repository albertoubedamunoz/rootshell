//
//  MCPTokenManager.swift
//  rootshell
//
//  Manages authentication tokens for MCP server access
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
import os.log

/// Manages authentication tokens for MCP server
@MainActor
final class MCPTokenManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.rootshell", category: "MCPTokenManager")

    /// UserDefaults key for persisted token
    private static let tokenKey = "mcp_auth_token"

    /// The current authentication token
    @Published private(set) var currentToken: String?

    /// Whether a token has been generated
    var hasToken: Bool { currentToken != nil }

    init() {
        // Load persisted token on init
        loadPersistedToken()
    }

    // MARK: - Token Management

    /// Generate a new random token (32 hex characters = 128 bits)
    @discardableResult
    func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        let token: String
        if result == errSecSuccess {
            token = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            // Fallback to UUID-based token
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        currentToken = token
        persistToken(token)

        Self.logger.info("Generated new MCP authentication token")
        return token
    }

    /// Validate a provided token against the current token
    func validateToken(_ token: String) -> Bool {
        guard let currentToken = currentToken else {
            Self.logger.warning("Token validation failed: no token configured")
            return false
        }

        // Use constant-time comparison to prevent timing attacks
        let isValid = constantTimeCompare(token, currentToken)

        if !isValid {
            Self.logger.warning("Token validation failed: invalid token provided")
        }

        return isValid
    }

    /// Revoke the current token (disconnects all sessions)
    func revokeToken() {
        currentToken = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        Self.logger.info("Revoked MCP authentication token")
    }

    /// Ensure a token exists, generating one if needed
    func ensureToken() -> String {
        if let token = currentToken {
            return token
        }
        return generateToken()
    }

    // MARK: - Persistence

    private func loadPersistedToken() {
        if let token = UserDefaults.standard.string(forKey: Self.tokenKey) {
            currentToken = token
            Self.logger.debug("Loaded persisted MCP token")
        }
    }

    private func persistToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    // MARK: - Constant Time Comparison

    /// Compare two strings in constant time to prevent timing attacks
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        // If lengths differ, still iterate over the shorter one
        // but mark as not equal
        var result: UInt8 = aBytes.count == bBytes.count ? 0 : 1

        let minLength = min(aBytes.count, bBytes.count)
        for i in 0..<minLength {
            result |= aBytes[i] ^ bBytes[i]
        }

        return result == 0
    }
}
