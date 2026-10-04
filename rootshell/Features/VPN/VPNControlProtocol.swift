//
//  VPNControlProtocol.swift
//  rootshell
//
//  Canonical control-plane contract between the Catalyst app (client) and the
//  native macOS VPN host app (server) for the Standalone build. The host owns
//  NETunnelProviderManager + the system-extension packet tunnel; the Catalyst
//  app drives it over a Unix-domain socket in the shared App Group container.
//
//  Wire framing reuses `SocketMessage` (length-prefixed JSON) from
//  Core/Helper/SocketProtocol.swift, the same mechanism used for rootshell-helper.
//  This file is a pure data contract (Foundation only) so it compiles unchanged
//  on every platform and can be shared verbatim into the host app's project.
//

import Foundation

// MARK: - Commands

enum VPNControlCommand: String, Codable, Sendable {
    /// Liveness check; host replies success with no payload.
    case ping
    /// Ensure the packet-tunnel system extension is installed/activated
    /// (`OSSystemExtensionRequest`). Response is `VPNExtensionStatusResponse`.
    case activateExtension
    /// Query system-extension activation state without triggering a request.
    case extensionStatus
    /// Start the tunnel for a profile. Payload `VPNStartRequest`.
    case startVPN
    /// Stop the current tunnel.
    case stopVPN
    /// Query live tunnel status + stats. Response `VPNTunnelStatusResponse`.
    case getStatus
    /// Relay an opaque provider message (HTTP capture) to the tunnel; the
    /// response payload is the provider's reply.
    case providerMessage
    /// Add a DER certificate to the login keychain and trust it as an SSL root
    /// (HTTP capture CA). Prompts the user for their password.
    case installCATrust
    /// Remove the trust settings and keychain item for a DER certificate.
    case removeCATrust
}

// MARK: - Envelope

nonisolated struct VPNControlRequest: Codable, Sendable {
    let command: VPNControlCommand
    let payload: Data?

    init(command: VPNControlCommand, payload: Data? = nil) {
        self.command = command
        self.payload = payload
    }
}

nonisolated struct VPNControlResponse: Codable, Sendable {
    let success: Bool
    let payload: Data?
    let error: String?

    init(success: Bool, payload: Data? = nil, error: String? = nil) {
        self.success = success
        self.payload = payload
        self.error = error
    }
}

// MARK: - Payloads

struct VPNStartRequest: Codable, Sendable {
    let profileID: UUID
    /// "ssh" | "tssh" | "tssh-relay" | "direct" | "tailscale" — mirrors
    /// `VPNTunnelConfig.TransportType.rawValue`.
    let transportType: String

    /// Fully-resolved runtime config (JSON-encoded `VPNTunnelConfig`), populated
    /// by the host when the sysext — running as root in the global context —
    /// cannot read the per-user App Group / keychain that the iOS appex relies on.
    /// `nil` means the sysext resolves the profile itself from `VPNSharedProfileStore`
    /// (iOS-parity path). Either way the command shape is stable; which side
    /// resolves credentials is settled by the root-context spike (plan §2).
    let resolvedConfig: Data?

    /// True when a resolved credential is agent-backed and the host must run
    /// the agent signing broker loop for the tunnel's lifetime. Decoded with
    /// a `false` default so old app builds interoperate with new hosts and
    /// vice versa.
    let usesAgentSigning: Bool

    /// HTTP capture engine config (including the CA key) for the sysext, which
    /// can't read the user's keychain. Forwarded as the "captureConfig" start option.
    let captureConfig: Data?

    init(profileID: UUID, transportType: String, resolvedConfig: Data? = nil, usesAgentSigning: Bool = false, captureConfig: Data? = nil) {
        self.profileID = profileID
        self.transportType = transportType
        self.resolvedConfig = resolvedConfig
        self.usesAgentSigning = usesAgentSigning
        self.captureConfig = captureConfig
    }

    enum CodingKeys: String, CodingKey {
        case profileID, transportType, resolvedConfig, usesAgentSigning, captureConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        transportType = try container.decode(String.self, forKey: .transportType)
        resolvedConfig = try container.decodeIfPresent(Data.self, forKey: .resolvedConfig)
        usesAgentSigning = try container.decodeIfPresent(Bool.self, forKey: .usesAgentSigning) ?? false
        captureConfig = try container.decodeIfPresent(Data.self, forKey: .captureConfig)
    }
}

/// Ping response payload: identifies the running host build so the app can
/// detect and replace a stale instance (e.g. after a Sparkle update swapped
/// the bundle under a still-running host). Older hosts reply without a
/// payload — treated as stale.
nonisolated struct VPNHostInfoResponse: Codable, Sendable {
    var supportsTSSHRelay: Bool? = nil
    /// Host understands providerMessage / installCATrust / removeCATrust.
    var supportsHTTPCapture: Bool? = nil
    /// Host and sysext can run the Tailscale tunnel.
    var supportsTailscale: Bool? = nil
    let version: String
    let bundlePath: String
}

struct VPNExtensionStatusResponse: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case notInstalled
        case requesting         // activation request submitted, no approval verdict yet
        case awaitingApproval   // user must approve in System Settings → Login Items & Extensions
        case activated
        case needsReboot
        case failed
    }

    let state: State
    /// Installed sysext `CFBundleVersion`, when known (drives update reconciliation).
    let version: String?
    let message: String?

    init(state: State, version: String? = nil, message: String? = nil) {
        self.state = state
        self.version = version
        self.message = message
    }
}

struct VPNTunnelStatusResponse: Codable, Sendable {
    /// String mirror of `NEVPNStatus`:
    /// "invalid" | "disconnected" | "connecting" | "connected" | "reasserting" | "disconnecting".
    let status: String
    let profileID: UUID?
    let profileName: String?
    let host: String?
    let connectedSince: Date?
    let rxBytes: Int64?
    let txBytes: Int64?
    /// Last error surfaced by the tunnel (mirrors the app-group `vpn_last_error.txt`).
    let lastError: String?
    /// The raw provider `getStatus` JSON (from `sendProviderMessage`), so the
    /// Catalyst app can parse full stats/traffic the same way the iOS appex does.
    /// The root sysext's app-group container is per-uid and unreadable from the
    /// app, so stats must travel over the socket rather than a shared file.
    let statusJSON: String?

    init(
        status: String,
        profileID: UUID? = nil,
        profileName: String? = nil,
        host: String? = nil,
        connectedSince: Date? = nil,
        rxBytes: Int64? = nil,
        txBytes: Int64? = nil,
        lastError: String? = nil,
        statusJSON: String? = nil
    ) {
        self.status = status
        self.profileID = profileID
        self.profileName = profileName
        self.host = host
        self.connectedSince = connectedSince
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.lastError = lastError
        self.statusJSON = statusJSON
    }
}

// MARK: - Socket location

/// Control socket lives in the shared App Group container alongside the
/// rootshell-helper `commands.sock`. Kept short to stay under the 104-char
/// `sockaddr_un.sun_path` limit. Named here rather than reached for via
/// `AppGroupHelper`, which isn't compiled into the extension targets, so this
/// contract stays self-contained across every target that shares it.
nonisolated enum VPNControlPaths {
    static let appGroupIdentifier = AppIdentifiers.defaultAppGroupID

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var controlSocketPath: String? {
        containerURL?.appendingPathComponent("vpnControl.sock").path
    }

    /// Clears `VPNAutoRecovery`'s marker from the host, which doesn't build that type.
    static func clearAutoRecovery() {
        guard let url = containerURL?.appendingPathComponent("vpn_auto_recovery.txt") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
