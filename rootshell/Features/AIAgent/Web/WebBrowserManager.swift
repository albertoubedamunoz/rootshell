#if !CHINA_BUILD
//
//  WebBrowserManager.swift
//  rootshell
//
//  Manages hidden WKWebView instances for web search and fetch operations
//

import Foundation
import WebKit
import os.log

/// Manages hidden WKWebView instances for AI agent web operations
@MainActor
final class WebBrowserManager: NSObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WebBrowserManager")

    /// Shared instance
    static let shared = WebBrowserManager()

    /// Configuration
    private let config: WebBrowserConfig

    /// Hidden window for hosting web views
    private var hiddenWindow: UIWindow?

    /// Active web views being tracked for cleanup
    private var activeWebViews: Set<WKWebView> = []

    /// Continuations waiting for page load
    private var loadContinuations: [WKWebView: CheckedContinuation<Void, Error>] = [:]

    private override init() {
        self.config = .default
        super.init()
    }

    // MARK: - Public API

    /// Perform a web search and extract results
    /// - Parameters:
    ///   - query: The search query
    ///   - engine: Search engine to use (default: duckduckgo)
    ///   - maxResults: Maximum results to return
    /// - Returns: Array of search results
    func search(query: String, engine: SearchEngine = .duckduckgo, maxResults: Int = 5) async throws -> [SearchResult] {
        guard let url = engine.searchURL(query) else {
            throw WebBrowserError.invalidURL(query)
        }

        Self.logger.info("Searching \(engine.displayName) for: \(query)")

        let webView = try await loadURL(url)
        defer { cleanup(webView) }

        let results = try await WebContentExtractor.extractSearchResults(from: webView, engine: engine)

        Self.logger.info("Found \(results.count) search results")

        return Array(results.prefix(maxResults))
    }

    /// Fetch and extract content from a URL
    /// - Parameters:
    ///   - urlString: The URL to fetch
    ///   - extractLinks: Whether to extract links from the page
    /// - Returns: Extracted page content
    func fetch(urlString: String, extractLinks: Bool = true) async throws -> ExtractedContent {
        guard let url = URL(string: urlString) else {
            throw WebBrowserError.invalidURL(urlString)
        }

        Self.logger.info("Fetching URL: \(url.absoluteString)")

        let webView = try await loadURL(url)
        defer { cleanup(webView) }

        let content = try await WebContentExtractor.extractPageContent(
            from: webView,
            extractLinks: extractLinks,
            maxChars: config.maxContentChars,
            maxLinks: config.maxLinks
        )

        Self.logger.info("Extracted \(content.mainText.count) chars from \(url.host ?? "unknown")")

        return content
    }

    // MARK: - WebView Management

    /// Load a URL in a hidden web view and wait for completion
    private func loadURL(_ url: URL) async throws -> WKWebView {
        let webView = createWebView()

        // Ensure hidden window exists and add web view
        setupHiddenWindow()
        hiddenWindow?.rootViewController?.view.addSubview(webView)
        activeWebViews.insert(webView)

        Self.logger.debug("Loading URL: \(url.absoluteString)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Load the URL and wait for completion with timeout
        let request = URLRequest(url: url)
        webView.load(request)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuations[webView] = continuation

                // Set up timeout
                Task {
                    try await Task.sleep(nanoseconds: UInt64(config.pageLoadTimeout * 1_000_000_000))
                    if let cont = self.loadContinuations.removeValue(forKey: webView) {
                        Self.logger.warning("Page load timed out after \(self.config.pageLoadTimeout)s")
                        cont.resume(throwing: WebBrowserError.timeout(url))
                    }
                }
            }
        } catch {
            cleanup(webView)
            throw error
        }

        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        Self.logger.debug("Page loaded in \(String(format: "%.2f", loadTime))s")

        // Wait a moment for JavaScript to execute
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        return webView
    }

    /// Create a new ephemeral web view
    private func createWebView() -> WKWebView {
        // Use non-persistent data store for privacy (no cookies persist)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        // Configure preferences
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences = preferences

        // Set reasonable viewport
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true

        // Set a realistic user agent
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        return webView
    }

    /// Set up hidden window to host web views
    private func setupHiddenWindow() {
        guard hiddenWindow == nil else { return }

        // Create a hidden window
        let window = UIWindow(frame: CGRect(x: -1000, y: -1000, width: 1024, height: 768))
        window.windowLevel = .init(rawValue: -1000) // Below everything
        window.isHidden = false
        window.rootViewController = UIViewController()
        window.rootViewController?.view.isHidden = true

        hiddenWindow = window
        Self.logger.debug("Created hidden window for web views")
    }

    /// Clean up a web view and its resources
    func cleanup(_ webView: WKWebView) {
        Self.logger.debug("Cleaning up web view")

        // Cancel any pending continuation
        if let continuation = loadContinuations.removeValue(forKey: webView) {
            continuation.resume(throwing: WebBrowserError.cancelled)
        }

        // Stop loading and remove from hierarchy
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()

        // Clear website data
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            Self.logger.debug("Cleared website data for web view")
        }

        activeWebViews.remove(webView)

        // Clean up hidden window if no more web views
        if activeWebViews.isEmpty {
            hiddenWindow?.isHidden = true
            hiddenWindow = nil
            Self.logger.debug("Removed hidden window (no active web views)")
        }
    }

    /// Clean up all active web views
    func cleanupAll() {
        Self.logger.info("Cleaning up all web views (\(self.activeWebViews.count) active)")
        for webView in activeWebViews {
            cleanup(webView)
        }
    }

    /// Execute JavaScript in a web view
    func executeJS(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: WebBrowserError.javaScriptError(error.localizedDescription))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebBrowserManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            Self.logger.debug("Navigation finished: \(webView.url?.absoluteString ?? "unknown")")
            if let continuation = loadContinuations.removeValue(forKey: webView) {
                continuation.resume()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            Self.logger.error("Navigation failed: \(error.localizedDescription)")
            if let continuation = loadContinuations.removeValue(forKey: webView) {
                let url = webView.url ?? URL(string: "about:blank")!
                continuation.resume(throwing: WebBrowserError.loadFailed(url, error.localizedDescription))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            Self.logger.error("Provisional navigation failed: \(error.localizedDescription)")
            if let continuation = loadContinuations.removeValue(forKey: webView) {
                let url = webView.url ?? URL(string: "about:blank")!
                continuation.resume(throwing: WebBrowserError.loadFailed(url, error.localizedDescription))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow all navigations for now
        decisionHandler(.allow)
    }
}
#endif
