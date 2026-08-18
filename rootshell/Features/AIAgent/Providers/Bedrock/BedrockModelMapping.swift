#if !CHINA_BUILD
//
//  BedrockModelMapping.swift
//  rootshell
//
//  Translates our internal Bedrock model IDs (with `bedrock-` prefix to
//  disambiguate from the direct-API ones) into the actual Bedrock model
//  invocation IDs, region-aware.
//
//  Anthropic's newest Claude models on Bedrock are only invokable through
//  cross-region inference profiles, which prepend the geography (`us.`,
//  `eu.`, `apac.`) to the bare model ID. The mapping below resolves both
//  the bare ID and the geography prefix in one place.
//

import Foundation

enum BedrockModelMapping {
    /// Per-model invocation metadata. Anthropic's Claude 4.x models on Bedrock
    /// are not invocable via their bare foundation IDs — each must go through
    /// a cross-region inference profile (e.g., `us.anthropic.claude-opus-5`),
    /// and the set of available geographies differs per model. We pick the
    /// closest geographic profile to the user's chosen region; if the model
    /// doesn't have a profile in that geo we fall back to `global`, which is
    /// available for every Anthropic model on Bedrock today.
    private struct ModelDefinition {
        /// Foundation model ID exactly as registered in Bedrock — note that
        /// Haiku 4.5 includes a date stamp and `-v1:0` suffix, while the
        /// Opus/Sonnet 4.x entries don't. These match what
        /// `aws bedrock list-foundation-models --by-provider anthropic` returns.
        let foundationID: String
        let geographies: Set<String>
    }

    private static let definitions: [String: ModelDefinition] = [
        "bedrock-claude-opus-5": ModelDefinition(
            foundationID: "anthropic.claude-opus-5",
            geographies: ["us", "eu", "global"]
        ),
        "bedrock-claude-sonnet-4-6": ModelDefinition(
            foundationID: "anthropic.claude-sonnet-4-6",
            geographies: ["us", "eu", "global"]
        ),
        "bedrock-claude-sonnet-5": ModelDefinition(
            foundationID: "anthropic.claude-sonnet-5",
            geographies: ["us", "eu", "global"]
        ),
        "bedrock-claude-haiku-4-5": ModelDefinition(
            foundationID: "anthropic.claude-haiku-4-5-20251001-v1:0",
            geographies: ["us", "eu", "au", "global"]
        )
    ]

    /// Resolve the invocable Bedrock model ID for the given internal ID + region.
    /// Always returns an inference-profile-prefixed ID; falls back to `global.`
    /// when no closer geographic profile is available for the model in that region.
    static func bedrockModelID(internalID: String, region: String) -> String? {
        guard let def = definitions[internalID] else { return nil }
        let geo = preferredGeography(for: region, available: def.geographies)
        return "\(geo).\(def.foundationID)"
    }

    /// Map the underlying Anthropic model family for an internal Bedrock model ID,
    /// returning the same ID `AnthropicProvider` knows about — e.g.,
    /// `bedrock-claude-opus-5` → `claude-opus-5`. Used to look up the model's
    /// `AIProviderModel` (capabilities, max tokens) since Bedrock and direct
    /// share the same model capabilities.
    static func anthropicFamilyID(internalID: String) -> String? {
        switch internalID {
        case "bedrock-claude-opus-5":     return "claude-opus-5"
        case "bedrock-claude-sonnet-4-6": return "claude-sonnet-4-6"
        case "bedrock-claude-sonnet-5":   return "claude-sonnet-5"
        case "bedrock-claude-haiku-4-5":  return "claude-haiku-4-5-20251001"
        default: return nil
        }
    }

    /// Pick the closest inference-profile geography to the user's AWS region,
    /// constrained to what the specific model actually offers. `global` is the
    /// always-available fallback.
    private static func preferredGeography(for region: String, available: Set<String>) -> String {
        let candidate: String
        if region.hasPrefix("us-") || region.hasPrefix("ca-") {
            candidate = "us"
        } else if region.hasPrefix("eu-") {
            candidate = "eu"
        } else if region == "ap-northeast-1" {
            candidate = "jp"
        } else if region == "ap-southeast-2" {
            candidate = "au"
        } else {
            candidate = "global"
        }
        return available.contains(candidate) ? candidate : "global"
    }
}
#endif
