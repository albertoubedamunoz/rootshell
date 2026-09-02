import Foundation
import UIKit
import os.log

extension Notification.Name {
    /// Posted when the auto-redact configuration changes (enabled flag or
    /// the needle list). `GhosttyApp` observes this and pushes the new set
    /// to every live surface.
    static let redactionConfigDidChange = Notification.Name("com.rootshell.redactionConfigDidChange")
}

/// A single auto-redact entry: a string (a name spelling, an e-mail
/// address, ...) that must never appear in the rendered terminal display.
struct RedactionItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }
}

/// Global auto-redact state: a user-maintained list of sensitive strings
/// that the terminal renders as bullets (at the original cell widths) so
/// they never leak into screenshots or screen recordings. Masking is
/// display-only inside GhosttyKit; the underlying screen data, selection,
/// and copy are untouched.
///
/// The list itself is sensitive, so it is stored as an encoded blob in the
/// Keychain (see `KeychainManager.saveRedactionItems`), never in
/// UserDefaults or on-disk config files. Only the enabled flag lives in
/// UserDefaults. Modeled on `BrightnessManager`: `@Observable` singleton
/// broadcasting via `NotificationCenter` (project convention).
@MainActor
@Observable
final class RedactionManager {
    static let shared = RedactionManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RedactionManager")

    /// True while `reload(keys:)` re-assigns `isEnabled` from the store.
    @ObservationIgnored private var isReloading = false

    /// Matching is case-insensitive in the renderer; entries shorter than
    /// this are rejected in the UI because single characters would mask
    /// half the screen.
    static let minimumItemLength = 2

    /// Scalars that can never appear in an entry: GhosttyKit rejects
    /// needles containing the mask bullet (masked output must never
    /// re-match) or the Kitty graphics placeholder, and NUL would be
    /// truncated at the C-string boundary. Checked at the Unicode-scalar
    /// level to exactly mirror GhosttyKit's codepoint-level validation —
    /// a Character-level check would let e.g. bullet + variation selector
    /// through, showing redaction as on while the string renders in the
    /// clear.
    private static let forbiddenScalars: Set<Unicode.Scalar> = ["\u{0000}", "\u{2022}", "\u{10EEEE}"]

    /// Whether the text (after trimming) is acceptable as a new entry.
    static func isValidItemText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumItemLength else { return false }
        return !trimmed.unicodeScalars.contains { forbiddenScalars.contains($0) }
    }

    /// Whether redaction is currently active. With an empty list the
    /// renderer receives an empty set, so the flag is a no-op until
    /// strings exist — but it is always settable.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            guard loaded, ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Privacy.autoRedact, isEnabled) }
            notifyChanged()
        }
    }

    /// The redaction entries. Mutate through add/update/remove so the
    /// Keychain copy stays in sync.
    private(set) var items: [RedactionItem] = []

    /// True once at least one entry exists; the toggle shortcut and menu
    /// item are inert until then.
    var isConfigured: Bool { !items.isEmpty }

    /// The strings handed to GhosttyKit when redaction is on.
    var needleStrings: [String] { items.map(\.text) }

    /// Guards the UserDefaults/Keychain writes in didSet paths against
    /// running before the initial load (or before first unlock).
    private var loaded = false

    private init() {
        isEnabled = false
        ProtectedDataGuard.whenAvailable { [weak self] in
            self?.load()
        }

        SettingsRefreshHub.shared.register(keys: [Settings.Privacy.autoRedact.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }

        // The list syncs via iCloud Keychain; re-read on foreground so
        // entries added on another device show up without a relaunch.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.reloadFromKeychain()
            }
        }
    }

    /// Re-read the Keychain copy and adopt it if it differs from the
    /// in-memory list (e.g. iCloud Keychain delivered changes from
    /// another device while we were backgrounded).
    private func reloadFromKeychain() {
        guard loaded else { return }
        let fresh: [RedactionItem]
        do {
            let data = try KeychainManager.shared.loadRedactionItems()
            guard let decoded = try? JSONDecoder().decode([RedactionItem].self, from: data) else { return }
            fresh = decoded
        } catch KeychainManager.KeychainError.itemNotFound {
            fresh = []
        } catch {
            return
        }
        guard fresh != items else { return }
        items = fresh
        notifyChanged()
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        guard keys.contains(Settings.Privacy.autoRedact.name) else { return }
        isReloading = true
        defer { isReloading = false }
        isEnabled = SettingsStore.shared.get(Settings.Privacy.autoRedact)
    }

    private func load() {
        isEnabled = SettingsStore.shared.get(Settings.Privacy.autoRedact)
        do {
            let data = try KeychainManager.shared.loadRedactionItems()
            items = try JSONDecoder().decode([RedactionItem].self, from: data)
        } catch KeychainManager.KeychainError.itemNotFound {
            items = []
        } catch {
            Self.logger.error("Failed to load redaction items: \(error.localizedDescription)")
            items = []
        }
        loaded = true
        if isEnabled, isConfigured {
            NotificationCenter.default.post(name: .redactionConfigDidChange, object: nil)
        }
        // The legacy menu is built before this deferred Keychain load runs
        // and would otherwise show Auto-Redact disabled until the next
        // mutation. Rebuild unconditionally so enablement and checkmark
        // reflect the stored list.
        UIMenuSystem.main.setNeedsRebuild()
    }

    /// Flip redaction on/off (keyboard shortcut / menu path). Always
    /// allowed: with an empty list the flag simply has no visible effect
    /// until strings are added (or sync in from another device).
    func toggle() {
        isEnabled.toggle()
    }

    /// Add a new entry. Returns false when the trimmed text is invalid,
    /// already present, or could not be persisted (in-memory state is
    /// only mutated after the Keychain write succeeds).
    @discardableResult
    func addItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidItemText(trimmed) else { return false }
        guard !items.contains(where: { $0.text == trimmed }) else { return false }
        var newItems = items
        newItems.append(RedactionItem(text: trimmed))
        guard persist(newItems) else { return false }
        items = newItems
        notifyChanged()
        return true
    }

    func removeItems(at offsets: IndexSet) {
        var newItems = items
        for index in offsets.sorted(by: >) where newItems.indices.contains(index) {
            newItems.remove(at: index)
        }
        guard persist(newItems) else { return }
        items = newItems
        notifyChanged()
    }

    func removeItem(id: UUID) {
        var newItems = items
        newItems.removeAll { $0.id == id }
        guard persist(newItems) else { return }
        items = newItems
        notifyChanged()
    }

    /// Write the new list to the Keychain BEFORE mutating memory: a
    /// mutation that only lived in memory would silently vanish on
    /// relaunch, dropping protection the user believes is configured.
    /// Returns false (leaving state untouched) on failure.
    private func persist(_ newItems: [RedactionItem]) -> Bool {
        guard loaded else { return false }
        do {
            if newItems.isEmpty {
                try KeychainManager.shared.deleteRedactionItems()
            } else {
                let data = try JSONEncoder().encode(newItems)
                try KeychainManager.shared.saveRedactionItems(data)
            }
            return true
        } catch {
            Self.logger.error("Failed to persist redaction items: \(error.localizedDescription)")
            return false
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .redactionConfigDidChange, object: nil)
        // The legacy (pre-26) menu bar shows a checkmark on the toggle
        // item; UIKit only re-queries command state on a rebuild.
        UIMenuSystem.main.setNeedsRebuild()
    }
}
