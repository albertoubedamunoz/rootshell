import Foundation
import CloudKit
import CryptoKit

/// Deterministic CloudKit record name helper
enum CloudKitRecordName {
    static func make(recordType: String, identity: String) -> String {
        let data = Data(identity.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(recordType)_\(hex)"
    }

    static func recordType(from recordName: String) -> String? {
        recordName.split(separator: "_", maxSplits: 1).first.map(String.init)
    }
}

/// Protocol for types that can be converted to/from CKRecord
protocol CloudKitSyncable: SyncableRecord {
    /// CloudKit record type name
    static var recordType: String { get }

    /// Current schema version for this record type
    static var schemaVersion: Int { get }

    /// Convert this record to a CKRecord
    func toCKRecord() -> CKRecord

    /// Deterministic record name for this record
    static func recordName(for record: Self) -> String

    /// Apply the record fields to an existing CKRecord (used for conflict resolution)
    func apply(to record: CKRecord)

    /// Create an instance from a CKRecord
    static func from(_ record: CKRecord) -> Self?
}

extension CloudKitSyncable {
    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }
}
