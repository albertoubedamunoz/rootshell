import Foundation

// MARK: - OAuth Token Response

/// Response from Tailscale OAuth token exchange
struct TailscaleTokenResponse: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int  // seconds until expiry (typically 3600)

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

// MARK: - Device Response

/// Device from Tailscale API
struct TailscaleDeviceResponse: Codable, Sendable {
    let id: String
    let name: String           // FQDN: "hostname.tailnet.ts.net"
    let hostname: String       // Short hostname
    let addresses: [String]    // ["100.x.x.x", "fd7a:..."]
    let os: String?
    let user: String?
    let authorized: Bool
    let lastSeen: String?      // ISO8601 timestamp
    let tags: [String]?
    let clientVersion: String?
    let keyExpiryDisabled: Bool?
    let expires: String?
    // Extra fields from ?fields=all (all optional; safe if Tailscale omits them)
    let connectedToControl: Bool?
    let updateAvailable: Bool?
    let isExternal: Bool?
    let blocksIncomingConnections: Bool?
    let advertisedRoutes: [String]?
    let enabledRoutes: [String]?
    let clientConnectivity: TailscaleClientConnectivity?

    /// Extract the IPv4 address (100.x.x.x) from addresses array
    var ipv4Address: String? {
        addresses.first { $0.hasPrefix("100.") }
    }

    /// Extract the IPv6 address from addresses array
    var ipv6Address: String? {
        addresses.first { $0.contains(":") }
    }

    /// Parse a Tailscale ISO8601 timestamp. Tailscale omits fractional seconds
    /// (e.g. "2022-03-04T15:14:46Z") but we accept the fractional variant too.
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// Convert to CloudInstance
    func toCloudInstance(accountID: UUID) -> CloudInstance {
        var instance = CloudInstance(
            accountID: accountID,
            providerInstanceID: id,
            providerID: TailscaleProvider.providerID,
            label: hostname,
            status: authorized ? .running : .stopped
        )

        instance.hostname = name
        instance.ipv4Address = ipv4Address
        instance.ipv6Address = ipv6Address
        instance.image = os
        instance.tags = tags ?? []
        instance.lastUpdated = Date()

        // Richer mesh metadata (surfaced in device rows + the connection info sheet)
        instance.clientVersion = clientVersion
        instance.updateAvailable = updateAvailable
        instance.lastSeen = Self.parseDate(lastSeen)
        instance.isOnline = connectedToControl
        instance.owner = user
        instance.isExternal = isExternal
        instance.acceptsConnections = blocksIncomingConnections.map { !$0 }
        instance.keyExpiry = (keyExpiryDisabled == true) ? nil : Self.parseDate(expires)
        instance.keyExpiryDisabled = keyExpiryDisabled
        instance.advertisedRoutes = advertisedRoutes
        instance.enabledRoutes = enabledRoutes
        instance.connectionQuality = clientConnectivity?.toQuality()

        return instance
    }
}

// MARK: - Client Connectivity

/// Subset of Tailscale's `clientConnectivity` report we surface in the UI.
struct TailscaleClientConnectivity: Codable, Sendable {
    let endpoints: [String]?
    let latency: [String: TailscaleDERPLatency]?
    let clientSupports: TailscaleClientSupports?

    /// Collapse the raw report into the provider-agnostic quality model.
    func toQuality() -> CloudConnectionQuality {
        var quality = CloudConnectionQuality()
        quality.hasDirectEndpoints = (endpoints?.isEmpty == false)
        if let preferred = latency?.first(where: { $0.value.preferred == true }) {
            quality.preferredDERPRegion = preferred.key
            quality.preferredDERPLatencyMs = preferred.value.latencyMs
        }
        quality.supportsIPv6 = clientSupports?.ipv6
        return quality
    }
}

/// Per-DERP-region latency entry from `clientConnectivity.latency`.
struct TailscaleDERPLatency: Codable, Sendable {
    let preferred: Bool?
    let latencyMs: Double?
}

/// Feature-support flags from `clientConnectivity.clientSupports`.
struct TailscaleClientSupports: Codable, Sendable {
    let ipv6: Bool?
}

// MARK: - Devices List Response

/// Response from Tailscale devices list endpoint
struct TailscaleDevicesResponse: Codable, Sendable {
    let devices: [TailscaleDeviceResponse]
}

// MARK: - Tailnet Info Response

/// Response from Tailscale tailnet info endpoint (for validation)
struct TailscaleTailnetResponse: Codable, Sendable {
    let name: String
}

// MARK: - Error Response

/// Error response from Tailscale API
struct TailscaleErrorResponse: Codable, Sendable {
    let message: String
}
