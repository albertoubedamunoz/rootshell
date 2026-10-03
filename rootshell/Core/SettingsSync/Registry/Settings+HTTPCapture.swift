//
//  Settings+HTTPCapture.swift
//  rootshell
//
//  HTTP capture (MITM) keys. The CA itself is device-only and lives in the keychain.
//

#if !CHINA_BUILD

import Foundation

nonisolated extension Settings {
    enum HTTPCapture {
        /// Surge-style hostname list: `*.example.com`, `-exclude.com`, `host:8443`, `*`.
        static let mitmHosts = SettingKey(
            "httpCapture.mitmHosts",
            default: ["-*.apple.com", "-*.icloud.com", "-*.mzstatic.com", "-*.apple-cloudkit.com"],
            group: .connections, configKey: "http-capture-mitm-hosts",
            title: String(localized: "Decrypted Hosts", comment: "Setting title"))
        /// JSON-encoded `[CaptureRewriteRule]`.
        static let rewriteRules = SettingKey<Data?>(
            "httpCapture.rewriteRules", default: nil, group: .connections,
            title: String(localized: "Rewrite Rules", comment: "Setting title"))
        static let enableHTTP2 = SettingKey(
            "httpCapture.enableHTTP2", default: true, group: .connections,
            configKey: "http-capture-http2",
            title: String(localized: "Decrypt HTTP/2", comment: "Setting title"))
        static let autoBypassPinned = SettingKey(
            "httpCapture.autoBypassPinned", default: true, group: .connections,
            configKey: "http-capture-auto-bypass-pinned",
            title: String(localized: "Skip Hosts That Reject the Certificate", comment: "Setting title"))
        static let skipUpstreamVerify = SettingKey(
            "httpCapture.skipUpstreamVerify", default: false, group: .connections,
            configKey: "http-capture-skip-upstream-verify",
            title: String(localized: "Skip Server Certificate Verification", comment: "Setting title"))
        static let recordPackets = SettingKey(
            "httpCapture.recordPackets", default: false, group: .connections,
            configKey: "http-capture-record-packets",
            title: String(localized: "Record Packets for pcap", comment: "Setting title"))
        static let lookUpServerLocation = SettingKey(
            "httpCapture.lookUpServerLocation", default: true, group: .connections,
            configKey: "http-capture-server-location",
            title: String(localized: "Look Up Server Locations", comment: "Setting title"))
        static let showFavicons = SettingKey(
            "httpCapture.showFavicons", default: true, group: .connections,
            configKey: "http-capture-favicons",
            title: String(localized: "Show Network Favicons", comment: "Setting title"))
        static let maxBodyMB = SettingKey(
            "httpCapture.maxBodyMB", default: 10, group: .connections,
            configKey: "http-capture-max-body-mb", range: 1...200,
            title: String(localized: "Maximum Body Size (MB)", comment: "Setting title"))
        static let maxSessionMB = SettingKey(
            "httpCapture.maxSessionMB", default: 500, group: .connections,
            configKey: "http-capture-max-session-mb", range: 10...10000,
            title: String(localized: "Maximum Session Size (MB)", comment: "Setting title"))
        static let retainedSessions = SettingKey(
            "httpCapture.retainedSessions", default: 50, group: .connections,
            configKey: "http-capture-retained-sessions", range: 1...1000,
            title: String(localized: "Sessions to Keep", comment: "Setting title"))
        static let directDNSServers = SettingKey(
            "httpCapture.directDNSServers", default: [String](), group: .connections,
            configKey: "http-capture-direct-dns",
            title: String(localized: "Local Capture DNS Servers", comment: "Setting title"))
        static let presentation = SettingKey(
            "httpCapture.presentation", default: PanelPresentation.sidebar, group: .connections,
            configKey: "http-capture-presentation",
            title: String(localized: "HTTP Capture Presentation", comment: "Setting title"))
        static let sidebarWidth = SettingKey(
            "httpCapture.sidebar.width", default: 480.0, group: .connections, policy: .deviceOnly,
            title: String(localized: "HTTP Capture Sidebar Width", comment: "Setting title"))
        static let hudWidth = SettingKey(
            "httpCapture.hud.width", default: 1100.0, group: .connections, policy: .deviceOnly,
            title: String(localized: "HTTP Capture Overlay Width", comment: "Setting title"))
        static let hudHeight = SettingKey(
            "httpCapture.hud.height", default: 720.0, group: .connections, policy: .deviceOnly,
            title: String(localized: "HTTP Capture Overlay Height", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            mitmHosts.erased, rewriteRules.erased, enableHTTP2.erased, autoBypassPinned.erased,
            skipUpstreamVerify.erased, recordPackets.erased, lookUpServerLocation.erased, showFavicons.erased,
            maxBodyMB.erased, maxSessionMB.erased,
            retainedSessions.erased, directDNSServers.erased, presentation.erased, sidebarWidth.erased,
            hudWidth.erased, hudHeight.erased,
        ]
    }
}

#endif
