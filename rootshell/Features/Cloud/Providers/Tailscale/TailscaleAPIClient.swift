import Foundation
import os.log

// MARK: - Tailscale API Client

/// HTTP client for Tailscale API v2
@MainActor
final class TailscaleAPIClient: CloudProviderAPIClient, VMCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TailscaleAPIClient")

    private let baseURL = TailscaleProvider.OAuthConfig.baseURL
    private let tokenURL = TailscaleProvider.OAuthConfig.tokenURL
    private var credentials: CloudCredentials
    private let accountID: UUID
    private let urlSession: URLSession

    init(credentials: CloudCredentials, accountID: UUID) {
        self.credentials = credentials
        self.accountID = accountID
        self.urlSession = URLSession.shared
    }

    /// Get the current credentials (may include refreshed access token)
    var currentCredentials: CloudCredentials {
        credentials
    }

    // MARK: - CloudProviderAPIClient

    func validateCredentials() async throws -> Bool {
        Self.logger.info("Validating Tailscale credentials")
        do {
            // Try to get a token and list devices
            try await refreshTokenIfNeeded()
            _ = try await getAccountInfo()
            Self.logger.info("Tailscale credentials validated successfully")
            return true
        } catch CloudAPIError.unauthorized {
            Self.logger.warning("Tailscale credentials validation failed - unauthorized")
            return false
        } catch CloudAPIError.forbidden {
            Self.logger.warning("Tailscale credentials validation failed - forbidden (check scopes)")
            return false
        } catch {
            Self.logger.error("Tailscale credentials validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        Self.logger.info("Fetching Tailscale account info")

        // Ensure we have a valid token
        try await refreshTokenIfNeeded()

        // List devices to validate access. Use the same online filter as
        // listInstances() so the header count matches what users see in the list.
        let devices = try await listDevices()
        let deviceCount = onlineDevices(devices).count

        // Use stored tailnet name for display if available, otherwise show device count
        let displayName = if let tailnet = credentials.tailscaleTailnet, !tailnet.isEmpty {
            "\(tailnet) (\(deviceCount) devices)"
        } else {
            "\(deviceCount) devices"
        }

        return ProviderAccountInfo(
            accountID: credentials.tailscaleClientId ?? "tailscale",
            displayName: displayName
        )
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        Self.logger.info("Fetching Tailscale devices")

        // Ensure we have a valid token
        try await refreshTokenIfNeeded()

        let devices = try await listDevices()
        let online = onlineDevices(devices)
        Self.logger.info("Fetched \(devices.count) Tailscale devices, \(online.count) online within 30m")

        return online.map { $0.toCloudInstance(accountID: accountID) }
    }

    /// The Tailscale API returns every authorized device regardless of online state.
    /// Drop anything whose `lastSeen` is missing or older than 30 minutes so long-offline
    /// machines don't show up in the list, header counts, or Quick Connect.
    /// Tailscale's lastSeen has no fractional seconds (e.g. "2022-03-04T15:14:46Z"); we
    /// also accept fractional-second variants for resilience.
    private func onlineDevices(_ devices: [TailscaleDeviceResponse]) -> [TailscaleDeviceResponse] {
        let now = Date()
        let freshnessWindow: TimeInterval = 30 * 60
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var unparseable: [String] = []
        let online = devices.filter { device in
            guard let lastSeenString = device.lastSeen else { return false }
            let lastSeen = plainFormatter.date(from: lastSeenString)
                ?? fractionalFormatter.date(from: lastSeenString)
            guard let lastSeen else {
                unparseable.append(lastSeenString)
                return false
            }
            return now.timeIntervalSince(lastSeen) <= freshnessWindow
        }

        if !unparseable.isEmpty {
            let sample = unparseable.first ?? "<nil>"
            let count = unparseable.count
            Self.logger.warning("Could not parse lastSeen for \(count) Tailscale devices (sample: \(sample))")
        }
        return online
    }

    // MARK: - Token Management

    /// Refresh the access token if needed (expired or missing)
    func refreshTokenIfNeeded() async throws {
        // Check if we need to refresh
        if credentials.tailscaleAccessToken != nil,
           !credentials.needsRefresh {
            Self.logger.debug("Tailscale token still valid")
            return
        }

        Self.logger.info("Refreshing Tailscale access token")
        let tokenResponse = try await exchangeCredentialsForToken()

        // Update credentials with new token
        credentials.tailscaleAccessToken = tokenResponse.accessToken
        credentials.tailscaleTokenExpiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        // Save updated credentials to Keychain (if account exists)
        // During initial validation, the account hasn't been saved yet, so this may fail
        do {
            try CloudAccountManager.shared.updateCredentials(credentials)
        } catch {
            Self.logger.debug("Could not update credentials in keychain (account may not exist yet): \(error.localizedDescription)")
        }

        Self.logger.info("Tailscale token refreshed, expires in \(tokenResponse.expiresIn) seconds")
    }

    /// Exchange client credentials for access token
    func exchangeCredentialsForToken() async throws -> TailscaleTokenResponse {
        guard let clientId = credentials.tailscaleClientId,
              let clientSecret = credentials.tailscaleClientSecret else {
            throw CloudAPIError.invalidCredentials
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Client credentials grant
        let body = "grant_type=client_credentials&client_id=\(clientId)&client_secret=\(clientSecret)"
        request.httpBody = body.data(using: .utf8)

        Self.logger.debug("POST \(self.tokenURL.absoluteString)")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse
        }

        Self.logger.debug("Token response status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw CloudAPIError.unauthorized
        case 403:
            throw CloudAPIError.forbidden
        default:
            if let errorResponse = try? JSONDecoder().decode(TailscaleErrorResponse.self, from: data) {
                Self.logger.error("Tailscale token error: \(errorResponse.message)")
            }
            throw CloudAPIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(TailscaleTokenResponse.self, from: data)
        } catch {
            Self.logger.error("Failed to decode token response: \(error.localizedDescription)")
            throw CloudAPIError.decodingError(error)
        }
    }

    // MARK: - Private Helpers

    private func listDevices() async throws -> [TailscaleDeviceResponse] {
        // Use "-" to automatically resolve to the tailnet associated with OAuth credentials
        // This avoids users needing to know their tailnet name/ID
        let response: TailscaleDevicesResponse = try await get(path: "/tailnet/-/devices?fields=all")
        return response.devices
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let token = credentials.tailscaleAccessToken else {
            throw CloudAPIError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.logger.debug("GET \(url.absoluteString)")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse
        }

        Self.logger.debug("Response status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw CloudAPIError.unauthorized
        case 403:
            throw CloudAPIError.forbidden
        case 404:
            throw CloudAPIError.notFound
        case 429:
            throw CloudAPIError.rateLimited
        case 500...599:
            throw CloudAPIError.serverError(httpResponse.statusCode)
        default:
            if let errorResponse = try? JSONDecoder().decode(TailscaleErrorResponse.self, from: data) {
                Self.logger.error("Tailscale API error: \(errorResponse.message)")
            }
            throw CloudAPIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error("Failed to decode response: \(error.localizedDescription)")
            throw CloudAPIError.decodingError(error)
        }
    }
}
