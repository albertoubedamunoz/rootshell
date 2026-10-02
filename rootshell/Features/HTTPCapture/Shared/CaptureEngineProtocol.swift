//
//  CaptureEngineProtocol.swift
//  rootshell
//
//  Contract between the app and the VPN extension for HTTP capture. Shared into
//  VPNTunnelExtension and the macOS `tunnel` system extension.
//

#if !CHINA_BUILD

import Foundation
import Security

/// Mirrors `captureConfig` in trzsz-ssh/vpntunnel/capture.go.
nonisolated struct CaptureEngineConfig: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var sessionID: String = ""
    var segmentNonce: String = ""
    /// Filled in by the extension; the spool lives in its own container on macOS.
    var spoolDir: String = ""
    var mitmHosts: [String] = []
    var caCertPEM: String = ""
    /// Empty in the persisted iOS file; the extension reads the key from the keychain.
    var caKeyPEM: String = ""
    var caProfileB64: String = ""
    var enableH2: Bool = true
    var skipUpstreamVerify: Bool = false
    var autoBypassPinned: Bool = true
    var maxBodyBytes: Int64 = 10 << 20
    var maxSessionBytes: Int64 = 500 << 20
    var pcap: Bool = false
    var rewriteRules: [CaptureRewriteRule] = []
    /// Direct transport only: DNS servers (empty = the network's own resolvers).
    var directDNSServers: [String] = []
}

/// Mirrors `rewriteRule` in trzsz-ssh/vpntunnel/rewrite.go.
nonisolated struct CaptureRewriteRule: Codable, Sendable, Hashable, Identifiable {
    enum Phase: String, Codable, Sendable, CaseIterable { case request, response }
    enum Action: String, Codable, Sendable, CaseIterable { case addHeader, setHeader, removeHeader, replaceBody }

    var id: String = UUID().uuidString
    var enabled: Bool = true
    var name: String = ""
    /// URL glob ("api.example.com/v1/*", "*://*.example.com/*") or regex when isRegex.
    var match: String = ""
    var isRegex: Bool = false
    var phase: Phase = .response
    var action: Action = .setHeader
    var header: String = ""
    var value: String = ""
    var find: String = ""
    var replace: String = ""
    var bodyRegex: Bool = false
}

/// Provider messages: "capture.<command>\n<JSON body>".
nonisolated enum CaptureMessage {
    static let prefix = "capture."

    enum Command: String, Sendable {
        case configure, stop, reset, sessions, list, read, delete
        /// Engine status, answered in order after every earlier capture command.
        case status
    }

    static func encode(_ command: Command, body: Data? = nil) -> Data {
        var data = Data((prefix + command.rawValue + "\n").utf8)
        if let body { data.append(body) }
        return data
    }

    static func encode<T: Encodable>(_ command: Command, json: T) -> Data {
        encode(command, body: try? JSONEncoder().encode(json))
    }

    static func decode(_ data: Data) -> (Command, Data)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let head = String(data: data[data.startIndex..<newline], encoding: .utf8),
              head.hasPrefix(prefix),
              let command = Command(rawValue: String(head.dropFirst(prefix.count))) else { return nil }
        return (command, Data(data[data.index(after: newline)...]))
    }

    static func isCaptureMessage(_ data: Data) -> Bool {
        data.starts(with: Data(prefix.utf8))
    }
}

nonisolated struct CaptureReadRequest: Codable, Sendable {
    var session: String
    var path: String
    var offset: Int64
    var max: Int
}

nonisolated struct CaptureFileInfo: Codable, Sendable, Hashable {
    var path: String
    var size: Int64
}

nonisolated struct CaptureSessionRef: Codable, Sendable {
    var session: String
}

nonisolated struct CaptureReply: Codable, Sendable {
    var ok: Bool
    var error: String?
    var count: Int?
}

nonisolated enum CapturePaths {
    static let directoryName = "HTTPCapture"
    static let sessionsDirectoryName = "Sessions"
    static let engineConfigName = "engine.json"
    /// Raw bytes per read. On macOS the reply travels base64 in a JSON socket
    /// frame, and SocketMessage rejects frames of 1 MiB or more.
    static let readChunkLimit = 512 * 1024

    static func root(appGroupID: String = AppIdentifiers.defaultAppGroupID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func sessionsRoot(appGroupID: String = AppIdentifiers.defaultAppGroupID) -> URL? {
        root(appGroupID: appGroupID)?.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    }

    static func engineConfigURL() -> URL? {
        root()?.appendingPathComponent(engineConfigName)
    }

    /// Session IDs are UUID strings; anything else is rejected before touching the filesystem.
    static func isValidSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// Relative spool paths ("index.jsonl", "bodies/x.res", "ws/x.jsonl").
    static func isValidRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }

    /// Creates the capture root with a protection class that keeps it writable
    /// while the device is locked (after first unlock).
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    static func readEngineConfig() -> CaptureEngineConfig? {
        guard let url = engineConfigURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CaptureEngineConfig.self, from: data)
    }

    static func writeEngineConfig(_ config: CaptureEngineConfig) throws {
        guard let root = root(), let url = engineConfigURL() else { return }
        try ensureDirectory(root)
        var stored = config
        stored.caKeyPEM = "" // never on disk
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The capture CA lives in the shared keychain group so the iOS extension can
/// sign leaf certificates. Device-only: it is never synced.
nonisolated enum CaptureCAKeychain {
    static let service = "com.rootshell.httpcapture.ca"
    static let certAccount = "certificate"
    static let keyAccount = "privateKey"

    static func read() -> (certPEM: String, keyPEM: String)? {
        guard let cert = readItem(certAccount), let key = readItem(keyAccount) else { return nil }
        return (cert, key)
    }

    @discardableResult
    static func write(certPEM: String, keyPEM: String) -> Bool {
        writeItem(certAccount, certPEM) && writeItem(keyAccount, keyPEM)
    }

    static func delete() {
        for account in [certAccount, keyAccount] {
            SecItemDelete(baseQuery(account) as CFDictionary)
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func readItem(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeItem(_ account: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable as String] = false
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}

#endif
