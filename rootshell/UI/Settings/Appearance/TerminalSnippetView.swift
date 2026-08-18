//
//  TerminalSnippetView.swift
//  rootshell
//
//  Mini terminal preview showing colored text using theme colors
//

import SwiftUI

/// Displays a compact fake terminal output using theme colors
struct TerminalSnippetView: View {
    let colors: ThemeManager.ThemeInfo.ThemeColors
    let compact: Bool

    private var fontSize: CGFloat {
        compact ? 7 : 8
    }

    private var lineSpacing: CGFloat {
        compact ? 1 : 2
    }

    private var padding: CGFloat {
        compact ? 4 : 6
    }

    private var backgroundColor: Color {
        Color(hex: colors.background) ?? .black
    }

    private var foregroundColor: Color {
        Color(hex: colors.foreground) ?? .white
    }

    /// Get palette color at index, falling back to foreground if unavailable
    private func paletteColor(_ index: Int) -> Color {
        guard index < colors.palette.count else {
            return foregroundColor
        }
        return Color(hex: colors.palette[index]) ?? foregroundColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            promptLine
            outputLine1
            outputLine2
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundColor)
    }

    // MARK: - Terminal Lines

    /// Prompt line: user@host:~$ ls
    private var promptLine: some View {
        HStack(spacing: 0) {
            Text("user@host")
                .foregroundColor(paletteColor(4)) // blue
            Text(":")
                .foregroundColor(foregroundColor)
            Text("~$ ")
                .foregroundColor(paletteColor(5)) // magenta
            Text("ls")
                .foregroundColor(foregroundColor)
        }
    }

    /// Output line 1: drwxr-xr-x  docs  src
    private var outputLine1: some View {
        HStack(spacing: 0) {
            Text("drwxr-xr-x  ")
                .foregroundColor(paletteColor(2)) // green
            Text("docs  ")
                .foregroundColor(paletteColor(4)) // blue (directory)
            Text("src")
                .foregroundColor(paletteColor(4)) // blue (directory)
        }
    }

    /// Output line 2: -rw-r--r--  README.md
    private var outputLine2: some View {
        HStack(spacing: 0) {
            Text("-rw-r--r--  ")
                .foregroundColor(foregroundColor)
            Text("README.md")
                .foregroundColor(paletteColor(3)) // yellow
        }
    }
}

// MARK: - Preview

#Preview("Compact - Catppuccin Mocha") {
    TerminalSnippetView(
        colors: ThemeManager.ThemeInfo.ThemeColors(
            background: "#1e1e2e",
            foreground: "#cdd6f4",
            cursor: "#f5e0dc",
            palette: [
                "#45475a", // 0 black
                "#f38ba8", // 1 red
                "#a6e3a1", // 2 green
                "#f9e2af", // 3 yellow
                "#89b4fa", // 4 blue
                "#f5c2e7", // 5 magenta
                "#94e2d5", // 6 cyan
                "#bac2de"  // 7 white
            ]
        ),
        compact: true
    )
    .frame(width: 120, height: 45)
    .clipShape(RoundedRectangle(cornerRadius: 6))
}

#Preview("Card - Dracula") {
    TerminalSnippetView(
        colors: ThemeManager.ThemeInfo.ThemeColors(
            background: "#282a36",
            foreground: "#f8f8f2",
            cursor: "#f8f8f2",
            palette: [
                "#21222c", // 0 black
                "#ff5555", // 1 red
                "#50fa7b", // 2 green
                "#f1fa8c", // 3 yellow
                "#bd93f9", // 4 blue
                "#ff79c6", // 5 magenta
                "#8be9fd", // 6 cyan
                "#f8f8f2"  // 7 white
            ]
        ),
        compact: false
    )
    .frame(width: 200, height: 70)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}

#Preview("Card - Solarized Light") {
    TerminalSnippetView(
        colors: ThemeManager.ThemeInfo.ThemeColors(
            background: "#fdf6e3",
            foreground: "#657b83",
            cursor: "#657b83",
            palette: [
                "#073642", // 0 black
                "#dc322f", // 1 red
                "#859900", // 2 green
                "#b58900", // 3 yellow
                "#268bd2", // 4 blue
                "#d33682", // 5 magenta
                "#2aa198", // 6 cyan
                "#eee8d5"  // 7 white
            ]
        ),
        compact: false
    )
    .frame(width: 200, height: 70)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}
