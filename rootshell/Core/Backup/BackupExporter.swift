import Foundation
import LocalAuthentication
import os.log

enum BackupExporter {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BackupExporter")

    // MARK: - Gather All

    @MainActor
    static func gatherPayload(
        categories: Set<BackupCategory>,
        laContext: LAContext?
    ) async throws -> (BackupPayload, ExportSummary) {
        var cats = BackupCategories()
        var summary = ExportSummary()

        if categories.contains(.sshKeys) {
            let result = gatherSSHKeys(context: laContext)
            cats.sshKeys = result.backup
            summary.categoryCounts[.sshKeys] = result.backup.entries.count
            summary.skippedKeys = result.skippedKeyNames
        }

        if categories.contains(.sshPasswords) {
            let result = await gatherSSHPasswords()
            cats.sshPasswords = result
            summary.categoryCounts[.sshPasswords] = result.entries.count
        }

        if categories.contains(.connectionHistory) {
            let entries = gatherConnectionHistory()
            cats.connectionHistory = entries
            summary.categoryCounts[.connectionHistory] = entries.count
        }

        if categories.contains(.knownHosts) {
            let hosts = gatherKnownHosts()
            cats.knownHosts = hosts
            summary.categoryCounts[.knownHosts] = hosts.count
        }

        if categories.contains(.connectionProfiles) {
            let profiles = gatherConnectionProfiles()
            cats.connectionProfiles = profiles
            summary.categoryCounts[.connectionProfiles] = profiles.count
        }

        if categories.contains(.customThemes) {
            let themes = gatherCustomThemes()
            cats.customThemes = themes
            summary.categoryCounts[.customThemes] = themes.themes.count
        }

        if categories.contains(.customFonts) {
            let fonts = gatherCustomFonts()
            cats.customFonts = fonts
            summary.categoryCounts[.customFonts] = fonts.families.count
        }

        if categories.contains(.keybindOverrides) {
            if let data = gatherKeybindOverrides() {
                cats.keybindOverrides = data
                summary.categoryCounts[.keybindOverrides] = 1
            }
            if let config = gatherImportedKeybindConfig() {
                cats.importedKeybindConfig = config
            }
        }

        if categories.contains(.hssConfig) {
            if let config = gatherHSSConfig() {
                cats.hssConfig = config
                summary.categoryCounts[.hssConfig] = 1
            }
        }

        if categories.contains(.cloudAccounts) {
            let accounts = gatherCloudAccounts()
            cats.cloudAccounts = accounts
            summary.categoryCounts[.cloudAccounts] = accounts.entries.count
        }

        #if !CHINA_BUILD
        if categories.contains(.aiSettings) {
            let ai = gatherAISettings()
            cats.aiSettings = ai
            summary.categoryCounts[.aiSettings] = ai.apiKeys.count + (ai.settings.isEmpty ? 0 : 1)
        }
        #endif

        if categories.contains(.appPreferences) {
            let prefs = gatherAppPreferences()
            cats.appSettings = prefs
            summary.categoryCounts[.appPreferences] = prefs.count
        }

        if categories.contains(.wifiAPManualEntries) {
            let manualAPs = gatherWiFiAPManualEntries()
            cats.wifiAPManualEntries = manualAPs
            summary.categoryCounts[.wifiAPManualEntries] = manualAPs.accessPoints.count
        }

        let payload = BackupPayload(
            version: 1,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            deviceName: deviceName(),
            categories: cats
        )

        return (payload, summary)
    }

    // MARK: - SSH Keys

