//
//  GPGAgentConfig.swift
//  rootshell
//
//  Configuration for GPG agent forwarding per connection.
//
//  GPG agent forwarding is the OpenPGP analogue of SSH agent forwarding,
//  with a fundamentally different transport: it rides reverse Unix-domain
//  socket forwarding (the `streamlocal-forward@openssh.com` SSH extension)
//  rather than the dedicated `auth-agent@openssh.com` channel that
//  SSHAgentConfig drives. The remote `gpg` client connects to a Unix
//  socket at `remoteSocketPath`, sshd opens a reverse channel back to
//  the iPad, and the bytes on that channel are the Assuan protocol that
//  GPGAgentManager speaks.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Configuration for GPG agent forwarding on a specific connection.
///
/// Mirrors ``SSHAgentConfig`` in shape but is intentionally a distinct
/// type: the lifecycle (need a remote socket path, need a separate
/// approval surface for sign vs decrypt) and the persisted UUID space
/// (forwardedKeyIDs reference ``GPGKey`` UUIDs, not ``SSHKey``) differ.
nonisolated struct GPGAgentConfig: Codable, Hashable, Sendable {
    /// Approval mode for forwarded signing requests.
    nonisolated enum ApprovalMode: String, Codable, CaseIterable, Sendable {
        /// Automatically approve every request without prompting.
        case autoApprove = "auto"
        /// Approve a key once, then auto-approve further requests for
        /// the same key until the session disconnects.
        case sessionApprove = "session"
        /// Prompt the user for every individual request.
        case perRequest = "prompt"

        var displayName: String {
            switch self {
            case .autoApprove: return String(localized: "Auto-approve", comment: "GPG agent approval: auto-approve")
            case .sessionApprove: return String(localized: "Session", comment: "GPG agent approval: session")
            case .perRequest: return String(localized: "Ask each time", comment: "GPG agent approval: ask each time")
            }
        }

        var description: String {
            switch self {
            case .autoApprove:
                return String(localized: "Automatically approve all signing requests", comment: "GPG agent approval description: auto-approve")
            case .sessionApprove:
                return String(localized: "Approve requests until disconnection", comment: "GPG agent approval description: session")
            case .perRequest:
                return String(localized: "Prompt for approval on each request", comment: "GPG agent approval description: per request")
            }
        }
    }

    /// Whether GPG agent forwarding is enabled for this connection.
    var enabled: Bool

    /// Approval mode for `PKSIGN` requests.
    var approvalMode: ApprovalMode

    /// IDs of GPG keys to expose to the remote. Empty means "all imported
    /// GPG keys" — matching ``SSHAgentConfig``'s convention.
    var forwardedKeyIDs: Set<UUID>

    /// Path on the remote where the forwarded socket should be
    /// created. Supports two placeholders that get resolved at
    /// connect time by probing the remote (`id -u` / `$HOME` over
    /// the SSH transport before the streamlocal-forward request):
    ///
    ///   * `{HOME}` — the remote user's home directory
    ///   * `{UID}`  — the remote user's numeric UID
    ///
    /// Pre-resolved literal paths also work — substitution only
    /// applies when one of the placeholders is present in the
    /// string.
    ///
    /// The default is `{HOME}/.gnupg/S.gpg-agent`, which is the path
    /// the remote's `gpg` client will look for when contacting "the
    /// agent". This works on macOS (no XDG runtime dir), Linux
    /// servers (no `/run/user/<uid>` because no desktop session),
    /// and Linux desktops alike — gpg always falls back to
    /// `~/.gnupg/S.gpg-agent` if the XDG path isn't usable.
    ///
    /// Note: the "extra socket" convention (`.extra` suffix) only
    /// applies when forwarding a *local* gpg-agent's restricted socket
    /// through to a remote — we ARE the agent on the iPad side, not a
    /// forwarder of another agent, so the suffix doesn't apply. The
    /// remote needs the socket at the standard `S.gpg-agent` name for
    /// gpg to find it.
    var remoteSocketPath: String

    /// Default gpg-agent forwarding socket path. Cross-platform via
    /// `{HOME}` substitution — see ``remoteSocketPath``.
    static let defaultRemoteSocketPath = "{HOME}/.gnupg/S.gpg-agent"

    /// Default configuration: disabled, prompts every time when enabled.
    static let disabled = GPGAgentConfig(
        enabled: false,
        approvalMode: .perRequest,
        forwardedKeyIDs: [],
        remoteSocketPath: defaultRemoteSocketPath
    )

    /// Create a configuration that forwards every available GPG key.
    static func withAllKeys(mode: ApprovalMode, remoteSocketPath: String = defaultRemoteSocketPath) -> GPGAgentConfig {
        GPGAgentConfig(
            enabled: true,
            approvalMode: mode,
            forwardedKeyIDs: [],
            remoteSocketPath: remoteSocketPath
        )
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case enabled, approvalMode, forwardedKeyIDs, remoteSocketPath
    }

    init(
        enabled: Bool,
        approvalMode: ApprovalMode,
        forwardedKeyIDs: Set<UUID>,
        remoteSocketPath: String
    ) {
        self.enabled = enabled
        self.approvalMode = approvalMode
        self.forwardedKeyIDs = forwardedKeyIDs
        self.remoteSocketPath = remoteSocketPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        approvalMode = try container.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .perRequest
        forwardedKeyIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .forwardedKeyIDs) ?? []
        remoteSocketPath = try container.decodeIfPresent(String.self, forKey: .remoteSocketPath) ?? Self.defaultRemoteSocketPath
    }
}

