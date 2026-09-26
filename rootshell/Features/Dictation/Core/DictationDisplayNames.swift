#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationDisplayNames.swift
//  rootshell
//

import Foundation

extension DictationModel {
    var displayName: String {
        switch self {
        case .parakeetV3: String(localized: "Parakeet v3")
        case .parakeetUltra: String(localized: "Parakeet Ultra")
        case .parakeetRedux: String(localized: "Parakeet Redux")
        case .parakeetV2English: String(localized: "Parakeet v2")
        }
    }

    var summary: String {
        switch self {
        case .parakeetV3: String(localized: "25 European languages. The balanced default.")
        case .parakeetUltra: String(localized: "Same languages as v3, most accurate, largest download.")
        case .parakeetRedux: String(localized: "Same languages as v3, smallest download, slightly less accurate.")
        case .parakeetV2English: String(localized: "English only, strongest English recall.")
        }
    }
}

extension DictationCommitMode {
    var displayName: String {
        switch self {
        case .preview: String(localized: "Preview")
        case .live: String(localized: "Live")
        case .handsFree: String(localized: "Hands-Free")
        }
    }

    var summary: String {
        switch self {
        case .preview: String(localized: "Review what you said, then tap Insert or Run. Nothing reaches the terminal on its own.")
        case .live: String(localized: "Each phrase is typed when you pause. Return is never pressed for you.")
        case .handsFree: String(localized: "Each phrase is typed and submitted with Return when you pause. Best for chatting with a coding agent.")
        }
    }
}

extension DictationFormatting {
    var displayName: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .command: String(localized: "Command")
        case .prose: String(localized: "Prose")
        case .agent: String(localized: "Agent Prompt")
        }
    }

    var summary: String {
        switch self {
        case .auto: String(localized: "Agent Prompt when a coding agent is running or the Agent preset is selected, otherwise Command.")
        case .command: String(localized: "Shell input: spoken symbols like “dash dash help” become --help, lowercase, no trailing period.")
        case .prose: String(localized: "Sentences exactly as recognized, with punctuation.")
        case .agent: String(localized: "Prompts for coding agents: filler words removed, “new line” breaks lines without submitting, and code idioms like “camel case user id”.")
        }
    }
}

extension DictationFormatter.Style {
    var displayName: String {
        switch self {
        case .command: String(localized: "Command")
        case .prose: String(localized: "Prose")
        case .agent: String(localized: "Agent Prompt")
        }
    }
}

/// Languages Parakeet v3 recognizes, by ISO 639-1 code.
enum DictationLanguages {
    static let codes = [
        "en", "de", "es", "fr", "it", "pt", "nl", "pl", "cs", "sk", "sl", "hr", "bg", "ro", "hu",
        "da", "sv", "fi", "et", "lv", "lt", "mt", "el", "ru", "uk",
    ]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
#endif
