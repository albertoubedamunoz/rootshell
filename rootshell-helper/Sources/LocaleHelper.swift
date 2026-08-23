//
//  LocaleHelper.swift
//  rootshell-helper
//
//  Provides locale formatting utilities for shell sessions
//
//  iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
//  which don't exist as valid POSIX locales on Linux servers. This helper extracts
//  language and region codes separately to produce clean POSIX-compatible locales.
//

import Foundation

/// Provides locale formatting utilities for shell sessions
///
/// iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
/// which don't exist as valid POSIX locales on Linux servers. This helper extracts
/// language and region codes separately to produce clean POSIX-compatible locales.
enum LocaleHelper {

    /// Returns the system locale in POSIX format (e.g., "en_US.UTF-8")
    ///
    /// Uses the first preferred language from iOS settings, which contains
    /// both language and region as a BCP-47 tag (e.g., "en-US").
    ///
    /// This avoids the bug where `Locale.current.language.languageCode` and
    /// `Locale.current.region` are independent settings - a user with preferred
    /// language "English (US)" but region "Germany" would incorrectly produce
    /// "en_DE.UTF-8" if we mixed them.
    ///
    /// Falls back to "C.UTF-8" if preferred languages cannot be determined.
    static var posixLocale: String {
        // Use first preferred language which has correct language+region pairing
        guard let firstPreferred = Locale.preferredLanguages.first,
              let posix = bcp47ToPosix(firstPreferred) else {
            return "C.UTF-8"
        }
        return posix
    }

    /// Returns the LANGUAGE environment variable value for gettext
    ///
    /// macOS/iOS has a concept of preferred languages separate from the system locale.
    /// The LANGUAGE env var overrides translations and uses colon-separated priority.
    ///
    /// Example: "en_US.UTF-8:de_DE.UTF-8" means prefer English, fall back to German.
    ///
    /// Returns nil if preferred languages cannot be determined.
    static var preferredLanguages: String? {
        let preferred = Locale.preferredLanguages
        guard !preferred.isEmpty else { return nil }

        let formatted = preferred.compactMap { bcp47ToPosix($0) }
        guard !formatted.isEmpty else { return nil }

        return formatted.joined(separator: ":")
    }

    /// Converts a BCP-47 language tag to POSIX locale format
    ///
    /// - Parameter bcp47: BCP-47 tag like "en-US" or "de-DE"
    /// - Returns: POSIX locale like "en_US.UTF-8" or nil if invalid
    private static func bcp47ToPosix(_ bcp47: String) -> String? {
        // BCP-47 uses hyphen (en-US), POSIX uses underscore (en_US)
        let components = bcp47.split(separator: "-", maxSplits: 1)

        guard let lang = components.first, !lang.isEmpty else {
            return nil
        }

        if components.count == 2 {
            let region = components[1]
            return "\(lang)_\(region).UTF-8"
        } else {
            // Language only, no region
            return "\(lang).UTF-8"
        }
    }
}