/// A pending GPG operation request awaiting user approval. Mirrors
/// ``SSHAgentApprovalRequest`` but adds the verb (sign vs decrypt),
/// hash algorithm, and short hash preview — for `PKSIGN` the user is
/// authorising an opaque digest, so surfacing the algorithm + a few
/// hash bytes is the cheapest way to give them something to compare
/// against the remote operation. For `PKDECRYPT` no digest is sent;
/// the user authorises by key name + remote host instead.
struct GPGAgentApprovalRequest: Identifiable, Sendable {
    let id = UUID()

    /// Whether the remote is asking us to sign or decrypt. Drives the
    /// approval sheet copy — "Sign with X" vs "Decrypt with X" — and
    /// whether the hash-preview row is shown.
    enum Verb: Sendable, Hashable {
        case sign
        case decrypt
    }

    /// What operation the remote requested.
    let verb: Verb

    /// The user-friendly name of the key being requested.
    let keyName: String

    /// Primary fingerprint of the key (uppercase hex, no separators).
    let fingerprint: String

    /// Keygrip the remote requested (matches the `SIGKEY`/`SETKEY` value).
    let keygrip: String

    /// The remote host requesting the operation.
    let remoteHost: String?

    /// Human-readable session label (e.g., "user@host via jump").
    let sessionName: String

    /// Hash algorithm the remote set via `SETHASH`. `nil` for decrypt
    /// requests (no digest is exchanged) and as a defensive fallback
    /// if `SETHASH` never arrived.
    let hashAlgorithm: GPGHashAlgorithm?

    /// First 8 bytes of the hash, hex-encoded, for visual comparison.
    /// Empty string for decrypt requests.
    let hashPreview: String

    /// Completion handler invoked with the user's decision.
    let completion: @Sendable (Bool) -> Void

    /// Time the request was created (for any timeout UI).
    let timestamp = Date()
}

/// Hash algorithm identifiers used by GPG over Assuan.
///
/// The raw values match the algorithm IDs gpg-agent receives via
/// `SETHASH <id> <hex>` — `8` is SHA-256, `10` is SHA-512, etc. Only
/// the algorithms we actually expect to honour are enumerated;
/// unknown ids degrade gracefully via ``unknown``.
nonisolated enum GPGHashAlgorithm: Sendable, Hashable {
    case sha1
    case sha224
    case sha256
    case sha384
    case sha512
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 2: self = .sha1
        case 11: self = .sha224
        case 8: self = .sha256
        case 9: self = .sha384
        case 10: self = .sha512
        default: self = .unknown(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .sha1: return "SHA-1"
        case .sha224: return "SHA-224"
        case .sha256: return "SHA-256"
        case .sha384: return "SHA-384"
        case .sha512: return "SHA-512"
        case .unknown(let id): return "algo \(id)"
        }
    }

    /// Expected digest length in bytes for the algorithm. `nil` for
    /// unknown ids — the Assuan layer should reject `PKSIGN` rather
    /// than guessing.
    var digestByteCount: Int? {
        switch self {
        case .sha1: return 20
        case .sha224: return 28
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        case .unknown: return nil
        }
    }
}
