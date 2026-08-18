import Foundation
import Combine
import os.log

// MARK: - WiFi AP Account Manager

/// Manages WiFi AP provider accounts with CRUD operations
@MainActor
class WiFiAPAccountManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WiFiAPAccountManager")

    static let shared = WiFiAPAccountManager()

    private static let accountsMetadataKey = "wifiAPAccountsMetadata"

    // MARK: - Published State

    @Published private(set) var accounts: [WiFiAPAccount] = []

    let accountsDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Dependencies

    private let keychainManager: KeychainManager
    private let providerRegistry: WiFiAPProviderRegistry

    // MARK: - Initialization

    private init() {
        self.keychainManager = KeychainManager.shared
        self.providerRegistry = WiFiAPProviderRegistry.shared
        loadAccounts()
    }

    // MARK: - Account CRUD

    @discardableResult
    func addAccount(
        providerID: String,
        label: String,
        authMethod: WiFiAPAuthMethod,
        credentials: WiFiAPCredentials
    ) throws -> WiFiAPAccount {
        Self.logger.info("Adding WiFi AP account: \(label) (\(providerID))")

        guard providerRegistry.provider(for: providerID) != nil else {
            throw AccountError.unknownProvider(providerID)
        }

        let account = WiFiAPAccount(
            id: credentials.accountID,
            providerID: providerID,
            authMethod: authMethod,
            label: label
        )

        do {
            let credentialsData = try JSONEncoder().encode(credentials)
            try keychainManager.saveWiFiAPCredentials(credentialsData, identifier: account.id.uuidString)
        } catch {
            Self.logger.error("Failed to save credentials: \(error.localizedDescription)")
            throw AccountError.keychainError(error)
        }

        accounts.append(account)
        saveAccounts()
        accountsDidChange.send()

        Self.logger.info("Added WiFi AP account: \(account.id.uuidString)")
        return account
    }

    func updateAccount(_ account: WiFiAPAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            Self.logger.warning("Cannot update unknown account: \(account.id.uuidString)")
            return
        }

        accounts[index] = account
        saveAccounts()
        accountsDidChange.send()
    }

    func updateAccountSyncInfo(accountID: UUID, lastSyncDate: Date, deviceCount: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }

        accounts[index].lastSyncDate = lastSyncDate
        accounts[index].deviceCount = deviceCount
        saveAccounts()
        accountsDidChange.send()
    }

    func deleteAccount(id: UUID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountError.accountNotFound
        }

        Self.logger.info("Deleting WiFi AP account: \(id.uuidString)")

        do {
            try keychainManager.deleteWiFiAPCredentials(identifier: id.uuidString)
        } catch {
            Self.logger.error("Failed to delete credentials: \(error.localizedDescription)")
            throw AccountError.keychainError(error)
        }

        accounts.remove(at: index)
        saveAccounts()
        accountsDidChange.send()

        Self.logger.info("Deleted WiFi AP account: \(id.uuidString)")
    }

    // MARK: - Credentials Access

    func getCredentials(for accountID: UUID) throws -> WiFiAPCredentials {
        let data = try keychainManager.loadWiFiAPCredentials(identifier: accountID.uuidString)
        return try JSONDecoder().decode(WiFiAPCredentials.self, from: data)
    }

    func updateCredentials(_ credentials: WiFiAPCredentials) throws {
        let identifier = credentials.accountID.uuidString
        // Delete existing entry first since saveWiFiAPCredentials only does SecItemAdd
        try? keychainManager.deleteWiFiAPCredentials(identifier: identifier)
        let data = try JSONEncoder().encode(credentials)
        try keychainManager.saveWiFiAPCredentials(data, identifier: identifier)
    }

    // MARK: - API Client Factory

    func createAPIClient(for accountID: UUID) throws -> any WiFiAPProviderAPIClient {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountError.accountNotFound
        }

        guard let providerType = providerRegistry.provider(for: account.providerID) else {
            throw AccountError.unknownProvider(account.providerID)
        }

        let credentials = try getCredentials(for: accountID)
        return providerType.createAPIClient(credentials: credentials)
    }

    // MARK: - Account Queries

    func account(for id: UUID) -> WiFiAPAccount? {
        accounts.first(where: { $0.id == id })
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsMetadataKey),
              let accounts = try? JSONDecoder().decode([WiFiAPAccount].self, from: data) else {
            self.accounts = []
            return
        }
        self.accounts = accounts
        Self.logger.info("Loaded \(accounts.count) WiFi AP accounts")
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else {
            Self.logger.error("Failed to encode accounts")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.accountsMetadataKey)
    }

    // MARK: - Error Types

    enum AccountError: LocalizedError {
        case unknownProvider(String)
        case accountNotFound
        case keychainError(Error)

        var errorDescription: String? {
            switch self {
            case .unknownProvider(let id):
                return "Unknown WiFi AP provider: \(id)"
            case .accountNotFound:
                return "Account not found"
            case .keychainError(let error):
                return "Keychain error: \(error.localizedDescription)"
            }
        }
    }
}
