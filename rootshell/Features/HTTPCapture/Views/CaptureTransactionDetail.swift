//
//  CaptureTransactionDetail.swift
//  rootshell
//
//  One request: overview and timing, request and response (headers, query,
//  cookies, body), and WebSocket frames.
//

#if !CHINA_BUILD

import SwiftUI

struct CaptureTransactionDetail: View {
    let model: HTTPCaptureModel
    let document: CaptureSessionDocument
    let transactionID: String

    enum Tab: String, CaseIterable, Identifiable {
        case overview, request, response, frames
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: String(localized: "Overview", comment: "HTTP capture detail tab")
            case .request: String(localized: "Request", comment: "HTTP capture detail tab")
            case .response: String(localized: "Response", comment: "HTTP capture detail tab")
            case .frames: String(localized: "Frames", comment: "HTTP capture detail tab: WebSocket frames")
            }
        }
    }

    @State private var tab: Tab = .response

    var body: some View {
        if let tx = document.transaction(transactionID) {
            VStack(spacing: 0) {
                titleBar(tx)
                if tx.kind == .http {
                    Picker(String(localized: "Section", comment: "HTTP capture detail tab picker"), selection: $tab) {
                        ForEach(tabs(for: tx)) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                Divider()
                content(tx)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(tx.displayHost)
            .navigationBarTitleDisplayMode(.inline)
            .id(transactionID)
        } else {
            ContentUnavailableView(String(localized: "Request Not Found", comment: "HTTP capture detail missing"), systemImage: "questionmark")
        }
    }

    private func tabs(for tx: CaptureTransaction) -> [Tab] {
        tx.isWebSocket ? Tab.allCases : [.overview, .request, .response]
    }

    private func titleBar(_ tx: CaptureTransaction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tx.method).font(.caption.monospaced().weight(.bold)).foregroundStyle(.secondary)
                    if let status = tx.status {
                        Text("\(status) \(tx.reasonPhrase ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CaptureFormat.statusColor(status))
                    }
                }
                Text(tx.url)
                    .font(.callout.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CaptureTransactionActionsMenu(model: model, document: document, transactionID: transactionID)
                .equatable()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ tx: CaptureTransaction) -> some View {
        if tx.kind != .http {
            CaptureOverview(tx: tx)
        } else {
            switch tab {
            case .overview: CaptureOverview(tx: tx)
            case .request: CaptureMessageView(document: document, tx: tx, side: .request)
            case .response: CaptureMessageView(document: document, tx: tx, side: .response)
            case .frames: CaptureWebSocketFramesView(document: document, tx: tx)
            }
        }
    }
}

/// Equatable owner for the request's ⋯ menu. The detail redraws on every
/// document refresh while recording, which would rebuild an open menu.
private struct CaptureTransactionActionsMenu: View, Equatable {
    let model: HTTPCaptureModel
    let document: CaptureSessionDocument
    let transactionID: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.document === rhs.document && lhs.transactionID == rhs.transactionID
    }

    var body: some View {
        Menu {
            CaptureTransactionActionsMenuItems(model: model, document: document, transactionID: transactionID)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "Actions", comment: "HTTP capture request actions"))
    }
}

/// Looks the request up per presentation so the actions see its latest state.
private struct CaptureTransactionActionsMenuItems: View {
    let model: HTTPCaptureModel
    let document: CaptureSessionDocument
    let transactionID: String

    var body: some View {
        if let tx = document.transaction(transactionID) {
            CaptureTransactionMenu(model: model, document: document, tx: tx)
        }
    }
}

// MARK: - Overview

struct CaptureOverview: View {
    let tx: CaptureTransaction
    @Setting(Settings.HTTPCapture.lookUpServerLocation) private var lookUpServerLocation
    @Setting(Settings.HTTPCapture.showFavicons) private var showFavicons

