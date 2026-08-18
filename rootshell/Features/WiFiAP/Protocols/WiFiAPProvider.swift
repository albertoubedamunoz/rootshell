import Foundation

// MARK: - WiFi AP Provider Protocol

/// Protocol for WiFi AP management providers (Ubiquiti, Ruckus, etc.)
protocol WiFiAPProvider {
    nonisolated static var providerID: String { get }
    nonisolated static var displayName: String { get }
    nonisolated static var iconName: String { get }
    nonisolated static var logoImageName: String? { get }
    nonisolated static var supportedAuthMethods: [WiFiAPAuthMethod] { get }
    static func createAPIClient(credentials: WiFiAPCredentials) -> any WiFiAPProviderAPIClient
}

// MARK: - Auth Method

enum WiFiAPAuthMethod: String, Codable, CaseIterable, Sendable {
    case apiKey = "api_key"

    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        }
    }
}

// MARK: - Provider Registry

@MainActor
class WiFiAPProviderRegistry {
    static let shared = WiFiAPProviderRegistry()

    private var providers: [String: any WiFiAPProvider.Type] = [:]

    private init() {
        register(UbiquitiProvider.self)
    }

    func register<P: WiFiAPProvider>(_ providerType: P.Type) {
        providers[P.providerID] = providerType
    }

    func provider(for providerID: String) -> (any WiFiAPProvider.Type)? {
        providers[providerID]
    }

    var availableProviders: [any WiFiAPProvider.Type] {
        Array(providers.values)
    }

    var providerIDs: [String] {
        Array(providers.keys)
    }
}
