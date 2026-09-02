//
//  ConnectionSidebarModifier.swift
//  rootshell
//
//  Connection sidebar. Uses overlay on iPad (avoids fullScreenCover's UIKit presentation
//  system which caused deadlocks). iPhone uses standard sheet.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Connection Sidebar Tab

enum ConnectionSidebarTab {
    case lastUsed
    case ssh
    case vnc
    case profiles
    case browse
    case local
    case kubernetes
    case console
}

// MARK: - Connection Sidebar Modifier

struct ConnectionSidebarModifier<PhoneContent: View, SidebarContent: View>: ViewModifier {
    @Binding var showSidebar: Bool
    let contentID: AnyHashable
    let preventDismissal: Bool
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    @ViewBuilder var phoneContent: () -> PhoneContent
    @ViewBuilder var sidebarContent: () -> SidebarContent

    private var isPhone: Bool {
#if os(visionOS)
        return false
#else
        return UIDevice.current.userInterfaceIdiom == .phone
#endif
    }

    func body(content: Content) -> some View {
        if isPhone {
            content
                .sheet(isPresented: $showSidebar) {
                    phoneContent()
                        .id(contentID)
                        .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
                        .interactiveDismissDisabled(preventDismissal)
                }
        } else {
            #if os(visionOS)
            content
                .sheet(isPresented: $showSidebar) {
                    sidebarContent()
                        .id(contentID)
                        .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
                        .interactiveDismissDisabled(preventDismissal)
                }
            #else
            content
                .overlay {
                    SidePanelOverlay(
                        isPresented: $showSidebar,
                        edge: .trailing,
                        panelWidth: 460,
                        backdropAlpha: themeColors != nil ? 0.4 : 0.5,
                        contentID: contentID,
                        preventDismissal: preventDismissal,
                        content: {
                            ConnectionSidebarPanelView(
                                preventDismissal: preventDismissal,
                                themeColors: themeColors,
                                accentColor: accentColor,
                                colorScheme: colorScheme,
                                onClose: { if !preventDismissal { showSidebar = false } },
                                sidebarContent: sidebarContent
                            )
                        }
                    )
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard)
                }
            #endif
        }
    }
}

// MARK: - Panel View

private struct ConnectionSidebarPanelView<SidebarContent: View>: View {
    let preventDismissal: Bool
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    let onClose: () -> Void
    @ViewBuilder var sidebarContent: () -> SidebarContent

    private let sidebarMaxWidth: CGFloat = 460
    private let sidebarCornerRadius: CGFloat = 20
    private let sidebarVerticalContentPadding: CGFloat = 6

    @Setting(Settings.Window.hideTitleBar) private var hideWindowTitleBar

    /// With the title bar hidden the OS may still report a top safe-area
    /// inset for chrome that isn't there, leaving a gap above the panel;
    /// extend to the top edge like the main content does.
    private var hiddenTitlebarTopEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
        hideWindowTitleBar ? .top : []
        #else
        []
        #endif
    }

    private var sheetBackground: Color {
        themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: sidebarCornerRadius,
            bottomLeadingRadius: sidebarCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )

        shape.fill(sheetBackground)
    }

    var body: some View {
        ZStack {
            sidebarBackground

            sidebarContent()
                .environment(\.sheetThemeColors, themeColors)
                .padding(.vertical, sidebarVerticalContentPadding)
        }
        .frame(maxWidth: sidebarMaxWidth)
        .frame(maxHeight: .infinity)
        .optionalColorSchemeEnvironment(colorScheme)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: sidebarCornerRadius,
            bottomLeadingRadius: sidebarCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .shadow(color: .black.opacity(0.3), radius: 20, x: -5)
        .tint(accentColor)
        .ignoresSafeArea(.keyboard)
        .ignoresSafeArea(.container, edges: hiddenTitlebarTopEdges)
    }
}
