//
//  ProfileExtensionPayload.swift
//  rootshell
//
//  Versioned envelope for profile fields that ride the single opaque
//  CloudKit `extensionData` blob instead of per-field schema additions.
//

import Foundation

/// Versioned envelope holding extension fields for `ConnectionProfile`.
///
/// Decoding is tolerant at field level: a payload written by a newer build
/// (unknown fields, undecodable members) must not sink the envelope, and an
/// undecodable envelope must not sink the profile (callers decode the whole
/// envelope with `try?`).
struct ProfileExtensionPayload: Codable, Hashable, Sendable {
    /// Envelope schema version for future migrations.
    static let currentVersion = 1

    var version: Int

    /// Screen Sharing / VNC configuration, when this profile is a VNC profile.
    var vncConfig: VNCConnectionConfig?

    init(
        version: Int = ProfileExtensionPayload.currentVersion,
        vncConfig: VNCConnectionConfig? = nil
    ) {
        self.version = version
        self.vncConfig = vncConfig
    }

    /// True when nothing meaningful is stored. Empty envelopes are omitted
    /// from profile JSON and never written to CKRecords.
    var isEmpty: Bool {
        vncConfig == nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, vncConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? Self.currentVersion
        // Field-level tolerance: a bad vncConfig must not sink the envelope.
        vncConfig = (try? container.decodeIfPresent(VNCConnectionConfig.self, forKey: .vncConfig)) ?? nil
        // Early development builds stored the VNC object directly before the
        // versioned envelope was introduced. Preserve those profiles too.
        if vncConfig == nil,
           let legacyConfig = try? VNCConnectionConfig(from: decoder),
           !legacyConfig.host.isEmpty {
            vncConfig = legacyConfig
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(vncConfig, forKey: .vncConfig)
    }
}
