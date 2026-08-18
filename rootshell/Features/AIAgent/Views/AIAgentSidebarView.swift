#if !CHINA_BUILD
//
//  AIAgentSidebarView.swift
//  rootshell
//
//  Sidebar container for AI Agent with draggable resize divider
//

import SwiftUI
#if targetEnvironment(macCatalyst)
import AppKit
#endif

/// Sidebar container for AI Agent with draggable resize divider
struct AIAgentSidebarView: View {
    @Binding var isPresented: Bool
    let session: AIAgentSession
    let tabID: UUID
    @Binding var isDragging: Bool  // Exposed to parent for animation control
    @Binding var sidebarWidth: CGFloat  // Binding to parent's local state for smooth updates
    let totalWidth: CGFloat  // Total available width from parent for max calculation

    var themeManager = ThemeManager.shared

    private let minWidth: CGFloat = 280
    private let maxWidthFraction: CGFloat = 0.65

    var body: some View {
        // Calculate max width based on total available width from parent
        let maxWidth = totalWidth * maxWidthFraction

        HStack(spacing: 0) {
            // Divider handle (on the leading edge of this right-side column;
            // dragging left widens it). Snaps to / double-taps back to 400.
            SidebarResizeDivider(
                side: .right,
                width: $sidebarWidth,
                isDragging: $isDragging,
                minWidth: minWidth,
                maxWidth: maxWidth,
                defaultWidth: 400,
                backgroundColor: dividerBackgroundColor,
                onCommit: { AICredentialsManager.shared.aiAgentSidebarWidth = $0 }
            )

            // AI Agent content - fills available width
            AIAgentOverlayView(
                isPresented: $isPresented,
                session: session,
                tabID: tabID,
                useWindowThemeColors: false
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
        }
        // Bleed the opaque column fill into the bottom safe area (home-indicator
        // strip) without moving the chat content, mirroring the docked tab
        // sidebar. The terminal's drawable extends into that strip
        // (TerminalSplitTreeView `.ignoresSafeArea(.bottom)`), so during an
        // app-tab swipe a tab sliding right would otherwise smear a sliver into
        // the bottom-right corner this column's frame doesn't reach. As the
        // HStack's last sibling this column already draws above the terminal
        // content, so the opaque fill hides the overflow. No-op on Catalyst
        // (no bottom safe area).
        .background(dividerBackgroundColor.ignoresSafeArea(.container, edges: .bottom))
    }

    private var dividerBackgroundColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor
        }
        return Color(uiColor: .systemBackground)
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var isPresented = true

        var body: some View {
            ZStack {
                Color.gray.opacity(0.3)

                Text("Terminal Content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Note: This preview won't work without a real AIAgentSession
                // AIAgentSidebarView(isPresented: $isPresented, session: ...)
            }
        }
    }

    return PreviewWrapper()
}
#endif
