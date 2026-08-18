import Foundation

// MARK: - Instance Status

/// Status of a cloud VM instance
enum CloudInstanceStatus: String, Codable, CaseIterable, Sendable {
    case running = "running"
    case stopped = "stopped"
    case provisioning = "provisioning"
    case rebooting = "rebooting"
    case migrating = "migrating"
    case unknown = "unknown"

    var displayName: String {
        rawValue.capitalized
    }

    /// Whether SSH is likely available
    var isSSHReady: Bool {
        self == .running
    }

    /// Color name for status indicator
    var statusColor: String {
        switch self {
        case .running: return "green"
        case .stopped: return "gray"
        case .provisioning, .rebooting, .migrating: return "orange"
        case .unknown: return "secondary"
        }
    }

    /// SF Symbol for status
    var iconName: String {
        switch self {
        case .running: return "circle.fill"
        case .stopped: return "stop.circle.fill"
        case .provisioning: return "arrow.clockwise.circle.fill"
        case .rebooting: return "arrow.triangle.2.circlepath.circle.fill"
        case .migrating: return "arrow.right.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Connection Quality

/// Mesh path quality as reported by a network device (e.g. Tailscale's
/// `clientConnectivity`). Note: this is the device's own view of its
/// connectivity, not the path between this client and the device.
struct CloudConnectionQuality: Codable, Hashable, Sendable {
    /// True if the device exposes reachable UDP endpoints (direct path likely possible)
    var hasDirectEndpoints: Bool?
    /// Preferred DERP relay region name (e.g. "New York City")
    var preferredDERPRegion: String?
    /// Latency to the preferred DERP relay, in milliseconds
    var preferredDERPLatencyMs: Double?
    /// True if the device's OS supports IPv6
    var supportsIPv6: Bool?
}

// MARK: - Cloud Instance Model

/// Provider-agnostic representation of a cloud VM instance
struct CloudInstance: Codable, Identifiable, Hashable, Sendable {
    /// Local unique identifier
    let id: UUID

    /// Reference to the cloud account this instance belongs to
    let accountID: UUID

    /// Provider-specific instance ID (e.g., Linode ID, EC2 instance ID)
    let providerInstanceID: String

    /// Provider type (denormalized for quick filtering)
    let providerID: String

    // MARK: - Display Fields

    /// Instance label/name from provider
    var label: String

    /// Current status
    var status: CloudInstanceStatus

    /// Region/datacenter (e.g., "us-east", "us-west-1")
    var region: String?

    /// Instance type/size (e.g., "g6-nanode-1", "t2.micro")
    var instanceType: String?

    /// Operating system image
    var image: String?

    // MARK: - SSH-Relevant Fields

    /// Primary IPv4 address (public)
    var ipv4Address: String?

    /// Primary IPv6 address
    var ipv6Address: String?

    /// Private/internal IP (for VPC connections)
    var privateIP: String?

    /// Reverse DNS / hostname
    var hostname: String?

    // MARK: - Metadata

    /// Tags/labels from the provider
    var tags: [String]

    /// Date this cache entry was last updated from provider
    var lastUpdated: Date

    // MARK: - Network-Device Metadata (Tailscale / NetBird meshes)
    //
    // All optional so existing on-disk `cloud_cache` JSON keeps decoding after
    // an upgrade (synthesized Codable uses `decodeIfPresent` for optionals).

    /// Mesh client version (e.g. "v1.78.1")
    var clientVersion: String?

    /// True if the provider reports a client update is available
    var updateAvailable: Bool?

    /// When the device was last seen by the control plane
    var lastSeen: Date?

    /// True if the device currently holds a live connection to the control plane
    var isOnline: Bool?

    /// Owner of the device (typically an email)
    var owner: String?

    /// True if the device is shared into this network from another (external)
    var isExternal: Bool?

    /// True if the device accepts incoming connections (false = blocks all, incl. ping/SSH)
    var acceptsConnections: Bool?

    /// Node-key / auth-key expiry (nil if disabled or not applicable)
    var keyExpiry: Date?

    /// True if key expiry is disabled for this device
    var keyExpiryDisabled: Bool?

    /// Subnet routes this device advertises (may include the exit-node default routes)
    var advertisedRoutes: [String]?

    /// Subnet routes that have been approved/enabled by an admin
    var enabledRoutes: [String]?

    /// Mesh connection-quality report, as reported by the device itself
    var connectionQuality: CloudConnectionQuality?

    nonisolated init(
        id: UUID = UUID(),
        accountID: UUID,
        providerInstanceID: String,
        providerID: String,
        label: String,
        status: CloudInstanceStatus = .unknown
    ) {
        self.id = id
        self.accountID = accountID
        self.providerInstanceID = providerInstanceID
        self.providerID = providerID
        self.label = label
        self.status = status
        self.region = nil
        self.instanceType = nil
        self.image = nil
        self.ipv4Address = nil
        self.ipv6Address = nil
        self.privateIP = nil
        self.hostname = nil
        self.tags = []
        self.lastUpdated = Date()
    }

    // MARK: - SSH Integration

    /// Best address for SSH (prefers hostname for Tailscale/NetBird, public IPv4 for others)
    var sshHost: String? {
        // Tailscale & NetBird: prefer the MagicDNS/Magic-DNS FQDN over the overlay IP.
        // The FQDN (e.g. host.netbird.cloud) is stable across re-registration and ties
        // the host key to a name rather than the 100.x CG-NAT overlay address.
        if providerID == "tailscale" || providerID == "netbird" {
            return hostname ?? ipv4Address ?? ipv6Address ?? privateIP
        }
        return ipv4Address ?? hostname ?? ipv6Address ?? privateIP
    }

    /// Whether SSH is likely available
    /// - Returns true if status indicates running, OR if we have an IP but status is unknown
    ///   (e.g., Azure VMs where we can't get power state in bulk)
    var canSSH: Bool {
        guard sshHost != nil else { return false }
        return status.isSSHReady || status == .unknown
    }

    /// Default SSH username based on provider and image
    var defaultSSHUsername: String {
        switch providerID {
        case "linode": return "root"
        case "aws":
            // AWS default depends on the AMI/image - check image, label, and tags
            // Combine all searchable text for OS detection
            let searchText = [
                image,
                label,
                tags.joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " ").lowercased()

            if searchText.contains("ubuntu") { return "ubuntu" }
            if searchText.contains("debian") { return "admin" }
            if searchText.contains("centos") { return "centos" }
            if searchText.contains("fedora") { return "fedora" }
            if searchText.contains("rhel") || searchText.contains("red hat") { return "ec2-user" }
            if searchText.contains("suse") { return "ec2-user" }
            if searchText.contains("amazon") || searchText.contains("amzn") { return "ec2-user" }
            if searchText.contains("bitnami") { return "bitnami" }
            return "ec2-user"
        case "gcp": return "root"
        case "azure": return "azureuser"
        case "digitalocean": return "root"
        case "tailscale": return UserPreferences.effectiveUsername  // Default to display name for Tailscale
        case "netbird": return UserPreferences.effectiveUsername  // NetBird peers are real hosts; use the user's preferred username
        default: return "root"
        }
    }

    // MARK: - Search Support

    /// Check if instance matches a search query
    func matches(query: String) -> Bool {
        let searchQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        if searchQuery.isEmpty { return true }

        // Match against various fields
        if label.lowercased().contains(searchQuery) { return true }
        if ipv4Address?.contains(searchQuery) == true { return true }
        if ipv6Address?.lowercased().contains(searchQuery) == true { return true }
        if hostname?.lowercased().contains(searchQuery) == true { return true }
        if region?.lowercased().contains(searchQuery) == true { return true }
        if instanceType?.lowercased().contains(searchQuery) == true { return true }
        if tags.contains(where: { $0.lowercased().contains(searchQuery) }) { return true }

        return false
    }

    // MARK: - Network-Device Helpers

    /// True for overlay-mesh providers whose `image` carries a clean OS-family
    /// string ("linux", "macOS", …) — as opposed to VM providers whose image is
    /// an AMI/snapshot identifier.
    var isNetworkDevice: Bool {
        providerID == "tailscale" || providerID == "netbird"
    }

    /// True if this device advertises a default route (acts as an exit node).
    var isExitNode: Bool {
        guard let advertisedRoutes else { return false }
        return advertisedRoutes.contains("0.0.0.0/0") || advertisedRoutes.contains("::/0")
    }

    /// Advertised subnet routes excluding the exit-node default routes.
    var subnetRoutes: [String] {
        (advertisedRoutes ?? []).filter { $0 != "0.0.0.0/0" && $0 != "::/0" }
    }

    // MARK: - Display Helpers

    /// Formatted region name
    var regionDisplayName: String {
        region ?? "Unknown"
    }

    /// Short instance type display
    var instanceTypeShort: String {
        instanceType ?? "Unknown"
    }
}
