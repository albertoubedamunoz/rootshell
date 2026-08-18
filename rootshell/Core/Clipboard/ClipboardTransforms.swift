//
//  ClipboardTransforms.swift
//  rootshell
//
//  Developer-focused text transforms for the clipboard manager: case
//  conversion, base64/hex, URL encoding, JWT decode, hashes, JSON
//  formatting, line operations, shell escaping. Transforms are pure
//  String -> String functions applied to a clipboard entry's text.
//

import Crypto
import Foundation

extension Data {
    /// Lowercase hex string with no separators (hash and hex-encode transforms).
    nonisolated func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum ClipboardTransformError: LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): return message
        }
    }
}

// nonisolated + Sendable so applies can run off the main actor: transforms are
// pure String -> String work that would stall the UI on large entries.
nonisolated struct ClipboardTransform: Identifiable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case textCase
        case encoding
        case web
        case crypto
        case json
        case lines
        case shell
        case info

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .textCase: return String(localized: "Case", comment: "Clipboard transform category")
            case .encoding: return String(localized: "Encoding", comment: "Clipboard transform category")
            case .web: return String(localized: "Web", comment: "Clipboard transform category")
            case .crypto: return String(localized: "Hashes", comment: "Clipboard transform category")
            case .json: return String(localized: "JSON", comment: "Clipboard transform category")
            case .lines: return String(localized: "Lines", comment: "Clipboard transform category")
            case .shell: return String(localized: "Shell", comment: "Clipboard transform category")
            case .info: return String(localized: "Info", comment: "Clipboard transform category")
            }
        }
    }

    enum Parameter: Sendable {
        case integer(label: String, defaultValue: Int, range: ClosedRange<Int>)
    }

    /// Stable identifier, e.g. "base64.encode".
    let id: String
    let name: String
    let category: Category
    let icon: String
    var parameter: Parameter?
    /// Display-only results (counts) offer Copy but not Paste/Save.
    var isDisplayOnly: Bool
    let apply: @Sendable (String, Int?) throws -> String

    init(id: String,
         name: String,
         category: Category,
         icon: String,
         parameter: Parameter? = nil,
         isDisplayOnly: Bool = false,
         apply: @escaping @Sendable (String, Int?) throws -> String) {
        self.id = id
        self.name = name
        self.category = category
        self.icon = icon
        self.parameter = parameter
        self.isDisplayOnly = isDisplayOnly
        self.apply = apply
    }
}

