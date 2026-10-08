//
//  TailnetRouting.swift
//  rootshell
//
//  What the dial paths need to know about the in-app Tailscale engine,
//  readable from any thread, and the dialer that hands them tailnet sockets.
//

#if !CHINA_BUILD

import Foundation
import NIOCore
import NIOPosix
import os

nonisolated final class TailnetRouting: Sendable {
    static let shared = TailnetRouting()

    struct State: Sendable {
        /// The mode is rootshell Only (whether or not it is turned on).
        var rootshellOnly = false
        /// rootshell Only is turned on.
        var enabled = false
        var onDemand = true
        var exitNode = false
        var exitNodeAllowLAN = false
        /// MagicDNS suffix and peer names from the last netmap, so on-demand
        /// starts recognise short names before the engine runs.
        var suffix: String?
        var peerNames: Set<String> = []
        /// Hosts recently dialed over the tailnet, for Connection Info.
        var routedHosts: Set<String> = []
        /// ALL_PROXY / NO_PROXY for the local shell, nil when unused.
        var shellProxyEnvironment: [String: String]?
    }

    /// Seeded from saved settings, so connections restored at launch route
    /// correctly before the app's startup work runs.
    private let lock = OSAllocatedUnfairLock(initialState: TailnetRouting.savedState())

    static func savedState() -> State {
        let mode = TailnetModeSettings.load()
        var state = State()
        apply(mode, to: &state)
        if let cache = loadPeerCache() {
            state.suffix = cache.suffix
            state.peerNames = Set(cache.names)
        }
        return state
    }

    static func apply(_ mode: TailnetModeSettings, to state: inout State) {
        state.rootshellOnly = mode.effectiveMode == .rootshellOnly
        state.enabled = state.rootshellOnly && mode.inAppEnabled
        state.onDemand = mode.connectOnDemand
        state.exitNode = mode.exitNodeID?.isEmpty == false
        state.exitNodeAllowLAN = mode.exitNodeAllowLAN
    }

    // MARK: - Peer cache

    struct PeerCache: Codable, Sendable {
        var suffix: String?
        var names: [String]
    }

    private static var peerCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailnet-peers.json")
    }

    static func loadPeerCache() -> PeerCache? {
        guard let url = peerCacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PeerCache.self, from: data)
    }

    func storePeers(suffix: String?, names: Set<String>) {
        update { state in
            state.suffix = suffix
            state.peerNames = names
        }
        guard let url = Self.peerCacheURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(PeerCache(suffix: suffix, names: names.sorted())).write(to: url, options: .atomic)
    }

    var state: State { lock.withLock { $0 } }

    func update(_ body: @Sendable (inout State) -> Void) {
        lock.withLock { body(&$0) }
    }

    func noteRouted(_ host: String) {
        let key = Self.normalize(host)
        lock.withLock { _ = $0.routedHosts.insert(key) }
    }

    func wasRouted(_ host: String) -> Bool {
        let key = Self.normalize(host)
        return lock.withLock { $0.routedHosts.contains(key) }
    }

    static func normalize(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// A tailnet address or name, judged without the engine: 100.64/10,
    /// Tailscale's IPv6 range, *.ts.net, the MagicDNS suffix or a known peer.
    func looksLikeTailnet(_ host: String) -> Bool {
        let name = Self.normalize(host)
        if Self.isTailscaleIP(name) { return true }
        if name.hasSuffix(".ts.net") { return true }
        let state = state
        if let suffix = state.suffix, !suffix.isEmpty, name.hasSuffix("." + suffix) { return true }
        return state.peerNames.contains(name)
    }

    /// Whether a connection to host should start the engine on demand. With
    /// an exit node every remote host goes through the tailnet.
    func wantsEngine(for host: String) -> Bool {
        let state = state
        guard state.enabled, state.onDemand else { return false }
        if looksLikeTailnet(host) { return true }
        return state.exitNode && !Self.isLocal(Self.normalize(host), allowLAN: state.exitNodeAllowLAN)
    }

    static func isTailscaleIP(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 { return octets[0] == 100 && (64...127).contains(octets[1]) }
        return host.hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isLocal(_ host: String, allowLAN: Bool) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host == "::1" { return true }
        guard allowLAN else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
}

/// Shown when a tailnet host can't be reached because rootshell Only is off
/// or signed out.
nonisolated struct TailnetOffError: LocalizedError {
    var underlying: String?

    var errorDescription: String? {
        let hint = String(
            localized: "Tailscale (rootshell only) is off. Turn it on in Settings › VPN › Tailscale.",
            comment: "Connection error for a tailnet host while in-app Tailscale is off"
        )
        guard let underlying, !underlying.isEmpty else { return hint }
        return "\(underlying)\n\n\(hint)"
    }
}

nonisolated enum TailnetDialer {
    /// The tailnet address host is reached at in-app, or nil for the OS.
    /// Starts the engine on demand.
    static func route(_ host: String) async -> String? {
        let routing = TailnetRouting.shared
        let state = routing.state
        guard state.enabled else { return nil }
        if !TailnetGo.isRunning {
            var wanted = routing.wantsEngine(for: host)
            // A name the OS can't resolve may be a MagicDNS name not cached yet.
            if !wanted, state.onDemand, isName(host), await !osResolves(host) {
                wanted = true
            }
            guard wanted else { return nil }
            logger.info("Starting in-app Tailscale on demand for \(host, privacy: .public)")
            guard await TailnetInAppEngine.shared.ensureRunning() else {
                logger.error("In-app Tailscale didn't come up for \(host, privacy: .public)")
                return nil
            }
        }
        guard let ip = await TailnetGo.resolve(host) else { return nil }
        logger.info("\(host, privacy: .public) routes over in-app Tailscale (\(ip, privacy: .public))")
        routing.noteRouted(host)
        routing.noteRouted(ip)
        return ip
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetRouting")

    private static func isName(_ host: String) -> Bool {
        let name = TailnetRouting.normalize(host)
        return !name.isEmpty && !name.contains(":") && name.split(separator: ".").contains { Int($0) == nil }
    }

    /// Whether the system resolver knows host, waiting at most two seconds.
    private static func osResolves(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { result in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                finish(status == 0)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(true) }
        }
    }

    /// A connected Channel over the tailnet when host belongs to it, else nil.
    /// autoRead stays off, like MPTCPBootstrap, until Citadel installs its handlers.
    static func channel(host: String, port: Int, timeout: TimeAmount) async throws -> Channel? {
        guard let ip = await route(host) else { return nil }
        let fd = try await TailnetGo.dialTCP(host: ip, port: port, timeout: .nanoseconds(timeout.nanoseconds))
        do {
            return try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.autoRead, value: false)
                .takingOwnershipOfDescriptor(inputOutput: fd)
                .get()
        } catch {
            close(fd)
            throw error
        }
    }

    /// Adds the turn-it-on hint when a tailnet host failed through the OS
    /// while rootshell Only is the mode but isn't running.
    static func explain(_ error: Error, host: String) -> Error {
        let routing = TailnetRouting.shared
        guard routing.state.rootshellOnly, !TailnetGo.isRunning, routing.looksLikeTailnet(host) else { return error }
        return TailnetOffError(underlying: error.localizedDescription)
    }
}

#endif
