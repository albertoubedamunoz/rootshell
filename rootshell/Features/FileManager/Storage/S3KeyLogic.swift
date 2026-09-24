//
//  S3KeyLogic.swift
//  rootshell
//
//  Pure key rules for S3 listings and copies. No I/O, so it is unit-tested directly.
//

import Foundation

nonisolated enum S3KeyLogic {
    /// `key` relative to `prefix` when it is a direct child, without a trailing slash.
    static func childName(_ key: String, under prefix: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        var rest = key.dropFirst(prefix.count)
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return String(rest)
    }

    /// `bucket/key`, URL-encoded as the x-amz-copy-source header requires.
    static func copySource(bucket: String, key: String) -> String {
        let raw = bucket + "/" + key
        return raw.addingPercentEncoding(withAllowedCharacters: copySourceAllowed) ?? raw
    }

    /// RFC 3986 unreserved characters plus "/"; `.alphanumerics` would pass non-ASCII letters.
    private static let copySourceAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )
}