    @MainActor
    static func gatherSSHKeys(context: LAContext?) -> (backup: SSHKeysBackup, skippedKeyNames: [String]) {
        let keyManager = SSHKeyManager.shared
        let keychainManager = KeychainManager.shared
        var entries: [SSHKeyBackupEntry] = []
        var skippedNames: [String] = []

        for key in keyManager.savedKeys {
            let privateKeyData: Data
            do {
                privateKeyData = try keychainManager.loadPrivateKey(
                    identifier: key.id.uuidString,
                    authRequirement: key.authRequirement,
                    context: context
                )
            } catch {
                logger.warning("Skipping key '\(key.name)': \(error.localizedDescription)")
                skippedNames.append(key.name)
                continue
            }

            var exportKeyData = privateKeyData
            var exportMetadata = key

            // Legacy-encrypted blobs are exported normalized (decrypted); an
            // encrypted entry without its passphrase could never restore.
            if let keyString = String(data: privateKeyData, encoding: .utf8) {
                let passphrase = keychainManager.loadPassphrase(forKey: key.id.uuidString)
                do {
                    switch try OpenSSHKeyNormalizer.normalize(keyString: keyString, passphrase: passphrase) {
                    case .normalized(let text):
                        exportKeyData = Data(text.utf8)
                        exportMetadata.hasPassphrase = false
                    case .alreadyPlaintext, .notOpenSSHContainer:
                        exportMetadata.hasPassphrase = false
                    }
                } catch {
                    logger.warning("Skipping key '\(key.name)': encrypted with no usable local passphrase")
                    skippedNames.append(key.name)
                    continue
                }
            }

            entries.append(SSHKeyBackupEntry(
                metadata: exportMetadata,
                privateKeyData: exportKeyData
            ))
        }

        return (SSHKeysBackup(entries: entries, defaultKeyIDs: keyManager.defaultKeyIDs), skippedNames)
    }

    // MARK: - SSH Passwords

    @MainActor
    static func gatherSSHPasswords() async -> SSHPasswordsBackup {
        let passwordManager = SSHPasswordManager.shared
        var entries: [SSHPasswordBackupEntry] = []

        for saved in passwordManager.savedPasswords {
            do {
                let password = try await passwordManager.loadPassword(connectionKey: saved.connectionKey)
                entries.append(SSHPasswordBackupEntry(metadata: saved, password: password))
            } catch {
                logger.warning("Skipping password for \(saved.connectionKey): \(error.localizedDescription)")
            }
        }

        return SSHPasswordsBackup(entries: entries)
    }

    // MARK: - Connection History

    @MainActor
    static func gatherConnectionHistory() -> [SSHConnectionHistoryEntry] {
        SSHConnectionHistoryManager.shared.entries
    }

    // MARK: - Known Hosts

    @MainActor
    static func gatherKnownHosts() -> [KnownHost] {
        KnownHostsManager.shared.allHosts
    }

    // MARK: - Connection Profiles

    @MainActor
    static func gatherConnectionProfiles() -> [ConnectionProfile] {
        ConnectionProfileManager.shared.profiles
    }

    // MARK: - Custom Themes

    @MainActor
    static func gatherCustomThemes() -> CustomThemesBackup {
        let themeManager = CustomThemeManager.shared
        var entries: [CustomThemeBackupEntry] = []

        for theme in themeManager.customThemes {
            let content = theme.toGhosttyFileContent()
            entries.append(CustomThemeBackupEntry(theme: theme, themeFileContent: content))
        }

        return CustomThemesBackup(themes: entries)
    }

    // MARK: - Custom Fonts

    @MainActor
    static func gatherCustomFonts() -> CustomFontsBackup {
        let fontManager = FontManager.shared
        var entries: [CustomFontBackupEntry] = []

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fontsDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)

        for family in fontManager.customFontFamilies {
            var fontFiles: [FontFileData] = []

            for file in family.fontFiles {
                let filePath = fontsDir.appendingPathComponent(file.filename)
                if let data = try? Data(contentsOf: filePath) {
                    fontFiles.append(FontFileData(
                        filename: file.filename,
                        originalName: file.originalName,
                        data: data
                    ))
                }
            }

            if !fontFiles.isEmpty {
                entries.append(CustomFontBackupEntry(family: family, fontFiles: fontFiles))
            }
        }

