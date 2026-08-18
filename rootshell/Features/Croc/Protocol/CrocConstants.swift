#if !targetEnvironment(macCatalyst)

import Foundation

/// Constants matching the Go croc implementation for wire-protocol compatibility.
nonisolated enum CrocConstants {
    /// Maximum TCP buffer size for framed messages (64 KB).
    static let tcpBufferSize = 1024 * 64

    /// Maximum size of a single read message (64 MB).
    static let maxReadMessageSize = 1024 * 1024 * 64

    /// Chunk size for file data transfer (half of TCP buffer = 32 KB).
    static let chunkSize = tcpBufferSize / 2

    /// Magic bytes prepended to every framed TCP message.
    static let magic = Data("croc".utf8)

    // MARK: - Default Relay Configuration

    /// Default IPv4 relay hostname.
    static let defaultRelayHost = "croc.schollz.com"

    /// Default IPv6 relay hostname.
    static let defaultRelay6Host = "croc6.schollz.com"

    /// Default relay port.
    static let defaultPort = "9009"

    /// Default relay port as integer.
    static let defaultPortInt = 9009

    /// Default relay password.
    static let defaultPassphrase = "pass123"

    /// Default number of transfer ports (multiplexed data channels).
    static let defaultTransfers = 4

    /// Default multicast address for LAN peer discovery.
    static let defaultMulticastAddress = "239.255.255.250"

    /// IPv6 multicast group for LAN peer discovery.
    static let defaultMulticastAddress6 = "ff02::c"

    /// UDP port for multicast peer discovery (peerdiscovery library default; NOT the relay port).
    static let discoveryPort: UInt16 = 9999

    /// Default elliptic curve for PAKE key exchange.
    static let defaultCurve = "p256"

    /// Default hash algorithm for file verification.
    static let defaultHashAlgorithm = "xxhash"

    // MARK: - Relay Server

    /// Room cleanup interval for relay server.
    static let roomCleanupInterval: TimeInterval = 10 * 60

    /// Room time-to-live for relay server.
    static let roomTTL: TimeInterval = 3 * 60 * 60

    // MARK: - Timeouts

    /// TCP connection timeout.
    static let connectionTimeout: TimeInterval = 30

    /// Relay candidate timeout after the initial fast-fail attempt.
    static let relayConnectTimeout: TimeInterval = 5

    /// Timeout when probing sender-advertised local relay addresses.
    static let localRelayConnectTimeout: TimeInterval = 0.5

    /// Delay before the sender connects to its own local relay.
    static let localRelayStartupDelay: TimeInterval = 0.5

    /// Timeout for a local relay listener to reach the ready state.
    static let localRelayReadyTimeout: TimeInterval = 5

    /// TCP read/write deadline.
    static let readWriteDeadline: TimeInterval = 3 * 60 * 60

    /// Short read timeout for payload after header.
    static let shortReadTimeout: TimeInterval = 10

    // MARK: - LAN Discovery

    /// Delay between multicast broadcast packets.
    static let discoveryDelay: TimeInterval = 0.020

    /// Receiver discovery timeout.
    static let discoveryTimeout: TimeInterval = 0.200

    /// Sender discovery time limit (when using external relay).
    static let senderDiscoveryTimeLimit: TimeInterval = 30

    // MARK: - Relay Authentication

    /// Weak key used for relay server PAKE authentication.
    static let relayWeakKey: [UInt8] = [1, 2, 3]

    /// Curve used for relay server PAKE authentication.
    static let relayCurve = "siec"

    // MARK: - Public DNS Servers (for --internal-dns)

    static let publicDNS = [
        "1.0.0.1",                // Cloudflare
        "1.1.1.1",                // Cloudflare
        "[2606:4700:4700::1111]", // Cloudflare
        "[2606:4700:4700::1001]", // Cloudflare
        "8.8.4.4",                // Google
        "8.8.8.8",                // Google
        "[2001:4860:4860::8844]", // Google
        "[2001:4860:4860::8888]", // Google
        "9.9.9.9",                // Quad9
        "149.112.112.112",        // Quad9
        "[2620:fe::fe]",          // Quad9
        "[2620:fe::fe:9]",        // Quad9
        "8.26.56.26",             // Comodo
        "8.20.247.20",            // Comodo
        "208.67.220.220",         // Cisco OpenDNS
        "208.67.222.222",         // Cisco OpenDNS
        "[2620:119:35::35]",      // Cisco OpenDNS
        "[2620:119:53::53]",      // Cisco OpenDNS
    ]

    // MARK: - Version

    static let version = "v10.4.2"
}

#endif
