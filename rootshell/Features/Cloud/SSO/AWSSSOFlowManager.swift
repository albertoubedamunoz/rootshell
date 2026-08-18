import Foundation
import UIKit
import Combine

// MARK: - AWS SSO Flow Manager

/// Manages the AWS SSO device authorization flow
@MainActor
class AWSSSOFlowManager: ObservableObject {

    // MARK: - Published State

    /// Whether authentication is in progress
    @Published private(set) var isAuthenticating = false

    /// Current status message to display
    @Published private(set) var statusMessage: String?

    /// User code to display (user enters this in browser)
    @Published private(set) var userCode: String?

    /// Verification URL to open
    @Published private(set) var verificationURL: URL?

    /// Available accounts after authentication
    @Published private(set) var availableAccounts: [AWSSSOAccount] = []

    /// Available roles for selected account
    @Published private(set) var availableRoles: [AWSSSORole] = []

    // MARK: - Private State

    private var isCancelled = false
    private var currentTask: Task<Void, Never>?

    // MARK: - Constants

    private static let defaultPollingInterval: TimeInterval = 5
    private static let maxPollingDuration: TimeInterval = 300 // 5 minutes

    // MARK: - Public Methods

    /// Start the AWS SSO authentication flow
    /// - Parameters:
    ///   - startURL: The AWS SSO start URL (e.g., https://my-org.awsapps.com/start)
    ///   - region: AWS region for SSO
    /// - Returns: The SSO session with tokens
    func startSSOFlow(startURL: String, region: String) async throws -> AWSSSOSession {
        guard !isAuthenticating else {
            throw AWSSSOError.apiError(code: "in_progress", message: "Authentication already in progress")
        }

        isAuthenticating = true
        isCancelled = false
        statusMessage = "Starting authentication..."

        defer {
            isAuthenticating = false
            userCode = nil
            verificationURL = nil
        }

        let oidcClient = AWSSSOOIDCClient(region: region)

        // Step 1: Register client (or use cached)
        statusMessage = "Registering client..."
        let clientRegistration = try await oidcClient.registerClient()

        if isCancelled { throw AWSSSOError.cancelled }

        // Step 2: Start device authorization
        statusMessage = "Starting device authorization..."
        let deviceAuth = try await oidcClient.startDeviceAuthorization(
            clientId: clientRegistration.clientId,
            clientSecret: clientRegistration.clientSecret,
            startURL: startURL
        )

        if isCancelled { throw AWSSSOError.cancelled }

        // Step 3: Display user code and open browser
        userCode = deviceAuth.userCode

        if let verificationUriComplete = deviceAuth.verificationUriComplete,
           let url = URL(string: verificationUriComplete) {
            verificationURL = url
        } else if let url = URL(string: deviceAuth.verificationUri) {
            verificationURL = url
        }

        statusMessage = "Open your browser and enter the code"

        // Automatically open Safari
        if let url = verificationURL {
            await UIApplication.shared.open(url)
        }

        // Step 4: Poll for token
        let pollingInterval = max(TimeInterval(deviceAuth.interval), Self.defaultPollingInterval)
        let tokenResponse = try await pollForToken(
            oidcClient: oidcClient,
            clientId: clientRegistration.clientId,
            clientSecret: clientRegistration.clientSecret,
            deviceCode: deviceAuth.deviceCode,
            interval: pollingInterval,
            expiresIn: deviceAuth.expiresIn
        )

        if isCancelled { throw AWSSSOError.cancelled }

        // Step 5: Create SSO session
        let session = AWSSSOSession(
            clientId: clientRegistration.clientId,
            clientSecret: clientRegistration.clientSecret,
            clientSecretExpiresAt: Date(timeIntervalSince1970: TimeInterval(clientRegistration.clientSecretExpiresAt)),
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            tokenExpiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            startURL: startURL,
            region: region
        )

        statusMessage = "Authentication successful!"
        return session
    }

    /// Get available accounts for an SSO session
    func listAccounts(session: AWSSSOSession) async throws -> [AWSSSOAccount] {
        statusMessage = "Loading accounts..."
        let portalClient = AWSSSOPortalClient(region: session.region, accessToken: session.accessToken)
        let accounts = try await portalClient.listAccounts()
        availableAccounts = accounts
        statusMessage = nil
        return accounts
    }

    /// Get available roles for an account
    func listRoles(session: AWSSSOSession, accountId: String) async throws -> [AWSSSORole] {
        statusMessage = "Loading roles..."
        let portalClient = AWSSSOPortalClient(region: session.region, accessToken: session.accessToken)
        let roles = try await portalClient.listAccountRoles(accountId: accountId)
        availableRoles = roles
        statusMessage = nil
        return roles
    }

    /// Get STS credentials for a role
    func getCredentials(
        session: AWSSSOSession,
        accountId: String,
        roleName: String
    ) async throws -> AWSSTSCredentials {
        statusMessage = "Getting credentials..."
        let portalClient = AWSSSOPortalClient(region: session.region, accessToken: session.accessToken)
        let credentials = try await portalClient.getRoleCredentials(accountId: accountId, roleName: roleName)
        statusMessage = nil
        return credentials
    }

    /// Refresh SSO token
    func refreshToken(session: AWSSSOSession) async throws -> AWSSSOSession {
        guard let refreshToken = session.refreshToken else {
            throw AWSSSOError.apiError(code: "no_refresh_token", message: "No refresh token available")
        }

        let oidcClient = AWSSSOOIDCClient(region: session.region)
        let tokenResponse = try await oidcClient.refreshToken(
            clientId: session.clientId,
            clientSecret: session.clientSecret,
            refreshToken: refreshToken
        )

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
    }

    // MARK: - Private Methods

    private func pollForToken(
        oidcClient: AWSSSOOIDCClient,
        clientId: String,
        clientSecret: String,
        deviceCode: String,
        interval: TimeInterval,
        expiresIn: Int
    ) async throws -> SSOTokenResponse {
        let startTime = Date()
        let maxDuration = min(TimeInterval(expiresIn), Self.maxPollingDuration)
        var currentInterval = interval

        while !isCancelled {
            // Check timeout
            if Date().timeIntervalSince(startTime) > maxDuration {
                throw AWSSSOError.timeout
            }

            statusMessage = "Waiting for authorization..."

            // Wait before polling
            try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))

            if isCancelled { throw AWSSSOError.cancelled }

            do {
                // Try to get token
                let tokenResponse = try await oidcClient.createToken(
                    clientId: clientId,
                    clientSecret: clientSecret,
                    deviceCode: deviceCode
                )
                return tokenResponse
            } catch let error as AWSSSOError {
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

        throw AWSSSOError.cancelled
    }
}
