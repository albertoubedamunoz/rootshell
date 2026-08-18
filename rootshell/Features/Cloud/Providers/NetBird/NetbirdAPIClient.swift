import Foundation
import os.log

// MARK: - NetBird API Client

/// HTTP client for the NetBird Management API.
///
/// NetBird authenticates with a static Personal Access Token (`nbp_…`) sent via
/// the `Token` auth scheme — simpler than Tailscale's OAuth client-credentials
/// flow, so there is no token exchange or refresh.
@MainActor
final class NetbirdAPIClient: CloudProviderAPIClient, VMCapableProvider {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "NetbirdAPIClient")

    private let credentials: CloudCredentials
    private let accountID: UUID
    private let urlSession: URLSession

    init(credentials: CloudCredentials, accountID: UUID) {
        self.credentials = credentials
        self.accountID = accountID
        self.urlSession = URLSession.shared
    }

    /// Resolves the base URL for the NetBird API.
    ///
    /// An empty/absent management URL means NetBird Cloud. A *non-empty*
    /// management URL must resolve to a valid absolute http(s) URL with a host
    /// — we **throw** rather than fall back to Cloud, because silently
    /// defaulting would send a self-hosted Personal Access Token to
    /// api.netbird.io. A scheme-less host (e.g. "netbird.example.com") is
    /// normalized to https. We also trim a trailing slash and a trailing "/api"
    /// so the "/api/…" path is never doubled.
    private func resolveBaseURL() throws -> URL {
        guard let raw = credentials.netbirdManagementURL?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            return NetbirdProvider.APIConfig.defaultBaseURL
        }

        var normalized = raw
        // Default to https when the scheme is omitted.
        if !normalized.contains("://") {
            normalized = "https://" + normalized
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized.hasSuffix("/api") {
            normalized.removeLast(4)
        }

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw CloudAPIError.invalidManagementURL
        }
        return url
    }

    // MARK: - CloudProviderAPIClient

    func validateCredentials() async throws -> Bool {
        Self.logger.info("Validating NetBird credentials")
        do {
            _ = try await getAccountInfo()
            Self.logger.info("NetBird credentials validated successfully")
            return true
        } catch CloudAPIError.unauthorized {
            Self.logger.warning("NetBird credentials validation failed - unauthorized")
            return false
        } catch CloudAPIError.forbidden {
            Self.logger.warning("NetBird credentials validation failed - forbidden")
            return false
        } catch {
            Self.logger.error("NetBird credentials validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    func getAccountInfo() async throws -> ProviderAccountInfo {
        Self.logger.info("Fetching NetBird account info")

        let peers = try await listPeers()
        let connectedCount = peers.filter { $0.connected }.count

        return ProviderAccountInfo(
            accountID: "netbird",
            displayName: "\(connectedCount) peers"
        )
    }

    // MARK: - VMCapableProvider

    func listInstances() async throws -> [CloudInstance] {
        Self.logger.info("Fetching NetBird peers")

        let peers = try await listPeers()
        let connected = peers.filter { $0.connected }
        Self.logger.info("Fetched \(peers.count) NetBird peers, \(connected.count) connected")

        return connected.map { $0.toCloudInstance(accountID: accountID) }
    }

    // MARK: - Private Helpers

    private func listPeers() async throws -> [NetbirdPeerResponse] {
        try await get(path: "/api/peers")
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let base = try resolveBaseURL()
        guard let url = URL(string: base.absoluteString + path) else {
            throw CloudAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let token = credentials.bearerToken else {
            throw CloudAPIError.invalidCredentials
        }
        // NetBird uses the "Token" auth scheme, not "Bearer".
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

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
            if let errorResponse = try? JSONDecoder().decode(NetbirdErrorResponse.self, from: data) {
                let message = errorResponse.message
                Self.logger.error("NetBird API error: \(message)")
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
