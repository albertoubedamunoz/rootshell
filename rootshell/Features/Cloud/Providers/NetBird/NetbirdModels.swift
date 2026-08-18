import Foundation

// MARK: - Peer Response

/// Peer from the NetBird Management API (`GET /api/peers`).
///
/// The list endpoint returns a bare JSON array of these objects (not wrapped in
/// a container like Tailscale's `{ devices: [...] }`), so the API client decodes
/// `[NetbirdPeerResponse]` directly.
struct NetbirdPeerResponse: Codable, Sendable {
    let id: String
    let name: String?
    /// NetBird overlay IP (e.g. "100.x.x.x" in the 100.64.0.0/10 range).
    let ip: String?
    let ipv6: String?
    /// Real-time peer ↔ management connection status.
    let connected: Bool
    let lastSeen: String?
    let os: String?
    let hostname: String?
    /// Peer FQDN for NetBird DNS, e.g. "host.netbird.cloud".
    let dnsLabel: String?
    let sshEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ip
        case ipv6
        case connected
        case lastSeen = "last_seen"
        case os
        case hostname
        case dnsLabel = "dns_label"
        case sshEnabled = "ssh_enabled"
    }

    /// Convert to a provider-agnostic ``CloudInstance``.
    func toCloudInstance(accountID: UUID) -> CloudInstance {
        let displayLabel = name ?? hostname ?? dnsLabel ?? ip ?? id
        var instance = CloudInstance(
            accountID: accountID,
            providerInstanceID: id,
            providerID: NetbirdProvider.providerID,
            label: displayLabel,
            status: connected ? .running : .stopped
        )

        // Prefer the NetBird overlay IP for SSH (always routable when the device
        // is on the NetBird network); expose the FQDN as the hostname for display.
        instance.ipv4Address = ip
        instance.ipv6Address = ipv6
        instance.hostname = dnsLabel ?? hostname
        instance.image = os
        instance.lastUpdated = Date()

        return instance
    }
}

// MARK: - Error Response

/// Error response from the NetBird API
struct NetbirdErrorResponse: Codable, Sendable {
    let message: String
}
