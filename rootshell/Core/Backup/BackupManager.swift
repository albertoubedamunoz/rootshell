import Foundation
import LocalAuthentication
import os.log

@MainActor
@Observable
final class BackupManager {
    static let shared = BackupManager()
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BackupManager")

    enum State: Equatable {
        case idle
        case exporting(progress: Double, category: String)
        case importing(progress: Double, category: String)
        case completed(isExport: Bool)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): true
            case (.exporting(let p1, let c1), .exporting(let p2, let c2)): p1 == p2 && c1 == c2
            case (.importing(let p1, let c1), .importing(let p2, let c2)): p1 == p2 && c1 == c2
            case (.completed(let e1), .completed(let e2)): e1 == e2
            case (.failed(let m1), .failed(let m2)): m1 == m2
            default: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var exportSummary: ExportSummary?
    private(set) var restoreSummary: RestoreSummary?
    private(set) var lastBackupURL: URL?

    private init() {}

    // MARK: - Create Backup

    func createBackup(categories: Set<BackupCategory>, password: String) async throws -> URL {
        state = .idle
        exportSummary = nil
        lastBackupURL = nil

        let categoryList = Array(categories)
        let totalSteps = Double(categoryList.count + 1) // +1 for encryption

        // Create LAContext for biometric auth if SSH keys are included
        var laContext: LAContext?
        if categories.contains(.sshKeys) {
            let context = LAContext()
            context.localizedReason = "Authenticate to include SSH keys in backup"
            laContext = context
        }

        // Gather data
        for (index, category) in categoryList.enumerated() {
            let progress = Double(index) / totalSteps
            state = .exporting(progress: progress, category: category.displayName)
            // Allow UI to update
            await Task.yield()
        }

        state = .exporting(progress: 0.5, category: "Gathering data...")

        let (payload, summary) = try await BackupExporter.gatherPayload(
            categories: categories,
            laContext: laContext
        )

        exportSummary = summary

        guard summary.totalItems > 0 else {
            throw BackupError.noDataToBackup
        }

        // Encode
        state = .exporting(progress: 0.8, category: "Encrypting...")
        await Task.yield()

        let jsonData: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            jsonData = try encoder.encode(payload)
        } catch {
            throw BackupError.encodingFailed(error)
        }

        // Encrypt
        let fileData: Data
        do {
            fileData = try BackupCrypto.encrypt(payload: jsonData, password: password)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.encryptionFailed(error)
        }

