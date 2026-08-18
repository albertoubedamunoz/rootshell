//
//  HistoryExtensionPayload.swift
//  rootshell
//
//  Versioned envelope for connection-history fields that ride the single
//  opaque CloudKit `extensionData` blob instead of per-field schema additions.
//

import Foundation

/// Versioned envelope holding extension fields for `SSHConnectionHistoryEntry`.
///
/// The `SSHConnectionHistory` record type mirrors every field individually, so
/// each new field used to cost a production CloudKit schema deploy. This is the
/// history-side counterpart of `ProfileExtensionPayload`: adding a field here
/// costs nothing once `extensionData` exists on the record type.
///
/// Decoding is tolerant at field level: a payload written by a newer build
/// (unknown fields, undecodable members) must not sink the envelope, and an
/// undecodable envelope must not sink the history entry (callers decode the
/// whole envelope with `try?`).
///
/// Presence is meaningful. A record that carries an envelope was written by a
/// build that knows these fields, so a nil member means "explicitly cleared".
/// A record with no envelope came from a build that predates them, and the
/// merge keeps whatever the receiving device already had.
struct HistoryExtensionPayload: Codable, Hashable, Sendable {
    /// Envelope schema version for future migrations.
    static let currentVersion = 1

    var version: Int

    /// Per-connection `TERM` override. nil means the connection inherits the
    /// global remote default.
    var terminalType: String?

    init(
        version: Int = HistoryExtensionPayload.currentVersion,
        terminalType: String? = nil
    ) {
        self.version = version
        self.terminalType = terminalType
    }

    private enum CodingKeys: String, CodingKey {
        case version, terminalType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? Self.currentVersion
        // Field-level tolerance: a bad member must not sink the envelope.
        terminalType = (try? container.decodeIfPresent(String.self, forKey: .terminalType)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(terminalType, forKey: .terminalType)
    }
}
