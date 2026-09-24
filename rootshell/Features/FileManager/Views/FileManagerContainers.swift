//
//  FileManagerContainers.swift
//  rootshell
//
//  Hosts for FileManagerView: a resizable column beside the terminal (the AI
//  sidebar's pattern) and a draggable HUD over it (Open in Folder's pattern).
//

import SwiftUI

struct FileManagerSidebarView: View {
    let manager: FileManagerModel
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let canFocus: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (FileManagerPresentation) -> Void

    static let minWidth: CGFloat = 300
    static let defaultWidth: CGFloat = 460
    private let maxWidthFraction: CGFloat = 0.7

    /// The themed sheet background when UI theming is on, else the system one.
    private var background: Color {
        theme.themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeDivider(
                side: .right,
                width: $width,
                isDragging: $isDragging,
                minWidth: Self.minWidth,
                maxWidth: max(Self.minWidth, totalWidth * maxWidthFraction),
                defaultWidth: Self.defaultWidth,
                backgroundColor: background,
                onCommit: { SettingsStore.shared.set(Settings.Transfer.fileManagerSidebarWidth, Double($0)) }
            )
            FileManagerView(
                manager: manager,
                style: .sidebar,
                canFocus: canFocus,
                onClose: onClose,
                onSwitchPresentation: onSwitchPresentation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
        }
        .background(background.ignoresSafeArea(.container, edges: .bottom))
        .fileManagerTheme(theme)
    }
}

extension View {
    /// Theme environment for file manager content, as the AI and docked tab
    /// sidebars apply it: themed colors for sheets, the accent tint, and the
    /// theme's color scheme scoped to this subtree (never the window's).
    func fileManagerTheme(_ theme: ResolvedSheetTheme) -> some View {
        environment(\.sheetThemeColors, theme.themeColors)
            .tint(theme.accentColor)
            .optionalColorSchemeEnvironment(theme.colorScheme)
    }
}

struct FileManagerHUD: View {
    let manager: FileManagerModel
    let canFocus: Bool
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (FileManagerPresentation) -> Void

    var body: some View {
        GeometryReader { geometry in
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                forwardsFileManagerToggle: true,
                onDismiss: onClose
            ) {
                FileManagerView(
                    manager: manager,
                    style: .overlay,
                    canFocus: canFocus,
                    onClose: onClose,
                    onSwitchPresentation: onSwitchPresentation
                )
                .frame(
                    width: min(1000, max(320, geometry.size.width - 24)),
                    height: min(680, max(320, geometry.size.height - 24))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .floatingHUDPanelBackground()
                .fileManagerTheme(theme)
            }
        }
    }
}
