//
//  PortPreviewTabView.swift
//  rootshell
//
//  The content of a remote-port page tab. It is a plain WKWebView pointed at
//  the loopback forward, so the page and the listener live in the same
//  foreground app: switching to Safari would suspend the listener on iOS.
//

import SwiftUI
import UIKit
import WebKit

struct PortPreviewTabView: View {
    let preview: PortPreview

    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(preview.url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    reloadToken = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload")
                Button {
                    UIApplication.shared.open(preview.url)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Browser")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.bar)

            Divider()

            PortPreviewWebView(url: preview.url, fontSize: preview.fontSize)
                .id(reloadToken)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct PortPreviewWebView: UIViewRepresentable {
    let url: URL
    let fontSize: Double

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A forwarded development page should not write cookies into the
        // user's normal browsing session.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // A 16 pt web baseline is the browser default; this makes a 14 pt
        // terminal and the page's body text read at the same size.
        webView.pageZoom = CGFloat(fontSize / 16.0)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let zoom = CGFloat(fontSize / 16.0)
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
        }
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
