import Foundation
import Combine
import os.log

// MARK: - Cloud Account Manager

/// Manages cloud provider accounts with CRUD operations
@MainActor
class CloudAccountManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CloudAccountManager")

    static let shared = CloudAccountManager()

    private static let accountsMetadataKey = "cloudAccountsMetadata"

    // MARK: - Published State

    /// All saved cloud accounts (metadata only, credentials in Keychain)
    @Published private(set) var accounts: [CloudAccount] = []

    /// Publisher for account changes
    let accountsDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Dependencies

    private let keychainManager: KeychainManager
    private let providerRegistry: CloudProviderRegistry

    // MARK: - Initialization

    private init() {
        self.keychainManager = KeychainManager.shared
        self.providerRegistry = CloudProviderRegistry.shared
        registerBuiltInProviders()
        loadAccounts()
    }

    private func registerBuiltInProviders() {
        providerRegistry.register(LinodeProvider.self)
        providerRegistry.register(DigitalOceanProvider.self)
        providerRegistry.register(AWSProvider.self)
        providerRegistry.register(AzureProvider.self)
        Self.logger.info("Registered \(self.providerRegistry.providerIDs.count) cloud providers")
    }

    // MARK: - Account CRUD

    /// Adds a new cloud account
    /// - Parameters:
    ///   - providerID: The provider identifier (e.g., "linode")
    ///   - label: User-friendly name for the account
    ///   - authMethod: Authentication method used
    ///   - credentials: The credentials to store
    ///   - awsRegion: AWS region (only for AWS accounts)
    /// - Returns: The created account
    /// - Throws: Error if account creation fails
    @discardableResult
    func addAccount(
        providerID: String,
        label: String,
        authMethod: CloudAuthMethod,
        credentials: CloudCredentials,
        awsRegion: String? = nil
    ) throws -> CloudAccount {
        Self.logger.info("Adding cloud account: \(label) (\(providerID))")

        // Validate provider exists
        guard providerRegistry.provider(for: providerID) != nil else {
            throw AccountError.unknownProvider(providerID)
        }

        // Create account
        let account = CloudAccount(
            id: credentials.accountID,
            providerID: providerID,
            label: label,
            authMethod: authMethod,
            awsRegion: awsRegion
        )

        // Save credentials to Keychain
        do {
            let credentialsData = try JSONEncoder().encode(credentials)
            try keychainManager.saveCloudCredentials(credentialsData, identifier: account.id.uuidString)
        } catch {
            Self.logger.error("Failed to save credentials: \(error.localizedDescription)")
            throw AccountError.keychainError(error)
        }

        // Add to accounts list
        accounts.append(account)
        saveAccounts()
        accountsDidChange.send()

        Self.logger.info("Added cloud account: \(account.id.uuidString)")
        return account
    }

    /// Updates an existing account
    /// - Parameter account: The account with updated values
    func updateAccount(_ account: CloudAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            Self.logger.warning("Cannot update unknown account: \(account.id.uuidString)")
            return
        }

        accounts[index] = account
        saveAccounts()
        accountsDidChange.send()
        Self.logger.info("Updated cloud account: \(account.id.uuidString)")
    }

    /// Updates account metadata after a sync
    /// - Parameters:
    ///   - accountID: The account to update
    ///   - providerAccountID: Account ID from the provider
    ///   - displayName: Display name from the provider
    func updateAccountInfo(
        accountID: UUID,
        providerAccountID: String?,
        displayName: String?
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }

        accounts[index].providerAccountID = providerAccountID
        accounts[index].providerDisplayName = displayName
        accounts[index].lastSyncDate = Date()
        saveAccounts()
        accountsDidChange.send()
    }

    /// Deletes an account
    /// - Parameter id: The account ID to delete
    /// - Throws: Error if deletion fails
    func deleteAccount(id: UUID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountError.accountNotFound
        }

        Self.logger.info("Deleting cloud account: \(id.uuidString)")

        // Delete credentials from Keychain
        do {
            try keychainManager.deleteCloudCredentials(identifier: id.uuidString)
        } catch {
            Self.logger.error("Failed to delete credentials: \(error.localizedDescription)")
            throw AccountError.keychainError(error)
        }

        // Remove from accounts list
        accounts.remove(at: index)
        saveAccounts()
        accountsDidChange.send()

        Self.logger.info("Deleted cloud account: \(id.uuidString)")
    }

    // MARK: - Credentials Access

    /// Loads credentials for an account
    /// - Parameter accountID: The account ID
    /// - Returns: The credentials
    /// - Throws: Error if loading fails
    func getCredentials(for accountID: UUID) throws -> CloudCredentials {
        let data = try keychainManager.loadCloudCredentials(identifier: accountID.uuidString)
        return try JSONDecoder().decode(CloudCredentials.self, from: data)
    }

    /// Updates credentials for an account
    /// - Parameter credentials: The new credentials
    /// - Throws: Error if update fails
    func updateCredentials(_ credentials: CloudCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try keychainManager.updateCloudCredentials(data, identifier: credentials.accountID.uuidString)
    }

    /// Returns ready-to-use AWS credentials, refreshing SSO/STS tokens on demand.
    ///
    /// AI Agent chat sessions can outlive the 8-hour STS lifetime, so the Bedrock
    /// provider calls this helper before every request rather than relying on the
    /// periodic Cloud sync to keep credentials fresh. For static Access-Key
    /// accounts the call returns immediately with the long-lived credentials;
    /// for SSO accounts it refreshes the SSO access token and/or the STS role
    /// credentials as needed and writes the updated `CloudCredentials` back to
    /// the Keychain.
    func getRefreshedAWSCredentials(for accountID: UUID) async throws -> AWSCredentials {
        var credentials = try getCredentials(for: accountID)
        guard credentials.providerID == AWSProvider.providerID else {
            throw AccountError.invalidCredentials
        }

        switch credentials.authMethod {
        case .awsAccessKey:
            guard let awsCreds = credentials.awsCredentials else {
                throw AccountError.invalidCredentials
            }
            return awsCreds

        case .awsSSO:
            let flowManager = AWSSSOFlowManager()
            var didChange = false

            // The SSO access token (issued to the device) authorizes the call
            // that fetches role credentials below — refresh it first if it's
            // near expiry so the subsequent portal call doesn't 401.
            if credentials.needsSSOTokenRefresh, let session = credentials.awsSSOSession {
                let refreshed = try await flowManager.refreshToken(session: session)
                credentials.awsSSOSession = refreshed
                didChange = true
            }

            // STS role credentials live ~1 hour; mint fresh ones whenever the
            // current set is missing or near expiry.
            let stsNeedsRefresh = credentials.awsSTSCredentials?.needsRefresh ?? true
            if stsNeedsRefresh,
               let session = credentials.awsSSOSession,
               let accountId = credentials.awsSSOAccountId,
               let roleName = credentials.awsSSORole {
                let newSTS = try await flowManager.getCredentials(
                    session: session,
                    accountId: accountId,
                    roleName: roleName
                )
                credentials.awsSTSCredentials = newSTS
                didChange = true
            }

            if didChange {
                try updateCredentials(credentials)
            }

            guard let awsCreds = credentials.awsCredentials else {
                throw AccountError.invalidCredentials
            }
            return awsCreds

        default:
            throw AccountError.invalidCredentials
        }
    }

    // MARK: - API Client Factory

    /// Creates an API client for an account
    /// - Parameter accountID: The account ID
    /// - Returns: The API client
    /// - Throws: Error if client creation fails
    func createAPIClient(for accountID: UUID) throws -> any CloudProviderAPIClient {
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

    /// Gets an account by ID
    /// - Parameter id: The account ID
    /// - Returns: The account if found
    func account(for id: UUID) -> CloudAccount? {
        accounts.first(where: { $0.id == id })
    }

    /// Gets accounts for a specific provider
    /// - Parameter providerID: The provider ID
    /// - Returns: Accounts for that provider
    func accounts(for providerID: String) -> [CloudAccount] {
        accounts.filter { $0.providerID == providerID }
    }

    /// Total account count
    var accountCount: Int {
        accounts.count
    }

    /// Whether there are any accounts
    var hasAccounts: Bool {
        !accounts.isEmpty
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsMetadataKey),
              let accounts = try? JSONDecoder().decode([CloudAccount].self, from: data) else {
            self.accounts = []
            Self.logger.info("No saved cloud accounts found")
            return
        }
        self.accounts = accounts
        Self.logger.info("Loaded \(accounts.count) cloud accounts")
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
        case invalidCredentials

        var errorDescription: String? {
            switch self {
            case .unknownProvider(let id):
                return "Unknown cloud provider: \(id)"
            case .accountNotFound:
                return "Account not found"
            case .keychainError(let error):
                return "Keychain error: \(error.localizedDescription)"
            case .invalidCredentials:
                return "Invalid credentials"
            }
        }
    }
}
