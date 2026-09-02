//
//  Settings+AI.swift
//  rootshell
//
//  AI assistant, MCP, and voice keys. Compiled out of the China build.
//

import Foundation

#if !CHINA_BUILD

extension AIAgentPresentationMode: SettingValue {}
extension CommandApprovalMode: SettingValue {}
extension SearchEngine: SettingValue {}
extension VoiceConsultationMode: SettingValue {}
extension GeminiVoice: SettingValue {}

nonisolated extension Settings {
    enum AI {
        static let approvalMode = SettingKey(
            "ai.approvalMode", default: CommandApprovalMode.askAll, group: .ai, configKey: "ai-approval-mode",
            title: String(localized: "Approval Mode", comment: "Setting title"))
        static let globalSelectedModel = SettingKey(
            "ai.globalSelectedModel", default: AIProviderModel.defaultModelID, group: .ai, configKey: "ai-global-selected-model",
            title: String(localized: "AI Model", comment: "Setting title"))
        static let presentationMode = SettingKey(
            "ai.agent.presentation.mode", default: AIAgentPresentationMode.sidebar, group: .ai, policy: .localByDefault,
            configKey: "ai-agent-presentation-mode",
            title: String(localized: "AI Presentation", comment: "Setting title"))
        static let sidebarWidth = SettingKey(
            "ai.agent.sidebar.width", default: 400.0, group: .ai, policy: .deviceOnly,
            title: String(localized: "AI Sidebar Width", comment: "Setting title"))
        static let textSize = SettingKey(
            "aiAgentTextSize", default: 14.0, group: .ai, configKey: "ai-agent-text-size",
            title: String(localized: "AI Text Size", comment: "Setting title"))
        static let webSearchEnabled = SettingKey(
            "ai.webSearch.enabled", default: true, group: .ai, configKey: "ai-web-search-enabled",
            title: String(localized: "Enable Web Search", comment: "Setting title"))
        static let webSearchEngine = SettingKey(
            "ai.webSearch.defaultEngine", default: SearchEngine.duckduckgo, group: .ai, configKey: "ai-web-search-default-engine",
            title: String(localized: "Default Search Engine", comment: "Setting title"))
        static let commitMessageEnabled = SettingKey(
            "ai.commitMessage.enabled", default: false, group: .ai, configKey: "ai-commit-message-enabled",
            title: String(localized: "AI Commit Messages", comment: "Setting title"))
        static let commitMessageModel = SettingKey(
            "ai.commitMessage.model", default: "", group: .ai, configKey: "ai-commit-message-model",
            title: String(localized: "Commit Message Model", comment: "Setting title"))
        static let bedrockRegion = SettingKey(
            "ai.bedrock.region", default: BedrockRegions.defaultRegion, group: .ai, configKey: "ai-bedrock-region",
            title: String(localized: "Bedrock Region", comment: "Setting title"))
        static let bedrockCloudAccountID = SettingKey<String?>(
            "ai.bedrock.cloudAccountID", default: nil, group: .ai, policy: .deviceOnly,
            title: String(localized: "Bedrock Cloud Account", comment: "Setting title"))
        static let openAIAuthMode = SettingKey<String?>(
            "ai.openai.authMode", default: nil, group: .ai, policy: .deviceOnly,
            title: String(localized: "ChatGPT Sign-In Mode", comment: "Setting title"))
        // Endpoint URLs may embed proxy credentials, so this stays local until the user opts in.
        static let customProviders = SettingKey<Data?>(
            "ai.customProviders", default: nil, group: .ai, policy: .localByDefault,
            title: String(localized: "Custom AI Providers", comment: "Setting title"))
        static let openRouterFavorites = SettingKey(
            "ai.openrouter.favorites", default: [String](), group: .ai, configKey: "ai-openrouter-favorites",
            title: String(localized: "OpenRouter Favorites", comment: "Setting title"))
        static let openRouterDiscoveredModels = SettingKey<Data?>(
            "ai.openrouter.discoveredModels", default: nil, group: .ai, policy: .deviceOnly,
            title: String(localized: "OpenRouter Model Cache", comment: "Setting title"))
        static let chatGPTModels = SettingKey<Data?>(
            "ai.chatgpt.models", default: nil, group: .ai, policy: .deviceOnly,
            title: String(localized: "ChatGPT Model Cache", comment: "Setting title"))
        static let chatGPTModelsRefreshDate = AnySettingDefinition.opaque(
            "ai.chatgpt.modelsRefreshDate", group: .ai,
            title: String(localized: "ChatGPT Model Cache Date", comment: "Setting title"))
        static let yoloModeLegacy = SettingKey(
            "ai.yoloMode.enabled", default: false, group: .ai, policy: .deviceOnly,
            title: String(localized: "YOLO Mode (legacy)", comment: "Setting title"))
        static let fullscreenModeLegacy = SettingKey(
            "ai.agent.fullscreen.mode", default: false, group: .ai, policy: .deviceOnly,
            title: String(localized: "AI Full Screen (legacy)", comment: "Setting title"))
        static let mcpServerConfig = SettingKey<Data?>(
            "mcp_server_config", default: nil, group: .ai, policy: .localByDefault,
            title: String(localized: "MCP Server", comment: "Setting title"))
        static let mcpAuthToken = SettingKey<String?>(
            "mcp_auth_token", default: nil, group: .ai, policy: .deviceOnly,
            title: String(localized: "MCP Auth Token", comment: "Setting title"))
        static let voiceConsultationMode = SettingKey(
            "voice.agent.consultationMode", default: VoiceConsultationMode.letFlashDecide, group: .ai,
            configKey: "voice-agent-consultation-mode",
            title: String(localized: "Expert Consultation", comment: "Setting title"))
        static let voice = SettingKey(
            "voice.agent.voice", default: GeminiVoice.kore, group: .ai, configKey: "voice-agent-voice",
            title: String(localized: "Voice", comment: "Setting title"))

        /// Per-provider and per-model keys; the bare prefixes are never written.
        static let prefixRules: [SettingsRegistry.PrefixRule] = [
            .init(prefix: "ai.selectedModel.", valueType: .string, policy: .synced, group: .ai,
                  title: String(localized: "Model (per provider)", comment: "Setting title")),
            .init(prefix: "ai.temperature.", valueType: .double, policy: .synced, group: .ai,
                  title: String(localized: "Temperature (per provider)", comment: "Setting title")),
            .init(prefix: "ai.chatgpt.reasoningEffort.", valueType: .string, policy: .synced, group: .ai,
                  title: String(localized: "Reasoning Effort (per model)", comment: "Setting title")),
        ]

        static let all: [AnySettingDefinition] = [
            approvalMode.erased, globalSelectedModel.erased, presentationMode.erased, sidebarWidth.erased,
            textSize.erased, webSearchEnabled.erased, webSearchEngine.erased, commitMessageEnabled.erased,
            commitMessageModel.erased, bedrockRegion.erased, bedrockCloudAccountID.erased, openAIAuthMode.erased,
            customProviders.erased, openRouterFavorites.erased, openRouterDiscoveredModels.erased,
            chatGPTModels.erased, chatGPTModelsRefreshDate, yoloModeLegacy.erased, fullscreenModeLegacy.erased,
            mcpServerConfig.erased, mcpAuthToken.erased, voiceConsultationMode.erased, voice.erased,
        ]
    }
}

#else

nonisolated extension Settings {
    enum AI {
        static let prefixRules: [SettingsRegistry.PrefixRule] = []
        static let all: [AnySettingDefinition] = []
    }
}

#endif
