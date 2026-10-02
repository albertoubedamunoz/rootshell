//
//  CaptureController.swift
//  rootshell
//
//  Owns the active capture session: starts the tunnel if needed, pushes the
//  engine config to the VPN extension, and stops / finalizes sessions.
//

#if !CHINA_BUILD

import Foundation
import os.log

@MainActor
@Observable
final class CaptureController {
    static let shared = CaptureController()

    enum CaptureError: LocalizedError {
        case tunnelDidNotStart
        case engineUnavailable(String?)

        var errorDescription: String? {
            switch self {
            case .tunnelDidNotStart:
                String(localized: "The VPN did not connect, so capture could not start.", comment: "HTTP capture error")
            case .engineUnavailable(let detail):
                detail ?? String(localized: "The VPN extension did not accept the capture request. Update and reconnect the VPN.", comment: "HTTP capture error")
            }
        }
    }

    /// Engine counters from the provider status JSON.
    struct EngineStatus: Decodable, Equatable {
        var enabled: Bool
        var sessionID: String?
        var caLoaded: Bool
        var transactions: Int64
        var tunnels: Int64
        var tlsRejected: Int64
        var failures: Int64
        var bytesWritten: Int64
        var droppedBytes: Int64
        var activeMITM: Int
        var mitmOverflow: Int64
        var stopReason: String?
    }

    private(set) var activeSessionID: String?
    private(set) var isStarting = false
    private(set) var lastError: String?

    private let logger = CaptureSessionStore.logger

    private init() {
        if let persisted = CapturePaths.readEngineConfig(), persisted.enabled,
           CapturePaths.isValidSessionID(persisted.sessionID),
           CaptureSessionStore.shared.meta(persisted.sessionID)?.isRecording == true {
            activeSessionID = persisted.sessionID
        }
        #if STANDALONE && targetEnvironment(macCatalyst)
        MacVPNController.shared.captureConfigProvider = {
            MainActor.assumeIsolated {
                CaptureController.shared.engineConfigForMac()
            }
        }
        #endif
    }

    var isRecording: Bool { activeSessionID != nil }

    var engineStatus: EngineStatus? {
        guard let json = VPNManager.shared.latestStatusJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capture = object["capture"],
              let captureData = try? JSONSerialization.data(withJSONObject: capture) else { return nil }
        return try? JSONDecoder().decode(EngineStatus.self, from: captureData)
    }

    // MARK: - Start / stop

