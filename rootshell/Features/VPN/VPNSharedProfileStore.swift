//
//  VPNSharedProfileStore.swift
//  rootshell
//
//  Shared non-secret VPN profile mirror stored in the app group for
//  extensions, widgets, and background App Intents.
//

import Foundation
import os.log

nonisolated enum VPNSharedTransportType: String, Codable, Sendable, Hashable {
    case ssh
    case tssh
    /// No remote server: the extension dials upstream itself (HTTP capture).
    case direct
    /// Tailscale, optionally with an SSH egress host (iOS only).
    case tailscale
}

nonisolated enum VPNSharedAuthMethod: String, Codable, Sendable, Hashable {
    case none
    case savedPassword
    case key
    case passwordRequired
}

nonisolated struct VPNSharedProfileAuth: Codable, Sendable, Hashable {
    var method: VPNSharedAuthMethod
    var keyID: UUID?

    var isBackgroundStartable: Bool {
        switch method {
        case .none, .savedPassword, .key:
            return true
        case .passwordRequired:
            return false
        }
    }
}

/// Host key pinned for the VPN path. Captured from KnownHostsManager in the
/// main app; the extension refuses to connect unless the server presents it.
nonisolated struct VPNPinnedHostKey: Codable, Sendable, Hashable {
    var keyType: String          // e.g. "ssh-ed25519"
    var publicKeyBase64: String  // base64 wire blob (KnownHost.publicKeyData)
    var fingerprint: String      // "SHA256:" + colon-hex (KnownHost.fingerprint)
}

nonisolated struct VPNSharedJumpHostSnapshot: Codable, Sendable, Hashable {
    var tsshRelay: TSSHRelaySettings? = nil
    var host: String
    var port: Int
    var username: String
    var auth: VPNSharedProfileAuth
    var hostKey: VPNPinnedHostKey?
    // Canonical "<keytype> <base64>" CA public keys (HostCAManager) whose
    // patterns match this host; a CA-signed host certificate validates
    // against these when no plain key is pinned.
    var trustedCAKeys: [String]?
}

nonisolated struct VPNSharedProfileSnapshot: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var modifiedAt: Date
    var name: String
    var host: String
    var port: Int
    var username: String
    var transportType: VPNSharedTransportType
    var auth: VPNSharedProfileAuth
    var jumpHost: VPNSharedJumpHostSnapshot?
    var trzszMode: String?
    var trzszUDPPortMin: Int?
    var trzszUDPPortMax: Int?
    var trzszMTU: Int?
    var trzszConnectTimeoutSec: Int? = nil
    var trzszServerPath: String?
    var dnsServers: [String]
    var excludedRoutes: [String]
    // Reject QUIC (UDP 443) with ICMP so browsers fall back to HTTP/2.
    // Optional so profiles mirrored by older builds still decode.
    var blockQUIC: Bool?
    var isBackgroundStartable: Bool
    var hostKey: VPNPinnedHostKey?
    var trustedCAKeys: [String]?
}

private nonisolated struct VPNSharedProfileStorePayload: Codable, Sendable {
    var version: Int
    var lastUpdated: Date
    var profiles: [VPNSharedProfileSnapshot]
}

