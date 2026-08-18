import Foundation

// MARK: - WiFi AP Provider API Client Protocol

/// API client for WiFi AP providers
protocol WiFiAPProviderAPIClient: Sendable {
    /// Validate that the credentials are valid
    func validateCredentials() async throws -> Bool

    /// List all access points managed by this account
    func listAccessPoints() async throws -> [WiFiAccessPoint]
}

// MARK: - API Errors

enum WiFiAPAPIError: LocalizedError {
    case unauthorized
    case forbidden
    case invalidResponse
    case rateLimited(retryAfter: Int?)
    case serverError(statusCode: Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication failed - check your API key"
        case .forbidden:
            return "Access denied"
        case .invalidResponse:
            return "Invalid response from server"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited - retry after \(seconds)s"
            }
            return "Rate limited - please try again later"
        case .serverError(let code):
            return "Server error (\(code))"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
