//
//  FaviconManager.swift
//  rootshell
//
//  Favicon fetching and caching system for domain branding.
//

import CryptoKit
import Foundation
import OSLog
import SwiftUI

// MARK: - FaviconCache

actor FaviconCache {
    struct CacheEntry: Codable {
        let domain: String
        let timestamp: Date
        let isNegative: Bool
        let imageFilename: String?  // nil for negative entries
    }

    enum CacheResult: Sendable {
        case image(Data)
        case negative
    }

    private var index: [String: CacheEntry] = [:]
    private var loaded = false
    private var dirty = false
    private var pendingSave: Task<Void, Never>?

    private static let maxEntries = 200
    private static let positiveTTL: TimeInterval = 7 * 24 * 3600   // 7 days
    private static let negativeTTL: TimeInterval = 24 * 3600        // 24 hours

    /// Nonisolated mirror of recent positive image data, populated on every
    /// `storeImage` and consulted by the synchronous `cachedFavicon(for:)`
    /// path used by widgets/views. Reading the cache file from main on a
    /// View `.task` body would block the main thread; this mirror keeps a
    /// tiny in-memory snapshot so the sync read stays cheap.
    private nonisolated static let memoryMirror = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    private nonisolated var cacheDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty/favicon_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated var indexURL: URL { cacheDir.appendingPathComponent("index.json") }

    var count: Int {
        ensureLoaded()
        return index.count
    }

    /// Look up a cached favicon.
    ///
    /// Explicit profile favicon selections can opt into retrying a previous
    /// failure. Removing the negative entry here ensures requests arriving
    /// while the retry is in flight join that request instead of immediately
    /// returning the stale failure.
    func lookup(domain: String, retryCachedFailure: Bool = false) -> CacheResult? {
        ensureLoaded()
        let key = domain.lowercased()
        guard let entry = index[key] else { return nil }

        let ttl = entry.isNegative ? Self.negativeTTL : Self.positiveTTL
        if Date().timeIntervalSince(entry.timestamp) > ttl {
            index.removeValue(forKey: key)
            if let filename = entry.imageFilename {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(filename))
            }
            Self.memoryMirror.withLock { $0[key] = nil }
            scheduleSave()
            return nil
        }

        if entry.isNegative {
            guard retryCachedFailure else { return .negative }
            index.removeValue(forKey: key)
            Self.memoryMirror.withLock { $0[key] = nil }
            scheduleSave()
            return nil
        }

        guard let filename = entry.imageFilename,
              let data = try? Data(contentsOf: cacheDir.appendingPathComponent(filename)) else {
            // Image file missing — treat as cache miss
            index.removeValue(forKey: key)
            Self.memoryMirror.withLock { $0[key] = nil }
            scheduleSave()
            return nil
        }
        Self.memoryMirror.withLock { $0[key] = data }
        return .image(data)
    }

    func storeImage(domain: String, pngData: Data) {
        ensureLoaded()
        let key = domain.lowercased()
        let hash = SHA256.hash(data: Data(key.utf8))
        let filename = hash.prefix(16).map { String(format: "%02x", $0) }.joined() + ".png"
        try? pngData.write(to: cacheDir.appendingPathComponent(filename), options: .atomic)
        index[key] = CacheEntry(domain: key, timestamp: Date(), isNegative: false, imageFilename: filename)
        Self.memoryMirror.withLock { $0[key] = pngData }
        evictIfNeeded()
        scheduleSave()
    }

    func storeNegative(domain: String) {
        ensureLoaded()
        let key = domain.lowercased()
        index[key] = CacheEntry(domain: key, timestamp: Date(), isNegative: true, imageFilename: nil)
        Self.memoryMirror.withLock { $0[key] = nil }
        evictIfNeeded()
        scheduleSave()
    }

    func clear() {
        // Remove all image files
        for entry in index.values {
            if let filename = entry.imageFilename {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(filename))
            }
        }
        index.removeAll()
        Self.memoryMirror.withLock { $0.removeAll() }
        dirty = true
        saveNow()
    }

    /// Synchronous, nonisolated read for views/widgets that can't await.
    /// Returns nil if the requested domain hasn't been hit on the actor
    /// path yet — callers should fall back to the async `lookup`.
    nonisolated static func mirroredImage(domain: String) -> Data? {
        let key = domain.lowercased()
        return memoryMirror.withLock { $0[key] }
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        let now = Date()
        index = decoded.filter { entry in
            let ttl = entry.value.isNegative ? Self.negativeTTL : Self.positiveTTL
            return now.timeIntervalSince(entry.value.timestamp) <= ttl
        }
    }

    private func evictIfNeeded() {
        guard index.count > Self.maxEntries else { return }
        let sorted = index.sorted { $0.value.timestamp < $1.value.timestamp }
        let toRemove = index.count - Self.maxEntries
        for i in 0..<toRemove {
            let entry = sorted[i]
            if let filename = entry.value.imageFilename {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(filename))
            }
            let evictKey = entry.key
            index.removeValue(forKey: evictKey)
            Self.memoryMirror.withLock { $0[evictKey] = nil }
        }
    }

    private func scheduleSave() {
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - FaviconFetcher

enum FaviconFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    private static let maxBodySize = 512 * 1024  // 512KB
    private static let maxHTMLSize = 64 * 1024    // 64KB for HTML parsing
    private static let maxRedirects = 5
    private static let targetSize: CGFloat = 64

    /// Fetch favicon for a domain. Returns processed PNG data or nil.
    static func fetch(for domain: String) async -> Data? {
        // Strategy 1: Parse HTML for icon links
        if let data = await fetchFromHTML(domain: domain) {
            return data
        }

        // Strategy 2: Direct favicon.ico
        if let data = await fetchDirect(url: "https://\(domain)/favicon.ico") {
            return data
        }

        // Strategy 3: Try root domain if we have subdomains
        let rootDomain = Self.rootDomain(of: domain)
        if rootDomain != domain {
            if let data = await fetchFromHTML(domain: rootDomain) {
                return data
            }
            if let data = await fetchDirect(url: "https://\(rootDomain)/favicon.ico") {
                return data
            }
        }

        return nil
    }

    /// Extract domain from a URL string like "https://www.tp-link.com"
    static func extractDomain(from urlString: String) -> String? {
        // Handle URLs without scheme
        let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let url = URL(string: normalized), let host = url.host else { return nil }
        return host.lowercased()
    }

    // MARK: - HTML Parsing

    private static func fetchFromHTML(domain: String) async -> Data? {
        guard let url = URL(string: "https://\(domain)/") else { return nil }
        guard let html = await fetchHTML(url: url, depth: 0) else { return nil }
        let icons = parseIconLinks(html: html, baseURL: url)
        for iconURL in icons {
            if let data = await fetchDirect(url: iconURL) {
                return data
            }
        }
        return nil
    }

    private static func fetchHTML(url: URL, depth: Int) async -> String? {
        guard depth < maxRedirects else { return nil }
        guard let (data, response) = try? await session.data(from: url) else { return nil }

        if let httpResponse = response as? HTTPURLResponse,
           (301...308).contains(httpResponse.statusCode),
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let redirectURL = URL(string: location, relativeTo: url) {
            return await fetchHTML(url: redirectURL.absoluteURL, depth: depth + 1)
        }

        let truncated = data.prefix(maxHTMLSize)
        let html = String(decoding: truncated, as: UTF8.self)

        // Check for meta-refresh redirect
        if let refreshURL = parseMetaRefresh(html: html, baseURL: url) {
            return await fetchHTML(url: refreshURL, depth: depth + 1)
        }

        return html
    }

    private static func parseMetaRefresh(html: String, baseURL: URL) -> URL? {
        // Match <meta http-equiv="refresh" content="0; url=...">
        guard let match = html.range(of: #"<meta[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*url\s*=\s*([^"'\s>]+)"#,
                                      options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let matched = String(html[match])
        // Extract URL after url=
        guard let urlRange = matched.range(of: #"url\s*=\s*"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var urlStr = String(matched[urlRange.upperBound...])
        // Remove trailing quotes/angle brackets
        urlStr = urlStr.trimmingCharacters(in: CharacterSet(charactersIn: "\"' >"))
        return resolveURL(urlStr, base: baseURL)
    }

    private static func parseIconLinks(html: String, baseURL: URL) -> [String] {
        // Find all <link> tags
        let linkPattern = #"<link\s[^>]*>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) else {
            return []
        }

        struct IconCandidate {
            let url: String
            let priority: Int  // lower = better
        }

        var candidates: [IconCandidate] = []
        let nsHTML = html as NSString
        let matches = linkRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            let tag = nsHTML.substring(with: match.range)

            // Extract rel attribute
            guard let rel = extractAttribute("rel", from: tag)?.lowercased() else { continue }
            guard rel.contains("icon") else { continue }

            // Skip SVG
            if let type = extractAttribute("type", from: tag)?.lowercased(), type.contains("svg") {
                continue
            }
            if let href = extractAttribute("href", from: tag), href.lowercased().hasSuffix(".svg") {
                continue
            }

            guard let href = extractAttribute("href", from: tag),
                  let resolved = resolveURL(href, base: baseURL) else { continue }

            let priority: Int
            if rel.contains("apple-touch-icon") {
                priority = 0
            } else if rel.contains("icon") && extractAttribute("type", from: tag)?.lowercased().contains("png") == true {
                priority = 1
            } else if rel == "icon" {
                priority = 2
            } else {
                priority = 3
            }

            candidates.append(IconCandidate(url: resolved.absoluteString, priority: priority))
        }

        candidates.sort { $0.priority < $1.priority }
        return candidates.map(\.url)
    }

    private static func extractAttribute(_ name: String, from tag: String) -> String? {
        // Match name="value" or name='value'
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*?)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsTag = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        return nsTag.substring(with: match.range(at: 1))
    }

    private static func resolveURL(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Protocol-relative
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }

        // Absolute
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        // Root-relative
        if trimmed.hasPrefix("/") {
            guard let host = base.host else { return nil }
            return URL(string: "https://\(host)\(trimmed)")
        }

        // Relative
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    // MARK: - Direct Fetch & Processing

    private static func fetchDirect(url urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        return await fetchDirect(url: url)
    }

    private static func fetchDirect(url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            return nil
        }

        let capped = data.prefix(maxBodySize)
        return processImage(Data(capped))
    }

    private static func processImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSize, height: targetSize))
        let resized = renderer.pngData { context in
            image.draw(in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        }
        return resized
    }

    // MARK: - Domain Utilities

    private static func rootDomain(of domain: String) -> String {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count > 2 else { return domain.lowercased() }
        return parts.suffix(2).joined(separator: ".")
    }
}

