#if !CHINA_BUILD
//
//  ChatGPTCredentialStore.swift
//  rootshell
//
//  Keychain-backed storage for Sign in with ChatGPT: the saved account
//  registrations, the active one's renewable session, and this device's
//  agent host ID. Refresh is single-flighted across concurrent requests.
//

import Foundation
import Security
import os.log

/// What the settings screen needs to render the account picker.
nonisolated struct ChatGPTAccountsSnapshot: Sendable {
    let active: ChatGPTRegistration?
    let saved: [ChatGPTRegistration]
}

/// Owns the ChatGPT registrations: persistence, expiry, refresh, and sign-out.
///
/// An actor because refresh tokens rotate: concurrent requests would each burn
/// a refresh token and race each other's writes, invalidating the losers.
actor ChatGPTCredentialStore {
    static let shared = ChatGPTCredentialStore()

    /// Refresh this far ahead of the real expiry so a request never starts with
    /// a token that dies mid-flight.
    private static let refreshSkew: TimeInterval = 60

    /// Same Keychain service and access group as the AI API keys, own accounts.
    private static let keychainService = "com.ghostty.ai.apikey"
    private static let keychainAccessGroup = AppIdentifiers.keychainAccessGroup
    /// Backed up with the API keys; see `BackupExporter.gatherAISettings`.
    static let keychainAccount = "chatgpt-siwc"
    /// Device-only and never backed up, so a restore can't copy another host's ID.
    private static let hostIDAccount = "chatgpt-siwc-host"
    /// The pre-SIWC credential minted under the Codex CLI client.
    static let legacyKeychainAccount = "chatgpt-codex"

    static let needsReconnectKey = "ai.chatgpt.needsReconnect"
    private static let legacyDefaultsKeys = [
        "ai.chatgpt.models", "ai.chatgpt.modelsRefreshDate", "ai.chatgpt.modelsClientVersion"
    ]

    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTCredentials")
    private var refreshTask: (clientID: String, task: Task<ChatGPTSession, Error>)?

    /// Synchronous mirror of "the active account can spend its ChatGPT plan",
    /// for `isConfigured` checks that must not touch the Keychain on the main thread.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var _isUsableCached = false

    nonisolated static var isUsableCached: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _isUsableCached
    }

    nonisolated private static func setCached(_ value: Bool) {
        cacheLock.lock()
        _isUsableCached = value
        cacheLock.unlock()
    }

    private init() {}

    // MARK: - Accounts file

    private nonisolated struct AccountsFile: Codable {
        var activeClientID: String?
        var registrations: [ChatGPTRegistration]

        var active: ChatGPTRegistration? {
            activeClientID.flatMap { id in registrations.first { $0.clientID == id } }
        }
    }

    private func loadFile() -> AccountsFile {
        guard let data = loadFromKeychain(account: Self.keychainAccount),
              let file = try? JSONDecoder().decode(AccountsFile.self, from: data) else {
            return AccountsFile(activeClientID: nil, registrations: [])
        }
        return file
    }

    private func saveFile(_ file: AccountsFile) {
        guard let data = try? JSONEncoder().encode(file) else {
            logger.error("Failed to encode ChatGPT accounts")
            return
        }
        saveToKeychain(data, account: Self.keychainAccount, accessible: kSecAttrAccessibleAfterFirstUnlock)
        Self.setCached(file.active?.canUsePlan ?? false)
    }

    private func update(clientID: String, _ body: (inout ChatGPTRegistration) -> Void) {
        var file = loadFile()
        guard let index = file.registrations.firstIndex(where: { $0.clientID == clientID }) else { return }
        body(&file.registrations[index])
        saveFile(file)
    }

    // MARK: - Queries

    func snapshot() -> ChatGPTAccountsSnapshot {
        let file = loadFile()
        return ChatGPTAccountsSnapshot(active: file.active, saved: file.registrations)
    }

    /// Recomputes the synchronous cache. Call on launch and after backup restore.
    @discardableResult
    func refreshCachedState() -> Bool {
        let usable = loadFile().active?.canUsePlan ?? false
        Self.setCached(usable)
        return usable
    }

    // MARK: - Host identity

    /// This device's stable `ext_agent_host_id`, created on first use.
    func hostID() -> String {
        if let data = loadFromKeychain(account: Self.hostIDAccount),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let created = "urn:uuid:" + UUID().uuidString.lowercased()
        saveToKeychain(
            Data(created.utf8),
            account: Self.hostIDAccount,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        return created
    }

    // MARK: - Sign-in results

    /// Saves a freshly validated sign-in and makes it the active account.
    /// Upserts by issued client ID; a new registration gets a distinct label.
    @discardableResult
    func install(_ registration: ChatGPTRegistration) -> ChatGPTRegistration {
        var file = loadFile()
        var stored = registration

        if let index = file.registrations.firstIndex(where: { $0.clientID == registration.clientID }) {
            stored.label = file.registrations[index].label
            file.registrations[index] = stored
        } else {
            let base = registration.email ?? String(localized: "ChatGPT account")
            let taken = Set(file.registrations.map(\.label))
            var label = base
            var suffix = 2
            while taken.contains(label) {
                label = "\(base) (\(suffix))"
                suffix += 1
            }
            stored.label = label
            file.registrations.append(stored)
        }

        file.activeClientID = stored.clientID
        saveFile(file)
        UserDefaults.standard.removeObject(forKey: Self.needsReconnectKey)
        return stored
    }

    /// Switches to a saved account that still holds a session.
    func activate(clientID: String) -> Bool {
        var file = loadFile()
        guard file.registrations.contains(where: { $0.clientID == clientID && $0.isSignedIn }) else {
            return false
        }
        file.activeClientID = clientID
        saveFile(file)
        return true
    }

    /// Ends the active account's renewable session: revokes the refresh token,
    /// then clears the tokens while keeping the client mapping for a later sign-in.
    /// - Returns: whether OpenAI confirmed the revocation.
    func signOut() async -> Bool {
        let file = loadFile()
        guard let active = file.active, let session = active.session else { return true }

        if refreshTask?.clientID == active.clientID {
            refreshTask?.task.cancel()
            refreshTask = nil
        }

        // Stop requests before the network round trip.
        Self.setCached(false)
        let confirmed = await ChatGPTOAuth.revoke(refreshToken: session.refreshToken, clientID: active.clientID)
        if !confirmed {
            logger.warning("ChatGPT session revocation was not confirmed")
        }

        update(clientID: active.clientID) {
            $0.session = nil
            $0.idToken = nil
        }
        return confirmed
    }

    // MARK: - Access tokens

    /// The active account's session, fresh for at least the refresh skew.
    /// - Parameter forceRefresh: bypass the expiry check, e.g. after a 401.
    func validSession(forceRefresh: Bool = false) async throws -> ChatGPTSession {
        guard let active = loadFile().active, let current = active.session else {
            Self.setCached(false)
            throw ChatGPTAuthError.notSignedIn
        }
        guard current.canUsePlan else {
            throw ChatGPTAuthError.planNotEnabled
        }

        if !forceRefresh, Date().addingTimeInterval(Self.refreshSkew) < current.expiryDate {
            return current
        }

        // Join an in-flight refresh rather than starting a second one.
        if let refreshTask, refreshTask.clientID == active.clientID {
            return try await refreshTask.task.value
        }

        let clientID = active.clientID
        let task = Task<ChatGPTSession, Error> {
            let response = try await ChatGPTOAuth.refresh(refreshToken: current.refreshToken, clientID: clientID)
            return response.session(fallbackScopes: current.scopes)
        }
        refreshTask = (clientID, task)
        defer {
            if refreshTask?.clientID == clientID { refreshTask = nil }
        }

        do {
            let refreshed = try await task.value
            // Access token, expiry, scopes, and the rotated refresh token land together.
            update(clientID: clientID) { $0.session = refreshed }
            logger.info("Refreshed ChatGPT access token")
            guard refreshed.canUsePlan else { throw ChatGPTAuthError.planNotEnabled }
            return refreshed
        } catch {
            logger.error("ChatGPT token refresh failed: \(error.localizedDescription, privacy: .public)")
            throw classifyRefreshFailure(error, clientID: clientID)
        }
    }

    private static let unusableRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"
    ]

    /// Clears tokens only for a terminal answer; network and 5xx failures keep them.
    private func classifyRefreshFailure(_ error: Error, clientID: String) -> Error {
        guard case ChatGPTAuthError.tokenEndpoint(_, let code, _) = error, let code else {
            return error
        }
        if Self.unusableRefreshCodes.contains(code) {
            update(clientID: clientID) { $0.session = nil }
            Self.notifySignedOut()
            return ChatGPTAuthError.sessionExpired
        }
        if code == "invalid_client" {
            return ChatGPTAuthError.invalidClient
        }
        return error
    }

    nonisolated private static func notifySignedOut() {
        Task { @MainActor in
            AICredentialsManager.shared.setChatGPTSignedIn(false)
        }
    }

    // MARK: - Migration

    /// Drops the credential minted under the Codex CLI client and its model
    /// cache. It can't be revoked without using that client ID again.
    /// - Returns: whether a legacy credential was removed.
    func migrateLegacyCredential() -> Bool {
        guard loadFromKeychain(account: Self.legacyKeychainAccount) != nil else { return false }
        deleteFromKeychain(account: Self.legacyKeychainAccount)
        for key in Self.legacyDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.needsReconnectKey)
        logger.info("Removed legacy ChatGPT credential; sign-in required")
        return true
    }

    // MARK: - Keychain

    // Own copies of the SecItem plumbing: AICredentialsManager's helpers are
    // MainActor-bound, and this actor must stay off the main thread.
    // Non-synchronizable on purpose — refresh tokens rotate, so an iCloud-synced
    // copy goes stale the moment another device refreshes.

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup
        ]
    }

    private func saveToKeychain(_ data: Data, account: String, accessible: CFString) {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessible
        query[kSecAttrSynchronizable as String] = false

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        }
        if status != errSecSuccess {
            logger.error("Keychain save failed: \(status)")
        }
    }

    private func loadFromKeychain(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed: \(status)")
        }
    }
}
#endif
