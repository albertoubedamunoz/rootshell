//
//  CaptureExporters.swift
//  rootshell
//
//  Copy as cURL, raw HTTP messages, HAR 1.2, pcapng (with embedded TLS keys),
//  and zipped session archives.
//

#if !CHINA_BUILD

import Foundation

// MARK: - cURL

nonisolated enum CaptureCURL {
    /// Headers curl derives itself or that would break a replay.
    private static let skippedHeaders: Set<String> = ["content-length", "host", "connection", "transfer-encoding", "accept-encoding"]

    /// Chrome-style "Copy as cURL (bash)". `body` is the wire bytes, so signatures still verify.
    static func command(for tx: CaptureTransaction, body: Data?) -> String {
        var parts = ["curl \(quote(tx.url))"]
        let hasBody = !(body?.isEmpty ?? true)
        let method = tx.method.uppercased()
        if !(method == "GET" && !hasBody) && !(method == "POST" && hasBody) {
            parts.append("-X \(quote(method))")
        }
        for header in tx.requestHeaders.regular where !skippedHeaders.contains(header.name.lowercased()) {
            parts.append("-H \(quote("\(header.name): \(header.value)"))")
        }
        if let body, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8), !text.unicodeScalars.contains(where: isUnsafeControl) {
                parts.append("--data-raw \(quote(text))")
            } else {
                // Arguments can't carry NUL bytes; read binary bodies from a process substitution.
                parts.append("--data-binary @<(printf '%s' \(quote(body.base64EncodedString())) | base64 --decode)")
            }
        }
        if tx.requestHeaders.first("accept-encoding") != nil {
            parts.append("--compressed")
        }
        if tx.proto.hasPrefix("HTTP/2") {
            parts.append("--http2")
        }
        return parts.joined(separator: " \\\n  ")
    }

    private static func isUnsafeControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 && s != "\n" && s != "\t" && s != "\r"
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Raw messages

