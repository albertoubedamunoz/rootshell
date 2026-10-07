//
//  TailnetStateHandoff.swift
//  rootshell
//
//  Keeps Whole Device and rootshell Only one Tailscale device. On iOS both
//  read the same keychain items. On the Standalone Mac the VPN runs in a root
//  system extension with its own files, so the node state is copied across
//  whenever the mode changes hands.
//

#if !CHINA_BUILD

import Foundation
import os

@MainActor
enum TailnetStateHandoff {
    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetHandoff")

    /// Which side ran the node last, so a switch copies the newest state.
    private enum Owner: String {
        case app
        case vpn
    }

    private static let ownerKey = "tailnetStateOwner"

    private static var owner: Owner? {
        get { UserDefaults.standard.string(forKey: ownerKey).flatMap(Owner.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: ownerKey) }
    }

    /// Whether switching modes keeps the same device (no new sign-in).
    static var keepsIdentity: Bool {
        #if STANDALONE && targetEnvironment(macCatalyst)
        hostSupportsHandoff
        #else
        true
        #endif
    }

    #if STANDALONE && targetEnvironment(macCatalyst)
    private static var hostSupportsHandoff = true

    struct HandoffError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Couldn't move Tailscale from the VPN. Sign in again to use it inside rootshell.", comment: "Tailscale Mac mode switch failure")
        }
    }
    #endif

    /// Before the in-app engine takes over: copies the node out of the Mac
    /// system extension, starting it briefly without Tailscale if it is off.
    static func moveToApp() async throws {
        #if STANDALONE && targetEnvironment(macCatalyst)
        // The keychain already has the newest node, or the VPN never ran Tailscale.
        guard owner != .app, VPNTailnetProfile.appliedSettings() != nil else {
            owner = .app
            return
        }
        let mac = MacVPNController.shared
        hostSupportsHandoff = await mac.supportsTailnetStateHandoff()
        guard hostSupportsHandoff else {
            logger.info("Host can't hand off Tailscale state; in-app engine signs in separately")
            owner = .app
            return
        }
        let vpn = VPNManager.shared
        let startedForExport = !(vpn.isVPNActive(for: VPNTailnetProfile.id) && vpn.isTunnelUp)
        if startedForExport {
            try await mac.activateExtension()
            try await mac.startTailnet(restart: false, exportOnly: true)
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, await mac.status()?.status != "connected" {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let data = await mac.providerMessage(Data("tailscale.exportState".utf8), timeoutSeconds: 8)
        if startedForExport {
            try? await mac.stop()
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? [String: String] else {
            throw HandoffError()
        }
        TailnetKeychainState.deleteAll()
        for (key, value) in state {
            if let bytes = Data(base64Encoded: value) {
                try TailnetKeychainState.write(key, bytes)
            }
        }
        owner = .app
        logger.info("Moved Tailscale node state to the app (\(state.count) keys)")
        #endif
    }

    /// Node state for the Mac system extension to take over, when the in-app
    /// engine ran last; nil leaves its own copy in place.
    static func stateForVPN() -> [String: Data]? {
        #if STANDALONE && targetEnvironment(macCatalyst)
        guard owner == .app else { return nil }
        return TailnetKeychainState.readAll()
        #else
        return nil
        #endif
    }

    static func vpnDidStart() {
        owner = .vpn
    }

    static func engineDidStart() {
        owner = .app
    }
}

#endif
