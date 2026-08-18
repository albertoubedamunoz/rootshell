#if !CHINA_BUILD
//
//  CustomProviderModelDiscovery.swift
//  rootshell
//
//  Model-list discovery for custom provider endpoints
//

import Foundation
import os.log

/// Fetches the model list from a custom provider endpoint.
///
/// Uses plain URLSession rather than the OpenAI SDK for two reasons: the Anthropic Messages format
/// needs its own auth headers, and the SDK always emits an Authorization header, which an
/// unauthenticated local server should not receive.
///
/// MainActor-isolated to match `OpenRouterProvider.discoverModels` and because `AIProviderModel` is
/// isolated too. The network call still suspends off the main thread; only the decode runs here.
enum CustomProviderModelDiscovery {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CustomProviderDiscovery")

    /// A wrong LAN address must not hang the editor for URLSession's default 60s.
    private static let timeout: TimeInterval = 15

    /// Model list shapes seen in the wild. OpenAI-compatible servers return
    /// `{"data":[{"id","owned_by"}]}`; Anthropic returns `{"data":[{"id","display_name"}]}`.
    /// Both decode into this.
    private nonisolated struct ModelListResponse: Decodable {
        nonisolated struct Entry: Decodable {
            let id: String
            let displayName: String?
            let maxModelLen: Int?
            let contextLength: Int?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case maxModelLen = "max_model_len"
                case contextLength = "context_length"
            }
        }

        let data: [Entry]
    }

    static func discoverModels(
        endpointURL: String,
        apiFormat: AIAPIFormat,
        apiKey: String?
    ) async throws -> [AIProviderModel] {
        let urlString = CustomProviderConfig.modelsURL(for: endpointURL, format: apiFormat)
        guard let url = URL(string: urlString) else {
            throw AIProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch apiFormat {
        case .openAIResponses, .openAIChatCompletions:
            // Omitted entirely when there is no key, matching the `.none` authorization
            // OpenAIProvider uses. Discovery and inference must not disagree, or a server that
            // rejects one but not the other lists models and then 401s on the first message.
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode < 400 else {
            throw mapStatus(httpResponse.statusCode, data: data, urlString: urlString)
        }

        let entries: [ModelListResponse.Entry]
        if let wrapped = try? JSONDecoder().decode(ModelListResponse.self, from: data) {
            entries = wrapped.data
        } else if let bare = try? JSONDecoder().decode([ModelListResponse.Entry].self, from: data) {
            entries = bare
        } else {
            let shownURL = CustomProviderConfig.redactedURL(urlString)
            throw AIProviderError.invalidResponse("Unrecognized model list at \(shownURL)")
        }

        let count = entries.count
        let origin = CustomProviderConfig.loggableOrigin(urlString)
        logger.info("Discovered \(count) models from \(origin, privacy: .public)")

        return entries.map { entry in
            AIProviderModel.customEndpointModel(
                id: entry.id,
                displayName: entry.displayName ?? formatModelDisplayName(entry.id),
                contextWindowTokens: entry.maxModelLen ?? entry.contextLength
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    private static func mapStatus(_ statusCode: Int, data: Data, urlString: String) -> AIProviderError {
        let serverMessage = CustomEndpointErrorBody.message(from: data)
        let shownURL = CustomProviderConfig.redactedURL(urlString)
        switch statusCode {
        case 401, 403:
            return .invalidAPIKey
        case 404:
            // "This server has no model list" and "wrong path" are indistinguishable from a 404
            // alone, so name the URL that was actually requested.
            return .networkError(serverMessage ?? "No model list at \(shownURL). Check the Endpoint URL.")
        default:
            return .networkError(serverMessage ?? "HTTP error \(statusCode)")
        }
    }

    /// Format a model ID into a more readable display name
    private static func formatModelDisplayName(_ modelID: String) -> String {
        // Common formatting: replace hyphens with spaces, capitalize
        let formatted = modelID
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // Capitalize each word
        return formatted.split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                // Keep version numbers and common abbreviations as-is
                if lower.first?.isNumber == true || ["gpt", "llm", "ai"].contains(lower) {
                    return String(word)
                }
                return word.capitalized
            }
            .joined(separator: " ")
    }
}
#endif
