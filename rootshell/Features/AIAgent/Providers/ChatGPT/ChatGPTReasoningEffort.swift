#if !CHINA_BUILD
//
//  ChatGPTReasoningEffort.swift
//  rootshell
//
//  Reasoning-effort presets for ChatGPT subscription models. The Codex backend
//  reports each model's supported levels and default; the user's per-model
//  choice is persisted and clamped to whatever the model actually accepts.
//

import Foundation

/// The wire vocabulary for `reasoning.effort`. Raw values go into the request 1:1.
nonisolated enum ChatGPTReasoningEffort: String, Codable, CaseIterable, Sendable, Comparable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }

    /// Canonical ordering = declaration order.
    private var ordinal: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static func < (lhs: ChatGPTReasoningEffort, rhs: ChatGPTReasoningEffort) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    /// Snaps a requested effort down to the nearest level the ladder supports;
    /// floor is the lowest supported level.
    static func clampDown(_ requested: ChatGPTReasoningEffort, to ladder: [ChatGPTReasoningEffort]) -> ChatGPTReasoningEffort {
        let sorted = ladder.sorted()
        guard let lowest = sorted.first else { return requested }
        return sorted.last { $0 <= requested } ?? lowest
    }
}

// MARK: - Model capability gates

nonisolated enum ChatGPTModelCapabilities {
    /// Parses the numeric generation out of ids like "gpt-5.6-sol",
    /// "gpt-5.3-codex-spark". Non-gpt ids return nil.
    static func gptVersion(of modelID: String) -> Double? {
        guard modelID.hasPrefix("gpt-") else { return nil }
        let rest = modelID.dropFirst("gpt-".count)
        let versionPart = rest.prefix { $0.isNumber || $0 == "." }
        return Double(versionPart)
    }

    /// `reasoning.summary` is only accepted from the gpt-5.4 wire generation on;
    /// older Codex ids reject it with `400 Unsupported parameter`.
    static func supportsReasoningSummary(_ modelID: String) -> Bool {
        (gptVersion(of: modelID) ?? 0) >= 5.4
    }

    /// Same gate for `reasoning.context: "all_turns"`; older ids get no
    /// `context` key and the server defaults to current_turn.
    static func supportsAllTurnsContext(_ modelID: String) -> Bool {
        (gptVersion(of: modelID) ?? 0) >= 5.4
    }

    /// Effort ladder inference for models whose discovery entry omits
    /// `supported_reasoning_levels`.
    static func fallbackLadder(for modelID: String) -> [ChatGPTReasoningEffort] {
        let version = gptVersion(of: modelID) ?? 0
        if version >= 5.6 { return [.low, .medium, .high, .xhigh, .max] }
        if version >= 5.2 { return [.low, .medium, .high, .xhigh] }
        return [.minimal, .low, .medium, .high]
    }
}

// MARK: - Per-model persistence

/// The user's per-model effort override, resolved against the model's ladder at
/// request-build time. Keys carry the `ai.` prefix so they ride along in backups.
@MainActor
enum ChatGPTReasoningSettings {
    private static let keyPrefix = "ai.chatgpt.reasoningEffort."

    static func storedEffort(for modelID: String) -> ChatGPTReasoningEffort? {
        UserDefaults.standard.string(forKey: keyPrefix + modelID)
            .flatMap(ChatGPTReasoningEffort.init(rawValue:))
    }

    /// nil clears the override, falling back to the model's server default.
    static func setEffort(_ effort: ChatGPTReasoningEffort?, for modelID: String) {
        if let effort {
            UserDefaults.standard.set(effort.rawValue, forKey: keyPrefix + modelID)
        } else {
            UserDefaults.standard.removeObject(forKey: keyPrefix + modelID)
        }
    }

    /// The ladder the model accepts, from discovery when known.
    static func ladder(for modelID: String) -> [ChatGPTReasoningEffort] {
        if let model = ChatGPTModelStore.shared.model(id: modelID), !model.supportedEfforts.isEmpty {
            return model.supportedEfforts
        }
        return ChatGPTModelCapabilities.fallbackLadder(for: modelID)
    }

    /// The model's server-reported default, else medium.
    static func defaultEffort(for modelID: String) -> ChatGPTReasoningEffort {
        ChatGPTModelStore.shared.model(id: modelID)?.defaultEffort ?? .medium
    }

    /// What actually goes on the wire: override or default, clamped to the ladder.
    static func effectiveEffort(for modelID: String) -> ChatGPTReasoningEffort {
        let requested = storedEffort(for: modelID) ?? defaultEffort(for: modelID)
        return ChatGPTReasoningEffort.clampDown(requested, to: ladder(for: modelID))
    }
}
#endif
