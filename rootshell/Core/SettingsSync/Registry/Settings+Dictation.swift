//
//  Settings+Dictation.swift
//  rootshell
//
//  On-device dictation (FluidAudio Parakeet) keys. Registered in every build;
//  the feature itself is compiled out of China and visionOS builds.
//

import Foundation

/// On-device dictation needs FluidAudio, which is not linked into China or visionOS builds.
nonisolated enum DictationSupport {
    #if canImport(FluidAudio) && !CHINA_BUILD
    static let isCompiled = true
    #else
    static let isCompiled = false
    #endif

    static var isEnabled: Bool { isCompiled && SettingsStore.shared.value(Settings.Dictation.enabled) }
}

/// Parakeet models offered for dictation.
nonisolated enum DictationModel: String, CaseIterable, Sendable {
    case parakeetV3, parakeetUltra, parakeetRedux, parakeetV2English
}

/// How recognized speech reaches the terminal.
nonisolated enum DictationCommitMode: String, CaseIterable, Sendable {
    /// Held in the pane until Insert; nothing reaches the shell on its own.
    case preview
    /// Each phrase is inserted when you pause.
    case live
    /// Each phrase is inserted and submitted with Return when you pause.
    case handsFree
}

/// How a transcript is shaped before insertion.
nonisolated enum DictationFormatting: String, CaseIterable, Sendable {
    /// Agent when a coding agent is in the foreground, otherwise command.
    case auto
    /// Shell input: spoken symbols, no sentence punctuation.
    case command
    /// Plain sentences, as recognized.
    case prose
    /// Coding-agent prompts: prose plus filler removal and spoken code idioms.
    case agent
}

nonisolated enum DictationEncoderPrecision: String, CaseIterable, Sendable {
    case int8, int4
}

extension DictationModel: SettingValue {}
extension DictationCommitMode: SettingValue {}
extension DictationFormatting: SettingValue {}
extension DictationEncoderPrecision: SettingValue {}

nonisolated extension Settings {
    enum Dictation {
        static let enabled = SettingKey(
            "dictationEnabled", default: true, group: .dictation, policy: .localByDefault,
            configKey: "dictation", title: String(localized: "Dictation", comment: "Setting title"))
        static let model = SettingKey(
            "dictationModel", default: DictationModel.parakeetV3, group: .dictation, policy: .localByDefault,
            configKey: "dictation-model", title: String(localized: "Speech Model", comment: "Setting title"))
        /// ISO 639-1 code, or empty for automatic.
        static let language = SettingKey(
            "dictationLanguage", default: "", group: .dictation,
            configKey: "dictation-language", title: String(localized: "Dictation Language", comment: "Setting title"))
        static let commitMode = SettingKey(
            "dictationCommitMode", default: DictationCommitMode.preview, group: .dictation,
            configKey: "dictation-commit-mode", title: String(localized: "Insert Text", comment: "Setting title"))
        static let formatting = SettingKey(
            "dictationFormatting", default: DictationFormatting.auto, group: .dictation,
            configKey: "dictation-formatting", title: String(localized: "Formatting", comment: "Setting title"))
        static let voiceCommands = SettingKey(
            "dictationVoiceCommands", default: false, group: .dictation,
            configKey: "dictation-voice-commands", title: String(localized: "Voice Commands", comment: "Setting title"))
        static let quickReplies = SettingKey(
            "dictationQuickReplies", default: false, group: .dictation,
            configKey: "dictation-quick-replies", title: String(localized: "Agent Quick Replies", comment: "Setting title"))
        static let removeFillers = SettingKey(
            "dictationRemoveFillers", default: true, group: .dictation,
            configKey: "dictation-remove-fillers", title: String(localized: "Remove Filler Words", comment: "Setting title"))
        static let spokenCode = SettingKey(
            "dictationSpokenCode", default: true, group: .dictation,
            configKey: "dictation-spoken-code", title: String(localized: "Spoken Code Idioms", comment: "Setting title"))
        static let numberNormalization = SettingKey(
            "dictationNumberNormalization", default: true, group: .dictation,
            configKey: "dictation-number-normalization", title: String(localized: "Write Numbers as Digits", comment: "Setting title"))
        /// Seconds of silence that end listening; 0 keeps listening.
        static let autoStopSilence = SettingKey(
            "dictationAutoStopSilence", default: 4.0, group: .dictation,
            configKey: "dictation-auto-stop-silence", title: String(localized: "Stop After Silence", comment: "Setting title"))
        /// Silence that closes a phrase.
        static let pauseDuration = SettingKey(
            "dictationPauseDuration", default: 0.8, group: .dictation,
            configKey: "dictation-pause-duration", title: String(localized: "Phrase Pause", comment: "Setting title"))
        static let speechThreshold = SettingKey(
            "dictationSpeechThreshold", default: 0.6, group: .dictation,
            configKey: "dictation-speech-threshold", title: String(localized: "Speech Detection Threshold", comment: "Setting title"))
        static let vocabularyEnabled = SettingKey(
            "dictationVocabularyEnabled", default: false, group: .dictation,
            configKey: "dictation-vocabulary-boost", title: String(localized: "Vocabulary Boost", comment: "Setting title"))
        /// One term per entry, `term: alias, alias`.
        static let vocabulary = SettingKey(
            "dictationVocabulary", default: DictationVocabularyDefaults.terms, group: .dictation,
            configKey: "dictation-vocabulary", title: String(localized: "Vocabulary", comment: "Setting title"))
        static let screenVocabulary = SettingKey(
            "dictationScreenVocabulary", default: true, group: .dictation,
            configKey: "dictation-screen-vocabulary", title: String(localized: "Learn Words from Screen", comment: "Setting title"))
        static let encoderPrecision = SettingKey(
            "dictationEncoderPrecision", default: DictationEncoderPrecision.int8, group: .dictation,
            policy: .deviceOnly, title: String(localized: "Encoder Precision", comment: "Setting title"))
        static let keepLoadedMinutes = SettingKey(
            "dictationKeepLoadedMinutes", default: 5, group: .dictation, policy: .deviceOnly,
            title: String(localized: "Keep Model Loaded", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            enabled.erased, model.erased, language.erased, commitMode.erased, formatting.erased,
            voiceCommands.erased, quickReplies.erased, removeFillers.erased, spokenCode.erased,
            numberNormalization.erased, autoStopSilence.erased, pauseDuration.erased,
            speechThreshold.erased, vocabularyEnabled.erased, vocabulary.erased, screenVocabulary.erased,
            encoderPrecision.erased, keepLoadedMinutes.erased,
        ]
    }
}

/// Seed terms for vocabulary boosting: words Parakeet commonly mishears in a terminal.
nonisolated enum DictationVocabularyDefaults {
    static let terms: [String] = [
        "kubectl: cube control, cube cuddle, cube CTL",
        "sudo: pseudo, sue do",
        "ssh", "git", "grep", "awk", "sed", "npm", "npx", "pnpm", "yarn", "brew",
        "tmux: tee mux, T mux",
        "nginx: engine x",
        "systemctl: system control, system CTL",
        "journalctl: journal control",
        "chmod: change mode, C mod", "chown: change own",
        "zsh: Z shell", "bash", "vim", "nvim: neovim", "helix",
        "rsync: R sync", "curl", "wget", "jq", "ripgrep",
        "Docker", "Kubernetes", "Terraform", "Ansible", "Postgres", "Redis",
        "localhost", "stdout", "stderr", "env", "YAML", "JSON",
        "Claude Code", "Codex",
    ]
}
