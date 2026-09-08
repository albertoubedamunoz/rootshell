import Foundation

/// Pure input rules, shared by the keyboard UI and the commit boundary.
nonisolated enum QuickSettingsInput {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func searchScore(query: String, title: String, metadata: String) -> Int? {
        let query = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let title = normalized(title)
        let blob = title + " " + normalized(metadata)
        guard tokens.allSatisfy(blob.contains) else { return nil }
        return title == query ? 3 : title.hasPrefix(query) ? 2 : title.contains(query) ? 1 : 0
    }

    static func isHexColor(_ text: String) -> Bool {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return hex.count == 6 && hex.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    static func validNumber(_ value: Double, range: ClosedRange<Double>, integral: Bool) -> Bool {
        value.isFinite && range.contains(value) && (!integral || value.rounded() == value)
    }

    static func numberText(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func movedID(_ ids: [String], current: String?, offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[min(ids.count - 1, max(0, index + offset))]
    }
}
