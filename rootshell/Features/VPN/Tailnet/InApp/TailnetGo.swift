//
//  TailnetGo.swift
//  rootshell
//
//  Swift→Go calls for the in-app Tailscale engine, which lives in the
//  TrzszSSH Go runtime. Like TSSHCallGate, this is the only file that calls
//  the Iosbridge Tailnet* functions; blocking calls run off the caller.
//

#if !CHINA_BUILD

import Foundation
@preconcurrency import TrzszSSH

nonisolated enum TailnetGo {
    struct GoError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ProxyInfo: Decodable, Sendable, Equatable {
        let port: Int
        let user: String
        let pass: String
    }

    struct PingResult: Decodable, Sendable {
        var ip: String?
        var nodeName: String?
        var latencyMs: Double?
        var endpoint: String?
        var derp: String?
        var error: String?
    }

    private static let queue = DispatchQueue(
        label: "com.rootshell.tailnet.go",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func run<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func check(_ ok: Bool, _ error: NSError?) throws {
        guard ok else { throw GoError(message: error?.localizedDescription ?? "Tailscale call failed") }
    }

    static var isSupported: Bool { IosbridgeTailnetSupported() }

    /// Up and signed in; cheap (no network).
    static var isRunning: Bool { IosbridgeTailnetRunning() }

    static func start(configJSON: String, store: TailnetGoStateStore, callback: TailnetGoCallback) async throws {
        try await run {
            var error: NSError?
            try check(IosbridgeTailnetStart(configJSON, store, callback, &error), error)
        }
    }

    static func stop() async {
        _ = try? await run { IosbridgeTailnetStop() }
    }

    static func login() async throws {
        try await run {
            var error: NSError?
            try check(IosbridgeTailnetLogin(&error), error)
        }
    }

    static func logout() async throws {
        try await run {
            var error: NSError?
            try check(IosbridgeTailnetLogout(&error), error)
        }
    }

    static func status() async -> TailnetStatus? {
        let json = (try? await run { IosbridgeTailnetStatus() }) ?? ""
        return try? JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    static func setPrefs(json: String) async throws {
        try await run {
            var error: NSError?
            try check(IosbridgeTailnetSetPrefs(json, &error), error)
        }
    }

    /// The tailnet address for host, or nil when the OS should reach it.
    /// Blocks for a DNS lookup at most; call off the main thread.
    static func resolveBlocking(_ host: String) -> String? {
        let ip = IosbridgeTailnetResolve(host)
        return ip.isEmpty ? nil : ip
    }

    static func resolve(_ host: String) async -> String? {
        (try? await run { resolveBlocking(host) }) ?? nil
    }

    /// A connected stream socket to host:port over the tailnet. The caller
    /// owns the descriptor.
    static func dialTCP(host: String, port: Int, timeout: Duration) async throws -> Int32 {
        try await run {
            var fd = -1
            var error: NSError?
            try check(IosbridgeTailnetDialTCP(host, port, timeout.milliseconds, &fd, &error), error)
            return Int32(fd)
        }
    }

    /// A connected datagram socket for a UDP flow to host:remotePort. A
    /// non-zero localPort binds that port on this node.
    static func dialUDP(host: String, remotePort: Int, localPort: Int = 0, timeout: Duration = .seconds(10)) async throws -> Int32 {
        try await run {
            var fd = -1
            var error: NSError?
            try check(IosbridgeTailnetDialUDP(host, remotePort, localPort, timeout.milliseconds, &fd, &error), error)
            return Int32(fd)
        }
    }

    static func ping(host: String, timeout: Duration) async -> PingResult {
        let json = (try? await run { IosbridgeTailnetPing(host, timeout.milliseconds) }) ?? ""
        return (try? JSONDecoder().decode(PingResult.self, from: Data(json.utf8)))
            ?? PingResult(error: "Tailscale ping failed")
    }

    static func startProxy() async throws -> ProxyInfo {
        let json: String = try await run {
            var error: NSError?
            let json = IosbridgeTailnetProxyStart(&error)
            if let error { throw GoError(message: error.localizedDescription) }
            return json
        }
        return try JSONDecoder().decode(ProxyInfo.self, from: Data(json.utf8))
    }

    static func stopProxy() async {
        _ = try? await run { IosbridgeTailnetProxyStop() }
    }
}

private extension Duration {
    nonisolated var milliseconds: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Node state for the in-app engine: the same keychain items the iOS VPN
/// extension uses, so both modes are one device.
nonisolated final class TailnetGoStateStore: NSObject, IosbridgeTailnetStateStoreProtocol, @unchecked Sendable {
    func readState(_ key: String?) throws -> Data {
        try TailnetKeychainState.read(key ?? "")
    }

    func writeState(_ key: String?, value: Data?) throws {
        try TailnetKeychainState.write(key ?? "", value ?? Data())
    }
}

/// Status pushes from Go, delivered on Go's goroutine threads.
nonisolated final class TailnetGoCallback: NSObject, IosbridgeTailnetCallbackProtocol, @unchecked Sendable {
    private let onStatus: @Sendable (TailnetStatus) -> Void

    init(onStatus: @escaping @Sendable (TailnetStatus) -> Void) {
        self.onStatus = onStatus
    }

    func onTailnetState(_ statusJSON: String?) {
        guard let statusJSON,
              let status = try? JSONDecoder().decode(TailnetStatus.self, from: Data(statusJSON.utf8)) else { return }
        onStatus(status)
    }
}

#endif
