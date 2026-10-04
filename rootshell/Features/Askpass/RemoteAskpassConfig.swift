//
//  RemoteAskpassConfig.swift
//  rootshell
//
//  Per-connection setting for remote credential requests (#588): a
//  process on the host runs `rootshell-askpass`, which asks over a
//  forwarded Unix socket, and the user answers in a sheet.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Whether the remote host may ask this connection for credentials.
/// Every request is approved by hand, so there is no approval mode.
nonisolated struct RemoteAskpassConfig: Codable, Hashable, Sendable {
    var enabled: Bool

    static let disabled = RemoteAskpassConfig(enabled: false)

    private enum CodingKeys: String, CodingKey {
        case enabled
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// A credential request from the remote host, awaiting the user's answer.
struct RemoteAskpassRequest: Identifiable, Sendable {
    let id: UUID
    let remoteHost: String
    let remoteUser: String
    let sessionName: String
    /// Prompt text supplied by the remote helper (sanitized).
    let prompt: String
    /// Command line of the requesting process as reported by the remote
    /// helper. Untrusted: the requester controls it.
    let command: String
    /// Called once with the entered value, or nil when the user cancels.
    let completion: @Sendable (String?) -> Void
}
