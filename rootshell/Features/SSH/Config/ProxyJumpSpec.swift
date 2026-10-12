import Foundation

/// One hop of an OpenSSH `ProxyJump` / `-J` list: `[user@]host[:port]`,
/// `[user@][v6]:port`, or `ssh://[user@]host[:port]`.
nonisolated struct ProxyJumpSpec: Equatable, Sendable {
    var host: String
    var port: Int?
    var username: String?

    var portOrDefault: Int { port ?? 22 }

    /// Parses a comma-separated hop list. Returns nil for `none`, empty input,
    /// or any hop without a host.
    static func parseList(_ raw: String) -> [ProxyJumpSpec]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("none") != .orderedSame else { return nil }
        var hops: [ProxyJumpSpec] = []
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            guard let hop = parseHop(String(part)) else { return nil }
            hops.append(hop)
        }
        return hops
    }

    static func parseHop(_ raw: String) -> ProxyJumpSpec? {
        var remaining = raw.trimmingCharacters(in: .whitespaces)
        if remaining.lowercased().hasPrefix("ssh://") {
            remaining = String(remaining.dropFirst(6))
            if remaining.hasSuffix("/") { remaining.removeLast() }
        }
        var username: String?
        var port: Int?

        // Split on the last @ so AD-style user@domain names survive.
        if let at = remaining.lastIndex(of: "@") {
            let user = String(remaining[..<at])
            username = user.isEmpty ? nil : user
            remaining = String(remaining[remaining.index(after: at)...])
        }

        if remaining.hasPrefix("[") {
            guard let close = remaining.firstIndex(of: "]") else { return nil }
            let afterClose = remaining.index(after: close)
            if afterClose < remaining.endIndex {
                guard remaining[afterClose] == ":",
                      let p = Int(remaining[remaining.index(after: afterClose)...]), (1...65535).contains(p) else { return nil }
                port = p
            }
            remaining = String(remaining[remaining.index(after: remaining.startIndex)..<close])
        } else if remaining.filter({ $0 == ":" }).count == 1, let colon = remaining.firstIndex(of: ":") {
            guard let p = Int(remaining[remaining.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
            remaining = String(remaining[..<colon])
        }

        guard !remaining.isEmpty, !remaining.contains(where: \.isWhitespace) else { return nil }
        return ProxyJumpSpec(host: remaining, port: port, username: username)
    }
}
