import Foundation
import UIKit
import Combine
import os.log

// MARK: - Azure Device Code Flow Manager

/// Manages the Azure device code authorization flow
@MainActor
class AzureDeviceCodeFlowManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AzureDeviceCodeFlowManager")

    // MARK: - Published State

    /// Whether authentication is in progress
    @Published private(set) var isAuthenticating = false

    /// Current status message to display
    @Published private(set) var statusMessage: String?

    /// User code to display (user enters this in browser)
    @Published private(set) var userCode: String?

    /// Verification URL to open
    @Published private(set) var verificationURL: URL?

    /// Available subscriptions after authentication
    @Published private(set) var availableSubscriptions: [AzureSubscription] = []

    // MARK: - Private State

    private var isCancelled = false
    private var currentTask: Task<Void, Never>?

    // MARK: - Constants

    private static let defaultPollingInterval: TimeInterval = 5
    private static let maxPollingDuration: TimeInterval = 900  // 15 minutes

    /// Azure CLI's well-known public client ID (works without app registration)
    private static let azureCLIClientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

    /// Azure Management API scope (matches Azure CLI's scope format)
    private static let managementScope = "https://management.azure.com//.default offline_access openid profile"

    // MARK: - URL Builders

    private static func deviceCodeEndpoint(tenantId: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/devicecode")!
    }

    private static func tokenEndpoint(tenantId: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!
    }

    // MARK: - Private State for Two-Phase Flow

    private var pendingDeviceCode: String?
    private var pendingTenantId: String?
    private var pendingPollingInterval: TimeInterval = 5
    private var pendingExpiresIn: Int = 900

    // MARK: - Public Methods

    /// Phase 1: Request device code from Azure (does NOT start polling)
    /// Call this first, then show the code to user, then call `startPolling()` when user opens browser
    /// - Parameter tenantId: Azure tenant ID (use "organizations" for any work/school account)
    func requestCode(tenantId: String = "organizations") async throws {
        guard !isAuthenticating else {
            throw AzureError.apiError(code: "in_progress", message: "Authentication already in progress")
        }

        isAuthenticating = true
        isCancelled = false
        statusMessage = "Connecting to Microsoft..."

        // Request device code
        let deviceCodeResponse = try await requestDeviceCode(tenantId: tenantId)

        if isCancelled {
            isAuthenticating = false
            throw AzureError.cancelled
        }

        // Store for polling phase
        pendingDeviceCode = deviceCodeResponse.deviceCode
        pendingTenantId = tenantId
        pendingPollingInterval = max(TimeInterval(deviceCodeResponse.interval), Self.defaultPollingInterval)
        pendingExpiresIn = deviceCodeResponse.expiresIn

        // Set published properties for UI
        userCode = deviceCodeResponse.userCode
        if let url = URL(string: deviceCodeResponse.verificationUri) {
            verificationURL = url
        }
        statusMessage = "Enter the code in your browser"
    }

    /// Phase 2: Start polling for authorization (call after user opens browser)
    /// - Returns: The Azure session with tokens
    func startPolling() async throws -> AzureSession {
        guard let deviceCode = pendingDeviceCode,
              let tenantId = pendingTenantId else {
            throw AzureError.apiError(code: "no_pending_code", message: "No pending device code. Call requestCode() first.")
        }

        statusMessage = "Waiting for authorization..."

        let tokenResponse = try await pollForToken(
            tenantId: tenantId,
            deviceCode: deviceCode,
            interval: pendingPollingInterval,
            expiresIn: pendingExpiresIn
        )

        if isCancelled { throw AzureError.cancelled }

        // Clear pending state
        pendingDeviceCode = nil
        pendingTenantId = nil

        // Create session
        let session = AzureSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            tokenExpiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            tenantId: tenantId
        )

        statusMessage = "Authentication successful!"

        // Clear UI state
        isAuthenticating = false
        userCode = nil
        verificationURL = nil

        return session
    }

    /// Legacy single-call method (for compatibility)
    func startDeviceCodeFlow(tenantId: String = "organizations") async throws -> AzureSession {
        try await requestCode(tenantId: tenantId)
        return try await startPolling()
    }

    /// List available subscriptions for the authenticated session
    func listSubscriptions(session: AzureSession) async throws -> [AzureSubscription] {
        statusMessage = "Loading subscriptions..."

        let url = URL(string: "https://management.azure.com/subscriptions?api-version=2022-12-01")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzureError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error("List subscriptions failed (HTTP \(httpResponse.statusCode)): \(bodyStr)")
            throw AzureError.apiError(code: "http_\(httpResponse.statusCode)", message: "Failed to list subscriptions")
        }

        let decoder = JSONDecoder()
        let subscriptionResponse = try decoder.decode(AzureSubscriptionListResponse.self, from: data)

        // Log all subscriptions for debugging
        Self.logger.info("Azure returned \(subscriptionResponse.value.count) total subscription(s)")
        for sub in subscriptionResponse.value {
            Self.logger.info("  Subscription: \(sub.displayName) (\(sub.subscriptionId)) - state: \(sub.state)")
        }

        // Filter to only show Enabled subscriptions
        let enabledSubscriptions = subscriptionResponse.value.filter { $0.state.lowercased() == "enabled" }
        Self.logger.info("Filtered to \(enabledSubscriptions.count) enabled subscription(s)")

        availableSubscriptions = enabledSubscriptions
        statusMessage = nil

        return enabledSubscriptions
    }

    /// Refresh the Azure access token using the refresh token
    func refreshToken(session: AzureSession) async throws -> AzureSession {
        guard let refreshToken = session.refreshToken else {
            throw AzureError.apiError(code: "no_refresh_token", message: "No refresh token available")
        }

        let url = Self.tokenEndpoint(tenantId: session.tenantId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "client_id": Self.azureCLIClientId,
            "refresh_token": refreshToken,
            "scope": Self.managementScope
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AzureError.apiError(code: "refresh_failed", message: "Token refresh failed")
        }

        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(AzureTokenResponse.self, from: data)

        var updatedSession = session
        updatedSession.accessToken = tokenResponse.accessToken
        updatedSession.tokenExpiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        if let newRefreshToken = tokenResponse.refreshToken {
            updatedSession.refreshToken = newRefreshToken
        }

        return updatedSession
    }

    /// Cancel the current authentication flow
    func cancel() {
        isCancelled = true
        currentTask?.cancel()
        isAuthenticating = false
        userCode = nil
        verificationURL = nil
        statusMessage = nil
        pendingDeviceCode = nil
        pendingTenantId = nil
    }

    // MARK: - Private Methods

    private func requestDeviceCode(tenantId: String) async throws -> AzureDeviceCodeResponse {
        let url = Self.deviceCodeEndpoint(tenantId: tenantId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // For form-urlencoded, encode only characters that need encoding
        // Space becomes %20 or +, and special chars like &, = need encoding
        var formAllowed = CharacterSet.urlQueryAllowed
        formAllowed.remove(charactersIn: "&=+")

        let encodedScope = Self.managementScope
            .addingPercentEncoding(withAllowedCharacters: formAllowed)!
            .replacingOccurrences(of: "%20", with: "+")  // Use + for spaces in form data

        let bodyString = "client_id=\(Self.azureCLIClientId)&scope=\(encodedScope)"

        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzureError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error("Device code request failed (HTTP \(httpResponse.statusCode)): \(bodyStr)")
            throw AzureError.apiError(code: "http_\(httpResponse.statusCode)", message: "Failed to get device code")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AzureDeviceCodeResponse.self, from: data)
    }

    private func pollForToken(
        tenantId: String,
        deviceCode: String,
        interval: TimeInterval,
        expiresIn: Int
    ) async throws -> AzureTokenResponse {
        let startTime = Date()
        let maxDuration = min(TimeInterval(expiresIn), Self.maxPollingDuration)
        var currentInterval = interval

        while !isCancelled {
            // Check timeout
            if Date().timeIntervalSince(startTime) > maxDuration {
                throw AzureError.timeout
            }

            statusMessage = "Waiting for authorization..."

            // Wait before polling
            try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))

            if isCancelled { throw AzureError.cancelled }

            do {
                // Try to get token
                let tokenResponse = try await requestToken(
                    tenantId: tenantId,
                    deviceCode: deviceCode
                )
                return tokenResponse
            } catch let error as AzureError {
                switch error {
                case .authorizationPending:
                    // User hasn't authorized yet, keep polling
                    continue
                case .slowDown:
                    // Increase polling interval
                    currentInterval += 5
                    continue
                default:
                    throw error
                }
            }
        }

        throw AzureError.cancelled
    }

    private func requestToken(tenantId: String, deviceCode: String) async throws -> AzureTokenResponse {
        let url = Self.tokenEndpoint(tenantId: tenantId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": Self.azureCLIClientId,
            "device_code": deviceCode
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzureError.networkError("Invalid response")
        }

        // Check for error response
        if httpResponse.statusCode != 200 {
            let decoder = JSONDecoder()
            if let errorResponse = try? decoder.decode(AzureTokenError.self, from: data) {
                switch errorResponse.error {
                case "authorization_pending":
                    throw AzureError.authorizationPending
                case "slow_down":
                    throw AzureError.slowDown
                case "expired_token":
                    throw AzureError.expiredToken
                case "access_denied":
                    throw AzureError.accessDenied
                default:
                    throw AzureError.apiError(
                        code: errorResponse.error,
                        message: errorResponse.errorDescription ?? "Unknown error"
                    )
                }
            }
            throw AzureError.apiError(code: "http_\(httpResponse.statusCode)", message: "Token request failed")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AzureTokenResponse.self, from: data)
    }
}
