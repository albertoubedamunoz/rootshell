#if !CHINA_BUILD
//
//  CustomProviderConfig.swift
//  rootshell
//
//  Configuration for custom AI provider endpoints
//

import Foundation

/// Configuration for a custom AI provider endpoint
struct CustomProviderConfig: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var endpointURL: String
    var apiFormat: AIAPIFormat
    var useStreaming: Bool
    var isEnabled: Bool
    var discoveredModels: [AIProviderModel]
    var manualModels: [AIProviderModel]
    var createdDate: Date
    var lastModelRefresh: Date?

    /// Per-model context window sizes entered by the user.
    /// Backed as optional so decoding JSON written before this field existed doesn't fail.
    /// Access through `contextWindowOverrides` to treat nil as empty.
    private var contextWindowOverridesStorage: [String: Int]?

    var contextWindowOverrides: [String: Int] {
        get { contextWindowOverridesStorage ?? [:] }
        set { contextWindowOverridesStorage = newValue.isEmpty ? nil : newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        endpointURL: String,
        apiFormat: AIAPIFormat = .openAIResponses,
        useStreaming: Bool = true,
        isEnabled: Bool = true,
        discoveredModels: [AIProviderModel] = [],
        manualModels: [AIProviderModel] = [],
        createdDate: Date = Date(),
        lastModelRefresh: Date? = nil,
        contextWindowOverrides: [String: Int] = [:]
    ) {
        self.id = id
        self.name = name
        self.endpointURL = Self.normalizeEndpointURL(endpointURL)
        self.apiFormat = apiFormat
        self.useStreaming = useStreaming
        self.isEnabled = isEnabled
        self.discoveredModels = discoveredModels
        self.manualModels = manualModels
        self.createdDate = createdDate
        self.lastModelRefresh = lastModelRefresh
        self.contextWindowOverridesStorage = contextWindowOverrides.isEmpty ? nil : contextWindowOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpointURL, apiFormat, useStreaming, isEnabled
        case discoveredModels, manualModels, createdDate, lastModelRefresh
        case contextWindowOverridesStorage = "contextWindowOverrides"
    }

    /// Normalize endpoint URL to ensure it's valid for the OpenAI API
    /// - Ensures URL can be parsed
    /// - Fixes common mistakes like missing `/` before path segments
    static func normalizeEndpointURL(_ urlString: String) -> String {
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash for consistency
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        // Check if URL is valid
        guard URL(string: normalized) != nil else {
            // Try to fix common mistake: port followed directly by path (e.g., "8000v1" -> "8000/v1")
            // Pattern: scheme://host:port<path> where path doesn't start with /
            let portPathPattern = #"(https?://[^/:]+:\d+)([a-zA-Z])"#
            if let regex = try? NSRegularExpression(pattern: portPathPattern),
               let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
                let range = Range(match.range(at: 2), in: normalized)!
                normalized.insert("/", at: range.lowerBound)
            }
            return normalized
        }

        return normalized
    }

    /// Path components that name an operation rather than the API root. Users routinely paste
    /// the full request URL out of a curl command or a README. Multi-segment entries are matched
    /// before their single-segment suffixes.
    private static let endpointSuffixes: [[String]] = [
        ["chat", "completions"],
        ["messages"],
        ["completions"],
        ["responses"],
        ["models"]
    ]

    /// `v1`, `v1beta`, `v2alpha` — anything starting with `v` followed by a digit.
    /// Pure string work, and passed as a function value below, so it must not be actor-isolated.
    private nonisolated static func isVersionSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        guard lower.hasPrefix("v"), lower.count > 1 else { return false }
        return lower[lower.index(after: lower.startIndex)].isNumber
    }

    /// Resolve whatever the user typed into the API root every request is built from.
    /// Idempotent, so applying it again at another call site is harmless.
    ///
    /// `http://h:8000`, `http://h:8000/v1` and `http://h:8000/v1/messages` all resolve to
    /// `http://h:8000/v1`. Query and fragment are dropped; neither provider path preserved them.
    ///
    /// The version step is format-specific so each format keeps parity with the URLs it built
    /// before: the OpenAI SDK injected `/v1` after the proxy path unconditionally, while the
    /// Anthropic path used the typed URL verbatim, so only a bare origin gains a version there.
    ///
    /// Known limitation: a server that answers at the origin root with no version segment
    /// (`POST http://h:8000/messages`) cannot be expressed. Every Anthropic-compatible server we
    /// know of — the real API, oMLX, LiteLLM, vLLM — serves `/v1/messages`, and one text field
    /// cannot carry both meanings for a bare origin. The editor shows the resolved request URL so
    /// the mismatch is visible rather than silent.
    static func resolvedAPIRoot(_ urlString: String, format: AIAPIFormat) -> String {
        let normalized = normalizeEndpointURL(urlString)
        guard var components = URLComponents(string: normalized),
              components.scheme != nil,
              components.host != nil else {
            return normalized
        }

        var segments = components.path.split(separator: "/").map(String.init)
        // Always stripped. Leaving a bare operation path in place would only produce
        // "/messages/messages" once the caller appends the operation to this root.
        for suffix in endpointSuffixes where segments.count >= suffix.count {
            let tail = segments.suffix(suffix.count).map { $0.lowercased() }
            if tail == suffix {
                segments.removeLast(suffix.count)
                break
            }
        }

        // A trailing version segment means the user already gave us the root.
        let hasVersion = segments.last.map(isVersionSegment) ?? false
        if !hasVersion {
            switch format {
            case .openAIResponses, .openAIChatCompletions:
                segments.append("v1")
            case .anthropicMessages:
                // This format used the typed path verbatim, so a non-empty path must stay verbatim
                // or path-based gateways break. Only a bare origin gains the version.
                if segments.isEmpty {
                    segments.append("v1")
                }
            }
        }

        // Rebuilt through URLComponents rather than string interpolation so an IPv6 literal keeps
        // its brackets: interpolating `host` would turn http://[::1]:8000 into http://::1:8000.
        components.query = nil
        components.fragment = nil
        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        return components.string ?? normalized
    }

    /// The concrete URL a chat request hits, for display in the editor.
    static func requestURL(for endpointURL: String, format: AIAPIFormat) -> String {
        let root = resolvedAPIRoot(endpointURL, format: format)
        switch format {
        case .openAIResponses: return root + "/responses"
        case .openAIChatCompletions: return root + "/chat/completions"
        case .anthropicMessages: return root + "/messages"
        }
    }

    /// The model-list URL discovery hits, for display in the editor.
    static func modelsURL(for endpointURL: String, format: AIAPIFormat) -> String {
        resolvedAPIRoot(endpointURL, format: format) + "/models"
    }

    /// A URL safe to show or log. `http://user:pass@host/v1` is a legitimate way to reach a
    /// proxy, so the credentials stay in the request but must never reach an error card, a
    /// screenshot, or os_log.
    nonisolated static func redactedURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              components.user != nil || components.password != nil else {
            return urlString
        }
        components.user = "***"
        components.password = nil
        return components.string ?? urlString
    }

    /// Scheme, host and port only. The path can carry a bearer-like token on some gateways, so
    /// it is left out of anything published to os_log.
    nonisolated static func loggableOrigin(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return "" }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    /// The API root for this provider's stored URL and format.
    var resolvedAPIRoot: String {
        Self.resolvedAPIRoot(endpointURL, format: apiFormat)
    }

    /// Validate that the endpoint URL is properly formatted
    static func validateEndpointURL(_ urlString: String) -> Bool {
        let normalized = normalizeEndpointURL(urlString)
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host != nil else {
            return false
        }
        return true
    }

    /// All models from this provider (discovered + manual), with any user-provided
    /// `contextWindowOverrides` applied. Manual entries shadow discovered entries
    /// that share the same id so the list never contains duplicate Identifiable ids.
    var allModels: [AIProviderModel] {
        let manualIDs = Set(manualModels.map(\.id))
        let merged = discoveredModels.filter { !manualIDs.contains($0.id) } + manualModels
        let overrides = contextWindowOverrides
        guard !overrides.isEmpty else { return merged }
        return merged.map { model in
            guard let override = overrides[model.id] else { return model }
            return model.withContextWindowTokens(override)
        }
    }

    /// Keychain account identifier for this provider's API key
    var keychainAccount: String {
        "customProvider_\(id.uuidString)"
    }
}
#endif
