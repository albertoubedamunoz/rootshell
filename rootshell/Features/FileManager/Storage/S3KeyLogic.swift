//
//  S3KeyLogic.swift
//  rootshell
//
//  Pure key rules for S3 listings and copies. No I/O, so it is unit-tested directly.
//

import Foundation

nonisolated enum S3KeyLogic {
    enum ListedKey: Equatable {
        case child(String)
        /// The folder's own marker, or a key outside the prefix.
        case ignored
        /// A name a path can't hold literally ("", ".", ".."): normalization would
        /// turn it into its parent, so it is never offered as an item.
        case unrepresentable
    }

    static func classify(_ key: String, under prefix: String) -> ListedKey {
        guard key.hasPrefix(prefix) else { return .ignored }
        var rest = key.dropFirst(prefix.count)
        if rest.isEmpty { return .ignored }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.isEmpty || rest == "." || rest == ".." { return .unrepresentable }
        return rest.contains("/") ? .ignored : .child(String(rest))
    }

    /// `key` relative to `prefix` when it is a direct child, without a trailing slash.
    static func childName(_ key: String, under prefix: String) -> String? {
        if case .child(let name) = classify(key, under: prefix) { return name }
        return nil
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