        // Include which bundled families were replaced by custom imports
        let replaced = UserDefaults.standard.stringArray(forKey: "replacedBundledFamilies")

        return CustomFontsBackup(families: entries, replacedBundledFamilies: replaced)
    }

    // MARK: - Keybind Overrides

    @MainActor
    static func gatherKeybindOverrides() -> Data? {
        UserDefaults.standard.data(forKey: "keybindOverrides")
    }

    @MainActor
    static func gatherImportedKeybindConfig() -> ImportedKeybindConfigBackup? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let configPath = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("imported_keybinds.conf")

        guard FileManager.default.fileExists(atPath: configPath.path),
              let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }

        let filename = UserDefaults.standard.string(forKey: "externalGhosttyConfigPath_originalFilename")
        return ImportedKeybindConfigBackup(configContent: content, originalFilename: filename)
    }

    // MARK: - HSS Config

    @MainActor
    static func gatherHSSConfig() -> HSSConfigBackup? {
        let filename = UserDefaults.standard.string(forKey: "hss_config_filename")

        #if targetEnvironment(macCatalyst)
        // Mac Catalyst: resolve security-scoped bookmark to read the file
        guard let bookmarkData = UserDefaults.standard.data(forKey: "hss_config_bookmark") else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else {
            return nil
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return HSSConfigBackup(yamlContent: content, filename: filename)
        #else
        // iOS: read from the copied file in Documents
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let hssPath = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("hss_config.yml")

        guard FileManager.default.fileExists(atPath: hssPath.path),
              let content = try? String(contentsOf: hssPath, encoding: .utf8) else {
            return nil
        }
        return HSSConfigBackup(yamlContent: content, filename: filename)
        #endif
    }

    // MARK: - Cloud Accounts

    @MainActor
    static func gatherCloudAccounts() -> CloudAccountsBackup {
        let accountManager = CloudAccountManager.shared
        let keychainManager = KeychainManager.shared
        var entries: [CloudAccountBackupEntry] = []

        for account in accountManager.accounts {
            let credentialsData: Data
            do {
                credentialsData = try keychainManager.loadCloudCredentials(identifier: account.id.uuidString)
            } catch {
                logger.warning("Skipping cloud account '\(account.label)': credentials not accessible")
                continue
            }

            entries.append(CloudAccountBackupEntry(account: account, credentialsData: credentialsData))
        }

        return CloudAccountsBackup(entries: entries)
    }

    // MARK: - AI Settings

    #if !CHINA_BUILD
    @MainActor
    static func gatherAISettings() -> AISettingsBackup {
        let credManager = AICredentialsManager.shared

        var apiKeys: [AIAPIKeyEntry] = []
        // "chatgpt-codex" holds the JSON-encoded ChatGPT OAuth credential; it
        // round-trips through the same string path as the plain API keys. A
        // restored refresh token may have been rotated by another device, in
        // which case first use fails with invalid_grant and the UI shows
        // signed-out.
        let accountNames = ["anthropic", "google", "openai", "openrouter", "chatgpt-codex"]

        for name in accountNames {
            if let key = credManager.loadAPIKey(for: name) {
                apiKeys.append(AIAPIKeyEntry(accountName: name, apiKey: key))
            }
        }

        // Also gather custom provider API keys
        for provider in credManager.customProviders {
            if let key = credManager.loadAPIKey(for: provider) {
                apiKeys.append(AIAPIKeyEntry(accountName: provider.keychainAccount, apiKey: key))
            }
        }

        // Gather ALL ai.* UserDefaults keys (including per-provider suffixed keys
        // like ai.selectedModel.<provider> and ai.temperature.<provider>)
        var settings: [String: CodableValue] = [:]
        if let bundleID = Bundle.main.bundleIdentifier,
           let allDefaults = UserDefaults.standard.persistentDomain(forName: bundleID) {
            for (key, _) in allDefaults where key.hasPrefix("ai.") {
                if let value = readUserDefaultsValue(key: key) {
                    settings[key] = value
                }
            }
        }

        return AISettingsBackup(apiKeys: apiKeys, settings: settings)
    }
    #endif

    // MARK: - App Preferences

    /// Keys that should NOT be backed up — ephemeral state, device-specific IDs,
    /// migration flags, sync tokens, or data already handled by dedicated categories.
    private static let excludedPrefKeys: Set<String> = [
        // CloudKit sync state (device-specific, will be re-established)
        "cloudKitSyncEnabled", "cloudKitSyncHistory", "cloudKitSyncKnownHosts",
        "cloudKitSyncProfiles", "cloudKitLastSyncDate", "cloudKitZoneChangeToken",
        "cloudKitMigratedToCustomZone", "cloudKitDeviceID",
        // Migration flags (one-time, should re-run on fresh install)
        "sshKeysMetadataMigratedToKeychain", "nerdFontFamilyMigrationDone",
        // Data handled by dedicated backup categories
        "sshKeysMetadata", "defaultSSHKeyIDs", "cloudAccountsMetadata", "customFontFamilies",
        "keybindOverrides", "hss_config_filepath", "hss_config_filename",
        "hss_config_bookmark",
        "externalGhosttyConfigPath", "externalGhosttyConfigPath_originalFilename",
        // AI settings handled by dedicated backup category (all ai.* keys)
        // macOS Catalyst-only bookmarks (not portable)
        "externalGhosttyConfigPath_bookmark",
        // Ephemeral / runtime state
        "videoBackgroundPausedDownloads",
        // Apple system keys
        "ApplePressAndHoldEnabled",
    ]

    /// Prefixes for Apple/system keys that should never be backed up.
    private static let excludedPrefPrefixes = [
        "com.apple.", "Apple", "NS", "AK", "INNext", "PK",
    ]

    @MainActor
    static func gatherAppPreferences() -> [String: CodableValue] {
        var prefs: [String: CodableValue] = [:]

        guard let bundleID = Bundle.main.bundleIdentifier else { return prefs }

        // Get all keys from the app's UserDefaults domain
        let allKeys = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]

        for key in allKeys.keys {
            // Skip excluded keys
            if excludedPrefKeys.contains(key) { continue }

            // Skip keys with excluded prefixes
            if excludedPrefPrefixes.contains(where: { key.hasPrefix($0) }) { continue }

            // Skip AI temperature keys (handled by AI settings category)
            if key.hasPrefix("ai.") { continue }

            if let codable = readUserDefaultsValue(key: key) {
                prefs[key] = codable
            }
        }

        return prefs
    }

    // MARK: - WiFi AP Manual Entries

    @MainActor
    static func gatherWiFiAPManualEntries() -> WiFiAPManualEntriesBackup {
        let manager = ManualAPManager.shared
        return WiFiAPManualEntriesBackup(
            accessPoints: manager.manualAPs,
            vendorDomains: manager.vendorDomains
        )
    }

    // MARK: - Helpers

    private static func readUserDefaultsValue(key: String) -> CodableValue? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return nil }

        if let s = defaults.string(forKey: key) {
            return .string(s)
        }
        if let d = defaults.data(forKey: key) {
            return .data(d)
        }
        if let arr = defaults.stringArray(forKey: key) {
            return .stringArray(arr)
        }

        // Check numeric types
        let obj = defaults.object(forKey: key)
        if let b = obj as? Bool {
            return .bool(b)
        }
        if let i = obj as? Int {
            return .int(i)
        }
        if let d = obj as? Double {
            return .double(d)
        }

        return nil
    }

    private static func deviceName() -> String {
        #if targetEnvironment(macCatalyst)
        return ProcessInfo.processInfo.hostName
        #else
        return UIDevice.current.name
        #endif
    }
}
