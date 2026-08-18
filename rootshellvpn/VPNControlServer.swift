//
//  VPNControlServer.swift
//  rootshellvpn (VPN host)
//
//  Unix-domain-socket control server in the App Group container. The Catalyst
//  app (same uid) connects and drives the host: activate the extension, start /
//  stop the tunnel with a resolved config, query status. Wire format is
//  length-prefixed JSON (4-byte big-endian length + `VPNControlRequest` /
//  `VPNControlResponse` body), matching the rootshell-helper socket protocol.
//
//  Every accepted connection is authenticated by code signature (audit token →
//  SecCode, see `VPNPeerTrust`) before any request is read: the socket path is
//  writable by any same-user process, so the connection itself proves nothing.
//

import Foundation
import Darwin
import os
import os.log

final class VPNControlServer: @unchecked Sendable {
    static let shared = VPNControlServer()

    private let log = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "server")
    private static let handleLog = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "server")
    private var listenFD: Int32 = -1

    /// Set by the watchdog before it closes the listener, so the accept loop
    /// can distinguish "rebind requested" from a genuine accept failure.
    private let rebindRequested = OSAllocatedUnfairLock(initialState: false)

    func start() {
        guard let path = VPNControlPaths.controlSocketPath else {
            log.error("no App Group container — cannot bind control socket")
            return
        }
        log.info("control socket: \(path, privacy: .public)")
        DispatchQueue.global().async { [weak self] in self?.serverLoop(path) }
    }

    /// Bind + accept, rebinding whenever the listener dies or the socket path
    /// is deleted out from under us (app builds prior to 2026-07 sweep every
    /// `*.sock` in the container when relaunching rootshell-helper, leaving
    /// this server accepting on an unlinked inode nobody can connect to).
    private func serverLoop(_ path: String) {
        while true {
            guard let fd = bindListeningSocket(path) else {
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            listenFD = fd

            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .now() + 5, repeating: 5)
            watchdog.setEventHandler { [log, rebindRequested] in
                guard access(path, F_OK) != 0 else { return }
                // close(fd) exactly once — the fd number can be reused as soon
                // as it's closed, so a second close would hit an innocent fd.
                let first = rebindRequested.withLock { requested -> Bool in
                    if requested { return false }
                    requested = true
                    return true
                }
                if first {
                    log.error("control socket path deleted externally; rebinding")
                    close(fd)   // wakes the blocked accept() with EBADF
                }
            }
            watchdog.resume()

            while true {
                let client = accept(fd, nil, nil)
                if client >= 0 {
                    DispatchQueue.global().async { self.handleConnection(client) }
                    continue
                }
                if errno == EINTR { continue }
                break
            }

            watchdog.cancel()
            let wasRebind = rebindRequested.withLock { requested -> Bool in
                defer { requested = false }
                return requested
            }
            if !wasRebind {
                log.error("accept() failed errno=\(errno); rebinding")
                close(fd)
            }
        }
    }

    private func bindListeningSocket(_ path: String) -> Int32? {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log.error("socket() errno=\(errno)"); return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, cap - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { log.error("bind() errno=\(errno)"); close(fd); return nil }
        // Blocks other users only. Same-user peers get authenticated by code
        // signature in handleConnection — chmod can't distinguish those.
        chmod(path, 0o700)
        guard listen(fd, 8) == 0 else { log.error("listen() errno=\(errno)"); close(fd); return nil }
        return fd
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        // Only our signed Catalyst app may drive the tunnel. Reject before
        // reading anything; the peer identity comes from the kernel's audit
        // token, not from the request.
        guard VPNPeerTrust.isPeerTrusted(fd: fd, requirement: VPNPeerTrust.appClientRequirement) else {
            let pid = VPNPeerTrust.peerPID(fd: fd)
            log.error("rejected control connection from untrusted peer (pid \(pid))")
            return
        }
        guard let body = Self.readFrame(fd),
              let request = try? JSONDecoder().decode(VPNControlRequest.self, from: body) else {
            return
        }

        // Dispatch on the main actor (the controllers are @MainActor), block
        // this I/O thread until the response is ready.
        let sem = DispatchSemaphore(value: 0)
        var response = VPNControlResponse(success: false, error: "unhandled")
        Task { @MainActor in
            response = await Self.handle(request)
            sem.signal()
        }
        sem.wait()

        if !response.success {
            log.error("\(request.command.rawValue, privacy: .public) -> error: \(response.error ?? "?", privacy: .public)")
        } else {
            switch request.command {
            case .ping, .getStatus, .extensionStatus:
                log.debug("\(request.command.rawValue, privacy: .public) -> ok")
            default:
                log.info("\(request.command.rawValue, privacy: .public) -> ok")
            }
        }

        if let data = try? JSONEncoder().encode(response) {
            Self.writeFrame(fd, data)
        }
    }

    @MainActor
    private static func handle(_ request: VPNControlRequest) async -> VPNControlResponse {
        switch request.command {
        case .ping:
            // Identify this build so the app can spot a stale running host.
            let info = VPNHostInfoResponse(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                bundlePath: Bundle.main.bundlePath
            )
            return VPNControlResponse(success: true, payload: try? JSONEncoder().encode(info))

        case .activateExtension:
            // Fire activation and return immediately; the app polls
            // `extensionStatus` until activated (and surfaces approval-needed).
            SystemExtensionController.shared.activate()
            let payload = try? JSONEncoder().encode(
                VPNExtensionStatusResponse(state: mapState(SystemExtensionController.shared.state))
            )
            return VPNControlResponse(success: true, payload: payload)

        case .extensionStatus:
            let payload = try? JSONEncoder().encode(
                VPNExtensionStatusResponse(state: mapState(SystemExtensionController.shared.state))
            )
            return VPNControlResponse(success: true, payload: payload)

        case .startVPN:
            guard let payload = request.payload,
                  let start = try? JSONDecoder().decode(VPNStartRequest.self, from: payload),
                  let resolved = start.resolvedConfig else {
                return VPNControlResponse(success: false, error: "startVPN requires a resolvedConfig payload")
            }
            do {
                try await VPNTunnelController.shared.start(
                    profileID: start.profileID,
                    transportType: start.transportType,
                    resolvedConfig: resolved,
                    usesAgentSigning: start.usesAgentSigning
                )
                return VPNControlResponse(success: true)
            } catch {
                return VPNControlResponse(success: false, error: error.localizedDescription)
            }

        case .stopVPN:
            do {
                try await VPNTunnelController.shared.stop()
                return VPNControlResponse(success: true)
            } catch {
                return VPNControlResponse(success: false, error: error.localizedDescription)
            }

        case .getStatus:
            let status = await VPNTunnelController.shared.statusString()
            let json = await VPNTunnelController.shared.providerStatusJSON()
            if json == nil && (status == "connected" || status == "reasserting") {
                handleLog.error("getStatus: provider returned no statusJSON while \(status, privacy: .public)")
            }
            let profileID = await VPNTunnelController.shared.activeProfileID()
            let payload = try? JSONEncoder().encode(
                VPNTunnelStatusResponse(status: status, profileID: profileID, statusJSON: json)
            )
            return VPNControlResponse(success: true, payload: payload)
        }
    }

    private static func mapState(_ s: SystemExtensionController.State) -> VPNExtensionStatusResponse.State {
        switch s {
        case .activated: return .activated
        // .requesting is NOT approval-pending: every activation passes through
        // it briefly (an already-approved extension completes in <1s), and
        // reporting it as awaitingApproval flashes the approval banner on
        // every connect. Only requestNeedsUserApproval means the user must act.
        case .requesting: return .requesting
        case .needsApproval: return .awaitingApproval
        case .needsReboot: return .needsReboot
        case .failed: return .failed
        case .unknown: return .notInstalled
        }
    }

    // MARK: - Length-framed wire I/O (4-byte big-endian length + JSON body)

    private static func readFrame(_ fd: Int32) -> Data? {
        var lenBytes = [UInt8](repeating: 0, count: 4)
        guard readExact(fd, &lenBytes, 4) else { return nil }
        let length = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 4 * 1024 * 1024 else { return nil }
        var body = [UInt8](repeating: 0, count: Int(length))
        guard readExact(fd, &body, Int(length)) else { return nil }
        return Data(body)
    }

    private static func readExact(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
        var total = 0
        while total < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, count - total) }
            if n <= 0 { return false }
            total += n
        }
        return true
    }

    private static func writeFrame(_ fd: Int32, _ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        frame.withUnsafeBytes { raw in
            var off = 0
            let base = raw.baseAddress!
            while off < frame.count {
                let n = Darwin.write(fd, base + off, frame.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}