        // Write to temp file
        state = .exporting(progress: 0.95, category: "Saving...")
        await Task.yield()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let filename = "rootshell-backup-\(dateString).rootshellbackup"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try fileData.write(to: tempURL)
        } catch {
            throw BackupError.fileWriteFailed(error)
        }

        lastBackupURL = tempURL
        state = .completed(isExport: true)
        return tempURL
    }

    // MARK: - Validate Backup

    func validateBackup(at url: URL, password: String) async throws -> BackupManifest {
        let fileData: Data
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            fileData = try Data(contentsOf: url)
        } catch {
            throw BackupError.fileReadFailed(error)
        }

        let plaintext: Data
        do {
            plaintext = try BackupCrypto.decrypt(fileData: fileData, password: password)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.decryptionFailed(error)
        }

        let payload: BackupPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(BackupPayload.self, from: plaintext)
        } catch {
            throw BackupError.decodingFailed(error)
        }

        guard payload.version == 1 else {
            throw BackupError.unsupportedVersion(payload.version)
        }

        // Build category counts
        var counts: [BackupCategory: Int] = [:]
        let cats = payload.categories

        if let keys = cats.sshKeys { counts[.sshKeys] = keys.entries.count }
        if let passwords = cats.sshPasswords { counts[.sshPasswords] = passwords.entries.count }
        if let history = cats.connectionHistory { counts[.connectionHistory] = history.count }
        if let hosts = cats.knownHosts { counts[.knownHosts] = hosts.count }
        if let profiles = cats.connectionProfiles { counts[.connectionProfiles] = profiles.count }
        if let themes = cats.customThemes { counts[.customThemes] = themes.themes.count }
        if let fonts = cats.customFonts { counts[.customFonts] = fonts.families.count }
        if cats.keybindOverrides != nil { counts[.keybindOverrides] = 1 }
        if cats.hssConfig != nil { counts[.hssConfig] = 1 }
        if let cloud = cats.cloudAccounts { counts[.cloudAccounts] = cloud.entries.count }
        if let ai = cats.aiSettings { counts[.aiSettings] = ai.apiKeys.count + (ai.settings.isEmpty ? 0 : 1) }
        if let prefs = cats.appSettings { counts[.appPreferences] = prefs.count }
        if let manual = cats.wifiAPManualEntries { counts[.wifiAPManualEntries] = manual.accessPoints.count }

        return BackupManifest(
            version: payload.version,
            createdAt: payload.createdAt,
            appVersion: payload.appVersion,
            appBuild: payload.appBuild,
            deviceName: payload.deviceName,
            categoryCounts: counts
        )
    }

    // MARK: - Restore Backup

    func restoreBackup(
        at url: URL,
        password: String,
        categories: Set<BackupCategory>
    ) async throws -> RestoreSummary {
        state = .idle
        restoreSummary = nil

        state = .importing(progress: 0.1, category: "Decrypting...")
        await Task.yield()

        let fileData: Data
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            fileData = try Data(contentsOf: url)
        } catch {
            throw BackupError.fileReadFailed(error)
        }

        let plaintext: Data
        do {
            plaintext = try BackupCrypto.decrypt(fileData: fileData, password: password)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.decryptionFailed(error)
        }

        state = .importing(progress: 0.2, category: "Decoding...")
        await Task.yield()

        let payload: BackupPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(BackupPayload.self, from: plaintext)
        } catch {
            throw BackupError.decodingFailed(error)
        }

        guard payload.version == 1 else {
            throw BackupError.unsupportedVersion(payload.version)
        }

        // Restore each category with progress updates
        let categoryList = Array(categories)
        let totalSteps = Double(categoryList.count)

        for (index, category) in categoryList.enumerated() {
            let progress = 0.3 + (0.7 * Double(index) / totalSteps)
            state = .importing(progress: progress, category: category.displayName)
            await Task.yield()
        }

        state = .importing(progress: 0.5, category: "Restoring...")
        await Task.yield()

        let summary = await BackupImporter.restoreAll(payload: payload, categories: categories)

        logPostRestoreDiagnostics(payload: payload, categories: categories, summary: summary)

        restoreSummary = summary
        state = .completed(isExport: false)
        return summary
    }

    /// Dump a snapshot of local state immediately after a restore so we can tell whether
    /// records actually made it to disk vs were later overwritten by CloudKit or another path.
    /// Compare against the diagnostics dump on the next app launch.
    private func logPostRestoreDiagnostics(
        payload: BackupPayload,
        categories: Set<BackupCategory>,
        summary: RestoreSummary
    ) {
        Self.logger.info("=== Post-restore diagnostics ===")
        let categoryList = categories.map(\.rawValue).sorted().joined(separator: ", ")
        Self.logger.info("Categories requested: \(categoryList)")

        if categories.contains(.connectionProfiles), let backupProfiles = payload.categories.connectionProfiles {
            let backupCount = backupProfiles.count
            let backupIDs = backupProfiles.map(\.id.uuidString).sorted().joined(separator: ", ")
            let restored = summary.results[.connectionProfiles]?.restored ?? 0
            let errors = summary.results[.connectionProfiles]?.errors.count ?? 0
            let activeNow = ConnectionProfileManager.shared.profiles.count
            let totalNow = ConnectionProfileManager.shared.allRecordsForSync.count
            Self.logger.info("Profiles: backup contained \(backupCount), restore reported \(restored) applied (\(errors) errors), local now has \(activeNow) active / \(totalNow) total (incl \(totalNow - activeNow) tombstones)")
            Self.logger.info("Profile IDs from backup: \(backupIDs)")
        }

        if categories.contains(.connectionHistory), let backupHistory = payload.categories.connectionHistory {
            let backupCount = backupHistory.count
            let restored = summary.results[.connectionHistory]?.restored ?? 0
            let errors = summary.results[.connectionHistory]?.errors.count ?? 0
            let activeNow = SSHConnectionHistoryManager.shared.entries.count
            let totalNow = SSHConnectionHistoryManager.shared.allRecordsForSync.count
            Self.logger.info("History: backup contained \(backupCount), restore reported \(restored) applied (\(errors) errors), local now has \(activeNow) active / \(totalNow) total (incl \(totalNow - activeNow) tombstones)")
        }

        if categories.contains(.knownHosts), let backupHosts = payload.categories.knownHosts {
            let backupCount = backupHosts.count
            let restored = summary.results[.knownHosts]?.restored ?? 0
            let errors = summary.results[.knownHosts]?.errors.count ?? 0
            let activeNow = KnownHostsManager.shared.allHosts.count
            let totalNow = KnownHostsManager.shared.allRecordsForSync.count
            Self.logger.info("Known hosts: backup contained \(backupCount), restore reported \(restored) applied (\(errors) errors), local now has \(activeNow) active / \(totalNow) total (incl \(totalNow - activeNow) tombstones)")
        }

        // Only ask CloudKit for diagnostics when sync is actually enabled.
        // logDiagnostics() makes real CloudKit calls (account status, zone fetch,
        // subscription fetch) which we should not trigger from a local restore.
        if CloudKitSyncManager.shared.isSyncEnabled {
            Task {
                await CloudKitSyncManager.shared.logDiagnostics()
            }
        } else {
            Self.logger.info("CloudKit sync disabled, skipping CloudKit diagnostics dump")
        }

        Self.logger.info("=== End post-restore diagnostics ===")
    }

    // MARK: - Reset

    func reset() {
        state = .idle
        exportSummary = nil
        restoreSummary = nil
        lastBackupURL = nil
    }
}
