import Foundation

/// Observes live PTY bytes without changing the stream sent to Ghostty.
/// OSC 777;rootshell;open-url;<base64 UTF-8 URL>, terminated by BEL or ST.
/// Instances belong to one stream and must be called serially.
nonisolated struct TerminalURLRequestParser {
    private enum State { case ground, escape, osc, oscEscape, dcs, dcsEscape, string, stringEscape }
    private var state: State = .ground
    private var payload = Data()
    private var overflowed = false
    private let depth: Int
    private static let limit = 16 * 1024
    private static let prefix = Data("777;rootshell;open-url;".utf8)

    init(depth: Int = 0) { self.depth = depth }

    mutating func consume(_ data: Data) -> [URL] {
        var urls: [URL] = []
        for byte in data {
            // CAN and SUB cancel a control string, as in the terminal parser.
            if byte == 0x18 || byte == 0x1a {
                finish()
                continue
            }
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape }
            case .escape:
                switch byte {
                case 0x5d: begin(.osc)
                case 0x50: begin(.dcs)
                case 0x58, 0x5e, 0x5f: begin(.string) // SOS, PM, APC
                case 0x1b: break
                default: state = .ground
                }
            case .osc:
                if byte == 0x07 {
                    if let url = decodeURL() { urls.append(url) }
                    finish()
                } else if byte == 0x1b {
                    state = .oscEscape
                } else { append(byte) }
            case .oscEscape:
                if byte == 0x5c {
                    if let url = decodeURL() { urls.append(url) }
                    finish()
                } else {
                    // An embedded escape invalidates this OSC. Consume through
                    // its terminator instead of interpreting an injected OSC.
                    overflowed = true
                    state = byte == 0x1b ? .oscEscape : .osc
                }
            case .dcs:
                if byte == 0x1b { state = .dcsEscape }
                else { append(byte) }
            case .dcsEscape:
                if byte == 0x5c {
                    if !overflowed, depth < 2, payload.starts(with: Data("tmux;".utf8)) {
                        var inner = TerminalURLRequestParser(depth: depth + 1)
                        urls.append(contentsOf: inner.consume(Data(payload.dropFirst(5))))
                    }
                    finish()
                } else if byte == 0x1b {
                    // tmux doubles every ESC inside its passthrough wrapper.
                    append(0x1b)
                    state = .dcs
                } else {
                    append(0x1b)
                    append(byte)
                    state = .dcs
                }
            case .string:
                if byte == 0x1b { state = .stringEscape }
            case .stringEscape:
                if byte == 0x5c { finish() }
                else { state = byte == 0x1b ? .stringEscape : .string }
            }
        }
        return urls
    }

    private mutating func begin(_ next: State) {
        payload.removeAll(keepingCapacity: true)
        overflowed = false
        state = next
    }

    private mutating func finish() { begin(.ground) }

    private mutating func append(_ byte: UInt8) {
        guard !overflowed else { return }
        guard payload.count < Self.limit else {
            payload.removeAll(keepingCapacity: true)
            overflowed = true
            return
        }
        payload.append(byte)
    }

    private func decodeURL() -> URL? {
        guard !overflowed, payload.starts(with: Self.prefix),
              let decoded = Data(base64Encoded: Data(payload.dropFirst(Self.prefix.count))),
              let text = String(data: decoded, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// Serializes observation for callbacks arriving off the main actor.
nonisolated final class TerminalURLRequestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = TerminalURLRequestParser()
    private let onURL: @Sendable (URL) -> Void

    init(onURL: @escaping @Sendable (URL) -> Void) { self.onURL = onURL }

    func consume(_ data: Data) {
        lock.lock()
        let urls = parser.consume(data)
        // Deliver in stream order; the callback only enqueues main-actor work.
        for url in urls { onURL(url) }
        lock.unlock()
    }
}
