import Foundation

@MainActor
final class TSSHRelayStore {
    static let shared = TSSHRelayStore()
    private var store: SyncableFileStore<TSSHRelayRecord>
    init(directoryURL: URL? = nil) {
        store = SyncableFileStore(storeName: "tssh_relays", directoryURL: directoryURL)
    }
    var onLocalChange: ((TSSHRelayRecord, SyncOperation) -> Void)?
    var pending: [TSSHRelayRecord] { store.allRecords.filter(\.needsUpload) }

    func record(owner: TSSHRelayRecord.Owner, key: String) -> TSSHRelayRecord? {
        store.record(for: TSSHRelayRecord.identity(owner: owner, key: key))
    }

    /// Seed a companion when importing a new backup. A legacy import lacking
    /// relay fields never clears an existing independently synced preference.
    func seed(owner: TSSHRelayRecord.Owner, key: String, relays: [TSSHRelaySettings], modifiedAt: Date) throws {
        guard record(owner: owner, key: key) == nil, !relays.isEmpty else { return }
        let value = TSSHRelayRecord(owner: owner, key: key, relays: relays, modifiedAt: modifiedAt)
        try store.save(value, updateTimestamp: false, notifySync: false)
        onLocalChange?(value, .update)
    }

    func seed(owner: TSSHRelayRecord.Owner, key: String, settings: TSSHRelaySettings?, modifiedAt: Date) throws {
        try seed(owner: owner, key: key, relays: settings.map { [$0] } ?? [], modifiedAt: modifiedAt)
    }

    /// Records the relay hops in order; an empty chain clears relaying.
    func update(owner: TSSHRelayRecord.Owner, key: String, relays: [TSSHRelaySettings]) throws {
        let existing = record(owner: owner, key: key)
        guard existing?.relays != relays || existing?.isDeleted == true else { return }
        guard !relays.isEmpty || existing != nil else { return }
        let value = TSSHRelayRecord(owner: owner, key: key, relays: relays)
        try store.save(value, updateTimestamp: false, notifySync: false)
        onLocalChange?(value, .update)
    }

    func update(owner: TSSHRelayRecord.Owner, key: String, settings: TSSHRelaySettings?) throws {
        try update(owner: owner, key: key, relays: settings.map { [$0] } ?? [])
    }

    func applyRemote(_ incoming: TSSHRelayRecord) throws {
        if let current = store.record(for: incoming.id), current.modifiedAt >= incoming.modifiedAt {
            if current.modifiedAt == incoming.modifiedAt { try markSynced(incoming) }
            return
        }
        try store.save(incoming, updateTimestamp: false, notifySync: false)
    }

    func markSynced(_ value: TSSHRelayRecord) throws {
        guard var current = store.record(for: value.id), current.modifiedAt == value.modifiedAt,
              current.relays == value.relays, current.isDeleted == value.isDeleted else { return }
        current.syncedRevision = value.modifiedAt
        try store.save(current, updateTimestamp: false, notifySync: false)
    }

}