nonisolated enum ClipboardTransformCatalog {

    static func transforms(in category: ClipboardTransform.Category) -> [ClipboardTransform] {
        all.filter { $0.category == category }
    }

    static let all: [ClipboardTransform] = [
        // MARK: Case
        ClipboardTransform(
            id: "case.upper",
            name: String(localized: "UPPERCASE", comment: "Clipboard transform"),
            category: .textCase, icon: "textformat.size.larger"
        ) { text, _ in text.uppercased() },
        ClipboardTransform(
            id: "case.lower",
            name: String(localized: "lowercase", comment: "Clipboard transform"),
            category: .textCase, icon: "textformat.size.smaller"
        ) { text, _ in text.lowercased() },
        ClipboardTransform(
            id: "case.title",
            name: String(localized: "Title Case", comment: "Clipboard transform"),
            category: .textCase, icon: "textformat"
        ) { text, _ in text.localizedCapitalized },
        ClipboardTransform(
            id: "case.camel",
            name: String(localized: "camelCase", comment: "Clipboard transform"),
            category: .textCase, icon: "textformat.abc"
        ) { text, _ in
            let words = caseTokens(text)
            guard let first = words.first else { return text }
            return ([first.lowercased()] + words.dropFirst().map { $0.capitalized }).joined()
        },
        ClipboardTransform(
            id: "case.snake",
            name: String(localized: "snake_case", comment: "Clipboard transform"),
            category: .textCase, icon: "textformat.abc.dottedunderline"
        ) { text, _ in caseTokens(text).map { $0.lowercased() }.joined(separator: "_") },
        ClipboardTransform(
            id: "case.kebab",
            name: String(localized: "kebab-case", comment: "Clipboard transform"),
            category: .textCase, icon: "minus"
        ) { text, _ in caseTokens(text).map { $0.lowercased() }.joined(separator: "-") },

        // MARK: Encoding
        ClipboardTransform(
            id: "base64.encode",
            name: String(localized: "Base64 Encode", comment: "Clipboard transform"),
            category: .encoding, icon: "arrow.right.square"
        ) { text, _ in Data(text.utf8).base64EncodedString() },
        ClipboardTransform(
            id: "base64.decode",
            name: String(localized: "Base64 Decode", comment: "Clipboard transform"),
            category: .encoding, icon: "arrow.left.square"
        ) { text, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else {
                throw ClipboardTransformError.invalidInput(String(localized: "Not valid Base64", comment: "Clipboard transform error"))
            }
            return try utf8String(data)
        },
        ClipboardTransform(
            id: "base64url.encode",
            name: String(localized: "Base64URL Encode", comment: "Clipboard transform"),
            category: .encoding, icon: "arrow.right.square.fill"
        ) { text, _ in Data(text.utf8).base64URLEncodedString() },
        ClipboardTransform(
            id: "base64url.decode",
            name: String(localized: "Base64URL Decode", comment: "Clipboard transform"),
            category: .encoding, icon: "arrow.left.square.fill"
        ) { text, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = OpenPubkeyJOSE.base64URLDecode(trimmed) else {
                throw ClipboardTransformError.invalidInput(String(localized: "Not valid Base64URL", comment: "Clipboard transform error"))
            }
            return try utf8String(data)
        },
        ClipboardTransform(
            id: "hex.encode",
            name: String(localized: "Hex Encode", comment: "Clipboard transform"),
            category: .encoding, icon: "number.square"
        ) { text, _ in Data(text.utf8).hexEncodedString() },
        ClipboardTransform(
            id: "hex.decode",
            name: String(localized: "Hex Decode", comment: "Clipboard transform"),
            category: .encoding, icon: "number.square.fill"
        ) { text, _ in
            let data = try hexDecode(text)
            return try utf8String(data)
        },

        // MARK: Web
        ClipboardTransform(
            id: "url.encode.component",
            name: String(localized: "URL Encode (Component)", comment: "Clipboard transform"),
            category: .web, icon: "link.badge.plus"
        ) { text, _ in
            // RFC 3986 unreserved characters only — safe for a query value or path segment
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw ClipboardTransformError.invalidInput(String(localized: "Could not percent-encode text", comment: "Clipboard transform error"))
            }
            return encoded
        },
        ClipboardTransform(
            id: "url.encode.query",
            name: String(localized: "URL Encode (Full URL)", comment: "Clipboard transform"),
            category: .web, icon: "link"
        ) { text, _ in
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw ClipboardTransformError.invalidInput(String(localized: "Could not percent-encode text", comment: "Clipboard transform error"))
            }
            return encoded
        },
        ClipboardTransform(
            id: "url.decode",
            name: String(localized: "URL Decode", comment: "Clipboard transform"),
            category: .web, icon: "link.badge.minus"
        ) { text, _ in
            guard let decoded = text.removingPercentEncoding else {
                throw ClipboardTransformError.invalidInput(String(localized: "Not valid percent-encoding", comment: "Clipboard transform error"))
            }
            return decoded
        },
        ClipboardTransform(
            id: "jwt.decode",
            name: String(localized: "JWT Decode", comment: "Clipboard transform"),
            category: .web, icon: "key.viewfinder"
        ) { text, _ in try decodeJWT(text) },

        // MARK: Hashes
        ClipboardTransform(
            id: "hash.md5",
            name: "MD5",
            category: .crypto, icon: "number"
        ) { text, _ in Data(Insecure.MD5.hash(data: Data(text.utf8))).hexEncodedString() },
        ClipboardTransform(
            id: "hash.sha1",
            name: "SHA-1",
            category: .crypto, icon: "number"
        ) { text, _ in Data(Insecure.SHA1.hash(data: Data(text.utf8))).hexEncodedString() },
        ClipboardTransform(
            id: "hash.sha256",
            name: "SHA-256",
            category: .crypto, icon: "number"
        ) { text, _ in Data(SHA256.hash(data: Data(text.utf8))).hexEncodedString() },
        ClipboardTransform(
            id: "hash.sha512",
            name: "SHA-512",
            category: .crypto, icon: "number"
        ) { text, _ in Data(SHA512.hash(data: Data(text.utf8))).hexEncodedString() },

        // MARK: JSON
        ClipboardTransform(
            id: "json.pretty",
            name: String(localized: "JSON Pretty-Print", comment: "Clipboard transform"),
            category: .json, icon: "curlybraces"
        ) { text, _ in
            let object = try jsonObject(text)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            return try utf8String(data)
        },
        ClipboardTransform(
            id: "json.minify",
            name: String(localized: "JSON Minify", comment: "Clipboard transform"),
            category: .json, icon: "curlybraces.square"
        ) { text, _ in
            let object = try jsonObject(text)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
            return try utf8String(data)
        },

        // MARK: Lines
        ClipboardTransform(
            id: "lines.unwrap",
            name: String(localized: "Unwrap Paragraphs", comment: "Clipboard transform"),
            category: .lines, icon: "text.append"
        ) { text, _ in try ClipboardTextReflow.unwrap(text) },
        ClipboardTransform(
            id: "lines.wrap",
            name: String(localized: "Wrap to Width", comment: "Clipboard transform"),
            category: .lines, icon: "text.justify",
            parameter: .integer(
                label: String(localized: "Columns", comment: "Clipboard transform parameter"),
                defaultValue: 80,
                range: 20...240
            )
        ) { text, columns in try ClipboardTextReflow.wrap(text, columns: columns ?? 80) },
        ClipboardTransform(
            id: "lines.sort",
            name: String(localized: "Sort Lines", comment: "Clipboard transform"),
            category: .lines, icon: "arrow.up.arrow.down"
        ) { text, _ in mapLines(text) { $0.sorted() } },
        ClipboardTransform(
            id: "lines.unique",
            name: String(localized: "Unique Lines", comment: "Clipboard transform"),
            category: .lines, icon: "rectangle.compress.vertical"
        ) { text, _ in
            mapLines(text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        },
        ClipboardTransform(
            id: "lines.reverse",
            name: String(localized: "Reverse Lines", comment: "Clipboard transform"),
            category: .lines, icon: "arrow.uturn.down"
        ) { text, _ in mapLines(text) { $0.reversed() } },
        ClipboardTransform(
            id: "lines.trim",
            name: String(localized: "Trim Whitespace", comment: "Clipboard transform"),
            category: .lines, icon: "scissors"
        ) { text, _ in
            let trimmedLines = text
                .components(separatedBy: "\n")
                .map { line in
                    var trimmed = line
                    while let last = trimmed.last, last == " " || last == "\t" || last == "\r" {
                        trimmed.removeLast()
                    }
                    return trimmed
                }
            return trimmedLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        },

        // MARK: Shell
        ClipboardTransform(
            id: "shell.escape",
            name: String(localized: "Shell Escape", comment: "Clipboard transform"),
            category: .shell, icon: "terminal"
        ) { text, _ in Ghostty.Shell.escape(text) },
        ClipboardTransform(
            id: "shell.stripAnsi",
            name: String(localized: "Strip ANSI Codes", comment: "Clipboard transform"),
            category: .shell, icon: "paintbrush.pointed"
        ) { text, _ in stripANSI(text) },

        // MARK: Info
        ClipboardTransform(
            id: "info.counts",
            name: String(localized: "Count Characters / Words / Lines", comment: "Clipboard transform"),
            category: .info, icon: "sum",
            isDisplayOnly: true
        ) { text, _ in
            let characters = text.count
            let bytes = text.utf8.count
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
            let charactersLabel = String(localized: "Characters", comment: "Count summary row")
            let wordsLabel = String(localized: "Words", comment: "Count summary row")
            let linesLabel = String(localized: "Lines", comment: "Count summary row")
            let bytesLabel = String(localized: "Bytes (UTF-8)", comment: "Count summary row")
            return """
            \(charactersLabel): \(characters)
            \(wordsLabel): \(words)
            \(linesLabel): \(lines)
            \(bytesLabel): \(bytes)
            """
        },
    ]

    // MARK: - Helpers

    /// Splits on whitespace, underscores, hyphens, and camelCase boundaries.
    private static func caseTokens(_ input: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_-"))
        var tokens: [String] = []
        for chunk in input.components(separatedBy: separators) where !chunk.isEmpty {
            var current = ""
            for character in chunk {
                if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                    tokens.append(current)
                    current = String(character)
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { tokens.append(current) }
        }
        return tokens
    }

    private static func utf8String(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ClipboardTransformError.invalidInput(String(localized: "Result is not valid UTF-8 text", comment: "Clipboard transform error"))
        }
        return string
    }

    private static func hexDecode(_ text: String) throws -> Data {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else {
            throw ClipboardTransformError.invalidInput(String(localized: "Not valid hex (odd length)", comment: "Clipboard transform error"))
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ClipboardTransformError.invalidInput(String(localized: "Not valid hex", comment: "Clipboard transform error"))
            }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Removes ANSI/VT escape sequences: CSI (colors, cursor movement), OSC
    /// (titles, hyperlinks), DCS/SOS/PM/APC strings, and two-character escapes.
    /// Self-contained because PromptStyle.stripANSI is unavailable on macOS
    /// (PromptStyle.swift is local-shell-only, compiled out for Catalyst).
    private static func stripANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1b}" else {
                result.append(character)
                continue
            }
            guard let introducer = iterator.next() else { break }
            switch introducer {
            case "[":
                // CSI: skip parameter/intermediate bytes until a final byte (0x40-0x7E)
                while let byte = iterator.next() {
                    if let ascii = byte.asciiValue, (0x40...0x7E).contains(ascii) { break }
                }
            case "]":
                // OSC: terminated by BEL or ST (ESC \)
                var previous: Character?
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if previous == "\u{1b}", byte == "\\" { break }
                    previous = byte
                }
            case "P", "X", "^", "_":
                // DCS/SOS/PM/APC: terminated by ST (ESC \)
                var previous: Character?
                while let byte = iterator.next() {
                    if previous == "\u{1b}", byte == "\\" { break }
                    previous = byte
                }
            default:
                // Two-character escape (ESC 7, ESC c, ...) — drop both
                break
            }
        }
        return result
    }

    private static func jsonObject(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ClipboardTransformError.invalidInput(String(localized: "Not valid JSON", comment: "Clipboard transform error"))
        }
        return object
    }

    private static func mapLines(_ text: String, _ transform: ([String]) -> [String]) -> String {
        // Preserve a single trailing newline if present; operate on content lines.
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        let result = transform(lines).joined(separator: "\n")
        return hadTrailingNewline ? result + "\n" : result
    }

    /// Decodes a compact JWS/JWT into pretty-printed header + payload, with
    /// humanized timestamp claims. The signature is NOT verified.
    private static func decodeJWT(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let segments = try? OpenPubkeyJOSE.split(compactJWS: trimmed) else {
            throw ClipboardTransformError.invalidInput(
                String(localized: "Not a valid JWT (expected header.payload.signature)", comment: "Clipboard transform error")
            )
        }

        func prettyJSON(_ base64URL: String, segment: String) throws -> (pretty: String, object: [String: Any]?) {
            guard let data = OpenPubkeyJOSE.base64URLDecode(base64URL) else {
                throw ClipboardTransformError.invalidInput(
                    String(localized: "JWT \(segment) is not valid Base64URL", comment: "Clipboard transform error")
                )
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw ClipboardTransformError.invalidInput(
                    String(localized: "JWT \(segment) is not valid JSON", comment: "Clipboard transform error")
                )
            }
            let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return (try utf8String(prettyData), object as? [String: Any])
        }

        let header = try prettyJSON(segments.protectedB64, segment: "header")
        let payload = try prettyJSON(segments.payloadB64, segment: "payload")

        let headerLabel = String(localized: "Header", comment: "JWT decode section")
        let payloadLabel = String(localized: "Payload", comment: "JWT decode section")
        var output = "\(headerLabel):\n\(header.pretty)\n\n\(payloadLabel):\n\(payload.pretty)"

        if let claims = payload.object {
            var timeLines: [String] = []
            for (key, label) in [
                ("exp", String(localized: "Expires", comment: "JWT claim")),
                ("iat", String(localized: "Issued", comment: "JWT claim")),
                ("nbf", String(localized: "Not Before", comment: "JWT claim")),
            ] {
                guard let raw = claims[key] as? NSNumber else { continue }
                let date = Date(timeIntervalSince1970: raw.doubleValue)
                let formatted = date.formatted(date: .abbreviated, time: .standard)
                if key == "exp" {
                    let status = date < Date()
                        ? String(localized: "EXPIRED", comment: "JWT expiry status")
                        : String(localized: "valid", comment: "JWT expiry status")
                    timeLines.append("\(label): \(formatted) (\(status))")
                } else {
                    timeLines.append("\(label): \(formatted)")
                }
            }
            if !timeLines.isEmpty {
                output += "\n\n" + timeLines.joined(separator: "\n")
            }
        }

        output += "\n\n" + String(localized: "⚠ Signature not verified", comment: "JWT decode footer")
        return output
    }
}
