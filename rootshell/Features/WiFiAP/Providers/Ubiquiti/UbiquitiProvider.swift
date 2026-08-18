import Foundation

// MARK: - Ubiquiti Provider

struct UbiquitiProvider: WiFiAPProvider {
    nonisolated static let providerID = "ubiquiti"
    nonisolated static let displayName = "Ubiquiti (UniFi)"
    nonisolated static let iconName = "wifi.router"
    nonisolated static let logoImageName: String? = nil
    nonisolated static let supportedAuthMethods: [WiFiAPAuthMethod] = [.apiKey]

    static let apiKeyHelpURL = URL(string: "https://unifi.ui.com/")!

    static func createAPIClient(credentials: WiFiAPCredentials) -> any WiFiAPProviderAPIClient {
        UbiquitiAPIClient(credentials: credentials, accountID: credentials.accountID)
    }
}
