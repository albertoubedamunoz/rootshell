#if !CHINA_BUILD
//
//  WebFetchResult.swift
//  rootshell
//
//  Data models for web search and fetch results
//

import Foundation

// MARK: - Search Results

/// A single search result from a search engine
struct SearchResult: Sendable {
    let title: String
    let url: String
    let snippet: String
}

/// Supported search engines
enum SearchEngine: String, Sendable, CaseIterable {
    case duckduckgo
    case google

    var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        }
    }

    var searchURL: (String) -> URL? {
        switch self {
        case .duckduckgo:
            return { query in
                var components = URLComponents(string: "https://duckduckgo.com/")
                components?.queryItems = [URLQueryItem(name: "q", value: query)]
                return components?.url
            }
        case .google:
            return { query in
                var components = URLComponents(string: "https://www.google.com/search")
                components?.queryItems = [URLQueryItem(name: "q", value: query)]
                return components?.url
            }
        }
    }
}

// MARK: - Page Content

/// Extracted content from a web page
struct ExtractedContent: Sendable {
    let title: String
    let url: String
    let mainText: String
    let links: [ExtractedLink]
    let metadata: PageMetadata

    /// Total character count of main content
    var contentLength: Int {
        mainText.count
    }
}

/// A link extracted from a web page
struct ExtractedLink: Sendable {
    let text: String
    let url: String

    /// Format for LLM display
    var formatted: String {
        if text.isEmpty || text == url {
            return url
        }
        return "[\(text)](\(url))"
    }
}

/// Metadata extracted from a web page
struct PageMetadata: Sendable {
    let description: String?
    let author: String?
    let publishedDate: String?
    let siteName: String?

    static let empty = PageMetadata(description: nil, author: nil, publishedDate: nil, siteName: nil)
}

// MARK: - Errors

/// Errors that can occur during web browsing operations
enum WebBrowserError: LocalizedError, Sendable {
    case timeout(URL)
    case loadFailed(URL, String)
    case noContent(URL)
    case invalidURL(String)
    case javaScriptError(String)
    case blocked(URL)
    case cancelled
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .timeout(let url):
            return "Page load timed out: \(url.absoluteString)"
        case .loadFailed(let url, let message):
            return "Failed to load \(url.host ?? url.absoluteString): \(message)"
        case .noContent(let url):
            return "No content found on page: \(url.absoluteString)"
        case .invalidURL(let urlString):
            return "Invalid URL: \(urlString)"
        case .javaScriptError(let message):
            return "Content extraction failed: \(message)"
        case .blocked(let url):
            return "Access blocked (CAPTCHA or bot detection): \(url.host ?? url.absoluteString)"
        case .cancelled:
            return "Operation was cancelled"
        case .notAvailable:
            return "Web browser not available"
        }
    }
}

// MARK: - Configuration

/// Configuration for web browser operations
struct WebBrowserConfig: Sendable {
    /// Timeout for page load (seconds)
    let pageLoadTimeout: TimeInterval

    /// Timeout for JavaScript execution (seconds)
    let jsExecutionTimeout: TimeInterval

    /// Maximum characters to return for page content
    let maxContentChars: Int

    /// Maximum characters for search results
    let maxSearchResultsChars: Int

    /// Maximum number of links to extract
    let maxLinks: Int

    /// Default configuration
    static let `default` = WebBrowserConfig(
        pageLoadTimeout: 15.0,
        jsExecutionTimeout: 5.0,
        maxContentChars: 25000,
        maxSearchResultsChars: 8000,
        maxLinks: 20
    )
}
#endif