    /// Starts recording. Brings up the Local Capture tunnel when no VPN is connected.
    func start(name: String? = nil) async {
        guard !isStarting, activeSessionID == nil else { return }
        isStarting = true
        lastError = nil
        defer { isStarting = false }
        do {
            try CaptureCAManager.shared.ensureCA()
            let settings = SettingsStore.shared
            if !VPNManager.shared.isTunnelUp {
                // Persist first so the new tunnel comes up with the CA loaded.
                try CapturePaths.writeEngineConfig(engineConfig(sessionID: nil))
                try await VPNManager.shared.startDirectVPN(dnsServers: settings.value(Settings.HTTPCapture.directDNSServers))
                guard await waitForTunnel() else { throw CaptureError.tunnelDidNotStart }
            }
            let meta = try CaptureSessionStore.shared.create(
                name: name ?? Self.defaultName(),
                profileName: VPNManager.shared.activeProfileName,
                recordPackets: settings.value(Settings.HTTPCapture.recordPackets)
            )
            let config = engineConfig(sessionID: meta.id)
            try CapturePaths.writeEngineConfig(config)
            let reply = await send(.configure, json: configForTransport(config))
            let decoded = reply.flatMap { try? JSONDecoder().decode(CaptureReply.self, from: $0) }
            guard decoded?.ok == true else {
                try? CapturePaths.writeEngineConfig(engineConfig(sessionID: nil))
                CaptureSessionStore.shared.markEnded(meta.id)
                throw CaptureError.engineUnavailable(decoded?.error)
            }
            activeSessionID = meta.id
            // Existing connections predate capture; make apps reconnect through it.
            _ = await send(.reset)
            await CaptureSessionStore.shared.enforceRetention(limit: settings.value(Settings.HTTPCapture.retainedSessions))
        } catch {
            lastError = error.localizedDescription
            logger.error("capture start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        guard let id = activeSessionID else { return }
        activeSessionID = nil
        try? CapturePaths.writeEngineConfig(engineConfig(sessionID: nil))
        _ = await send(.stop)
        CaptureSessionStore.shared.markEnded(id)
        if CaptureSessionStore.isMirrored {
            await CaptureSessionStore.shared.mirrorFully(session: id)
        }
    }

    /// Re-sends rules and options to the engine (same session, same segment).
    func pushConfig() async {
        let config = engineConfig(sessionID: activeSessionID)
        try? CapturePaths.writeEngineConfig(config)
        guard VPNManager.shared.isTunnelUp else { return }
        _ = await send(.configure, json: configForTransport(config))
    }

    /// Closes existing connections so apps reconnect through the current rules.
    func resetConnections() async {
        _ = await send(.reset)
    }

    private func waitForTunnel() async -> Bool {
        for _ in 0..<60 {
            await VPNManager.shared.requestStatusUpdate()
            if VPNManager.shared.isTunnelUp { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func defaultName() -> String {
        Date().formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    // MARK: - Engine config

    func engineConfig(sessionID: String?) -> CaptureEngineConfig {
        let settings = SettingsStore.shared
        var config = CaptureEngineConfig()
        config.enabled = sessionID != nil
        config.sessionID = sessionID ?? ""
        config.mitmHosts = settings.value(Settings.HTTPCapture.mitmHosts)
        config.caCertPEM = CaptureCAManager.shared.certificatePEM ?? ""
        config.caProfileB64 = CaptureCAManager.shared.mobileconfig()?.base64EncodedString() ?? ""
        config.enableH2 = settings.value(Settings.HTTPCapture.enableHTTP2)
        config.skipUpstreamVerify = settings.value(Settings.HTTPCapture.skipUpstreamVerify)
        config.autoBypassPinned = settings.value(Settings.HTTPCapture.autoBypassPinned)
        config.maxBodyBytes = Int64(settings.value(Settings.HTTPCapture.maxBodyMB)) << 20
        config.maxSessionBytes = Int64(settings.value(Settings.HTTPCapture.maxSessionMB)) << 20
        config.pcap = settings.value(Settings.HTTPCapture.recordPackets)
        config.rewriteRules = Self.rewriteRules().filter(\.enabled)
        config.directDNSServers = settings.value(Settings.HTTPCapture.directDNSServers)
        return config
    }

    /// The macOS system extension can't read the keychain, so it gets the key inline.
    private func configForTransport(_ config: CaptureEngineConfig) -> CaptureEngineConfig {
        #if STANDALONE && targetEnvironment(macCatalyst)
        var withKey = config
        withKey.caKeyPEM = CaptureCAManager.shared.keyMaterial()?.keyPEM ?? ""
        return withKey
        #else
        return config
        #endif
    }

    #if STANDALONE && targetEnvironment(macCatalyst)
    fileprivate func engineConfigForMac() -> Data? {
        guard CaptureCAManager.shared.hasCA else { return nil }
        return try? JSONEncoder().encode(configForTransport(engineConfig(sessionID: activeSessionID)))
    }
    #endif

    // MARK: - Rules

    static func rewriteRules() -> [CaptureRewriteRule] {
        guard let data = SettingsStore.shared.value(Settings.HTTPCapture.rewriteRules),
              let rules = try? JSONDecoder().decode([CaptureRewriteRule].self, from: data) else { return [] }
        return rules
    }

    func saveRewriteRules(_ rules: [CaptureRewriteRule]) {
        SettingsStore.shared.set(Settings.HTTPCapture.rewriteRules, try? JSONEncoder().encode(rules))
        Task { await pushConfig() }
    }

    func saveHostRules(_ rules: [String]) {
        SettingsStore.shared.set(Settings.HTTPCapture.mitmHosts, rules)
        Task { await pushConfig() }
    }

    /// Adds "-host" ahead of every other rule so it is never decrypted.
    func excludeHost(_ host: String) {
        var rules = SettingsStore.shared.value(Settings.HTTPCapture.mitmHosts)
        let entry = "-" + host.lowercased()
        guard !rules.contains(entry) else { return }
        rules.insert(entry, at: 0)
        saveHostRules(rules)
    }

    func includeHost(_ host: String) {
        var rules = SettingsStore.shared.value(Settings.HTTPCapture.mitmHosts)
        let lower = host.lowercased()
        rules.removeAll { $0 == "-" + lower }
        if !rules.contains(lower) {
            rules.insert(lower, at: 0)
        }
        saveHostRules(rules)
        Task { await resetConnections() }
    }

    // MARK: - Transport

    func send(_ command: CaptureMessage.Command, body: Data? = nil) async -> Data? {
        await VPNManager.shared.sendProviderMessage(CaptureMessage.encode(command, body: body))
    }

    func send<T: Encodable>(_ command: CaptureMessage.Command, json: T) async -> Data? {
        await send(command, body: try? JSONEncoder().encode(json))
    }
}

#endif
