//
//  IPAddressExtractor.swift
//  rootshell
//
//  Finds an IPv4 or IPv6 address in free text such as a log line or URL.
//

import Foundation
import Network

nonisolated enum IPAddressExtractor {
    /// Only the head of a large clipboard is scanned.
    static let scanLimit = 4096

    private static let separators: Set<Character> = [
        ",", ";", "(", ")", "<", ">", "{", "}", "\"", "'", "`", "=", "@", "/", "|", "\\",
    ]
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,:;!?")

    /// The first address in `text`, without any port, brackets, zone, or prefix length.
    static func firstAddress(in text: String) -> String? {
        text.prefix(scanLimit)
            .split { $0.isWhitespace || separators.contains($0) }
            .lazy
            .compactMap { address(fromToken: String($0)) }
            .first
    }

    static func address(fromToken token: String) -> String? {
        if let address = ipv4(token) ?? ipv6(token) { return address }
        // Sentence punctuation ("from 1.2.3.4.") is retried only after the token
        // failed as-is, so a trailing "::" survives on IPv6.
        let trimmed = token.trimmingCharacters(in: trailingPunctuation)
        guard trimmed != token, !trimmed.isEmpty else { return nil }
        return ipv4(trimmed) ?? ipv6(trimmed)
    }

    private static func ipv4(_ token: String) -> String? {
        var host = Substring(token)
        if let colon = host.firstIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else { return nil }
            host = host[..<colon]
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) && UInt8($0) != nil }),
              IPv4Address(String(host)) != nil else { return nil }
        return String(host)
    }

    private static func ipv6(_ token: String) -> String? {
        var host = Substring(token)
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            host = host[host.index(after: host.startIndex)..<close]
        }
        if let percent = host.firstIndex(of: "%") { host = host[..<percent] }
        guard host.contains(":"),
              host.contains(where: \.isHexDigit),
              host.allSatisfy({ ($0.isASCII && $0.isHexDigit) || $0 == ":" || $0 == "." }),
              IPv6Address(String(host)) != nil else { return nil }
        return String(host)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isWholeNumber }
}