nonisolated enum VPNSharedProfileStore {
    private static let logger = Logger(subsystem: "com.rootshell", category: "VPNSharedProfileStore")

    static let currentVersion = 1
    static let fileName = "vpn_profiles.json"

    static let appGroupID = AppIdentifiers.defaultAppGroupID

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    static func write(_ profiles: [VPNSharedProfileSnapshot]) {
        guard let fileURL else {
            logger.error("App group container unavailable for VPN shared profile write")
            return
        }

        let payload = VPNSharedProfileStorePayload(
            version: currentVersion,
            lastUpdated: Date(),
            profiles: profiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to write VPN shared profiles: \(error.localizedDescription)")
        }
    }

    static func readAll() -> [VPNSharedProfileSnapshot] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(VPNSharedProfileStorePayload.self, from: data)
            return payload.profiles
        } catch {
            logger.error("Failed to read VPN shared profiles: \(error.localizedDescription)")
            return []
        }
    }

    static func profile(id: UUID) -> VPNSharedProfileSnapshot? {
        if id == VPNDirectProfile.id {
            return VPNDirectProfile.stored()
        }
        if id == VPNTailnetProfile.id {
            return VPNTailnetProfile.snapshot()
        }
        return readAll().first(where: { $0.id == id })
    }

    /// Profiles widgets, Control Center and Shortcuts can start: the mirrored
    /// list, led by Tailscale while it is signed in. `includingSignedOutTailnet`
    /// keeps a configured Tailscale widget or Shortcut resolving after sign-out.
    static func startableProfiles(includingSignedOutTailnet: Bool = false) -> [VPNSharedProfileSnapshot] {
        var profiles = readAll()
        #if !CHINA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
        if VPNTailnetProfile.isSignedIn
            || (includingSignedOutTailnet && VPNTailnetProfile.appliedSettings() != nil) {
            profiles.insert(VPNTailnetProfile.snapshot(), at: 0)
        }
        #endif
        return profiles.filter(\.isBackgroundStartable)
    }
}

extension VPNSharedProfileSnapshot {
    /// Picker subtitle: "user@host", or what Tailscale routes.
    nonisolated var pickerSubtitle: String {
        if transportType == .tailscale { return VPNTailnetProfile.summary() }
        if username.isEmpty || host.isEmpty { return host }
        return "\(username)@\(host)"
    }
}

/// The last VPN that connected on this device. The tunnel writes it, so starts
/// from widgets, Shortcuts or Control Center count while the app isn't running.
nonisolated enum VPNLastConnected {
    static let fileName = "vpn_last_connected.txt"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Local Capture is a capture tool, not a VPN to reconnect to.
    static func record(_ id: UUID) {
        guard id != VPNDirectProfile.id, id != read(), let fileURL else { return }
        try? Data(id.uuidString.utf8).write(to: fileURL, options: .atomic)
    }

    static func read() -> UUID? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return UUID(uuidString: String(decoding: data, as: UTF8.self))
    }
}

/// The VPN to reconnect at launch: set while one is up, cleared when it is
/// turned off on purpose, so a reboot or app update leaves it set.
nonisolated enum VPNAutoRecovery {
    static let fileName = "vpn_auto_recovery.txt"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Local Capture replaces the previous VPN but is never recovered itself.
    static func markRunning(_ id: UUID) {
        guard id != VPNDirectProfile.id else { return clear() }
        guard id != pendingProfileID(), let fileURL else { return }
        try? Data(id.uuidString.utf8).write(to: fileURL, options: .atomic)
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func pendingProfileID() -> UUID? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return UUID(uuidString: String(decoding: data, as: UTF8.self))
    }
}

/// Where a routing rule sends matching traffic in the Tailscale VPN.
nonisolated enum VPNRoutingAction: String, Codable, Sendable, Hashable, CaseIterable {
    case ssh
    case direct
}

/// A domain, glob, IP, or CIDR and where it goes. A bare domain also covers
/// its subdomains; the first matching rule wins.
nonisolated struct VPNRoutingRule: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var pattern: String
    var action: VPNRoutingAction
}

/// Device-local settings for the Tailscale VPN. No secrets: the node's keys
/// live in the keychain under `VPNTailnetProfile.keychainService`.
nonisolated struct VPNTailnetSettings: Codable, Sendable, Hashable {
    var hostname: String = ""
    var acceptRoutes: Bool = true
    /// SSH profile whose host carries rule-matched traffic; nil = Tailscale only.
    var sshEgressProfileID: UUID?
    /// Everything outside the tailnet goes through SSH, not just rule matches.
    var sendAllViaSSH: Bool = false
    var rules: [VPNRoutingRule] = []
    /// Resolvers for names Tailscale doesn't own; empty uses public defaults.
    var dnsServers: [String] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        acceptRoutes = try c.decodeIfPresent(Bool.self, forKey: .acceptRoutes) ?? true
        sshEgressProfileID = try c.decodeIfPresent(UUID.self, forKey: .sshEgressProfileID)
        sendAllViaSSH = try c.decodeIfPresent(Bool.self, forKey: .sendAllViaSSH) ?? false
        rules = try c.decodeIfPresent([VPNRoutingRule].self, forKey: .rules) ?? []
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
    }
}

