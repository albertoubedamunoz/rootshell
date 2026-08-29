//
//  PushKeychain.swift
//  RootshellPushKit
//
//  Device key + relay credential in the keychain group shared with the
//  notification service extension. AfterFirstUnlock so the extension can
//  decrypt while the device is locked; never synchronized.
//

import Foundation
import Security

/// The relay-sealed device credential and the APNs token it was issued for.
public struct PushCredentials: Codable, Sendable, Equatable {
    public var server: String
    public var deviceID: String
    public var deviceCred: String
    public var apnsToken: Data
    public var environment: String

    public init(server: String, deviceID: String, deviceCred: String, apnsToken: Data, environment: String) {
        self.server = server; self.deviceID = deviceID; self.deviceCred = deviceCred; self.apnsToken = apnsToken; self.environment = environment
    }
}

public struct PushKeychain: Sendable {
    public enum Item: String { case deviceKey = "com.rootshell.push.devicekey", credentials = "com.rootshell.push.credentials" }

    public let accessGroup: String

    public init(accessGroup: String) { self.accessGroup = accessGroup }

    public func loadPrivateKey() throws -> XWing.PrivateKey? {
        guard let seed = try read(.deviceKey) else { return nil }
        return try XWing.PrivateKey(seed: seed)
    }

    public func save(_ key: XWing.PrivateKey) throws { try write(.deviceKey, key.seed) }

    public func loadCredentials() throws -> PushCredentials? {
        guard let data = try read(.credentials) else { return nil }
        return try? JSONDecoder().decode(PushCredentials.self, from: data)
    }

    public func save(_ credentials: PushCredentials) throws {
        try write(.credentials, try JSONEncoder().encode(credentials))
    }

    public func delete(_ item: Item) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    public func deleteAll() throws {
        try delete(.deviceKey)
        try delete(.credentials)
    }

    private func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: item.rawValue,
         kSecAttrAccount as String: "device",
         kSecAttrAccessGroup as String: accessGroup]
    }

    private func read(_ item: Item) throws -> Data? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status) }
        return result as? Data
    }

    private func write(_ item: Item, _ data: Data) throws {
        var attrs = query(item)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let s = SecItemUpdate(query(item) as CFDictionary, update as CFDictionary)
            guard s == errSecSuccess else { throw KeychainError(s) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
}
