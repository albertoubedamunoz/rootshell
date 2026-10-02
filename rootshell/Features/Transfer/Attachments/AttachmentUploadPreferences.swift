//
//  AttachmentUploadPreferences.swift
//  rootshell
//
//  Upload directory and format resolution for pasted and dropped attachments.
//

import Foundation

enum AttachmentUploadPreferences {
    /// Per-host directories; registered as a prefix rule in `Settings.System`.
    private static let destinationPrefix = "paste.destination."

    struct RememberedDestination: Identifiable, Equatable {
        let host: String
        let path: String
        var id: String { host }
    }

    static var promptsBeforeUpload: Bool {
        SettingsStore.shared.get(Settings.Transfer.attachmentUploadConfirm)
    }

    static var defaultFormat: PasteInsertFormat {
        SettingsStore.shared.get(Settings.Transfer.attachmentUploadFormat)
    }

    /// The host's remembered directory, else the global default, else the built-in one.
    static func destination(for host: String) -> String {
        if let remembered = UserDefaults.standard.string(forKey: destinationPrefix + host)?.trimmed, !remembered.isEmpty {
            return remembered
        }
        return defaultDirectory
    }

    static var defaultDirectory: String {
        let configured = SettingsStore.shared.get(Settings.Transfer.attachmentUploadDirectory).trimmed
        return configured.isEmpty ? Settings.Transfer.attachmentUploadDirectory.defaultValue : configured
    }

    static func remember(destination: String, for host: String) {
        let trimmed = destination.trimmed
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: destinationPrefix + host)
    }

    static func rememberedDestinations() -> [RememberedDestination] {
        UserDefaults.standard.dictionaryRepresentation()
            .compactMap { key, value -> RememberedDestination? in
                guard key.hasPrefix(destinationPrefix), let path = value as? String else { return nil }
                return RememberedDestination(host: String(key.dropFirst(destinationPrefix.count)), path: path)
            }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    static func forget(host: String) {
        UserDefaults.standard.removeObject(forKey: destinationPrefix + host)
    }

    static func forgetAll() {
        for remembered in rememberedDestinations() {
            forget(host: remembered.host)
        }
    }

    /// "Don't ask again": these choices become the defaults and the sheet stops appearing.
    static func persistDefaults(destination: String, format: PasteInsertFormat) {
        let trimmed = destination.trimmed
        if !trimmed.isEmpty {
            SettingsStore.shared.set(Settings.Transfer.attachmentUploadDirectory, trimmed)
        }
        SettingsStore.shared.set(Settings.Transfer.attachmentUploadFormat, format)
        SettingsStore.shared.set(Settings.Transfer.attachmentUploadConfirm, false)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