/// Tailscale's sign-in state, written by the iOS extension for surfaces that
/// can't show the login page (widgets, Control Center, Shortcuts).
nonisolated struct VPNTailnetLoginState: Codable, Sendable, Equatable {
    /// Backend state of the current session; empty until it reports one.
    var state = ""
    /// Last definite answer: Running sets it, a login request clears it.
    var signedIn = false

    var needsLogin: Bool { state == "NeedsLogin" || state == "NeedsMachineAuth" }
}

/// The synthetic Tailscale VPN profile. Its settings stay on this device and
/// out of the synced profile list.
nonisolated enum VPNTailnetProfile {
    static let id = UUID(uuidString: "7A11E700-0000-4000-8000-0000000075AE")!
    static let fileName = "vpn_tailnet_settings.json"
    static let loginFileName = "vpn_tailnet_login.json"
    /// Opens the app to start Tailscale, showing the login page if needed.
    static let connectURL = URL(string: "rootshell://vpn/connect/\(id.uuidString)")!

    private static var loginFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(loginFileName)
    }

    static func loginState() -> VPNTailnetLoginState {
        guard let loginFileURL, let data = try? Data(contentsOf: loginFileURL),
              let state = try? JSONDecoder().decode(VPNTailnetLoginState.self, from: data) else {
            return VPNTailnetLoginState()
        }
        return state
    }

    static var isSignedIn: Bool { loginState().signedIn }

    static func storeLoginState(_ state: VPNTailnetLoginState) {
        guard let loginFileURL else { return }
        try? JSONEncoder().encode(state).write(to: loginFileURL, options: .atomic)
    }

    /// Extension: records a backend state change from Tailscale. Returns
    /// whether widgets should refresh (running, signed in or needing a login changed).
    @discardableResult
    static func recordBackendState(_ backendState: String) -> Bool {
        var login = loginState()
        let previous = login
        login.state = backendState
        if backendState == "Running" {
            login.signedIn = true
        } else if login.needsLogin {
            login.signedIn = false
        }
        guard login != previous else { return false }
        storeLoginState(login)
        return (login.state == "Running") != (previous.state == "Running")
            || login.needsLogin != previous.needsLogin
            || login.signedIn != previous.signedIn
    }
    /// The egress profile's snapshot, kept apart from vpn_profiles.json so a
    /// profile without its own VPN toggle stays out of widget and Shortcuts lists.
    static let egressFileName = "vpn_tailnet_egress.json"
    /// Keychain service for the node's Tailscale state (one item per key).
    static let keychainService = "com.rootshell.tailscale.state"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    private static var egressFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(egressFileName)
    }

    static func storeEgress(_ snapshot: VPNSharedProfileSnapshot?) {
        guard let egressFileURL else { return }
        guard let snapshot else {
            try? FileManager.default.removeItem(at: egressFileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: egressFileURL, options: .atomic)
    }

    static func settings() -> VPNTailnetSettings {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(VPNTailnetSettings.self, from: data) else {
            return VPNTailnetSettings()
        }
        return settings
    }

    static func store(_ settings: VPNTailnetSettings) {
        guard let fileURL else { return }
        try? JSONEncoder().encode(settings).write(to: fileURL, options: .atomic)
    }

    /// Settings the running tunnel started with, written by the extension;
    /// edits save immediately, so this is what "unapplied" compares against.
    static let appliedFileName = "vpn_tailnet_applied.json"

    private static var appliedFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(appliedFileName)
    }

    static func storeApplied(_ settings: VPNTailnetSettings) {
        guard let appliedFileURL else { return }
        try? JSONEncoder().encode(settings).write(to: appliedFileURL, options: .atomic)
    }

    static func appliedSettings() -> VPNTailnetSettings? {
        guard let appliedFileURL, let data = try? Data(contentsOf: appliedFileURL) else { return nil }
        return try? JSONDecoder().decode(VPNTailnetSettings.self, from: data)
    }

    /// Profile shape the start path and widgets use; host names the egress.
    static func snapshot() -> VPNSharedProfileSnapshot {
        let egress = egressSnapshot()
        let settings = settings()
        return VPNSharedProfileSnapshot(
            id: id,
            modifiedAt: Date(),
            name: String(localized: "Tailscale", comment: "Name of the Tailscale VPN profile"),
            host: egress?.host ?? "",
            port: 0,
            username: "",
            transportType: .tailscale,
            auth: VPNSharedProfileAuth(method: .none, keyID: nil),
            jumpHost: nil,
            trzszMode: nil,
            trzszUDPPortMin: nil,
            trzszUDPPortMax: nil,
            trzszMTU: nil,
            trzszServerPath: nil,
            dnsServers: settings.dnsServers,
            excludedRoutes: [],
            blockQUIC: nil,
            isBackgroundStartable: egress?.isBackgroundStartable ?? true,
            hostKey: nil,
            trustedCAKeys: nil
        )
    }

    /// What Tailscale routes, naming the SSH egress profile if one is set.
    static func summary() -> String {
        let settings = settings()
        guard let egress = egressSnapshot(settings) else {
            return String(localized: "Tailnet only", comment: "VPN quick connect: Tailscale without SSH egress")
        }
        return settings.sendAllViaSSH
            ? String(localized: "Tailnet, everything else via \(egress.name)", comment: "VPN quick connect: Tailscale with full SSH egress")
            : String(localized: "Tailnet, with rules via \(egress.name)", comment: "VPN quick connect: Tailscale with rule-based SSH egress")
    }

    /// The SSH egress profile snapshot, if one is set and still mirrored.
    static func egressSnapshot(_ settings: VPNTailnetSettings = settings()) -> VPNSharedProfileSnapshot? {
        guard let egressID = settings.sshEgressProfileID,
              let egressFileURL, let data = try? Data(contentsOf: egressFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(VPNSharedProfileSnapshot.self, from: data),
              snapshot.id == egressID,
              snapshot.transportType == .ssh || snapshot.transportType == .tssh else { return nil }
        return snapshot
    }
}

