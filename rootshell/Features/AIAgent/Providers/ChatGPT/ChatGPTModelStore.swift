#if !CHINA_BUILD
//
//  ChatGPTModelStore.swift
//  rootshell
//
//  The ChatGPT-subscription backend serves its own model lineup, distinct from
//  api.openai.com. Discover it rather than hardcoding SKUs that rotate.
//

import Foundation
import Observation
import os.log

/// A model discovered from the Codex backend, including its reasoning ladder.
nonisolated struct CachedChatGPTModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let contextWindow: Int
    /// Effort levels the model accepts, sorted ascending.
    let supportedEfforts: [ChatGPTReasoningEffort]
    /// The backend's `default_reasoning_level` when reported.
    let defaultEffort: ChatGPTReasoningEffort?
}

@Observable
@MainActor
final class ChatGPTModelStore {
    static let shared = ChatGPTModelStore()

    // The ai. prefix keeps these keys inside the existing backup sweep.
    private static let cacheKey = "ai.chatgpt.models"
    private static let cacheDateKey = "ai.chatgpt.modelsRefreshDate"

    /// Codex discovery omits `context_window` for the gpt-5.6 SKUs; OpenAI's
    /// registry declares 372000 for those and 272000 elsewhere.
    private nonisolated static let defaultContextWindow = 272_000
    private nonisolated static let gpt56ContextWindow = 372_000
    private static let defaultMaxOutputTokens = 128_000

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTModelStore")

    /// Used until discovery succeeds, so the picker is never empty.
    private static let fallbackModels: [CachedChatGPTModel] = [
        CachedChatGPTModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
                           contextWindow: gpt56ContextWindow,
                           supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                           defaultEffort: .medium),
        CachedChatGPTModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
                           contextWindow: gpt56ContextWindow,
                           supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                           defaultEffort: .medium),
        CachedChatGPTModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
                           contextWindow: gpt56ContextWindow,
                           supportedEfforts: [.low, .medium, .high, .xhigh, .max],
                           defaultEffort: .medium)
    ]

    private(set) var models: [CachedChatGPTModel]
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?

    /// True while the picker is showing the built-in list rather than the
    /// backend's own lineup.
    var isUsingFallback: Bool { lastRefreshed == nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([CachedChatGPTModel].self, from: data),
           !cached.isEmpty {
            models = cached
            lastRefreshed = UserDefaults.standard.object(forKey: Self.cacheDateKey) as? Date
        } else {
            models = Self.fallbackModels
        }
    }

    func model(id: String) -> CachedChatGPTModel? {
        models.first { $0.id == id }
    }

    /// The lineup as picker-ready provider models.
    var providerModels: [AIProviderModel] {
        models.map { model in
            AIProviderModel(
                id: model.id,
                displayName: model.displayName,
                description: "ChatGPT subscription",
                tier: .standard,
                supportsTools: true,
                // The Codex backend rejects temperature outright.
                supportsTemperature: false,
                supportsThinking: true,
                source: .chatGPT,
                maxCompletionTokens: min(Self.defaultMaxOutputTokens, model.contextWindow),
                contextWindowTokens: model.contextWindow
            )
        }
    }

    /// Reloads from UserDefaults after a backup restore.
    func reloadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([CachedChatGPTModel].self, from: data),
           !cached.isEmpty {
            models = cached
            lastRefreshed = UserDefaults.standard.object(forKey: Self.cacheDateKey) as? Date
        } else {
            models = Self.fallbackModels
            lastRefreshed = nil
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 86_400) async {
        if let last = lastRefreshed, Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard ChatGPTCredentialStore.isSignedInCached else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let accessToken: String
        do {
            accessToken = try await ChatGPTCredentialStore.shared.validCredentials().accessToken
        } catch {
            Self.logger.error("Cannot list ChatGPT models: \(error.localizedDescription, privacy: .public)")
            return
        }

        // `/codex/models` is the current route; `/models` is the older one.
        for path in ["/codex/models", "/models"] {
            if let discovered = await fetchModels(path: path, accessToken: accessToken), !discovered.isEmpty {
                models = discovered
                lastRefreshed = Date()
                if let encoded = try? JSONEncoder().encode(discovered) {
                    UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
                    UserDefaults.standard.set(lastRefreshed, forKey: Self.cacheDateKey)
                }
                let count = discovered.count
                Self.logger.info("Discovered \(count) ChatGPT models from \(path, privacy: .public)")
                return
            }
        }

        Self.logger.warning("ChatGPT model discovery failed; keeping the current list")
    }

    // MARK: - Discovery

    private func fetchModels(path: String, accessToken: String) async -> [CachedChatGPTModel]? {
        guard var components = URLComponents(string: "https://chatgpt.com/backend-api" + path) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client_version", value: ChatGPTOAuth.clientVersion)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (header, value) in ChatGPTOAuth.requestHeaders(accessToken: accessToken, sessionID: UUID().uuidString) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.setValue("application/json", forHTTPHeaderField: "accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let entries = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
            return Self.normalize(entries)
        } catch {
            return nil
        }
    }

    nonisolated static func normalize(_ entries: [[String: Any]]) -> [CachedChatGPTModel] {
        var seen = Set<String>()

        return entries
            .compactMap { entry -> (model: CachedChatGPTModel, priority: Int)? in
                guard let id = (entry["slug"] as? String) ?? (entry["id"] as? String), !id.isEmpty else {
                    return nil
                }
                // The backend marks internal SKUs as hidden; don't offer them.
                if let visibility = entry["visibility"] as? String,
                   visibility == "hide" || visibility == "hidden" {
                    return nil
                }
                guard seen.insert(id).inserted else { return nil }

                let contextWindow = entry["context_window"] as? Int
                    ?? (id.hasPrefix("gpt-5.6") ? gpt56ContextWindow : defaultContextWindow)

                // `supported_reasoning_levels` is [{"effort": "low"}, ...];
                // "none" marks non-reasoning operation, which we don't offer.
                var efforts = ((entry["supported_reasoning_levels"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["effort"] as? String).flatMap(ChatGPTReasoningEffort.init(rawValue:)) }
                if efforts.isEmpty {
                    efforts = ChatGPTModelCapabilities.fallbackLadder(for: id)
                }
                efforts = Array(Set(efforts)).sorted()

                let defaultEffort = (entry["default_reasoning_level"] as? String)
                    .flatMap(ChatGPTReasoningEffort.init(rawValue:))

                return (
                    CachedChatGPTModel(
                        id: id,
                        displayName: (entry["display_name"] as? String) ?? id,
                        contextWindow: contextWindow,
                        supportedEfforts: efforts,
                        defaultEffort: defaultEffort
                    ),
                    entry["priority"] as? Int ?? Int.max
                )
            }
            .sorted { $0.priority < $1.priority }
            .map(\.model)
    }
}
#endif
