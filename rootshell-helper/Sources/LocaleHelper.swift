//
//  LocaleHelper.swift
//  rootshell-helper
//
//  Provides locale formatting utilities for shell sessions
//
//  iOS `Locale.current.identifier` can include regional modifiers like `en_US@rg=dezzzz`
//  which aren't valid POSIX locales. This helper extracts language and region codes
//  separately and only returns locales macOS actually ships.
//

import Foundation

/// Provides locale formatting utilities for shell sessions
enum LocaleHelper {

    /// Returns the system locale in POSIX format (e.g., "en_US.UTF-8")
    ///
    /// Uses the first preferred language, which pairs language and region
    /// correctly (e.g., "en-US"). `Locale.current.region` is an independent
    /// setting: English (US) with region Germany would otherwise give "en_DE".
    ///
    /// Falls back to "C.UTF-8" if no installed locale matches the language.
    static var posixLocale: String {
        guard let firstPreferred = Locale.preferredLanguages.first,
              let posix = posixLocale(for: firstPreferred, installed: installedUTF8Locales) else {
            return "C.UTF-8"
        }
        return posix
    }

    /// Maps a BCP-47 tag to an installed UTF-8 locale. macOS pairs any language
    /// with any region (fr-US, en-MX) but has no data for most such pairs, so
    /// the language's likely region (fr_FR) or another same-language locale substitutes.
    static func posixLocale(for tag: String, installed: Set<String>) -> String? {
        let components = Locale.Language.Components(identifier: tag)
        guard let lang = components.languageCode?.identifier.lowercased(), !lang.isEmpty else {
            return nil
        }
        let script = components.script?.identifier
        // Likely region honors the script: zh-Hant gives TW, zh-Hans gives CN.
        let likely = maximal("\(lang)\(script.map { "-\($0)" } ?? "")").region?.identifier
        let sameLanguage = installed.filter { $0.hasPrefix("\(lang)_") }.sorted()
        let otherRegions = sameLanguage.map { String($0.dropFirst(lang.count + 1).prefix { $0 != "." }) }
        let regions = [components.region?.identifier.uppercased(), likely].compactMap { $0 } + otherRegions
        for region in regions {
            if let name = localeName(lang: lang, script: script, region: region), installed.contains(name) {
                return name
            }
        }
        return sameLanguage.first
    }

    private static let scriptModifiers = ["Latn": "latin", "Cyrl": "cyrillic"]

    /// The locale for `region` in `script`: the plain name when it's the region's
    /// default script (zh_TW is Hant), else a modifier variant (sr_RS.UTF-8@latin),
    /// or nil when no such variant exists (Traditional Chinese in CN).
    private static func localeName(lang: String, script: String?, region: String) -> String? {
        let name = "\(lang)_\(region).UTF-8"
        guard let script, maximal("\(lang)-\(region)").script?.identifier != script else {
            return name
        }
        return scriptModifiers[script].map { "\(name)@\($0)" }
    }

    private static func maximal(_ identifier: String) -> Locale.Language.Components {
        Locale.Language.Components(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
    }

    /// UTF-8 locales with data in /usr/share/locale, e.g. "fr_FR.UTF-8" or "sr_RS.UTF-8@latin".
    static let installedUTF8Locales: Set<String> = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/usr/share/locale")) ?? []
        return Set(names.filter { $0.hasSuffix(".UTF-8") || $0.contains(".UTF-8@") })
    }()
}
