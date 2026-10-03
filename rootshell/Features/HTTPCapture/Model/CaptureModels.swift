//
//  CaptureModels.swift
//  rootshell
//
//  App-side model of a capture session: the engine's index events folded into
//  transactions, plus the app-owned session metadata.
//

#if !CHINA_BUILD

import Foundation
import UniformTypeIdentifiers

/// One line of the engine's index.jsonl (fields mirror vpntunnel/recorder.go).
nonisolated struct CaptureIndexEvent: Decodable, Sendable {
    let t: String
    let id: String?
    let ts: Double?
    let seg: String?
    let session: String?
    let transport: String?
    let reason: String?
    let conn: String?
    let method: String?
    let url: String?
    let host: String?
    let scheme: String?
    let proto: String?
    let reqHeaders: [[String]]?
    let reqHead: String?
    let client: String?
    let server: String?
    let sni: String?
    let tls: String?
    let alpn: String?
    let connectMs: Double?
    let tlsMs: Double?
    let reused: Bool?
    let rewritten: [String]?
    let status: Int?
    let resHeaders: [[String]]?
    let resHead: String?
    let reqBytes: Int64?
    let resBytes: Int64?
    let reqBodyFile: String?
    let resBodyFile: String?
    let reqTruncated: Bool?
    let resTruncated: Bool?
    let error: String?
    let ws: Bool?
    let note: String?
    let start: Double?
    let bytesUp: Int64?
    let bytesDown: Int64?
    let detail: String?
    let bypassed: Bool?
    let stage: String?
}

nonisolated struct CaptureHeader: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let value: String

    static func list(_ pairs: [[String]]?) -> [CaptureHeader] {
        (pairs ?? []).enumerated().compactMap { index, pair in
            pair.count == 2 ? CaptureHeader(id: index, name: pair[0], value: pair[1]) : nil
        }
    }
}

extension Array where Element == CaptureHeader {
    nonisolated func first(_ name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    nonisolated func all(_ name: String) -> [String] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Without HTTP/2 pseudo-headers (":method", ":path", …).
    nonisolated var regular: [CaptureHeader] { filter { !$0.name.hasPrefix(":") } }
}

nonisolated struct CaptureTransaction: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// A decrypted or plain HTTP exchange.
        case http
        /// A connection relayed without inspection.
        case tunnel
        /// The client refused our certificate (likely pinning).
        case rejected
        /// Upstream dial or TLS failed.
        case failure
    }

    enum Side: String, Sendable, CaseIterable { case request, response }

    let id: String
    var kind: Kind
    var started: Date
    var responseAt: Date?
    var ended: Date?

    var method = ""
    var url = ""
    var host = ""
    var scheme = ""
    var proto = ""
    var requestHeaders: [CaptureHeader] = []
    var requestHead: String?
    var connectionID: String?
    var client: String?
    var server: String?
    var sni: String?
    var tlsVersion: String?
    var alpn: String?
    var connectMs: Double?
    var tlsMs: Double?
    var reused = false
    var requestRewrites: [String] = []

    var status: Int?
    var reasonPhrase: String?
    var responseProto: String?
    var responseHeaders: [CaptureHeader] = []
    var responseHead: String?
    var responseRewrites: [String] = []

    var requestBytes: Int64 = 0
    var responseBytes: Int64 = 0
    var requestBodyFile: String?
    var responseBodyFile: String?
    var requestTruncated = false
    var responseTruncated = false
    var error: String?
    var note: String?
    var isWebSocket = false

    var tunnelReason: String?
    var bypassed = false

    var isComplete: Bool { ended != nil }

    var components: URLComponents? { URLComponents(string: url) }

    var path: String {
        guard let c = components else { return url }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return c.percentEncodedQuery.map { p + "?" + $0 } ?? p
    }

    var displayHost: String {
        if !host.isEmpty { return host }
        return sni ?? server ?? ""
    }

    /// The upstream address without its port or brackets, when `server` is an IP literal.
    var serverIP: String? { server.flatMap(IPAddressExtractor.address(fromToken:)) }

    var durationMs: Double? {
        guard let ended else { return nil }
        return ended.timeIntervalSince(started) * 1000
    }

    var ttfbMs: Double? {
        guard let responseAt else { return nil }
        return responseAt.timeIntervalSince(started) * 1000
    }

    var wasRewritten: Bool { !requestRewrites.isEmpty || !responseRewrites.isEmpty }

    func headers(_ side: Side) -> [CaptureHeader] { side == .request ? requestHeaders : responseHeaders }
    func bodyFile(_ side: Side) -> String? { side == .request ? requestBodyFile : responseBodyFile }
    func bodyBytes(_ side: Side) -> Int64 { side == .request ? requestBytes : responseBytes }
    func truncated(_ side: Side) -> Bool { side == .request ? requestTruncated : responseTruncated }

    var responseContentType: String? { responseHeaders.first("content-type") }
    var contentKind: CaptureContentKind {
        CaptureContentKind(contentType: responseContentType, url: url)
    }
}

