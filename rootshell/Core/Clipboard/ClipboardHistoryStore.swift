//
//  ClipboardHistoryStore.swift
//  rootshell
//
//  Encrypted-at-rest persistence for in-app clipboard history.
//  Single AES-256-GCM encrypted JSON file; the symmetric key lives in the
//  Keychain (device-only, after-first-unlock) and is deleted on wipe so
//  any file remnants become unreadable.
//

import Crypto
import Foundation
import os

// MARK: - Encryption

@MainActor
final class ClipboardEncryptionManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ClipboardEncryption")

    private var cachedKey: SymmetricKey?

    enum ClipboardEncryptionError: LocalizedError {
        case keyGenerationFailed
        case encryptionFailed(Error)
        case decryptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:
                return "Failed to generate or retrieve clipboard encryption key"
            case .encryptionFailed(let error):
                return "Clipboard encryption failed: \(error.localizedDescription)"
            case .decryptionFailed(let error):
                return "Clipboard decryption failed: \(error.localizedDescription)"
            }
        }
    }

    /// Pre-fetch the encryption key on MainActor so it can be passed to background work.
    func getKey() throws -> SymmetricKey {
        if let cached = cachedKey {
            return cached
        }

        if let keyData = try? KeychainManager.shared.loadClipboardEncryptionKey() {
            let key = SymmetricKey(data: keyData)
            cachedKey = key
            return key
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        do {
            try KeychainManager.shared.saveClipboardEncryptionKey(keyData)
        } catch {
            Self.logger.error("Failed to save clipboard encryption key: \(error.localizedDescription)")
            throw ClipboardEncryptionError.keyGenerationFailed
        }

        cachedKey = key
        Self.logger.info("Generated and saved new clipboard encryption key")
        return key
    }

    /// Clears the cached key and deletes the Keychain item. The next getKey()
    /// generates a fresh key, so previously written files become unreadable.
    func destroyKey() {
        cachedKey = nil
        do {
            try KeychainManager.shared.deleteClipboardEncryptionKey()
        } catch {
            Self.logger.error("Failed to delete clipboard encryption key: \(error.localizedDescription)")
        }
    }

    /// Encrypt data using a pre-fetched key. Can be called from any thread.
    nonisolated static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                throw ClipboardEncryptionError.encryptionFailed(
                    NSError(domain: "ClipboardEncryption", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to produce combined sealed box"])
                )
            }
            return combined
        } catch let error as ClipboardEncryptionError {
            throw error
        } catch {
            throw ClipboardEncryptionError.encryptionFailed(error)
        }
    }

    /// Decrypt data using a pre-fetched key. Can be called from any thread.
    nonisolated static func decrypt(_ combined: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ClipboardEncryptionError.decryptionFailed(error)
        }
    }
}

// MARK: - File store

@MainActor
final class ClipboardHistoryStore {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ClipboardHistoryStore")

    private let encryption = ClipboardEncryptionManager()

    /// Writes are chained on this task so a stale snapshot can never
    /// overwrite a newer one, and wipe() waits out any in-flight write.
    private var saveTask: Task<Void, Never>?

    private nonisolated static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(".ghostty/clipboard", isDirectory: true)
    }

    private nonisolated static var fileURL: URL {
        directory.appendingPathComponent("history.json.enc")
    }

    // nonisolated so the Codable conformance is usable from the detached
    // encode/decode tasks below.
    private nonisolated struct HistoryFile: Codable {
        var version: Int
        var entries: [ClipboardEntry]
    }

    // MARK: Load

    /// Loads and decrypts the history file. A corrupt or undecryptable file is
    /// deleted so the store self-heals (matches scrollback persistence behavior).
    func load() async -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return [] }
        guard let key = try? encryption.getKey() else {
            Self.logger.error("Clipboard history load skipped: no encryption key available")
            return []
        }

        let task = Task.detached(priority: .userInitiated) { () -> [ClipboardEntry]? in
            do {
                let encrypted = try Data(contentsOf: Self.fileURL)
                let plaintext = try ClipboardEncryptionManager.decrypt(encrypted, using: key)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let file = try decoder.decode(HistoryFile.self, from: plaintext)
                return file.entries
            } catch {
                Self.logger.error("Clipboard history unreadable, deleting file: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: Self.fileURL)
                return nil
            }
        }

        guard let entries = await task.value else { return [] }
        let count = entries.count
        Self.logger.debug("Loaded \(count) clipboard history entries")
        return entries
    }

    // MARK: Save

    /// Encrypts and writes a snapshot in the background. Callers debounce.
    func write(_ snapshot: [ClipboardEntry]) {
        guard let key = try? encryption.getKey() else {
            Self.logger.error("Clipboard history save skipped: no encryption key available")
            return
        }

        let previous = saveTask
        saveTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let plaintext = try encoder.encode(HistoryFile(version: 1, entries: snapshot))
                let encrypted = try ClipboardEncryptionManager.encrypt(plaintext, using: key)
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try encrypted.write(to: Self.fileURL, options: .atomic)
            } catch {
                Self.logger.error("Clipboard history save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Wipe

    /// Removes the store directory and destroys the encryption key.
    /// Chained behind any in-flight write so the file can't be resurrected.
    func wipe() {
        let previous = saveTask
        saveTask = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard FileManager.default.fileExists(atPath: Self.directory.path) else { return }
            do {
                try FileManager.default.removeItem(at: Self.directory)
            } catch {
                Self.logger.error("Clipboard history wipe failed: \(error.localizedDescription)")
            }
        }
        encryption.destroyKey()
        Self.logger.info("Clipboard history wiped")
    }
}
