//
//  TailnetStatus.swift
//  rootshell
//
//  Tailscale state reported by the VPN extension, and the provider messages
//  that drive login and logout.
//

#if !CHINA_BUILD

import Foundation
import Security

/// Reply to `tailscale.status` (vpntunnel's statusJSONOut plus egress state).
nonisolated struct TailnetStatus: Decodable, Sendable, Equatable {
    struct Peer: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var dnsName: String?
        var os: String?
        var ips: [String]?
        var online: Bool

        var id: String { dnsName ?? name }
        var displayName: String {
            dnsName?.split(separator: ".").first.map(String.init) ?? name
        }
    }

    struct Egress: Decodable, Sendable, Equatable {
        var state: String
        var host: String?
        var error: String?
    }

    var state: String
    var authURL: String?
    var error: String?
    var tailnet: String?
    var magicDNSSuffix: String?
    var selfNode: Peer?
    var peers: [Peer]?
    var peersTotal: Int?
    var egress: Egress?

    enum CodingKeys: String, CodingKey {
        case state, authURL, error, tailnet, magicDNSSuffix, peers, peersTotal, egress
        case selfNode = "self"
    }

    var isRunning: Bool { state == "Running" }
    var needsLogin: Bool { state == "NeedsLogin" || state == "NeedsMachineAuth" }
}

extension VPNManager {
    /// Current Tailscale state, or nil when the tunnel isn't up.
    func tailnetStatus() async -> TailnetStatus? {
        guard let data = await sendProviderMessage(Data("tailscale.status".utf8), timeout: 3) else { return nil }
        return try? JSONDecoder().decode(TailnetStatus.self, from: data)
    }

    /// Asks for a fresh login URL; returns an error message on failure.
    func tailnetLogin() async -> String? {
        await tailnetCommand("tailscale.login")
    }

    /// Logs this device out of the tailnet; returns an error message on failure.
    func tailnetLogout() async -> String? {
        await tailnetCommand("tailscale.logout", timeout: 20)
    }

    private func tailnetCommand(_ message: String, timeout: TimeInterval = 8) async -> String? {
        guard let data = await sendProviderMessage(Data(message.utf8), timeout: timeout) else {
            return String(localized: "The VPN isn't running.", comment: "Tailscale command error when the tunnel is down")
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return reply?["error"] as? String
    }
}

/// The node's Tailscale keys, stored by the VPN extension.
enum TailnetKeychain {
    /// Forgets this device's tailnet identity while the VPN is off.
    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VPNTailnetProfile.keychainService,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        VPNTailnetProfile.storeLoginState(VPNTailnetLoginState())
    }
}

#endif