    private var geoIP: String? { lookUpServerLocation ? tx.serverIP : nil }
    private var geo: GeoInfo? { CaptureGeoLookup.shared.geo(for: geoIP) }

    // Same scroll-and-card layout as the request/response tabs; a grouped Form
    // paints an opaque background that clashes with the HUD's glass.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let problem = problemText {
                    problemBanner(problem)
                }
                section(String(localized: "General", comment: "HTTP capture overview section")) {
                    row(String(localized: "URL", comment: "HTTP capture field"), tx.url)
                    row(String(localized: "Protocol", comment: "HTTP capture field"), tx.proto)
                    if let status = tx.status { row(String(localized: "Status", comment: "HTTP capture field"), String(status)) }
                    row(String(localized: "Started", comment: "HTTP capture field"), tx.started.formatted(date: .abbreviated, time: .standard))
                    if let reason = tx.tunnelReason { row(String(localized: "Handling", comment: "HTTP capture field"), CaptureFormat.tunnelReason(reason)) }
                }
                section(String(localized: "Connection", comment: "HTTP capture overview section")) {
                    if let client = tx.client { row(String(localized: "Client", comment: "HTTP capture field"), client) }
                    if let server = tx.server { serverRow(server) }
                    if let sni = tx.sni, !sni.isEmpty { row("SNI", sni) }
                    if let tls = tx.tlsVersion { row("TLS", tls) }
                    if let alpn = tx.alpn, !alpn.isEmpty { row("ALPN", alpn) }
                    if tx.reused { row(String(localized: "Connection", comment: "HTTP capture field"), String(localized: "Reused", comment: "HTTP capture: kept-alive connection")) }
                }
                if let geo {
                    section(String(localized: "Server Network", comment: "HTTP capture overview section: geo info for the server IP")) {
                        if let place = Self.place(geo) {
                            row(String(localized: "Location", comment: "HTTP capture field"), [geo.flag, place].compactMap { $0 }.joined(separator: " "))
                        }
                        if !geo.asNumber.isEmpty { row("ASN", geo.asNumber) }
                        if let name = geo.asName, !name.isEmpty { row(String(localized: "AS Name", comment: "HTTP capture field"), name) }
                        if let domain = geo.asDomain, !domain.isEmpty {
                            field(String(localized: "AS Domain", comment: "HTTP capture field")) {
                                HStack(spacing: 6) {
                                    if showFavicons {
                                        FaviconImage(domain: domain, size: 14)
                                    }
                                    Text(domain).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        if !geo.network.isEmpty { row(String(localized: "Network", comment: "HTTP capture field"), geo.network) }
                    }
                }
                if tx.kind == .http {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Timing", comment: "HTTP capture overview section")).font(.headline)
                        CaptureTimingBars(tx: tx)
                            .padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                    }
                }
                section(String(localized: "Size", comment: "HTTP capture overview section")) {
                    row(tx.kind == .http ? String(localized: "Request Body", comment: "HTTP capture field") : String(localized: "Sent", comment: "HTTP capture field"),
                        CaptureFormat.bytes(tx.requestBytes) + (tx.requestTruncated ? " · " + String(localized: "truncated", comment: "HTTP capture: body over the size limit") : ""))
                    row(tx.kind == .http ? String(localized: "Response Body", comment: "HTTP capture field") : String(localized: "Received", comment: "HTTP capture field"),
                        CaptureFormat.bytes(tx.responseBytes) + (tx.responseTruncated ? " · " + String(localized: "truncated", comment: "HTTP capture: body over the size limit") : ""))
                }
                if tx.wasRewritten {
                    section(String(localized: "Rewrites Applied", comment: "HTTP capture overview section")) {
                        let rules = CaptureController.rewriteRules()
                        ForEach(tx.requestRewrites + tx.responseRewrites, id: \.self) { id in
                            Text(rules.first { $0.id == id }.map { $0.name.isEmpty ? $0.match : $0.name } ?? id)
                                .font(.caption)
                        }
                        if let note = tx.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(12)
        }
        .modifier(ScrollEdgeEffectHiddenModifier())
        .task(id: CaptureGeoLookup.shared.key(for: geoIP)) { await CaptureGeoLookup.shared.track(geoIP) }
    }

    private func problemBanner(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if tx.kind == .rejected || tx.kind == .failure {
                Button(String(localized: "Don't Decrypt This Host", comment: "HTTP capture action")) {
                    CaptureController.shared.excludeHost(tx.host)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func serverRow(_ server: String) -> some View {
        field(String(localized: "Server", comment: "HTTP capture field")) {
            HStack(spacing: 6) {
                if let flag = geo?.flag {
                    Text(flag).help(geo?.countryName ?? geo?.countryCode ?? "")
                }
                Text(server).font(.caption.monospaced()).textSelection(.enabled)
                Spacer(minLength: 4)
                if let ip = tx.serverIP {
                    CopyButton(text: ip)
                }
            }
        }
        .hostAddressCopyMenu(ipAddress: tx.serverIP)
    }

    private static func place(_ geo: GeoInfo) -> String? {
        let country = geo.countryName.flatMap { $0.isEmpty ? nil : $0 } ?? geo.countryCode
        let parts = [geo.cityName ?? "", country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var problemText: String? {
        switch tx.kind {
        case .rejected:
            String(localized: "The app closed the connection after seeing the capture certificate. It probably pins its certificates, so its traffic can't be decrypted.", comment: "HTTP capture pinning explanation")
                + (tx.bypassed ? " " + String(localized: "It is skipped for the rest of this VPN session.", comment: "HTTP capture pinning auto-bypass note") : "")
        case .failure:
            tx.error
        default:
            tx.error
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            CaptureFieldTable(content: content)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        field(title) {
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
        .contextMenu {
            Button(String(localized: "Copy Value", comment: "HTTP capture action")) { UIPasteboard.general.string = value }
        }
    }

    private func field<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Striped rows in a hairline card, matching `CaptureKeyValueTable`.
private struct CaptureFieldTable<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

struct CaptureTimingBars: View {
    let tx: CaptureTransaction

    private var segments: [(String, Double, Color)] {
        var out: [(String, Double, Color)] = []
        if let c = tx.connectMs, c > 0 { out.append((String(localized: "Connect", comment: "HTTP capture timing"), c, .orange)) }
        if let t = tx.tlsMs, t > 0 { out.append(("TLS", t, .purple)) }
        let ttfb = tx.ttfbMs ?? 0
        out.append((String(localized: "Waiting", comment: "HTTP capture timing: time to first byte"), max(0, ttfb), .green))
        if let total = tx.durationMs {
            out.append((String(localized: "Download", comment: "HTTP capture timing"), max(0, total - ttfb), .blue))
        }
        return out
    }

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.2).frame(width: max(2, geo.size.width * seg.1 / total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                HStack {
                    Circle().fill(seg.2).frame(width: 8, height: 8)
                    Text(seg.0)
                    Spacer()
                    Text(CaptureFormat.duration(seg.1)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if tx.reused {
                Text("Connection reused; connect and TLS time belong to an earlier request.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Request / response

struct CaptureMessageView: View {
    let document: CaptureSessionDocument
    let tx: CaptureTransaction
    let side: CaptureTransaction.Side

    @State private var rawHeaders = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headersSection
                if side == .request, let items = tx.components?.queryItems, !items.isEmpty {
                    keyValueSection(String(localized: "Query", comment: "HTTP capture section"), items.map { ($0.name, $0.value ?? "") })
                }
                let cookies = cookiePairs
                if !cookies.isEmpty {
                    keyValueSection(side == .request ? String(localized: "Cookies", comment: "HTTP capture section") : String(localized: "Set-Cookie", comment: "HTTP capture section"), cookies)
                }
                CaptureBodyViewer(document: document, tx: tx, side: side)
            }
            .padding(12)
        }
        .modifier(ScrollEdgeEffectHiddenModifier())
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Headers", comment: "HTTP capture section")).font(.headline)
                Spacer()
                Picker(String(localized: "Header Format", comment: "HTTP capture header view picker"), selection: $rawHeaders) {
                    Text(String(localized: "Table", comment: "HTTP capture header view")).tag(false)
                    Text(String(localized: "Raw", comment: "HTTP capture header view")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                CopyButton(text: CaptureMessageExport.head(for: tx, side: side))
            }
            if rawHeaders {
                Text(CaptureMessageExport.head(for: tx, side: side).replacingOccurrences(of: "\r\n", with: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                let headers = tx.headers(side)
                if headers.isEmpty {
                    Text(side == .response && tx.status == nil
                         ? String(localized: "No response yet.", comment: "HTTP capture: pending response")
                         : String(localized: "No headers.", comment: "HTTP capture: empty header list"))
                        .foregroundStyle(.secondary)
                } else {
                    CaptureKeyValueTable(pairs: headers.map { ($0.name, $0.value) })
                }
            }
        }
    }

    private func keyValueSection(_ title: String, _ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            CaptureKeyValueTable(pairs: pairs)
        }
    }

    private var cookiePairs: [(String, String)] {
        if side == .request {
            return tx.requestHeaders.all("cookie")
                .flatMap { $0.split(separator: ";") }
                .compactMap { part in
                    let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return kv.count == 2 ? (kv[0], kv[1]) : nil
                }
        }
        return tx.responseHeaders.all("set-cookie").compactMap { value in
            guard let first = value.split(separator: ";").first else { return nil }
            let kv = first.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 ? (kv[0], value) : nil
        }
    }
}

struct CaptureKeyValueTable: View {
    let pairs: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pair.0)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 90, maxWidth: 180, alignment: .leading)
                    Text(pair.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                .contextMenu {
                    Button(String(localized: "Copy Value", comment: "HTTP capture action")) { UIPasteboard.general.string = pair.1 }
                    Button(String(localized: "Copy Line", comment: "HTTP capture action")) { UIPasteboard.general.string = "\(pair.0): \(pair.1)" }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - WebSocket

struct CaptureWebSocketFramesView: View {
    let document: CaptureSessionDocument
    let tx: CaptureTransaction

    @State private var frames: [CaptureWSFrame] = []
    @State private var expanded: Set<Int> = []

    var body: some View {
        List {
            if frames.isEmpty {
                Text(String(localized: "No frames recorded.", comment: "HTTP capture WebSocket empty")).foregroundStyle(.secondary)
            }
            ForEach(frames) { frame in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: frame.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(frame.isOutgoing ? .green : .blue)
                        Text(frame.opcodeName).font(.caption.monospaced().weight(.semibold))
                        Text(CaptureFormat.bytes(frame.len)).font(.caption2).foregroundStyle(.secondary)
                        if frame.truncated == true { Text(String(localized: "truncated", comment: "HTTP capture: body over the size limit")).font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Text(frame.date.formatted(date: .omitted, time: .standard)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let text = frame.text {
                        Text(text)
                            .font(.caption.monospaced())
                            .lineLimit(expanded.contains(frame.id) ? nil : 3)
                            .textSelection(.enabled)
                    } else if let data = frame.payload, !data.isEmpty {
                        Text(CaptureHex.dump(data.prefix(expanded.contains(frame.id) ? 4096 : 64)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if expanded.contains(frame.id) { expanded.remove(frame.id) } else { expanded.insert(frame.id) }
                }
                .contextMenu {
                    if let text = frame.text {
                        Button(String(localized: "Copy Text", comment: "HTTP capture action")) { UIPasteboard.general.string = text }
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: tx.ended) {
            frames = await document.webSocketFrames(tx)
        }
    }
}

#endif
