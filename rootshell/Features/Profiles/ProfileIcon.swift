import Foundation

/// Parsed representation of a profile's `iconName` storage string.
///
/// Storage forms (all plain strings, so CloudKit sync and backups pass
/// them through unchanged):
/// - bare SF Symbol name ("server.rack") — legacy format, unchanged
/// - "nf:<hex codepoint>" — glyph from the bundled Symbols Nerd Font
/// - "favicon" — the profile host's website icon
/// - "favicon:<hostname>" — a specific host's website icon
///
/// Old app versions render unknown strings as a blank SF Symbol image;
/// they never crash or rewrite the stored value.
enum ProfileIcon: Equatable, Hashable {
    case symbol(String)
    case nerd(Unicode.Scalar)
    /// nil = resolve against the profile's own host at render time
    case favicon(customHost: String?)

    static let nerdPrefix = "nf:"
    static let faviconSentinel = "favicon"
    static let faviconPrefix = "favicon:"

    /// PostScript name of the bundled SymbolsNerdFontMono-Regular.ttf
    /// (family "Symbols Nerd Font Mono" — same font GhosttyKit embeds
    /// for terminal glyph fallback, so UI and terminal render identically)
    static let nerdFontName = "SymbolsNFM"

    static let fallback = ProfileIcon.symbol("star.fill")

    init(storageString: String?) {
        guard let raw = storageString, !raw.isEmpty else {
            self = .fallback
            return
        }
        if raw == Self.faviconSentinel {
            self = .favicon(customHost: nil)
        } else if raw.hasPrefix(Self.faviconPrefix) {
            let host = String(raw.dropFirst(Self.faviconPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .favicon(customHost: host.isEmpty ? nil : host)
        } else if raw.hasPrefix(Self.nerdPrefix) {
            if let value = UInt32(raw.dropFirst(Self.nerdPrefix.count), radix: 16),
               let scalar = Unicode.Scalar(value) {
                self = .nerd(scalar)
            } else {
                self = .fallback
            }
        } else {
            self = .symbol(raw)
        }
    }

    var storageString: String {
        switch self {
        case .symbol(let name): return name
        case .nerd(let scalar): return Self.nerdPrefix + String(scalar.value, radix: 16)
        case .favicon(let customHost):
            if let customHost { return Self.faviconPrefix + customHost }
            return Self.faviconSentinel
        }
    }

    /// The glyph as a renderable string (nerd icons only)
    var glyphString: String? {
        if case .nerd(let scalar) = self { return String(scalar) }
        return nil
    }
}
