//
//  CaptureBodyViewer.swift
//  rootshell
//
//  Picks a viewer from the body's content type: JSON tree / pretty, rendered
//  HTML, highlighted source, image, form and multipart tables, or hex. Every
//  body can also open in Quick Look, be copied, or be shared.
//

#if !CHINA_BUILD

import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct CaptureBodyViewer: View {
    let document: CaptureSessionDocument
    let tx: CaptureTransaction
    let side: CaptureTransaction.Side

    enum Mode: String, CaseIterable, Identifiable {
        case tree, pretty, preview, source, image, table, parts, raw, hex
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tree: String(localized: "Tree", comment: "HTTP capture body view")
            case .pretty: String(localized: "Pretty", comment: "HTTP capture body view")
            case .preview: String(localized: "Preview", comment: "HTTP capture body view")
            case .source: String(localized: "Source", comment: "HTTP capture body view")
            case .image: String(localized: "Image", comment: "HTTP capture body view")
            case .table: String(localized: "Table", comment: "HTTP capture body view")
            case .parts: String(localized: "Parts", comment: "HTTP capture body view")
            case .raw: String(localized: "Raw", comment: "HTTP capture body view")
            case .hex: String(localized: "Hex", comment: "HTTP capture body view")
            }
        }
    }

    @State private var body_: (data: Data, decoded: Bool)?
    @State private var loaded = false
    @State private var mode: Mode?
    @State private var quickLookURL: URL?
    @State private var shareItem: CaptureShareItem?

    private var contentType: String? { tx.headers(side).first("content-type") }
    private var kind: CaptureContentKind {
        side == .response ? tx.contentKind : CaptureContentKind(contentType: contentType)
    }

    private var modes: [Mode] {
        switch kind {
        case .json: [.tree, .pretty, .raw, .hex]
        case .html: [.preview, .source, .hex]
        case .javascript, .css, .xml, .text: [.source, .hex]
        case .image: contentType?.contains("svg") == true ? [.preview, .source, .hex] : [.image, .hex]
        case .form: [.table, .raw]
        case .multipart: [.parts, .raw, .hex]
        case .font, .media, .binary, .none: [.hex, .raw]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if let body_, !body_.data.isEmpty {
                viewer(for: mode ?? modes.first ?? .hex, data: body_.data)
            } else {
                Text(tx.bodyBytes(side) > 0
                     ? String(localized: "The body was not stored.", comment: "HTTP capture: body missing")
                     : String(localized: "No body.", comment: "HTTP capture: empty body"))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(tx.id)-\(side.rawValue)-\(tx.ended?.timeIntervalSince1970 ?? 0)") {
            body_ = await document.decodedBody(tx, side: side)
            loaded = true
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $shareItem) { item in CaptureShareSheet(items: [item.url]) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Body", comment: "HTTP capture section")).font(.headline)
            Text(sizeDescription).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if modes.count > 1 {
                Picker(String(localized: "View", comment: "HTTP capture body view picker"), selection: Binding(get: { mode ?? modes[0] }, set: { mode = $0 })) {
                    ForEach(modes) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if let data = body_?.data, !data.isEmpty {
                Button { quickLookURL = writeTemp(data) } label: { Image(systemName: "eye") }
                    .help(String(localized: "Quick Look", comment: "HTTP capture body action"))
                    .accessibilityLabel(String(localized: "Quick Look", comment: "HTTP capture body action"))
                Button { copy(data) } label: { Image(systemName: "doc.on.doc") }
                    .help(String(localized: "Copy Body", comment: "HTTP capture body action"))
                    .accessibilityLabel(String(localized: "Copy Body", comment: "HTTP capture body action"))
                Button { shareItem = writeTemp(data).map(CaptureShareItem.init) } label: { Image(systemName: "square.and.arrow.up") }
                    .help(String(localized: "Save or Share Body", comment: "HTTP capture body action"))
                    .accessibilityLabel(String(localized: "Save or Share Body", comment: "HTTP capture body action"))
            }
        }
        .buttonStyle(.borderless)
    }

    private var sizeDescription: String {
        var parts: [String] = []
        if let body_ { parts.append(CaptureFormat.bytes(Int64(body_.data.count))) }
        if body_?.decoded == true, let encoding = tx.headers(side).first("content-encoding") {
            parts.append(String(localized: "decoded from \(encoding)", comment: "HTTP capture: body was compressed"))
        }
        if tx.truncated(side) {
            parts.append(String(localized: "truncated", comment: "HTTP capture: body over the size limit"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func viewer(for mode: Mode, data: Data) -> some View {
        switch mode {
        case .tree: CaptureJSONTree(data: data)
        case .pretty: CaptureCodeView(text: CaptureJSONFormatter.pretty(String(decoding: data, as: UTF8.self)), language: .json)
        case .preview:
            CaptureHTMLPreview(data: data, mimeType: contentType ?? "text/html")
                .frame(minHeight: 320)
        case .source: CaptureCodeView(text: String(decoding: data, as: UTF8.self), language: CaptureSyntax.Language(kind: kind))
        case .image:
            if let image = UIImage(data: data) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                CaptureHexView(data: data)
            }
        case .table: CaptureKeyValueTable(pairs: CaptureForm.parseURLEncoded(data))
        case .parts: CaptureMultipartView(data: data, contentType: contentType ?? "")
        case .raw: CaptureCodeView(text: String(decoding: data, as: UTF8.self), language: .plain)
        case .hex: CaptureHexView(data: data)
        }
    }

    private func copy(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = text
        } else if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
        } else {
            UIPasteboard.general.setData(data, forPasteboardType: UTType.data.identifier)
        }
    }

    private func writeTemp(_ data: Data) -> URL? {
        let mime = contentType?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let ext = mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? kind.fileExtension
        let name = (tx.components?.path.split(separator: "/").last.map(String.init) ?? side.rawValue)
            .replacingOccurrences(of: ".\(ext)", with: "")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(CaptureExportNaming.safe(name)).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct CaptureShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - JSON

enum CaptureJSONFormatter {
    /// Re-indents JSON without parsing, so key order and number formatting survive.
    static func pretty(_ text: String, indent: String = "  ") -> String {
        var out = ""
        out.reserveCapacity(text.count + text.count / 4)
        var level = 0
        var inString = false
        var escaped = false
        var pendingEmpty = false
        for ch in text {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if pendingEmpty {
                pendingEmpty = false
                if ch == "}" || ch == "]" {
                    out.append(ch)
                    continue
                }
                out.append("\n" + String(repeating: indent, count: level))
            }
            switch ch {
            case "\"":
                inString = true
                out.append(ch)
            case "{", "[":
                out.append(ch)
                level += 1
                pendingEmpty = true
            case "}", "]":
                level = max(0, level - 1)
                out.append("\n" + String(repeating: indent, count: level) + String(ch))
            case ",":
                out.append(",\n" + String(repeating: indent, count: level))
            case ":":
                out.append(": ")
            case " ", "\n", "\r", "\t":
                break
            default:
                out.append(ch)
            }
        }
        return out
    }
}

struct CaptureJSONTree: View {
    let data: Data
    @State private var root: CaptureJSONNode?
    @State private var failed = false

    var body: some View {
        Group {
            if let root {
                VStack(alignment: .leading, spacing: 0) {
                    CaptureJSONNodeView(node: root, depth: 0, startExpanded: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            } else if failed {
                CaptureCodeView(text: String(decoding: data, as: UTF8.self), language: .json)
            } else {
                ProgressView()
            }
        }
        .task(id: data) {
            let parsed = await Task.detached { CaptureJSONNode.parse(data) }.value
            root = parsed
            failed = parsed == nil
        }
    }
}

nonisolated struct CaptureJSONNode: Identifiable, Sendable {
    enum Value: Sendable {
        case object([CaptureJSONNode])
        case array([CaptureJSONNode])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    let id: Int
    let key: String?
    let value: Value

    nonisolated static func parse(_ data: Data) -> CaptureJSONNode? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var counter = 0
        return build(object, key: nil, counter: &counter)
    }

    nonisolated private static func build(_ object: Any, key: String?, counter: inout Int) -> CaptureJSONNode {
        counter += 1
        let id = counter
        switch object {
        case let dict as [String: Any]:
            let children = dict.keys.sorted().map { build(dict[$0]!, key: $0, counter: &counter) }
            return CaptureJSONNode(id: id, key: key, value: .object(children))
        case let array as [Any]:
            let children = array.enumerated().map { build($1, key: "[\($0)]", counter: &counter) }
            return CaptureJSONNode(id: id, key: key, value: .array(children))
        case let string as String:
            return CaptureJSONNode(id: id, key: key, value: .string(string))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return CaptureJSONNode(id: id, key: key, value: .bool(number.boolValue))
            }
            return CaptureJSONNode(id: id, key: key, value: .number(number.stringValue))
        default:
            return CaptureJSONNode(id: id, key: key, value: .null)
        }
    }
}

private struct CaptureJSONNodeView: View {
    let node: CaptureJSONNode
    let depth: Int
    let startExpanded: Bool
    @State private var expanded: Bool?
    @State private var limit = 200

    var body: some View {
        switch node.value {
        case .object(let children), .array(let children):
            let isOpen = expanded ?? (startExpanded || depth < 2)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded = !isOpen
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        keyText
                        Text(summary(node.value, count: children.count))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if isOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(children.prefix(limit)) { child in
                            CaptureJSONNodeView(node: child, depth: depth + 1, startExpanded: false)
                        }
                        if children.count > limit {
                            Button(String(localized: "Show \(children.count - limit) More", comment: "HTTP capture JSON tree")) {
                                limit += 500
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer().frame(width: 12)
                keyText
                leafText
                    .textSelection(.enabled)
            }
            .contextMenu {
                Button(String(localized: "Copy Value", comment: "HTTP capture action")) { UIPasteboard.general.string = leafString }
            }
        }
    }

    @ViewBuilder
    private var keyText: some View {
        if let key = node.key {
            Text(key + ":").font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.purple)
        }
    }

    private var leafString: String {
        switch node.value {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: ""
        }
    }

    private var leafText: some View {
        let color: Color
        var text = leafString
        switch node.value {
        case .string:
            color = .red
            text = "\"\(text)\""
        case .number: color = .blue
        case .bool, .null: color = .orange
        default: color = .primary
        }
        return Text(text).font(.caption.monospaced()).foregroundStyle(color).lineLimit(8)
    }

    private func summary(_ value: CaptureJSONNode.Value, count: Int) -> String {
        if case .array = value { return "[\(count)]" }
        return "{\(count)}"
    }
}

// MARK: - Source view with highlighting

nonisolated enum CaptureSyntax {
    enum Language: Sendable {
        case json, javascript, css, markup, plain

        init(kind: CaptureContentKind) {
            switch kind {
            case .json: self = .json
            case .javascript: self = .javascript
            case .css: self = .css
            case .html, .xml, .image: self = .markup
            default: self = .plain
            }
        }
    }

    static let highlightLimit = 300_000

    private static let jsKeywords = "\\b(?:break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|function|if|import|in|instanceof|let|new|return|super|switch|this|throw|try|typeof|var|void|while|with|yield|async|await|of|static|get|set|true|false|null|undefined)\\b"

    /// Rules in priority order: a later rule never recolors a range an earlier one claimed.
    private static func rules(_ language: Language) -> [(String, UIColor)] {
        switch language {
        case .json:
            return [
                ("\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)", .systemPurple),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .systemRed),
                ("-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", .systemBlue),
                ("\\b(?:true|false|null)\\b", .systemOrange),
            ]
        case .javascript:
            return [
                ("/\\*[\\s\\S]*?\\*/", .systemGray),
                ("(?<![:\\\\])//[^\\n]*", .systemGray),
                ("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`", .systemRed),
                (jsKeywords, .systemPink),
                ("\\b\\d+(?:\\.\\d+)?\\b", .systemBlue),
            ]
        case .css:
            return [
                ("/\\*[\\s\\S]*?\\*/", .systemGray),
                ("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'", .systemRed),
                ("@[a-zA-Z-]+", .systemPink),
                ("[a-zA-Z-]+(?=\\s*:[^;{]*;)", .systemPurple),
                ("-?\\b\\d+(?:\\.\\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\\b", .systemBlue),
                ("#[0-9a-fA-F]{3,8}\\b", .systemOrange),
            ]
        case .markup:
            return [
                ("<!--[\\s\\S]*?-->", .systemGray),
                ("\"[^\"]*\"|'[^']*'", .systemRed),
                ("</?[a-zA-Z][\\w:.-]*|/?>", .systemPink),
                ("\\b[a-zA-Z_:][\\w:.-]*(?==)", .systemPurple),
            ]
        case .plain:
            return []
        }
    }

    static func highlight(_ text: String, language: Language, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
        guard text.utf16.count <= highlightLimit else { return result }
        let full = NSRange(location: 0, length: (text as NSString).length)
        var claimed = IndexSet()
        for (pattern, color) in rules(language) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range, range.length > 0 else { return }
                let span = range.location..<(range.location + range.length)
                if claimed.intersects(integersIn: span) { return }
                claimed.insert(integersIn: span)
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return result
    }
}

/// Read-only, selectable text view (UIKit handles large documents far better than Text).
struct CaptureCodeView: View {
    let text: String
    let language: CaptureSyntax.Language
    @State private var wraps = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Toggle(String(localized: "Wrap Lines", comment: "HTTP capture code view option"), isOn: $wraps)
                .toggleStyle(.button)
                .controlSize(.mini)
                .font(.caption2)
            CaptureTextView(text: text, language: language, wraps: wraps)
                .frame(minHeight: 120, maxHeight: 640)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct CaptureTextView: UIViewRepresentable {
    let text: String
    let language: CaptureSyntax.Language
    let wraps: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.alwaysBounceVertical = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let key = "\(text.hashValue)-\(wraps)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.textContainer.widthTracksTextView = wraps
        view.textContainer.size = CGSize(width: wraps ? view.bounds.width : 1_000_000, height: .greatestFiniteMagnitude)
        view.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let snapshot = text
        let language = language
        view.attributedText = NSAttributedString(string: snapshot, attributes: [.font: font, .foregroundColor: UIColor.label])
        let coordinator = context.coordinator
        let fontBox = UncheckedSendableBox(font)
        Task { @MainActor [weak view] in
            let highlighted = await Task.detached(priority: .userInitiated) {
                UncheckedSendableBox(CaptureSyntax.highlight(snapshot, language: language, font: fontBox.value))
            }.value
            if coordinator.key == key { view?.attributedText = highlighted.value }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var key = ""
    }
}

/// Moves an immutable UIKit value (font, attributed string) across a detached task.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - HTML preview

struct CaptureHTMLPreview: UIViewRepresentable {
    let data: Data
    let mimeType: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        // Captured pages must not fetch anything (tracking pixels, scripts).
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "rootshell.capture.block-network",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
        ) { list, _ in
            if let list { view.configuration.userContentController.add(list) }
            view.load(data, mimeType: mimeType.split(separator: ";").first.map(String.init) ?? "text/html",
                      characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

// MARK: - Forms and multipart

enum CaptureForm {
    static func parseURLEncoded(_ data: Data) -> [(String, String)] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return (kv.first ?? "", kv.count > 1 ? kv[1] : "")
        }
    }

    struct Part: Identifiable {
        let id: Int
        let headers: [(String, String)]
        let body: Data
        var name: String? { disposition("name") }
        var filename: String? { disposition("filename") }
        var contentType: String? { headers.first { $0.0.lowercased() == "content-type" }?.1 }

        private func disposition(_ key: String) -> String? {
            guard let value = headers.first(where: { $0.0.lowercased() == "content-disposition" })?.1 else { return nil }
            for part in value.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0].lowercased() == key {
                    return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return nil
        }
    }

    static func parseMultipart(_ data: Data, contentType: String) -> [Part] {
        guard let boundaryParam = contentType.split(separator: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("boundary=") }) else { return [] }
        let boundary = boundaryParam.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Part] = []
        var searchStart = data.startIndex
        var chunks: [Range<Data.Index>] = []
        var previous: Data.Index?
        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            if let previous { chunks.append(previous..<range.lowerBound) }
            previous = range.upperBound
            searchStart = range.upperBound
        }
        for (index, chunk) in chunks.enumerated() {
            var piece = data[chunk]
            if piece.starts(with: Data("\r\n".utf8)) { piece = piece.dropFirst(2) }
            if piece.suffix(2) == Data("\r\n".utf8) { piece = piece.dropLast(2) }
            guard let split = piece.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(decoding: piece[piece.startIndex..<split.lowerBound], as: UTF8.self)
            let headers: [(String, String)] = headerText.components(separatedBy: "\r\n").compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            parts.append(Part(id: index, headers: headers, body: Data(piece[split.upperBound...])))
        }
        return parts
    }
}

private struct CaptureMultipartView: View {
    let data: Data
    let contentType: String

    var body: some View {
        let parts = CaptureForm.parseMultipart(data, contentType: contentType)
        VStack(alignment: .leading, spacing: 10) {
            if parts.isEmpty {
                Text(String(localized: "Could not split the multipart body.", comment: "HTTP capture multipart error")).foregroundStyle(.secondary)
            }
            ForEach(parts) { part in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(part.name ?? String(localized: "Part \(part.id + 1)", comment: "HTTP capture multipart part")).font(.callout.weight(.semibold))
                        if let filename = part.filename { Text(filename).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(CaptureFormat.bytes(Int64(part.body.count))).font(.caption).foregroundStyle(.secondary)
                    }
                    CaptureKeyValueTable(pairs: part.headers)
                    if let text = String(data: part.body.prefix(4096), encoding: .utf8) {
                        Text(text).font(.caption.monospaced()).lineLimit(12).textSelection(.enabled)
                    } else {
                        Text(CaptureHex.dump(part.body.prefix(256))).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Hex

enum CaptureHex {
    static func line(_ data: Data, offset: Int) -> String {
        let bytes = Array(data)
        var hex = ""
        var ascii = ""
        for i in 0..<16 {
            if i < bytes.count {
                hex += String(format: "%02x ", bytes[i])
                ascii += (0x20...0x7e).contains(bytes[i]) ? String(UnicodeScalar(bytes[i])) : "."
            } else {
                hex += "   "
            }
            if i == 7 { hex += " " }
        }
        return String(format: "%08x  ", offset) + hex + " " + ascii
    }

    static func dump(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 16).map { start in
            let lower = data.startIndex + start
            return line(data[lower..<min(lower + 16, data.endIndex)], offset: start)
        }.joined(separator: "\n")
    }
}

struct CaptureHexView: View {
    let data: Data
    private let maxBytes = 4 << 20

    var body: some View {
        let shown = data.prefix(maxBytes)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<((shown.count + 15) / 16), id: \.self) { row in
                    let lower = shown.startIndex + row * 16
                    Text(CaptureHex.line(shown[lower..<min(lower + 16, shown.endIndex)], offset: row * 16))
                        .font(.caption.monospaced())
                        .fixedSize()
                }
                if data.count > maxBytes {
                    Text(String(localized: "Showing the first 4 MB. Use Quick Look or Share for the rest.", comment: "HTTP capture hex view limit"))
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .frame(minHeight: 120, maxHeight: 480)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

#endif
