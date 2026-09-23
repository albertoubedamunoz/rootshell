#if !targetEnvironment(macCatalyst)

import Foundation

// TUI-only presentation for the rf browser; the GUI file manager renders RFEntry itself.
@MainActor
extension RFEntry {
    /// Resolved icon definition with per-file Nerd Font icon and RGB color.
    var iconDef: RFIconDef {
        RFIconRegistry.resolve(self)
    }

    /// Color for this entry's name (theme-dependent, state-aware).
    /// Icon color comes from iconDef.fg directly.
    @MainActor
    func nameColor(theme: RFTheme) -> (UInt8, UInt8, UInt8) {
        if isDirectory { return theme.directoryColor }
        if isSymlink { return theme.symlinkColor }
        if isHidden { return theme.hiddenColor }
        if isExecutable { return theme.executableColor }
        // Use the per-icon color for regular files
        return iconDef.fg
    }

    /// Git status color.
    @MainActor
    func gitColor(theme: RFTheme) -> (UInt8, UInt8, UInt8)? {
        guard let status = gitStatus else { return nil }
        switch status {
        case .modified:  return theme.gitModified
        case .staged:    return theme.gitStaged
        case .added:     return theme.gitStaged
        case .untracked: return theme.gitUntracked
        case .deleted:   return theme.gitDeleted
        case .renamed:   return theme.gitModified
        case .conflict:  return theme.gitConflict
        case .ignored:   return nil
        }
    }

    /// Convert to display entry for rendering.
    @MainActor
    func toDisplayEntry(theme: RFTheme) -> RFDisplayEntry {
        var rightParts: [String] = []
        if !gitIndicator.isEmpty {
            rightParts.append(gitIndicator)
        }
        let sz = sizeString
        if !sz.isEmpty {
            rightParts.append(sz)
        }
        let rightText = rightParts.joined(separator: " ")

        let icon = iconDef
        let entryColor = nameColor(theme: theme)
        return RFDisplayEntry(
            name: name,
            path: path,
            icon: icon.text,
            iconColor: theme.readableDecorativeColor(icon.fg),
            color: theme.readableTextColor(entryColor),
            isDirectory: isDirectory,
            rightText: rightText,
            rightColor: gitColor(theme: theme).map { theme.readableDecorativeColor($0) }
        )
    }
}

#endif