/// The synthetic "Local Capture" profile: a Direct-transport tunnel with no
/// server, used to capture HTTP traffic. Never part of the synced profile list.
nonisolated enum VPNDirectProfile {
    static let id = UUID(uuidString: "C0FFEE00-0000-4000-8000-00000000D1E7")!
    static let fileName = "vpn_direct_profile.json"

    static func snapshot(dnsServers: [String]) -> VPNSharedProfileSnapshot {
        VPNSharedProfileSnapshot(
            id: id,
            modifiedAt: Date(),
            name: String(localized: "Local Capture", comment: "Name of the serverless VPN used for HTTP capture"),
            host: "",
            port: 0,
            username: "",
            transportType: .direct,
            auth: VPNSharedProfileAuth(method: .none, keyID: nil),
            jumpHost: nil,
            trzszMode: nil,
            trzszUDPPortMin: nil,
            trzszUDPPortMax: nil,
            trzszMTU: nil,
            trzszServerPath: nil,
            dnsServers: dnsServers,
            excludedRoutes: [],
            blockQUIC: nil,
            isBackgroundStartable: true,
            hostKey: nil,
            trustedCAKeys: nil
        )
    }

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedProfileStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    static func store(_ snapshot: VPNSharedProfileSnapshot) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    static func stored() -> VPNSharedProfileSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let snapshot = try? decoder.decode(VPNSharedProfileSnapshot.self, from: data) {
            return snapshot
        }
        return snapshot(dnsServers: [])
    }
}
