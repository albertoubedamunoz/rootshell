//
//  HolePunchConfig.swift
//  rootshell
//
//  Configuration for UDP hole-punching to traverse restrictive firewalls
//

import Foundation

// MARK: - Address Family

/// IP address family for hole-punch operations
enum AddressFamily: String, Codable, Hashable, Sendable, CaseIterable {
    /// Automatically detect based on target host resolution
    case auto
    /// Force IPv4
    case ipv4
    /// Force IPv6
    case ipv6

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto", comment: "Address family: auto-detect")
        case .ipv4: return String(localized: "IPv4", comment: "Address family: IPv4")
        case .ipv6: return String(localized: "IPv6", comment: "Address family: IPv6")
        }
    }
}

// MARK: - Hole-Punch Mode

/// When to perform UDP hole-punching
enum HolePunchMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Automatically detect if hole-punch is needed
    case automatic
    /// Always perform hole-punch (useful if you know firewall is restrictive)
    case always
    /// Never perform hole-punch
    case never

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic", comment: "Hole-punch mode: automatic detection")
        case .always: return String(localized: "Always", comment: "Hole-punch mode: always perform")
        case .never: return String(localized: "Never", comment: "Hole-punch mode: never perform")
        }
    }
}

// MARK: - Server Method

/// Method to send UDP punch packet from server
enum HolePunchServerMethod: String, Codable, Hashable, Sendable, CaseIterable {
    /// Auto-detect available method on server (tries raw socket first, then socat)
    case auto
    /// Use raw sockets via hping3/nping/scapy (requires sudo, but no SO_REUSEPORT needed)
    /// This is the preferred method as it allows multiple mosh sessions without port conflicts
    case rawSocket
    /// Use bash /dev/udp (most portable, IPv4 only, wrong source port)
    case bashUDP
    /// Use netcat (nc -u, wrong source port)
    case netcat
    /// Use socat with sourceport (requires SO_REUSEPORT on mosh-server for multi-session)
    case socat

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto-detect", comment: "Hole-punch server method: auto-detect")
        case .rawSocket: return String(localized: "Raw Socket (sudo)", comment: "Hole-punch server method: raw socket")
        case .bashUDP: return String(localized: "Bash /dev/udp", comment: "Hole-punch server method: bash UDP")
        case .netcat: return String(localized: "Netcat (nc)", comment: "Hole-punch server method: netcat")
        case .socat: return String(localized: "Socat", comment: "Hole-punch server method: socat")
        }
    }

    var description: String {
        switch self {
        case .auto:
            return String(localized: "Tries raw sockets (hping3/nping/scapy) first, falls back to socat", comment: "Hole-punch server method description: auto-detect")
        case .rawSocket:
            return String(localized: "Uses raw IP packets with correct source port. Requires sudo but supports multiple sessions.", comment: "Hole-punch server method description: raw socket")
        case .bashUDP:
            return String(localized: "Uses bash /dev/udp. Most portable but uses wrong source port (IPv4 only).", comment: "Hole-punch server method description: bash UDP")
        case .netcat:
            return String(localized: "Uses netcat. May not work with strict firewalls (wrong source port).", comment: "Hole-punch server method description: netcat")
        case .socat:
            return String(localized: "Uses socat with sourceport. Requires SO_REUSEPORT patch on mosh-server for multi-session.", comment: "Hole-punch server method description: socat")
        }
    }
}

// MARK: - STUN Server Configuration

/// Configuration for a STUN server
struct STUNServerConfig: Codable, Hashable, Sendable {
    /// STUN server hostname
    var host: String

    /// STUN server port (default: 3478)
    var port: Int

    /// Address family supported by this server
    var addressFamily: AddressFamily

    init(host: String, port: Int = 3478, addressFamily: AddressFamily = .auto) {
        self.host = host
        self.port = port
        self.addressFamily = addressFamily
    }
}

// MARK: - STUN Server Presets

/// Well-known STUN servers
struct STUNServer: Sendable {
    let host: String
    let port: Int
    let addressFamily: AddressFamily

    // MARK: - IPv4 STUN Servers

    /// Google STUN server (IPv4)
    static let googleV4 = STUNServer(host: "stun.l.google.com", port: 19302, addressFamily: .ipv4)

    /// Cloudflare STUN server (IPv4)
    static let cloudflareV4 = STUNServer(host: "stun.cloudflare.com", port: 3478, addressFamily: .ipv4)

    /// Twilio STUN server (IPv4)
    static let twilioV4 = STUNServer(host: "global.stun.twilio.com", port: 3478, addressFamily: .ipv4)

    // MARK: - IPv6 STUN Servers

    /// Google STUN server (IPv6)
    static let googleV6 = STUNServer(host: "stun.l.google.com", port: 19302, addressFamily: .ipv6)

    /// Cloudflare STUN server (IPv6)
    static let cloudflareV6 = STUNServer(host: "stun.cloudflare.com", port: 3478, addressFamily: .ipv6)

    // MARK: - Server Lists

    /// Default STUN servers for IPv4
    static let defaultIPv4Servers: [STUNServer] = [googleV4, cloudflareV4, twilioV4]

    /// Default STUN servers for IPv6
    static let defaultIPv6Servers: [STUNServer] = [googleV6, cloudflareV6]

    /// Convert to configuration struct
    func toConfig() -> STUNServerConfig {
        STUNServerConfig(host: host, port: port, addressFamily: addressFamily)
    }
}

// MARK: - Initial Strategy

