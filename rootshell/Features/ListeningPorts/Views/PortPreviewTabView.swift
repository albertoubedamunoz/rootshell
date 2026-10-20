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
    let roundedPanes: Bool
    let integratedTabJoin: IntegratedTabJoin?

    @Environment(\.paneCardRimPalette) private var paneCardRimPalette
    @State private var browser = PortPreviewBrowser()
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: browser.isSecure ? "lock" : "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("URL", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(navigate)
                    .accessibilityLabel("Address")
                if browser.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Button {
                    browser.reload(fallback: preview.url)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload")
                Button {
                    UIApplication.shared.open(browser.currentURL ?? preview.url)
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

            PortPreviewWebView(initialURL: preview.url, fontSize: preview.fontSize, browser: browser)
                .overlay {
                    if let message = browser.errorMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(uiColor: .systemBackground))
                    }
                }
        }
        .background(Color(uiColor: .systemBackground))
        // Terminal tabs get their card from the split view.
        .paneCardClip(roundedPanes)
        .overlay {
            if roundedPanes {
                JoinedCardRim(palette: paneCardRimPalette ?? .fallback, integratedTabJoin: integratedTabJoin)
            }
        }
        .onAppear { addressText = (browser.currentURL ?? preview.url).absoluteString }
        .onChange(of: browser.currentURL) { _, url in
            guard !addressFocused, let url else { return }
            addressText = url.absoluteString
        }
        .onChange(of: addressFocused) { _, focused in
            // Leaving the field without submitting restores the page's URL.
            if !focused { addressText = (browser.currentURL ?? preview.url).absoluteString }
        }
    }

    private func navigate() {
        // Not a web address: keep editing rather than covering the page.
        guard let url = PortPreviewBrowser.url(from: addressText) else {
            addressFocused = true
            return
        }
        addressFocused = false
        browser.load(url)
    }
}

/// Owns navigation for one page tab. The web view reports its own URL, so a
/// redirect or link never gets reverted by a SwiftUI update.
@Observable
final class PortPreviewBrowser: NSObject, WKNavigationDelegate {
    private(set) var currentURL: URL?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var isSecure: Bool { currentURL?.scheme?.lowercased() == "https" }

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The local port of this tab's forward.
    @ObservationIgnored private var forwardedPort: Int?

    /// A typed address: a missing scheme means http.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    func attach(_ webView: WKWebView, forwardedPort: Int?) {
        self.webView = webView
        self.forwardedPort = forwardedPort
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.currentURL = webView.url ?? self?.currentURL }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
        ]
    }

    func load(_ url: URL) {
        errorMessage = nil
        webView?.load(URLRequest(url: url))
    }

    func reload(fallback: URL) {
        errorMessage = nil
        if webView?.url != nil {
            webView?.reload()
        } else {
            load(currentURL ?? fallback)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    /// The tab's own forward is a dev server whose certificate is almost
    /// always self-signed; the SSH tunnel already authenticates the host.
    /// Every other host and port, names included, keeps normal validation.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              let forwardedPort, space.port == forwardedPort,
              Self.isIPv4Loopback(space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    private func show(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        errorMessage = error.localizedDescription
    }

    /// Only the literal address the forward binds: `127.0.0.1`, never a name.
    static func isIPv4Loopback(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        return address.s_addr == INADDR_LOOPBACK.bigEndian
    }
}

private struct PortPreviewWebView: UIViewRepresentable {
    let initialURL: URL
    let fontSize: Double
    let browser: PortPreviewBrowser

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
        browser.attach(webView, forwardedPort: initialURL.port)
        browser.load(initialURL)
        return webView
    }

    /// Navigation is the browser's; an update only carries the zoom.
    func updateUIView(_ webView: WKWebView, context: Context) {
        let zoom = CGFloat(fontSize / 16.0)
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
        }
    }
}
