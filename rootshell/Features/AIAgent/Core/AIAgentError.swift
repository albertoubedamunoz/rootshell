#if !CHINA_BUILD
//
//  AIAgentError.swift
//  rootshell
//
//  AI Agent error categories for display in UI
//

import SwiftUI

/// Categorized error types for AI Agent with display properties
enum AIAgentErrorCategory: Sendable, Equatable {
    /// Rate limited by the API
    case rateLimit(retryAfter: TimeInterval?)

    /// Network connectivity error
    case network(String)

    /// Authentication/API key error
    case authentication

    /// API quota exceeded
    case quota

    /// Model not available
    case modelUnavailable(String)

    /// Configuration error (not connected, missing setup)
    case configuration(String)

    /// Unknown/generic error
    case unknown(String)

    // MARK: - Display Properties

    /// SF Symbol icon name for this error category
    var icon: String {
        switch self {
        case .rateLimit:
            return "clock.badge.exclamationmark"
        case .network:
            return "wifi.slash"
        case .authentication:
            return "lock.slash"
        case .quota:
            return "creditcard.trianglebadge.exclamationmark"
        case .modelUnavailable:
            return "cpu.fill"
        case .configuration:
            return "gearshape.triangle.fill"
        case .unknown:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Color for this error category
    var color: Color {
        switch self {
        case .rateLimit:
            return .orange
        case .network:
            return .red
        case .authentication:
            return .red
        case .quota:
            return .orange
        case .modelUnavailable:
            return .yellow
        case .configuration:
            return .gray
        case .unknown:
            return .red
        }
    }

    /// Short title for the error
    var title: String {
        switch self {
        case .rateLimit:
            return String(localized: "Rate Limited", comment: "AI Agent error: rate limited by API")
        case .network:
            return String(localized: "Network Error", comment: "AI Agent error: network connectivity issue")
        case .authentication:
            return String(localized: "Authentication Failed", comment: "AI Agent error: invalid API key")
        case .quota:
            return String(localized: "Quota Exceeded", comment: "AI Agent error: API quota exceeded")
        case .modelUnavailable:
            return String(localized: "Model Unavailable", comment: "AI Agent error: model not available")
        case .configuration:
            return String(localized: "Configuration Error", comment: "AI Agent error: missing setup")
        case .unknown:
            return String(localized: "Error", comment: "AI Agent error: generic error title")
        }
    }

    /// Detailed message for the error
    var message: String {
        switch self {
        case .rateLimit(let retryAfter):
            if let seconds = retryAfter {
                let secs = Int(seconds)
                return String(localized: "Too many requests. Please wait \(secs) seconds before retrying.", comment: "AI Agent rate limit error with retry time")
            }
            return String(localized: "Too many requests. Please wait a moment before retrying.", comment: "AI Agent rate limit error")
        case .network(let detail):
            return detail.isEmpty ? String(localized: "Unable to connect to the AI service.", comment: "AI Agent network error") : detail
        case .authentication:
            return String(localized: "Invalid API key. Please check your API key in Settings.", comment: "AI Agent auth error")
        case .quota:
            return String(localized: "Your API quota has been exceeded. Please check your billing.", comment: "AI Agent quota error")
        case .modelUnavailable(let model):
            return String(localized: "The model '\(model)' is not available. Try selecting a different model.", comment: "AI Agent model unavailable error")
        case .configuration(let detail):
            return detail
        case .unknown(let detail):
            return detail
        }
    }

    /// Whether this error is likely retryable
    var isRetryable: Bool {
        switch self {
        case .rateLimit, .network, .unknown:
            return true
        case .authentication, .quota, .modelUnavailable, .configuration:
            return false
        }
    }

    // MARK: - Categorization

    /// Create an error category from an AIProviderError
    static func from(_ error: Error) -> AIAgentErrorCategory {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .notConfigured:
                return .configuration("API key not configured. Please set it in Settings.")
            case .invalidAPIKey:
                return .authentication
            case .rateLimited(let retryAfter):
                return .rateLimit(retryAfter: retryAfter)
            case .quotaExceeded:
                return .quota
            case .modelNotAvailable(let model):
                return .modelUnavailable(model)
            case .networkError(let message):
                return .network(message)
            case .invalidResponse(let message):
                return .unknown("Invalid response: \(message)")
            case .toolCallFailed(let message):
                return .unknown("Tool call failed: \(message)")
            case .cancelled:
                // Cancelled is not really an error to show
                return .unknown("Request was cancelled")
            case .unknown(let message):
                return .unknown(message)
            }
        }

        // Handle other error types
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(error.localizedDescription)
        }

        return .unknown(error.localizedDescription)
    }

    // MARK: - Equatable

    static func == (lhs: AIAgentErrorCategory, rhs: AIAgentErrorCategory) -> Bool {
        switch (lhs, rhs) {
        case (.rateLimit(let lhsRetry), .rateLimit(let rhsRetry)):
            return lhsRetry == rhsRetry
        case (.network(let lhsMsg), .network(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.authentication, .authentication):
            return true
        case (.quota, .quota):
            return true
        case (.modelUnavailable(let lhsModel), .modelUnavailable(let rhsModel)):
            return lhsModel == rhsModel
        case (.configuration(let lhsMsg), .configuration(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.unknown(let lhsMsg), .unknown(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}
#endif
