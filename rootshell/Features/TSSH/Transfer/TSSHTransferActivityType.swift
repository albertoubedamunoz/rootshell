//
//  TSSHTransferActivityType.swift
//  rootshell
//
//  NSUserActivity type for "Transfer to Nearby Device" Handoff offers.
//

import Foundation
import UIKit

enum TrzszTransferActivity {
    /// The NSUserActivity type advertised when the user taps "Transfer to
    /// Nearby Device" on a tssh tab. Must match the entry in Info.plist's
    /// NSUserActivityTypes array, otherwise iOS rejects the activity at
    /// becomeCurrent() time and Handoff never publishes it.
    nonisolated static let activityType = "com.kk2.ghostty-ios.transfer-tssh-session"

    /// Schema version for the userInfo + bootstrap payload. Receivers reject
    /// activities with a higher version than they understand.
    nonisolated static let payloadVersion = 1

    /// Keys for the activity's userInfo dictionary. Stored as plain strings
    /// rather than an enum because NSUserActivity userInfo values must be
    /// property-list types.
    nonisolated enum UserInfoKey {
        static let version = "v"
        static let originPubKey = "pk"
        static let originDeviceName = "name"
        static let displayName = "session"
        static let host = "host"
    }

    nonisolated static let requiredUserInfoKeys: Set<String> = [
        UserInfoKey.version,
        UserInfoKey.originPubKey,
        UserInfoKey.originDeviceName,
        UserInfoKey.displayName,
    ]

    /// Best-effort name for the local device, shown to the peer in the
    /// transfer sheets. Picked to be *accurate* rather than personalised,
    /// since we deliberately don't request the
    /// `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement.
    ///
    /// On Mac Catalyst, `UIDevice.current.name` returns the iPad-flavoured
    /// model string ("iPad") because the runtime presents itself as an
    /// iPad — that's what produced the misleading "iPad" label in the
    /// receiver's sheet when the user transferred from a Mac. Both
    /// `Host.localizedName` and `SCDynamicStoreCopyComputerName` are
    /// marked unavailable on Catalyst, so the best signal we can reach
    /// without an entitlement is `ProcessInfo.processInfo.hostName`, the
    /// Bonjour hostname derived from the computer name in System Settings
    /// (e.g. "Example-MacBook-Pro.local"). Strip the `.local` suffix and turn
    /// the Bonjour-mandated hyphens back into spaces so the peer sees
    /// something close to the original ("Example MacBook Pro").
    ///
    /// On iPadOS/iOS without the entitlement, `UIDevice.current.name`
    /// returns the generic model ("iPad", "iPhone") starting in iOS 16.
    /// That's accurate (it really is an iPad), just not personalised, and
    /// the peer's sheet correctly shows "From iPad" instead of pretending
    /// to know the user-assigned name.
    static func currentDeviceName() -> String {
        #if targetEnvironment(macCatalyst)
        let host = ProcessInfo.processInfo.hostName
        if !host.isEmpty, host.lowercased() != "localhost" {
            var cleaned = host
            if cleaned.hasSuffix(".local") {
                cleaned = String(cleaned.dropLast(".local".count))
            }
            cleaned = cleaned.replacingOccurrences(of: "-", with: " ")
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        #endif
        return UIDevice.current.name
    }
}

extension Notification.Name {
    /// Posted by the SwiftUI scene's `.onContinueUserActivity` handler when a
    /// nearby device offers a tssh transfer. Object is a `TrzszTransferOffer`.
    static let trzszTransferOfferReceived = Notification.Name("trzszTransferOfferReceived")

    /// Posted by MainView when the app enters background. In-flight transfer
    /// sheets listen for this and cancel their coordinators so Continuity
    /// streams close before the 5s graceful-termination watchdog hits.
    static let trzszTransferShouldCancelForBackground = Notification.Name("trzszTransferShouldCancelForBackground")
}
