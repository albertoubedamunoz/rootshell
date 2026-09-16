//
//  HerdrUpgradePrompt.swift
//  rootshell
//
//  One model behind every "install or upgrade herdr" surface: the gateway
//  card row, the main alert, and Connection Info. Hard refusals end control
//  mode; soft reasons only decorate a working session.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated struct HerdrUpgradePrompt: Equatable, Sendable {

    enum Reason: Equatable, Sendable {
        /// No herdr binary on the host's PATH.
        case herdrMissing
        /// The running server predates the minimum version.
        case versionTooOld(reported: String?)
        /// Stock herdr: fallback mode is running.
        case controlStreamMissing
        /// Fork protocol 1: one client per tab.
        case sharedViewingNeedsUpgrade
    }

    let reason: Reason

    static let installCommand = "curl -fsSL https://github.com/kitknox/herdr/releases/download/rootshell-channel/install.sh | sh"

    static let herdrMissing = HerdrUpgradePrompt(reason: .herdrMissing)
    static let controlStreamMissing = HerdrUpgradePrompt(reason: .controlStreamMissing)
    static let sharedViewingNeedsUpgrade = HerdrUpgradePrompt(reason: .sharedViewingNeedsUpgrade)
    static func versionTooOld(reported: String?) -> HerdrUpgradePrompt {
        HerdrUpgradePrompt(reason: .versionTooOld(reported: reported))
    }

    /// Control mode cannot run at all; the alert is the only surface left.
    var isHardRefusal: Bool {
        switch reason {
        case .herdrMissing, .versionTooOld: return true
        case .controlStreamMissing, .sharedViewingNeedsUpgrade: return false
        }
    }

    var title: String {
        switch reason {
        case .herdrMissing: return String(localized: "herdr Not Found")
        case .versionTooOld: return String(localized: "herdr Update Required")
        case .controlStreamMissing: return String(localized: "herdr Fallback Mode")
        case .sharedViewingNeedsUpgrade: return String(localized: "Upgrade herdr for Shared Viewing")
        }
    }

    var message: String {
        switch reason {
        case .herdrMissing:
            return String(localized: "herdr is not installed on this host, or is not on the login shell’s PATH. Install the rootshell herdr fork on the host to use control mode.")
        case .versionTooOld(let reported):
            return HerdrVersionError(reported: reported).localizedDescription
        case .controlStreamMissing:
            return String(localized: "The herdr on this host has no control stream, so rootshell is using server-rendered fallback mode. Install the rootshell herdr fork for full control mode.")
        case .sharedViewingNeedsUpgrade:
            return String(localized: "This host’s herdr allows one client per tab. Upgrade to the rootshell herdr fork to view the same tab from several devices at once.")
        }
    }

    var cardHeadline: String {
        switch reason {
        case .herdrMissing: return String(localized: "herdr not found on the host")
        case .versionTooOld: return String(localized: "herdr is too old for control mode")
        case .controlStreamMissing: return String(localized: "herdr fallback mode")
        case .sharedViewingNeedsUpgrade: return String(localized: "Upgrade herdr for shared viewing")
        }
    }
}
