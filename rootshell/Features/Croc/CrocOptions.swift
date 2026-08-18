#if !targetEnvironment(macCatalyst)

import Foundation

/// Configuration options for a croc transfer session.
/// Mirrors Go's `croc.Options` struct field-for-field.
nonisolated struct CrocOptions: Sendable {
    /// Whether this client is the sender (true) or receiver (false).
    var isSender: Bool = false

    /// Shared secret code phrase for PAKE key exchange.
    var sharedSecret: String = ""

    /// Room name derived from shared secret (SHA256 of code[:4] + "croc").
    var roomName: String = ""

    /// Debug logging enabled.
    var debug: Bool = false

    /// IPv4 relay address (host:port).
    var relayAddress: String = ""

    /// IPv6 relay address (host:port).
    var relayAddress6: String = ""

    /// Ports used for multiplexed data transfer.
    var relayPorts: [String] = []

    /// Password for relay server authentication.
    var relayPassword: String = CrocConstants.defaultPassphrase

    /// Redirect received file to stdout.
    var stdout: Bool = false

    /// Automatically agree to all prompts (--yes).
    var noPrompt: Bool = false

    /// Disable multiplexed transfer (use single port).
    var noMultiplexing: Bool = false

    /// Disable local relay / LAN discovery.
    var disableLocal: Bool = false

    /// Force local-only connections (no external relay).
    var onlyLocal: Bool = false

    /// Ignore piped stdin.
    var ignoreStdin: Bool = false

    /// Prompt both sender and receiver with machine ID (--ask).
    var ask: Bool = false

    /// Sending text instead of files (--text).
    var sendingText: Bool = false

    /// Disable compression.
    var noCompress: Bool = false

    /// Sender IP if known (e.g., "10.0.0.1:9009").
    var ip: String = ""

    /// Auto-overwrite without prompting.
    var overwrite: Bool = false

    /// Elliptic curve for PAKE (p256, p384, p521, siec, ed25519).
    var curve: String = CrocConstants.defaultCurve

    /// Hash algorithm (xxhash, imohash, md5).
    var hashAlgorithm: String = CrocConstants.defaultHashAlgorithm

    /// Upload speed throttle (e.g., "500k", "10m").
    var throttleUpload: String = ""

    /// Zip folder before sending.
    var zipFolder: Bool = false

    /// Testing flag (internal use).
    var testFlag: Bool = false

    /// Respect .gitignore when sending.
    var gitIgnore: Bool = false

    /// Multicast address for LAN discovery.
    var multicastAddress: String = CrocConstants.defaultMulticastAddress

    /// Show QR code of receive command.
    var showQrCode: Bool = false

    /// Exclude files containing any of these strings.
    var exclude: [String] = []

    /// Disable all output.
    var quiet: Bool = false

    /// Disable copy to clipboard.
    var disableClipboard: Bool = false

    /// Copy full command with env variable to clipboard.
    var extendedClipboard: Bool = false

    /// Output folder for received files.
    var outputFolder: String = "."

    /// Use internal DNS resolver.
    var internalDNS: Bool = false

    /// SOCKS5 proxy address.
    var socks5Proxy: String = ""

    /// HTTP CONNECT proxy address.
    var httpProxy: String = ""

    /// Text to send (when sendingText is true).
    var text: String = ""

    /// Base port for relay.
    var port: Int = CrocConstants.defaultPortInt

    /// Number of transfer ports.
    var transfers: Int = CrocConstants.defaultTransfers
}

#endif
