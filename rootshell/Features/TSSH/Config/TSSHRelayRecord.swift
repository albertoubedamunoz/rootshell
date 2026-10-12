import Foundation
import CloudKit
import CryptoKit

/// Companion records reuse the deployed profile schema. Old profile readers
/// skip them because profileID/name/sshConfig are absent; old writers therefore
/// cannot erase a relay preference by re-encoding their known profile fields.
struct TSSHRelayRecord: CloudKitSyncable, Sendable {
    enum Owner: String, Codable, Sendable { case profile, history }
    let id: UUID
    let owner: Owner
    let ownerKey: String
    /// Hop 1. Older builds read only this, so it stays a field of its own.
    var settings: TSSHRelaySettings?
    /// Relay hops after the first, in order.
    var extraHopSettings: [TSSHRelaySettings]?
    var modifiedAt: Date
    var isDeleted: Bool = false
    var syncedRevision: Date?

    static var recordType: String { "ConnectionProfile" }
    static var schemaVersion: Int { 1 }
    var needsUpload: Bool { syncedRevision != modifiedAt }

    static func identity(owner: Owner, key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("tssh-relay:\(owner.rawValue):\(key)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    init(owner: Owner, key: String, relays: [TSSHRelaySettings], modifiedAt: Date = Date()) {
        self.id = Self.identity(owner: owner, key: key)
        self.owner = owner
        self.ownerKey = key
        self.settings = relays.first
        self.extraHopSettings = relays.count > 1 ? Array(relays.dropFirst()) : nil
        self.modifiedAt = modifiedAt
    }

    /// Every relay hop in order; empty when relaying is off.
    var relays: [TSSHRelaySettings] {
        settings.map { [$0] + (extraHopSettings ?? []) } ?? []
    }

    // Preserve subsecond revision ordering even in the file store, whose
    // shared ISO-8601 Date strategy otherwise rounds timestamps to seconds.
    private enum CodingKeys: String, CodingKey {
        case id, owner, ownerKey, settings, extraHopSettings, modifiedAt, isDeleted, syncedRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        owner = try c.decode(Owner.self, forKey: .owner)
        ownerKey = try c.decode(String.self, forKey: .ownerKey)
        settings = try c.decodeIfPresent(TSSHRelaySettings.self, forKey: .settings)
        extraHopSettings = (try? c.decodeIfPresent([TSSHRelaySettings].self, forKey: .extraHopSettings)) ?? nil
        modifiedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .modifiedAt))
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        syncedRevision = try c.decodeIfPresent(Double.self, forKey: .syncedRevision).map(Date.init(timeIntervalSince1970:))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(owner, forKey: .owner)
        try c.encode(ownerKey, forKey: .ownerKey)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encodeIfPresent(extraHopSettings, forKey: .extraHopSettings)
        try c.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encodeIfPresent(syncedRevision?.timeIntervalSince1970, forKey: .syncedRevision)
    }

    static func recordName(for record: Self) -> String {
        CloudKitRecordName.make(recordType: "ConnectionTSSHRelay", identity: record.id.uuidString)
    }

    func apply(to record: CKRecord) {
        record["profileID"] = nil as String?
        record["name"] = nil as String?
        record["sshConfig"] = nil as Data?
        var wire = self
        wire.syncedRevision = nil
        record["extensionData"] = try? JSONEncoder().encode(wire)
        record["modifiedAt"] = modifiedAt
        record["isDeleted"] = isDeleted ? 1 : 0
        record["schemaVersion"] = Int64(Self.schemaVersion)
    }

    static func from(_ record: CKRecord) -> Self? {
        guard record.recordType == recordType,
              let data = record["extensionData"] as? Data,
              var value = try? JSONDecoder().decode(Self.self, from: data),
              value.id == identity(owner: value.owner, key: value.ownerKey),
              record.recordID.recordName == recordName(for: value) else { return nil }
        value.syncedRevision = value.modifiedAt
        return value
    }
}