/// Coarse body type used for filters, icons, and viewer choice.
nonisolated enum CaptureContentKind: String, CaseIterable, Sendable {
    case json, html, javascript, css, xml, plist, image, text, form, multipart, font, media, binary, none

    init(contentType: String?, url: String = "") {
        let ct = (contentType ?? "").lowercased()
        let mime = ct.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch true {
        case mime.isEmpty:
            self = Self.fromExtension(URL(string: url)?.pathExtension ?? "")
        case mime.contains("plist"): self = .plist
        case mime.contains("json"): self = .json
        case mime.contains("html"): self = .html
        case mime.contains("javascript") || mime.contains("ecmascript"): self = .javascript
        case mime == "text/css": self = .css
        case mime.contains("xml"): self = mime.contains("svg") ? .image : .xml
        case mime.hasPrefix("image/"): self = .image
        case mime == "application/x-www-form-urlencoded": self = .form
        case mime.hasPrefix("multipart/"): self = .multipart
        case mime.hasPrefix("font/") || mime.contains("font"): self = .font
        case mime.hasPrefix("video/") || mime.hasPrefix("audio/"): self = .media
        case mime.hasPrefix("text/"): self = .text
        default: self = .binary
        }
    }

    static func fromExtension(_ ext: String) -> CaptureContentKind {
        switch ext.lowercased() {
        case "json": .json
        case "html", "htm": .html
        case "js", "mjs": .javascript
        case "css": .css
        case "xml": .xml
        case "plist": .plist
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "avif": .image
        case "woff", "woff2", "ttf", "otf": .font
        case "mp4", "mov", "m3u8", "mp3", "aac", "m4a", "webm": .media
        case "txt": .text
        default: .none
        }
    }

    var systemImage: String {
        switch self {
        case .json: "curlybraces"
        case .html: "globe"
        case .javascript: "chevron.left.forwardslash.chevron.right"
        case .css: "paintbrush"
        case .xml: "chevron.left.slash.chevron.right"
        case .plist: "list.bullet.indent"
        case .image: "photo"
        case .text: "doc.plaintext"
        case .form, .multipart: "list.bullet.rectangle"
        case .font: "textformat"
        case .media: "play.rectangle"
        case .binary: "doc"
        case .none: "arrow.left.arrow.right"
        }
    }

    var title: String {
        switch self {
        case .json: "JSON"
        case .html: "HTML"
        case .javascript: "JS"
        case .css: "CSS"
        case .xml: "XML"
        case .plist: "Plist"
        case .image: String(localized: "Image", comment: "HTTP capture content type filter")
        case .text: String(localized: "Text", comment: "HTTP capture content type filter")
        case .form: String(localized: "Form", comment: "HTTP capture content type filter")
        case .multipart: String(localized: "Multipart", comment: "HTTP capture content type filter")
        case .font: String(localized: "Font", comment: "HTTP capture content type filter")
        case .media: String(localized: "Media", comment: "HTTP capture content type filter")
        case .binary: String(localized: "Binary", comment: "HTTP capture content type filter")
        case .none: String(localized: "Other", comment: "HTTP capture content type filter")
        }
    }

    /// File extension used for Quick Look / export.
    var fileExtension: String {
        switch self {
        case .json: "json"
        case .html: "html"
        case .javascript: "js"
        case .css: "css"
        case .xml: "xml"
        case .plist: "plist"
        case .text, .form: "txt"
        default: "bin"
        }
    }
}

/// App-owned metadata for one capture session (session.json).
nonisolated struct CaptureSessionMeta: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var endedAt: Date?
    var profileName: String?
    var recordedPackets: Bool = false
    var transactionCount: Int?
    var byteSize: Int64?
    /// macOS: every spool file has been copied out of the system extension.
    var mirrored: Bool?

    var isRecording: Bool { endedAt == nil }
}

