import Foundation

/// A reserved OSC 52 payload, intercepted before clipboard/history writes.
/// Mosh synchronizes clipboard state and native tmux routes it per pane.
nonisolated struct TerminalClipboardURLRequest: Sendable {
    static let namespace = "rootshell-open-url:"
    static let prefix = namespace + "v1:"
    static let lifetime: TimeInterval = 60
    static let futureClockTolerance: TimeInterval = 5

    let id: String
    let issuedAt: TimeInterval
    let url: URL

    static func isReservedClipboardState(_ encoded: String) -> Bool {
        guard encoded.utf8.count <= 16 * 1024,
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.hasPrefix(namespace)
    }

    static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 16 * 1024, text.hasPrefix(prefix) else { return nil }
        let fields = text.dropFirst(prefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              !fields[0].isEmpty, fields[0].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let timestamp = UInt64(fields[0]),
              fields[1].utf8.count == 32,
              fields[1].utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }),
              let url = TerminalWebURL.parse(String(fields[2])) else { return nil }
        return Self(id: String(fields[1]), issuedAt: TimeInterval(timestamp), url: url)
    }

    func isFresh(at now: TimeInterval) -> Bool {
        let age = now - issuedAt
        return age >= -Self.futureClockTolerance && age <= Self.lifetime
    }
}

/// Device-wide replay suppression, including after app restart. Stores only
/// request IDs and expiry times, never URLs. A full ledger rejects new entries
/// until expiry instead of evicting an ID that could still be replayed.
nonisolated struct TerminalURLRequestLedger {
    private(set) var expirations: [String: TimeInterval]
    static let capacity = 256

    init(data: Data? = nil) {
        expirations = data.flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: $0) } ?? [:]
    }

    mutating func consume(_ request: TerminalClipboardURLRequest, now: TimeInterval) -> Bool {
        expirations = expirations.filter { $0.value >= now }
        guard request.isFresh(at: now), expirations[request.id] == nil,
              expirations.count < Self.capacity else { return false }
        expirations[request.id] = request.issuedAt + TerminalClipboardURLRequest.lifetime
        return true
    }

    var data: Data? { try? JSONEncoder().encode(expirations) }
}