/// Strategy for initial connection attempt in reactive hole-punch flow
enum HolePunchInitialStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Try direct UDP first, then hole-punch if timeout (default)
    /// Best for most users - avoids unnecessary STUN for direct connections
    case directFirst

    /// Always hole-punch (skip direct attempt)
    /// Use if you know hole-punch is needed (e.g., known restrictive firewall)
    case alwaysPunch

    /// Never hole-punch (direct only)
    /// Use for local/LAN connections where hole-punch breaks things
    case directOnly

    var displayName: String {
        switch self {
        case .directFirst: return String(localized: "Try Direct First", comment: "Hole-punch initial strategy: try direct first")
        case .alwaysPunch: return String(localized: "Always Hole-Punch", comment: "Hole-punch initial strategy: always hole-punch")
        case .directOnly: return String(localized: "Direct Only", comment: "Hole-punch initial strategy: direct only")
        }
    }

    var description: String {
        switch self {
        case .directFirst:
            return String(localized: "Tries direct connection first, falls back to hole-punch if it times out", comment: "Hole-punch initial strategy description: try direct first")
        case .alwaysPunch:
            return String(localized: "Always performs hole-punch setup (skips direct attempt)", comment: "Hole-punch initial strategy description: always hole-punch")
        case .directOnly:
            return String(localized: "Only tries direct connection, never hole-punches", comment: "Hole-punch initial strategy description: direct only")
        }
    }
}

// MARK: - Hole-Punch Configuration

/// Configuration for UDP hole-punching behavior
struct HolePunchConfig: Codable, Hashable, Sendable {
    /// Whether hole-punching is enabled
    var enabled: Bool

    /// When to perform hole-punch
    var mode: HolePunchMode

    /// Initial connection strategy for reactive hole-punch flow
    /// Controls whether to try direct UDP before hole-punching
    var initialStrategy: HolePunchInitialStrategy

    /// Timeout for direct UDP connection attempt (seconds)
    /// If no packets received within this time, triggers hole-punch
    var directAttemptTimeoutSeconds: TimeInterval

    /// Timeout before triggering reactive hole-punch during active session (seconds)
    /// If heartbeat not received within this time, assumes connectivity lost
    var heartbeatTimeoutSeconds: TimeInterval

    /// Interval to refresh hole-punch before conntrack expires (seconds)
    /// Typical conntrack UDP timeout is 30-180s; we refresh at 50-60s to be safe
    var refreshIntervalSeconds: Int

    /// Method to send UDP punch packet from server
    var serverMethod: HolePunchServerMethod

    /// Preferred local UDP port (0 = system assigned)
    /// Using a specific port helps with symmetric NAT and ensures
    /// the hole-punch binds to the same port as Mosh transport
    var preferredLocalPort: UInt16

    /// Maximum retry attempts for hole-punch
    var maxRetries: Int

    /// Address family preference
    /// .auto: Match the address family used to reach mosh-server
    /// .ipv4: Force IPv4 (useful if IPv6 hole-punch fails)
    /// .ipv6: Force IPv6
    var addressFamilyPreference: AddressFamily

    /// Custom STUN servers (empty = use defaults for address family)
    var customSTUNServers: [STUNServerConfig]

    /// Timeout for STUN discovery in seconds
    var stunTimeoutSeconds: TimeInterval

    /// Creates default hole-punch configuration
    init(
        enabled: Bool = false,  // Disabled by default - user enables via Settings > Connections > Roam
        mode: HolePunchMode = .automatic,
        initialStrategy: HolePunchInitialStrategy = .directFirst,
        directAttemptTimeoutSeconds: TimeInterval = 3.0,
        heartbeatTimeoutSeconds: TimeInterval = 10.0,
        refreshIntervalSeconds: Int = 55,
        serverMethod: HolePunchServerMethod = .auto,
        preferredLocalPort: UInt16 = 0,
        maxRetries: Int = 3,
        addressFamilyPreference: AddressFamily = .auto,
        customSTUNServers: [STUNServerConfig] = [],
        stunTimeoutSeconds: TimeInterval = 3.0
    ) {
        self.enabled = enabled
        self.mode = mode
        self.initialStrategy = initialStrategy
        self.directAttemptTimeoutSeconds = directAttemptTimeoutSeconds
        self.heartbeatTimeoutSeconds = heartbeatTimeoutSeconds
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.serverMethod = serverMethod
        self.preferredLocalPort = preferredLocalPort
        self.maxRetries = maxRetries
        self.addressFamilyPreference = addressFamilyPreference
        self.customSTUNServers = customSTUNServers
        self.stunTimeoutSeconds = stunTimeoutSeconds
    }

    // MARK: - STUN Server Selection

    /// Returns STUN servers to use for the given address family
    func stunServers(for family: AddressFamily) -> [STUNServer] {
        // If custom servers are configured, use those
        if !customSTUNServers.isEmpty {
            return customSTUNServers
                .filter { $0.addressFamily == family || $0.addressFamily == .auto }
                .map { STUNServer(host: $0.host, port: $0.port, addressFamily: $0.addressFamily) }
        }

        // Otherwise use defaults
        switch family {
        case .auto, .ipv4:
            return STUNServer.defaultIPv4Servers
        case .ipv6:
            return STUNServer.defaultIPv6Servers
        }
    }
}

// MARK: - Default Config Factory

extension HolePunchConfig {
    /// UserDefaults key for Roam hole-punch enabled setting
    static let roamEnabledKey = "roamHolePunchEnabled"

    /// Configuration with hole-punch enabled in automatic mode
    static var automatic: HolePunchConfig {
        HolePunchConfig(enabled: true, mode: .automatic)
    }

    /// Configuration with hole-punch always enabled
    static var always: HolePunchConfig {
        HolePunchConfig(enabled: true, mode: .always)
    }

    /// Configuration with hole-punch disabled
    static var disabled: HolePunchConfig {
        HolePunchConfig(enabled: false)
    }
}