nonisolated enum CaptureMessageExport {
    enum Part: String, CaseIterable, Identifiable {
        case headers, body, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .headers: String(localized: "Headers", comment: "HTTP capture export part")
            case .body: String(localized: "Body", comment: "HTTP capture export part")
            case .both: String(localized: "Headers and Body", comment: "HTTP capture export part")
            }
        }
    }

    /// The head as it went over the wire for HTTP/1, or a synthesized one for HTTP/2.
    static func head(for tx: CaptureTransaction, side: CaptureTransaction.Side) -> String {
        if side == .request, let raw = tx.requestHead, !raw.isEmpty { return raw }
        if side == .response, let raw = tx.responseHead, !raw.isEmpty { return raw }
        var lines: [String] = []
        if side == .request {
            lines.append("\(tx.method) \(tx.path) \(tx.proto.isEmpty ? "HTTP/1.1" : tx.proto)")
            if tx.requestHeaders.first(":authority") != nil || tx.requestHeaders.first("host") == nil {
                lines.append("host: \(tx.host)")
            }
        } else {
            let status = tx.status.map(String.init) ?? "-"
            lines.append("\(tx.responseProto ?? tx.proto) \(status) \(tx.reasonPhrase ?? "")".trimmingCharacters(in: .whitespaces))
        }
        for header in tx.headers(side).regular {
            lines.append("\(header.name): \(header.value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    static func data(for tx: CaptureTransaction, side: CaptureTransaction.Side, part: Part, body: Data?) -> Data {
        switch part {
        case .headers: return Data(head(for: tx, side: side).utf8)
        case .body: return body ?? Data()
        case .both:
            var data = Data(head(for: tx, side: side).utf8)
            if let body { data.append(body) }
            return data
        }
    }
}

// MARK: - HAR

nonisolated enum CaptureHAR {
    static let sensitiveHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    struct Body: Sendable {
        var request: Data?
        var response: Data?
    }

    static func build(meta: CaptureSessionMeta, transactions: [CaptureTransaction], bodies: [String: Body], sanitize: Bool) throws -> Data {
        let entries: [[String: Any]] = transactions.filter { $0.kind == .http }.map { tx in
            entry(tx, body: bodies[tx.id] ?? Body(), sanitize: sanitize)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": "rootshell", "version": version],
                "pages": [] as [Any],
                "entries": entries,
                "comment": meta.name,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func entry(_ tx: CaptureTransaction, body: Body, sanitize: Bool) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let headers = { (list: [CaptureHeader]) -> [[String: String]] in
            list.regular
                .filter { !sanitize || !sensitiveHeaders.contains($0.name.lowercased()) }
                .map { ["name": $0.name, "value": $0.value] }
        }
        let query = (tx.components?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] }
        let httpVersion = tx.proto.isEmpty ? "HTTP/1.1" : tx.proto

        var request: [String: Any] = [
            "method": tx.method,
            "url": tx.url,
            "httpVersion": httpVersion,
            "cookies": [] as [Any],
            "headers": headers(tx.requestHeaders),
            "queryString": query,
            "headersSize": -1,
            "bodySize": tx.requestBytes,
        ]
        if let data = body.request, !data.isEmpty {
            let decoded = CaptureBodyDecoder.decode(data, contentEncoding: tx.requestHeaders.first("content-encoding")).data
            var post: [String: Any] = ["mimeType": tx.requestHeaders.first("content-type") ?? ""]
            if let text = String(data: decoded, encoding: .utf8) {
                post["text"] = text
            } else {
                post["text"] = decoded.base64EncodedString()
                post["comment"] = "base64"
            }
            request["postData"] = post
        }

        var content: [String: Any] = [
            "size": tx.responseBytes,
            "mimeType": tx.responseContentType ?? "",
        ]
        if let data = body.response, !data.isEmpty {
            let decoded = CaptureBodyDecoder.decode(data, contentEncoding: tx.responseHeaders.first("content-encoding"))
            content["size"] = decoded.data.count
            if decoded.decoded { content["compression"] = decoded.data.count - data.count }
            if let text = String(data: decoded.data, encoding: .utf8) {
                content["text"] = text
            } else {
                content["text"] = decoded.data.base64EncodedString()
                content["encoding"] = "base64"
            }
        }
        let response: [String: Any] = [
            "status": tx.status ?? 0,
            "statusText": tx.reasonPhrase ?? "",
            "httpVersion": tx.responseProto ?? httpVersion,
            "cookies": [] as [Any],
            "headers": headers(tx.responseHeaders),
            "content": content,
            "redirectURL": tx.responseHeaders.first("location") ?? "",
            "headersSize": -1,
            "bodySize": tx.responseBytes,
        ]

        let wait = tx.ttfbMs ?? 0
        let receive = max(0, (tx.durationMs ?? wait) - wait)
        var entry: [String: Any] = [
            "startedDateTime": formatter.string(from: tx.started),
            "time": tx.durationMs ?? 0,
            "request": request,
            "response": response,
            "cache": [:] as [String: Any],
            "timings": [
                "blocked": -1,
                "dns": -1,
                "connect": tx.connectMs ?? -1,
                "ssl": tx.tlsMs ?? -1,
                "send": 0,
                "wait": wait,
                "receive": receive,
            ],
        ]
        if let server = tx.server {
            entry["serverIPAddress"] = server.split(separator: ":").dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        if let conn = tx.connectionID { entry["connection"] = conn }
        if let error = tx.error { entry["comment"] = error }
        return entry
    }
}

// MARK: - pcapng

/// Builds a pcapng from the engine's packets.bin, embedding keylog.txt as a
/// Decryption Secrets Block so Wireshark decrypts intercepted TLS directly.
nonisolated enum CapturePcapng {
    static func assemble(sessionDirectory dir: URL, to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }

        try out.write(contentsOf: sectionHeader())
        try out.write(contentsOf: interfaceDescription())
        if let keylog = try? Data(contentsOf: dir.appendingPathComponent("keylog.txt")), !keylog.isEmpty {
            try out.write(contentsOf: decryptionSecrets(keylog))
        }
        guard let input = try? FileHandle(forReadingFrom: dir.appendingPathComponent("packets.bin")) else { return }
        defer { try? input.close() }

        var buffer = Data()
        var batch = Data()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while buffer.endIndex - cursor >= 13 {
                let ts = buffer[cursor..<cursor + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let length = Int(buffer[cursor + 8..<cursor + 12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard buffer.endIndex - cursor >= 13 + length else { break }
                let packet = buffer[(cursor + 13)..<(cursor + 13 + length)]
                batch.append(enhancedPacket(timestampNs: ts, packet: packet))
                cursor += 13 + length
            }
            buffer = Data(buffer[cursor...])
            if batch.count > 1 << 20 {
                try out.write(contentsOf: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try out.write(contentsOf: batch) }
    }

    private static func block(type: UInt32, body: Data) -> Data {
        let total = UInt32(12 + body.count)
        var d = Data()
        d.appendLE(type)
        d.appendLE(total)
        d.append(body)
        d.appendLE(total)
        return d
    }

    private static func padded(_ data: Data) -> Data {
        var d = data
        let pad = (4 - data.count % 4) % 4
        if pad > 0 { d.append(Data(count: pad)) }
        return d
    }

    private static func sectionHeader() -> Data {
        var body = Data()
        body.appendLE(UInt32(0x1A2B3C4D))
        body.appendLE(UInt16(1))
        body.appendLE(UInt16(0))
        body.appendLE(UInt64.max) // section length unknown
        return block(type: 0x0A0D0D0A, body: body)
    }

    private static func interfaceDescription() -> Data {
        var body = Data()
        body.appendLE(UInt16(101)) // LINKTYPE_RAW: packets start with the IP header
        body.appendLE(UInt16(0))
        body.appendLE(UInt32(0))   // snaplen: unlimited
        body.appendLE(UInt16(9))   // if_tsresol
        body.appendLE(UInt16(1))
        body.append(padded(Data([9]))) // 10^-9: nanoseconds
        body.appendLE(UInt16(0))   // opt_endofopt
        body.appendLE(UInt16(0))
        return block(type: 1, body: body)
    }

    private static func decryptionSecrets(_ keylog: Data) -> Data {
        var body = Data()
        body.appendLE(UInt32(0x544C534B)) // "TLSK": NSS key log
        body.appendLE(UInt32(keylog.count))
        body.append(padded(keylog))
        return block(type: 0x0000000A, body: body)
    }

    private static func enhancedPacket(timestampNs: UInt64, packet: Data) -> Data {
        var body = Data()
        body.appendLE(UInt32(0))
        body.appendLE(UInt32(timestampNs >> 32))
        body.appendLE(UInt32(timestampNs & 0xFFFF_FFFF))
        body.appendLE(UInt32(packet.count))
        body.appendLE(UInt32(packet.count))
        body.append(padded(Data(packet)))
        return block(type: 6, body: body)
    }
}

private extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - Archive

nonisolated enum CaptureArchive {
    /// Zips a session directory (session.json, index, bodies, frames, packets).
    static func zip(sessionDirectory dir: URL, name: String) throws -> URL {
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordinationError) { zipURL in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: zipURL, to: target)
                result = .success(target)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

nonisolated enum CaptureExportNaming {
    /// A filesystem-safe base name for exported files.
    static func safe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "capture" : cleaned
    }
}

#endif
