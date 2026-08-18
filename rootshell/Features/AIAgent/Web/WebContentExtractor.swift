#if !CHINA_BUILD
//
//  WebContentExtractor.swift
//  rootshell
//
//  JavaScript-based content extraction from web pages
//

import Foundation
import WebKit
import os.log

/// Extracts content from web pages using JavaScript injection
@MainActor
enum WebContentExtractor {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WebContentExtractor")

    // MARK: - Search Results Extraction

    /// Extract search results from a search engine results page
    static func extractSearchResults(from webView: WKWebView, engine: SearchEngine) async throws -> [SearchResult] {
        let script: String
        switch engine {
        case .duckduckgo:
            script = duckDuckGoExtractionScript
        case .google:
            script = googleExtractionScript
        }

        guard let result = try await WebBrowserManager.shared.executeJS(script, in: webView) else {
            throw WebBrowserError.noContent(webView.url ?? URL(string: "about:blank")!)
        }

        guard let resultsArray = result as? [[String: Any]] else {
            logger.error("Unexpected search results format: \(String(describing: result))")
            throw WebBrowserError.javaScriptError("Invalid search results format")
        }

        let searchResults = resultsArray.compactMap { dict -> SearchResult? in
            guard let title = dict["title"] as? String,
                  let url = dict["url"] as? String,
                  !title.isEmpty, !url.isEmpty else {
                return nil
            }
            let snippet = dict["snippet"] as? String ?? ""
            return SearchResult(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              url: url,
                              snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Check for CAPTCHA/block detection
        if searchResults.isEmpty {
            // Log diagnostic info to help debug selector failures
            let diagnosticScript = """
            (function() {
                return {
                    hasRso: !!document.querySelector('#rso'),
                    hasSearch: !!document.querySelector('#search'),
                    h3Count: document.querySelectorAll('h3').length,
                    linkCount: document.querySelectorAll('a[href^="http"]').length,
                    bodyPreview: document.body?.innerText?.slice(0, 500) || ''
                };
            })()
            """
            if let diagnostics = try? await WebBrowserManager.shared.executeJS(diagnosticScript, in: webView) as? [String: Any] {
                let hasRso = diagnostics["hasRso"] as? Bool ?? false
                let hasSearch = diagnostics["hasSearch"] as? Bool ?? false
                let h3Count = diagnostics["h3Count"] as? Int ?? 0
                let linkCount = diagnostics["linkCount"] as? Int ?? 0
                logger.warning("Search extraction found 0 results. Diagnostics: rso=\(hasRso), search=\(hasSearch), h3s=\(h3Count), links=\(linkCount)")
                if let preview = diagnostics["bodyPreview"] as? String, !preview.isEmpty {
                    logger.debug("Page preview: \(preview)")
                }
            }

            let blocked = try await detectBlocked(webView: webView)
            if blocked {
                throw WebBrowserError.blocked(webView.url ?? URL(string: "about:blank")!)
            }
        }

        return searchResults
    }

    // MARK: - Page Content Extraction

    /// Extract main content from a web page
    static func extractPageContent(
        from webView: WKWebView,
        extractLinks shouldExtractLinks: Bool,
        maxChars: Int,
        maxLinks: Int
    ) async throws -> ExtractedContent {
        let url = webView.url ?? URL(string: "about:blank")!

        // Extract title
        let title = try await extractTitle(from: webView)

        // Extract metadata
        let metadata = try await extractMetadata(from: webView)

        // Extract main content
        let mainText = try await extractMainText(from: webView, maxChars: maxChars)

        // Extract links if requested
        var links: [ExtractedLink] = []
        if shouldExtractLinks {
            links = try await extractLinks(from: webView, maxLinks: maxLinks)
        }

        // Verify we got some content
        if mainText.isEmpty {
            let blocked = try await detectBlocked(webView: webView)
            if blocked {
                throw WebBrowserError.blocked(url)
            }
            throw WebBrowserError.noContent(url)
        }

        return ExtractedContent(
            title: title,
            url: url.absoluteString,
            mainText: mainText,
            links: links,
            metadata: metadata
        )
    }

    // MARK: - Private Extraction Methods

    private static func extractTitle(from webView: WKWebView) async throws -> String {
        let script = """
        (function() {
            return document.title || '';
        })()
        """
        let result = try await WebBrowserManager.shared.executeJS(script, in: webView)
        return (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func extractMetadata(from webView: WKWebView) async throws -> PageMetadata {
        let script = """
        (function() {
            function getMeta(name) {
                const el = document.querySelector(`meta[name="${name}"], meta[property="${name}"]`);
                return el ? el.content : null;
            }
            return {
                description: getMeta('description') || getMeta('og:description'),
                author: getMeta('author') || getMeta('article:author'),
                publishedDate: getMeta('article:published_time') || getMeta('datePublished'),
                siteName: getMeta('og:site_name')
            };
        })()
        """
        guard let result = try await WebBrowserManager.shared.executeJS(script, in: webView) as? [String: Any] else {
            return .empty
        }

        return PageMetadata(
            description: result["description"] as? String,
            author: result["author"] as? String,
            publishedDate: result["publishedDate"] as? String,
            siteName: result["siteName"] as? String
        )
    }

    private static func extractMainText(from webView: WKWebView, maxChars: Int) async throws -> String {
        let script = pageContentExtractionScript(maxChars: maxChars)
        guard let result = try await WebBrowserManager.shared.executeJS(script, in: webView) as? String else {
            return ""
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractLinks(from webView: WKWebView, maxLinks: Int) async throws -> [ExtractedLink] {
        let script = linkExtractionScript(maxLinks: maxLinks)
        guard let result = try await WebBrowserManager.shared.executeJS(script, in: webView) as? [[String: String]] else {
            return []
        }

        return result.compactMap { dict -> ExtractedLink? in
            guard let url = dict["url"], !url.isEmpty else { return nil }
            let text = dict["text"] ?? ""
            return ExtractedLink(text: text.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
        }
    }

    private static func detectBlocked(webView: WKWebView) async throws -> Bool {
        let script = """
        (function() {
            const html = document.documentElement.innerHTML.toLowerCase();
            const body = document.body?.innerText?.toLowerCase() || '';

            // Common CAPTCHA/block indicators
            const indicators = [
                'captcha', 'verify you are human', 'are you a robot',
                'unusual traffic', 'automated access', 'bot detection',
                'access denied', 'blocked', 'cloudflare',
                'please complete the security check'
            ];

            for (const indicator of indicators) {
                if (html.includes(indicator) || body.includes(indicator)) {
                    return true;
                }
            }

            // Check for CAPTCHA iframes
            const captchaFrames = document.querySelectorAll('iframe[src*="captcha"], iframe[src*="recaptcha"]');
            if (captchaFrames.length > 0) return true;

            return false;
        })()
        """
        return try await WebBrowserManager.shared.executeJS(script, in: webView) as? Bool ?? false
    }

    // MARK: - JavaScript Scripts

    private static let duckDuckGoExtractionScript = """
    (function() {
        const results = [];

        // DuckDuckGo organic results
        document.querySelectorAll('[data-testid="result"]').forEach(r => {
            const titleEl = r.querySelector('[data-testid="result-title-a"]');
            const snippetEl = r.querySelector('[data-testid="result-snippet"]');

            if (titleEl) {
                results.push({
                    title: titleEl.textContent?.trim() || '',
                    url: titleEl.href || '',
                    snippet: snippetEl?.textContent?.trim() || ''
                });
            }
        });

        // Fallback: older DDG layout
        if (results.length === 0) {
            document.querySelectorAll('.result, .nrn-react-div').forEach(r => {
                const titleEl = r.querySelector('.result__a, a[data-testid]');
                const snippetEl = r.querySelector('.result__snippet, [data-testid="result-snippet"]');

                if (titleEl && titleEl.href) {
                    results.push({
                        title: titleEl.textContent?.trim() || '',
                        url: titleEl.href,
                        snippet: snippetEl?.textContent?.trim() || ''
                    });
                }
            });
        }

        return results;
    })()
    """

    private static let googleExtractionScript = """
    (function() {
        const results = [];
        const seen = new Set();

        function addResult(title, url, snippet) {
            if (!title || !url || seen.has(url)) return;
            if (url.includes('google.com')) return;
            seen.add(url);
            results.push({ title: title.trim(), url, snippet: (snippet || '').trim() });
        }

        // Strategy 1: Modern Google containers (#rso is the main results container)
        const rso = document.querySelector('#rso');
        if (rso) {
            rso.querySelectorAll('div.g, [data-hveid], [data-sokoban-container]').forEach(r => {
                const h3 = r.querySelector('h3');
                const link = r.querySelector('a[href^="http"]');
                if (h3 && link) {
                    // Find snippet: look for text blocks after the title
                    const snippetCandidates = r.querySelectorAll('[data-sncf], .VwiC3b, [style*="-webkit-line-clamp"], span:not(:has(*))');
                    let snippet = '';
                    snippetCandidates.forEach(el => {
                        const text = el.textContent?.trim() || '';
                        if (text.length > snippet.length && text.length < 500 && !el.contains(h3)) {
                            snippet = text;
                        }
                    });
                    addResult(h3.textContent, link.href, snippet);
                }
            });
        }

        // Strategy 2: Find h3 elements with nearby links (fallback)
        if (results.length === 0) {
            document.querySelectorAll('#search h3, #rso h3, .g h3').forEach(h3 => {
                const container = h3.closest('div[data-hveid], div.g, [data-sokoban-container]') || h3.parentElement;
                const link = h3.closest('a') || container?.querySelector('a[href^="http"]');
                if (link && link.href && !link.href.includes('google.com')) {
                    const snippet = container?.querySelector('span, .VwiC3b')?.textContent || '';
                    addResult(h3.textContent, link.href, snippet);
                }
            });
        }

        // Strategy 3: Structural pattern - any external link with substantial text (last resort)
        if (results.length === 0) {
            const searchArea = document.querySelector('#search, #rso, #main');
            if (searchArea) {
                searchArea.querySelectorAll('a[href^="http"]').forEach(link => {
                    if (link.href.includes('google.com')) return;
                    const text = link.textContent?.trim() || '';
                    if (text.length > 10 && text.length < 200) {
                        const parent = link.closest('div');
                        const snippet = parent?.textContent?.replace(text, '').trim().slice(0, 200) || '';
                        addResult(text, link.href, snippet);
                    }
                });
            }
        }

        return results;
    })()
    """

    private static func pageContentExtractionScript(maxChars: Int) -> String {
        """
        (function() {
            const maxChars = \(maxChars);

            // Elements to remove
            const removeSelectors = [
                'script', 'style', 'noscript', 'iframe', 'svg',
                'nav', 'header', 'footer', 'aside',
                '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]',
                '.nav', '.navbar', '.header', '.footer', '.sidebar',
                '.advertisement', '.ad', '.ads', '.advert',
                '.cookie', '.cookies', '.consent', '.gdpr',
                '.social', '.share', '.sharing',
                '.comments', '.comment-section',
                '.related', '.recommended',
                '.popup', '.modal', '.overlay',
                '[class*="cookie"]', '[class*="banner"]', '[class*="popup"]',
                '[id*="cookie"]', '[id*="banner"]', '[id*="popup"]'
            ];

            // Clone body to avoid modifying the page
            const clone = document.body.cloneNode(true);

            // Remove unwanted elements
            removeSelectors.forEach(sel => {
                clone.querySelectorAll(sel).forEach(el => el.remove());
            });

            // Try to find main content
            let content = '';
            const mainSelectors = ['article', 'main', '[role="main"]', '.post-content', '.article-content', '.entry-content', '.content'];

            for (const sel of mainSelectors) {
                const el = clone.querySelector(sel);
                if (el && el.textContent.trim().length > 100) {
                    content = el.textContent;
                    break;
                }
            }

            // Fallback: get all text from body
            if (!content || content.trim().length < 100) {
                content = clone.textContent || '';
            }

            // Clean up whitespace
            content = content
                .replace(/\\s+/g, ' ')
                .replace(/\\n\\s*\\n/g, '\\n\\n')
                .trim();

            // Truncate at sentence boundary if needed
            if (content.length > maxChars) {
                content = content.substring(0, maxChars);
                // Try to end at a sentence
                const lastPeriod = content.lastIndexOf('. ');
                const lastQuestion = content.lastIndexOf('? ');
                const lastExclaim = content.lastIndexOf('! ');
                const lastSentence = Math.max(lastPeriod, lastQuestion, lastExclaim);

                if (lastSentence > maxChars * 0.7) {
                    content = content.substring(0, lastSentence + 1);
                }
                content += '\\n\\n[Content truncated]';
            }

            return content;
        })()
        """
    }

    private static func linkExtractionScript(maxLinks: Int) -> String {
        """
        (function() {
            const maxLinks = \(maxLinks);
            const links = [];
            const seen = new Set();

            // Focus on content area links
            const contentAreas = document.querySelectorAll('article, main, [role="main"], .content, .post-content, .article-content, body');

            contentAreas.forEach(area => {
                area.querySelectorAll('a[href]').forEach(a => {
                    const href = a.href;

                    // Skip if already seen, or if it's an internal anchor, javascript, or common non-content links
                    if (seen.has(href)) return;
                    if (href.startsWith('#') || href.startsWith('javascript:')) return;
                    if (href.includes('login') || href.includes('signup') || href.includes('subscribe')) return;
                    if (href.includes('share') || href.includes('twitter.com/intent') || href.includes('facebook.com/sharer')) return;

                    // Skip very short link text (likely icons/buttons)
                    const text = (a.textContent || '').trim();
                    if (text.length < 3 && !a.querySelector('img')) return;

                    seen.add(href);
                    links.push({
                        text: text.substring(0, 100),
                        url: href
                    });
                });
            });

            return links.slice(0, maxLinks);
        })()
        """
    }
}
#endif
