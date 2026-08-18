import Foundation

// MARK: - AWS SSO OIDC Client

/// AWS SSO OIDC API client for device authorization flow
actor AWSSSOOIDCClient {
    private let region: String
    private let baseURL: String

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(region: String) {
        self.region = region
        self.baseURL = "https://oidc.\(region).amazonaws.com"
    }

    // MARK: - Client Registration

    /// Register a new OIDC client (valid for ~90 days)
    /// This is an anonymous request (no authentication required)
    func registerClient(clientName: String = "rootshell") async throws -> SSORegisterClientResponse {
        guard let url = URL(string: "\(baseURL)/client/register") else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "clientName": clientName,
            "clientType": "public"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorResponse = try? jsonDecoder.decode(SSOOIDCError.self, from: data)
            throw AWSSSOError.apiError(
                code: errorResponse?.error ?? "unknown",
                message: errorResponse?.error_description ?? "Registration failed"
            )
        }

        return try jsonDecoder.decode(SSORegisterClientResponse.self, from: data)
    }

    // MARK: - Device Authorization

    /// Start device authorization flow
    /// Returns device code, user code, and verification URL
    func startDeviceAuthorization(
        clientId: String,
        clientSecret: String,
        startURL: String
    ) async throws -> SSODeviceAuthorizationResponse {
        guard let url = URL(string: "\(baseURL)/device_authorization") else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "startUrl": startURL
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorResponse = try? jsonDecoder.decode(SSOOIDCError.self, from: data)
            throw AWSSSOError.apiError(
                code: errorResponse?.error ?? "unknown",
                message: errorResponse?.error_description ?? "Device authorization failed"
            )
        }

        return try jsonDecoder.decode(SSODeviceAuthorizationResponse.self, from: data)
    }

    // MARK: - Token Creation

    /// Poll for token after user authorizes in browser
    /// Returns access token and refresh token
    func createToken(
        clientId: String,
        clientSecret: String,
        deviceCode: String,
        grantType: String = "urn:ietf:params:oauth:grant-type:device_code"
    ) async throws -> SSOTokenResponse {
        guard let url = URL(string: "\(baseURL)/token") else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "deviceCode": deviceCode,
            "grantType": grantType
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorResponse = try? jsonDecoder.decode(SSOOIDCError.self, from: data)
            let errorCode = errorResponse?.error ?? "unknown"

            // Handle polling-specific errors
            switch errorCode {
            case "authorization_pending":
                throw AWSSSOError.authorizationPending
            case "slow_down":
                throw AWSSSOError.slowDown
            case "expired_token":
                throw AWSSSOError.expiredToken
            case "access_denied":
                throw AWSSSOError.accessDenied
            default:
                throw AWSSSOError.apiError(
                    code: errorCode,
                    message: errorResponse?.error_description ?? "Token creation failed"
                )
            }
        }

        return try jsonDecoder.decode(SSOTokenResponse.self, from: data)
    }

    /// Refresh an existing token using refresh token
    func refreshToken(
        clientId: String,
        clientSecret: String,
        refreshToken: String
    ) async throws -> SSOTokenResponse {
        guard let url = URL(string: "\(baseURL)/token") else {
            throw AWSSSOError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "refreshToken": refreshToken,
            "grantType": "refresh_token"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AWSSSOError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorResponse = try? jsonDecoder.decode(SSOOIDCError.self, from: data)
            throw AWSSSOError.apiError(
                code: errorResponse?.error ?? "unknown",
                message: errorResponse?.error_description ?? "Token refresh failed"
            )
        }

        return try jsonDecoder.decode(SSOTokenResponse.self, from: data)
    }
}

// MARK: - AWS SSO Error

enum AWSSSOError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(code: String, message: String)
    case authorizationPending
    case slowDown
    case expiredToken
    case accessDenied
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid SSO URL"
        case .invalidResponse:
            return "Invalid response from SSO service"
        case .apiError(_, let message):
            return message
        case .authorizationPending:
            return "Waiting for authorization"
        case .slowDown:
            return "Too many requests, slowing down"
        case .expiredToken:
            return "Authorization expired, please try again"
        case .accessDenied:
            return "Access denied"
        case .timeout:
            return "Authorization timed out"
        case .cancelled:
            return "Authorization cancelled"
        }
    }

    /// Whether this error indicates we should continue polling
    var shouldContinuePolling: Bool {
        switch self {
        case .authorizationPending, .slowDown:
            return true
        default:
            return false
        }
    }
}