// MARK: - FaviconManager

@MainActor
final class FaviconManager {
    static let shared = FaviconManager()

    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "favicon")

    private let cache = FaviconCache()
    private var inFlight: [String: [CheckedContinuation<Data?, Never>]] = [:]
    /// Domains that have already consumed their one retry for the current
    /// cached failure. A successful fetch clears the marker.
    private var retriedCachedFailureDomains: Set<String> = []

    /// Async cache size (delegates to the actor). Settings UI awaits this.
    var cacheEntryCount: Int {
        get async { await cache.count }
    }

    private init() {}

    /// Fetch a favicon, optionally retrying a cached failure once.
    ///
    /// Most callers should retain the default so missing favicons do not
    /// repeatedly generate network traffic. Explicit custom-host profile
    /// icons use the retry path because the user has specifically selected
    /// that hostname as the profile's icon. Recreated views cannot repeatedly
    /// bypass a newly stored negative result.
    func favicon(for domain: String, retryCachedFailure: Bool = false) async -> Data? {
        let key = domain.lowercased()
        var ownsFetch = false

        // Check cache first
        if let cached = await cache.lookup(domain: key) {
            switch cached {
            case .image(let data): return data
            case .negative:
                // A retry owner registers inFlight before its next actor hop,
                // so concurrent views join the retry even if their cache
                // lookup also returned the old negative entry.
                if inFlight[key] != nil {
                    return await waitForInFlightFavicon(for: key)
                }
                guard retryCachedFailure,
                      retriedCachedFailureDomains.insert(key).inserted else {
                    return nil
                }
                inFlight[key] = []
                ownsFetch = true

                // Consume this domain's one retry by removing the negative
                // entry. A failed retry stores a fresh negative result that
                // subsequent view recreations will respect.
                if case .image(let data)? = await cache.lookup(
                    domain: key,
                    retryCachedFailure: true
                ) {
                    // Another successful request may have populated the cache
                    // between the two actor hops. Use it instead of starting a
                    // redundant network fetch.
                    retriedCachedFailureDomains.remove(key)
                    finishInFlightFavicon(for: key, with: data)
                    return data
                }
            }
        }

        // Check if there's already an in-flight request for this domain
        if !ownsFetch {
            if inFlight[key] != nil {
                return await waitForInFlightFavicon(for: key)
            }

            // Start new fetch
            inFlight[key] = []
        }

        let result = await FaviconFetcher.fetch(for: key)

        if let data = result {
            retriedCachedFailureDomains.remove(key)
            await cache.storeImage(domain: key, pngData: data)
        } else {
            await cache.storeNegative(domain: key)
        }

        finishInFlightFavicon(for: key, with: result)

        return result
    }

    private func waitForInFlightFavicon(for key: String) async -> Data? {
        await withCheckedContinuation { continuation in
            guard inFlight[key] != nil else {
                continuation.resume(returning: nil)
                return
            }
            inFlight[key]?.append(continuation)
        }
    }

    private func finishInFlightFavicon(for key: String, with result: Data?) {
        let waiters = inFlight.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    /// Synchronous nonisolated read for views that can't await. Uses the
    /// in-memory mirror populated by the actor; returns nil if the domain
    /// hasn't been hit on the actor path yet (caller should fall back to
    /// async `favicon(for:)`).
    nonisolated func cachedFavicon(for domain: String) -> Data? {
        FaviconCache.mirroredImage(domain: domain)
    }

    func clearCache() async {
        retriedCachedFailureDomains.removeAll()
        await cache.clear()
    }
}

// MARK: - FaviconImage (SwiftUI View)

struct FaviconImage: View {
    let domain: String
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
            }
        }
        .frame(width: size, height: size)
        .task(id: domain) {
            if let cached = FaviconManager.shared.cachedFavicon(for: domain),
               let uiImage = UIImage(data: cached) {
                image = uiImage
                return
            }
            if let data = await FaviconManager.shared.favicon(for: domain),
               let uiImage = UIImage(data: data) {
                image = uiImage
            }
        }
    }
}
