//
//  SExpressionParser.swift
//  rootshell
//
//  Minimal canonical S-expression reader scoped to what
//  ``GPGAgentManager`` needs for `PKDECRYPT`: parse the
//  `(enc-val (rsa ...))` / `(enc-val (ecdh ...))` / `(enc-val (ecc
//  ...))` / `(enc-val (x25519 ...))` ciphertext blobs that gpg sends
//  over the INQUIRE channel.
//
//  Canonical form (no display hints, no comments):
//    * atom  : `<decimal-length>:<bytes>`
//    * list  : `(` then any number of values then `)`
//
//  We intentionally stop at "just enough" — no quoted strings, no
//  base64 hints, no comment skipping. The Assuan transport always
//  delivers canonical bytes, so the parser doesn't need the relaxed
//  forms that general-purpose S-expression readers support.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// One node of a parsed canonical S-expression.
///
/// `nonisolated` so the value methods can be called from
/// off-MainActor crypto paths — `GPGDecryptor.decrypt` runs inside
/// `Task.detached` and threads the parsed S-expression through.
/// Without explicit `nonisolated`, the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` pins these methods to
/// main and the call sites become illegal under strict concurrency.
nonisolated enum SExpr: Sendable, Hashable {
    case atom(Data)
    case list([SExpr])

    /// If this is an atom, the raw bytes; otherwise nil.
    var atomBytes: Data? {
        if case .atom(let d) = self { return d }
        return nil
    }

    /// If this is an atom of UTF-8 text, the decoded string; otherwise
    /// nil. Use for matching algorithm names like `enc-val`, `ecdh`.
    var atomString: String? {
        guard case .atom(let d) = self else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// If this is a list, its children; otherwise nil.
    var children: [SExpr]? {
        if case .list(let c) = self { return c }
        return nil
    }

    /// Whether this list starts with an atom whose value matches `name`.
    /// Lists in our domain are always headed by an algorithm name —
    /// `(ecdh (e ...) (s ...))`, `(rsa (a ...))`, etc.
    func isList(named name: String) -> Bool {
        guard case .list(let items) = self, let head = items.first else { return false }
        return head.atomString == name
    }

    /// Find the first child list whose head atom equals `name`. Used
    /// for picking `(e ...)`, `(s ...)`, `(kdf-params ...)` out of a
    /// parsed enc-val.
    func firstChild(named name: String) -> SExpr? {
        guard case .list(let items) = self else { return nil }
        return items.first(where: { $0.isList(named: name) })
    }

    /// If this is a single-key list `(name value)`, return the value
    /// atom's bytes. Returns nil if the shape doesn't match.
    var pairValue: Data? {
        guard case .list(let items) = self, items.count == 2 else { return nil }
        return items[1].atomBytes
    }
}

nonisolated enum SExpressionParseError: Error, LocalizedError, Equatable {
    case truncated
    case malformed
    case lengthOverflow

    var errorDescription: String? {
        switch self {
        case .truncated: return "S-expression input ended mid-token."
        case .malformed: return "S-expression input was malformed."
        case .lengthOverflow: return "S-expression atom length exceeded the allowed bound."
        }
    }
}

nonisolated enum SExpressionParser {

    /// Parse a single top-level canonical S-expression from `data`.
    /// `maxAtomLength` caps any single atom to defend against malicious
    /// length prefixes — set this to a generous bound for ciphertext
    /// MPIs (a 16-kbit RSA modulus is ~2 KB, an X25519 ephemeral is 32
    /// bytes; 64 KB is plenty).
    static func parse(_ data: Data, maxAtomLength: Int = 65_536) throws -> SExpr {
        var cursor = Cursor(data: data, maxAtomLength: maxAtomLength)
        let result = try parseValue(&cursor)
        // Trailing bytes are tolerated — Assuan sometimes pads the final
        // INQUIRE chunk with a newline. The caller has already framed
        // the payload, so anything left over is conservatively ignored.
        return result
    }

    private static func parseValue(_ c: inout Cursor) throws -> SExpr {
        guard let first = c.peek() else { throw SExpressionParseError.truncated }
        if first == 0x28 {  // '('
            c.advance()
            var items: [SExpr] = []
            while true {
                guard let next = c.peek() else { throw SExpressionParseError.truncated }
                if next == 0x29 {  // ')'
                    c.advance()
                    return .list(items)
                }
                items.append(try parseValue(&c))
            }
        } else if first >= 0x30 && first <= 0x39 {  // digit → atom
            return .atom(try parseAtom(&c))
        } else {
            throw SExpressionParseError.malformed
        }
    }

    private static func parseAtom(_ c: inout Cursor) throws -> Data {
        var length = 0
        while let b = c.peek(), b >= 0x30, b <= 0x39 {
            // Bounded multiplication — the cap also defends against
            // overflow even before we attempt the read.
            length = length &* 10 &+ Int(b - 0x30)
            if length > c.maxAtomLength { throw SExpressionParseError.lengthOverflow }
            c.advance()
        }
        guard let colon = c.peek(), colon == 0x3A else { throw SExpressionParseError.malformed }
        c.advance()
        guard let bytes = c.read(length) else { throw SExpressionParseError.truncated }
        return bytes
    }
}

// MARK: - Cursor

// pure parser state, driven from the off-MainActor crypto path
private nonisolated struct Cursor {
    let data: Data
    var idx: Data.Index
    let maxAtomLength: Int

    init(data: Data, maxAtomLength: Int) {
        self.data = data
        self.idx = data.startIndex
        self.maxAtomLength = maxAtomLength
    }

    func peek() -> UInt8? {
        guard idx < data.endIndex else { return nil }
        return data[idx]
    }

    mutating func advance() {
        idx = data.index(after: idx)
    }

    mutating func read(_ count: Int) -> Data? {
        guard let end = data.index(idx, offsetBy: count, limitedBy: data.endIndex) else {
            return nil
        }
        let slice = data.subdata(in: idx..<end)
        idx = end
        return slice
    }
}
