//
//  PushConfiguration.swift
//  RootshellPushKit
//
//  Identifiers shared by the app and the notification service extension.
//  Info.plist keys override the defaults per build variant.
//

import Foundation

public enum PushConfiguration {
    public static let categoryIdentifier = "com.rootshell.push"
    public static let headerUserInfoKey = "rs_header"
    public static let rejectedUserInfoKey = "rs_rejected"
    /// Set by the extension when it could not decrypt; the app re-posts these.
    public static let fallbackUserInfoKey = "rs_fallback"

    public static var server: URL {
        URL(string: plist("RootshellPushServer") ?? "https://push.rootshell.com")!
    }

    public static var keychainAccessGroup: String {
        plist("RootshellKeychainAccessGroup") ?? "D97ZME3ET2.com.kk2.ghostty-ios"
    }

    public static var appGroup: String {
        plist("RootshellAppGroup") ?? "group.com.kk2.ghostty"
    }

    /// APNs topic: the host app's bundle id (the extension strips its suffix).
    public static var topic: String {
        let id = Bundle.main.bundleIdentifier ?? "com.kk2.rootshell"
        if let range = id.range(of: ".PushNotificationService") { return String(id[..<range.lowerBound]) }
        return id
    }

    public static var keychain: PushKeychain { PushKeychain(accessGroup: keychainAccessGroup) }

    private static func plist(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
}
