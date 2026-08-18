//
//  MacVPNController.swift
//  rootshell (Catalyst, Standalone)
//
//  Entry point for VPN-over-SSH on macOS. The Catalyst app can't host a packet
//  tunnel, so this launches the native `rootshellvpn.app` agent (system-extension
//  host) and drives it over the App Group control socket: activate the extension,
//  resolve the profile + secrets, start/stop the tunnel, poll status.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import Darwin
import os.log

@MainActor
final class MacVPNController {
    static let shared = MacVPNController()

    private let logger = Logger(subsystem: "com.rootshell", category: "MacVPNController")
    nonisolated private static let fileLogger = Logger(subsystem: "com.rootshell", category: "MacVPNController")

    /// The host agent ships inside the app bundle and is launched IN PLACE —
    /// no /Applications install. Sparkle updates the whole bundle atomically,
    /// so the bundled copy is always current (system-extension activation
    /// requires rootshell.app itself to live in /Applications). Dev builds
    /// (deploy artifact gitignored) fall back to a manually installed copy.
    nonisolated static var hostAppURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("rootshellvpn.app"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let installed = URL(fileURLWithPath: "/Applications/rootshellvpn.app")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    /// Invoked when the system extension is waiting on user approval (so the app
    /// can tell the user to approve it), and when that resolves. Called on the
    /// main actor.
    var onApprovalRequired: (() -> Void)?
    var onApprovalResolved: (() -> Void)?

    enum MacVPNError: LocalizedError {
        case hostNotInstalled
        case hostUnreachable
        case profileNotFound
        case hostKeyNotTrusted(String)
        case activationFailed
        case activationTimedOut

        var errorDescription: String? {
            switch self {
            case .hostNotInstalled: return "The rootshell VPN helper is missing from the app bundle."
            case .hostUnreachable: return "Could not reach the rootshell VPN helper."
            case .profileNotFound: return "VPN profile not found."
            case .hostKeyNotTrusted(let host): return "No trusted SSH host key for \(host). Connect to this server in a regular SSH terminal session first so its host key can be verified and saved, then start the VPN."
            case .activationFailed: return "The VPN system extension failed to activate."
            case .activationTimedOut: return "Timed out waiting for the VPN system extension to be approved."
            }
        }
    }

    // MARK: - Host lifecycle

    /// Ensure the correct host agent is running and answering.
    ///
    /// The authoritative host is the bundled copy; a running host is "current"
    /// only when its version + bundle path match it. That self-reported info is
    /// only accepted from a peer whose code signature checked out —
    /// `VPNHostConnection` refuses to exchange anything with an unverified
    /// listener, so an impostor on the socket can't spoof it. A mismatch (stale
    /// /Applications copy, or a Sparkle update swapped the bundle under a
    /// running host) requires killing the old instance — macOS `open` reuses a
    /// running agent, so old code would silently keep serving otherwise. Never
    /// swap under a live tunnel; defer to the next idle connect instead.
    func ensureHostRunning() async throws {
        guard let hostURL = Self.hostAppURL else {
            throw MacVPNError.hostNotInstalled
        }
        let expectedVersion = Self.bundleVersion(hostURL)
        let running = await hostInfo()

        if let running, running.version == expectedVersion, running.bundlePath == hostURL.path {
            return
        }

        if running != nil {
            let connected = (await status())?.status == "connected"
            if connected {
                logger.info("stale VPN host is serving a live tunnel; deferring swap")
                return
            }
            logger.info("stale VPN host running; replacing with bundled copy")
        }

        // Unresponsive (dead or wedged) or stale: any live instance must be
        // verifiably dead before relaunch. Killing the host never drops the
        // tunnel (the sysext is an independent process).
        await terminateHost()
        launchHost(hostURL)
        try await awaitReady()
    }

    private func awaitReady() async throws {
        for _ in 0..<30 {   // ~3s
            try? await Task.sleep(for: .milliseconds(100))
            if await ping() { return }
        }
        throw MacVPNError.hostUnreachable
    }

    /// Terminate any running host agent and wait until it's actually gone,
    /// escalating SIGTERM → SIGKILL. `open` reuses a running instance, so
    /// install/relaunch must not proceed while the old process survives.
    private func terminateHost() async {
        for sig in ["TERM", "KILL"] {
            let killed = await Task.detached {
                Self.spawnAndWait("/usr/bin/killall", ["killall", "-\(sig)", "rootshellvpn"]) == 0
            }.value
            if !killed { return }   // no matching process — already gone
            for _ in 0..<10 {   // up to 2s per signal
                try? await Task.sleep(for: .milliseconds(200))
                let alive = await Task.detached { Self.hostProcessAlive() }.value
                if !alive { return }
            }
            logger.error("VPN host survived SIG\(sig, privacy: .public)")
        }
    }

    nonisolated private static func hostProcessAlive() -> Bool {
        // Signal 0 = existence check, nothing delivered.
        spawnAndWait("/usr/bin/pkill", ["pkill", "-0", "-x", "rootshellvpn"]) == 0
    }

    /// Spawn a tool and return its exit status (-1 on spawn/abnormal exit).
    nonisolated private static func spawnAndWait(_ path: String, _ argv: [String]) -> Int32 {
        var pid: pid_t = 0
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        guard posix_spawn(&pid, path, nil, nil, cArgs, environ) == 0 else { return -1 }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid, (status & 0x7f) == 0 else { return -1 }
        return (status >> 8) & 0xff
    }

    nonisolated private static func bundleVersion(_ appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    private func launchHost(_ hostURL: URL) {
        Task.detached {
            let rc = Self.spawnAndWait("/usr/bin/open", ["open", hostURL.path])
            if rc != 0 { Self.fileLogger.error("failed to launch host: \(rc)") }
        }
    }

    // MARK: - Control

    /// Activate the system extension and wait until it's live. Non-blocking on
    /// the host: it returns immediately and we poll `extensionStatus`, surfacing
    /// approval-needed to the UI (the host opens System Settings). All the waiting
    /// happens via async sleeps + off-actor socket I/O, so the UI never blocks.
    func activateExtension() async throws {
        try await ensureHostRunning()
        _ = try await send(VPNControlRequest(command: .activateExtension))

        var announcedApproval = false
        for _ in 0..<300 {   // up to ~5 min
            switch await extensionStatus()?.state {
            case .activated:
                if announcedApproval { onApprovalResolved?() }
                return
            case .awaitingApproval:
                if !announcedApproval { announcedApproval = true; onApprovalRequired?() }
            case .failed:
                throw MacVPNError.activationFailed
            default:
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw MacVPNError.activationTimedOut
    }

    /// Fast liveness probe (2s timeout), off-main. Lets cold-start restore skip
    /// status queries — and their error logging — when no host is running.
    func isHostResponsive() async -> Bool { await ping() }

    func extensionStatus() async -> VPNExtensionStatusResponse? {
        guard let response = try? await send(VPNControlRequest(command: .extensionStatus)),
              let payload = response.payload else { return nil }
        return try? JSONDecoder().decode(VPNExtensionStatusResponse.self, from: payload)
    }

    func start(profileID: UUID) async throws {
        guard var snapshot = VPNSharedProfileStore.profile(id: profileID) else {
            throw MacVPNError.profileNotFound
        }
        // Pin fresh host keys / trusted host CAs from the app's stores
        // (unreachable from the root sysext) and refuse to start when neither
        // exists. The sysext verifies the server against these on connect.
        let known = KnownHostsManager.shared.getHost(hostname: snapshot.host, port: snapshot.port)
        let caKeys = HostCAManager.shared.trustedCAOpenSSHKeys(forHost: snapshot.host)
        guard known != nil || !caKeys.isEmpty else {
            throw MacVPNError.hostKeyNotTrusted(snapshot.host)
        }
        snapshot.hostKey = known.map(VPNPinnedHostKey.init)
        snapshot.trustedCAKeys = caKeys.isEmpty ? nil : caKeys
        if var jump = snapshot.jumpHost {
            let jumpKnown = KnownHostsManager.shared.getHost(hostname: jump.host, port: jump.port)
            let jumpCAKeys = HostCAManager.shared.trustedCAOpenSSHKeys(forHost: jump.host)
            guard jumpKnown != nil || !jumpCAKeys.isEmpty else {
                throw MacVPNError.hostKeyNotTrusted(jump.host)
            }
            jump.hostKey = jumpKnown.map(VPNPinnedHostKey.init)
            jump.trustedCAKeys = jumpCAKeys.isEmpty ? nil : jumpCAKeys
            snapshot.jumpHost = jump
        }
        let resolved = try VPNCredentialResolver.resolve(snapshot: snapshot)
        let payload = try VPNCredentialResolver.encode(resolved)

        let isAgentKey = { (credential: VPNResolvedCredential?) -> Bool in
            if case .agentKey = credential { return true }
            return false
        }
        let request = VPNStartRequest(
            profileID: profileID,
            transportType: snapshot.transportType.rawValue,
            resolvedConfig: payload,
            usesAgentSigning: isAgentKey(resolved.credential) || isAgentKey(resolved.jumpCredential)
        )
        let body = try JSONEncoder().encode(request)

        try await ensureHostRunning()
        let response = try await send(VPNControlRequest(command: .startVPN, payload: body))
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "start failed")
        }
    }

    func stop() async throws {
        // A wedged host must not leave the user unable to disconnect (the
        // sysext keeps the tunnel up independently): recover the host and
        // retry once before surfacing an error.
        var response: VPNControlResponse
        do {
            response = try await send(VPNControlRequest(command: .stopVPN))
        } catch {
            logger.error("stop failed (\(error.localizedDescription, privacy: .public)); recovering host and retrying")
            try await ensureHostRunning()
            response = try await send(VPNControlRequest(command: .stopVPN))
        }
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "stop failed")
        }
    }

    func status() async -> VPNTunnelStatusResponse? {
        do {
            let response = try await send(VPNControlRequest(command: .getStatus))
            guard let payload = response.payload else {
                logger.error("getStatus: response missing payload")
                return nil
            }
            return try JSONDecoder().decode(VPNTunnelStatusResponse.self, from: payload)
        } catch {
            logger.error("getStatus failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Socket I/O (explicitly off the main actor)

    // Dedicated background queue for the blocking unix-socket round trips. Using
    // an explicit queue (not Task.detached) guarantees the blocking read never
    // runs on the main actor — during the system-extension approval wait the host
    // doesn't reply for a while, and any main-actor hop there beachballs the UI.
    nonisolated private static let ioQueue = DispatchQueue(
        label: "com.rootshell.vpn.host-io", attributes: .concurrent
    )

    private func ping() async -> Bool {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: VPNHostConnection.ping()) }
        }
    }

    private func hostInfo() async -> VPNHostInfoResponse? {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: VPNHostConnection.hostInfo()) }
        }
    }

    private func send(_ request: VPNControlRequest) async throws -> VPNControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do { continuation.resume(returning: try VPNHostConnection.send(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

#endif