nonisolated struct CaptureWSFrame: Decodable, Identifiable, Sendable, Hashable {
    var id: Int { lineIndex }
    var lineIndex = 0
    let ts: Double
    let dir: String
    let op: Int
    let fin: Bool
    let len: Int64
    let text: String?
    let b64: String?
    let truncated: Bool?
    let compressed: Bool?

    private enum CodingKeys: String, CodingKey { case ts, dir, op, fin, len, text, b64, truncated, compressed }

    var isOutgoing: Bool { dir == "out" }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    var payload: Data? {
        if let text { return Data(text.utf8) }
        return b64.flatMap { Data(base64Encoded: $0) }
    }

    var opcodeName: String {
        switch op {
        case 0: "continuation"
        case 1: "text"
        case 2: "binary"
        case 8: "close"
        case 9: "ping"
        case 10: "pong"
        default: "op \(op)"
        }
    }
}

/// Folds index events into transactions in arrival order.
nonisolated struct CaptureIndexFolder {
    private(set) var transactions: [CaptureTransaction] = []
    private var positions: [String: Int] = [:]
    private(set) var stopReason: String?

    mutating func apply(_ e: CaptureIndexEvent) {
        let date = Date(timeIntervalSince1970: (e.ts ?? 0) / 1000)
        switch e.t {
        case "txStart":
            guard let id = e.id else { return }
            var tx = CaptureTransaction(id: id, kind: .http, started: date)
            tx.method = e.method ?? ""
            tx.url = e.url ?? ""
            tx.host = e.host ?? ""
            tx.scheme = e.scheme ?? ""
            tx.proto = e.proto ?? ""
            tx.requestHeaders = CaptureHeader.list(e.reqHeaders)
            tx.requestHead = e.reqHead
            tx.connectionID = e.conn
            tx.client = e.client
            tx.server = e.server
            tx.sni = e.sni
            tx.tlsVersion = e.tls
            tx.alpn = e.alpn
            tx.connectMs = e.connectMs
            tx.tlsMs = e.tlsMs
            tx.reused = e.reused ?? false
            tx.requestRewrites = e.rewritten ?? []
            insert(tx)
        case "txResponse":
            update(e.id) { tx in
                tx.responseAt = date
                tx.status = e.status
                tx.reasonPhrase = e.reason
                tx.responseProto = e.proto
                tx.responseHeaders = CaptureHeader.list(e.resHeaders)
                tx.responseHead = e.resHead
                tx.responseRewrites = e.rewritten ?? []
            }
        case "txEnd":
            update(e.id) { tx in
                tx.ended = date
                tx.requestBytes = e.reqBytes ?? 0
                tx.responseBytes = e.resBytes ?? 0
                tx.requestBodyFile = e.reqBodyFile
                tx.responseBodyFile = e.resBodyFile
                tx.requestTruncated = e.reqTruncated ?? false
                tx.responseTruncated = e.resTruncated ?? false
                tx.error = e.error
                tx.note = e.note
                tx.isWebSocket = e.ws ?? false
            }
        case "tunnel":
            guard let id = e.id else { return }
            var tx = CaptureTransaction(id: id, kind: .tunnel, started: Date(timeIntervalSince1970: (e.start ?? e.ts ?? 0) / 1000))
            tx.ended = date
            tx.host = e.host ?? e.sni ?? ""
            tx.sni = e.sni
            tx.alpn = e.alpn
            tx.client = e.client
            tx.server = e.server
            tx.tunnelReason = e.reason
            tx.error = e.error
            tx.requestBytes = e.bytesUp ?? 0
            tx.responseBytes = e.bytesDown ?? 0
            tx.method = "CONNECT"
            tx.url = e.server ?? ""
            insert(tx)
        case "tlsRejected":
            guard let id = e.id else { return }
            var tx = CaptureTransaction(id: id, kind: .rejected, started: date)
            tx.ended = date
            tx.host = e.host ?? ""
            tx.server = e.server
            tx.error = e.detail
            tx.bypassed = e.bypassed ?? false
            tx.method = "TLS"
            tx.url = e.host ?? ""
            insert(tx)
        case "failure":
            guard let id = e.id else { return }
            var tx = CaptureTransaction(id: id, kind: .failure, started: date)
            tx.ended = date
            tx.host = e.host ?? ""
            tx.server = e.server
            tx.error = e.error
            tx.tunnelReason = e.stage
            tx.method = "TLS"
            tx.url = e.host ?? e.server ?? ""
            insert(tx)
        case "stop":
            stopReason = e.reason
        default:
            break
        }
    }

    private mutating func insert(_ tx: CaptureTransaction) {
        if let i = positions[tx.id] {
            transactions[i] = tx
            return
        }
        positions[tx.id] = transactions.count
        transactions.append(tx)
    }

    private mutating func update(_ id: String?, _ change: (inout CaptureTransaction) -> Void) {
        guard let id, let i = positions[id] else { return }
        change(&transactions[i])
    }
}

#endif
