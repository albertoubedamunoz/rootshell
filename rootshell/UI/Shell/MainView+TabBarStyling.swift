//
//  MainView+TabBarStyling.swift
//  rootshell
//
//  Tab bar color and styling computations for MainView.
//  Extracted for build parallelization.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Resolved Tab Bar Theme Bundle

/// Pre-resolved theme values for a single `MainView.body` evaluation.
///
/// Crash logs caught the main thread inside `MainView.effectiveThemeColors.getter`
/// repeatedly during scene-update transactions: every styling computed property
/// (`tabBarBackgroundColor`, `selectedTabBackgroundColor`, `tabTextColor`, etc.)
/// independently re-resolves the override theme and re-extracts UIColor RGB
/// components for `isLight`/blend factors. Computing once per body and passing
/// the bundle through is byte-identical to the per-call path.
struct ResolvedTabBarTheme {
    let themeColors: ThemeManager.ThemeInfo.ThemeColors?
    let baseColor: Color?
    let isLight: Bool
    let adaptivePrimaryBlend: CGFloat
    let adaptiveSecondaryBlend: CGFloat
    // Per-theme UI overrides (nil = use derived value). Applied as the final
    // step in each computed property below so the picker-set hex wins over
    // the algorithmic derivation. Built-in defaults (e.g. systemBackground
    // when no theme is available) are not overridable — overrides only
    // apply once we have a base color to derive from.
    let overrideTabBarBackground: Color?
    let overrideSelectedBackground: Color?
    let overrideUnselectedBackground: Color?
    let overrideTabText: Color?
    let overrideTabSecondaryText: Color?

    static let fallback = ResolvedTabBarTheme(
        themeColors: nil,
        baseColor: nil,
        isLight: false,
        adaptivePrimaryBlend: 0,
        adaptiveSecondaryBlend: 0,
        overrideTabBarBackground: nil,
        overrideSelectedBackground: nil,
        overrideUnselectedBackground: nil,
        overrideTabText: nil,
        overrideTabSecondaryText: nil
    )

    /// Resolved sheet styling for one `MainView.body` evaluation. The crash
    /// IPS files repeatedly catch main inside `MainView.effectiveThemeColors`
    /// during scene-update transactions because `applySheetModifiers` reads
    /// sheet theme + accent + color scheme once per attached `.themedSheet(...)`
    /// and per modifier; the chain has 8+ such attachments × 3 properties =
    /// 30+ effectiveThemeColors calls per body. Each call walks
    /// themeOverrideManager + themeManager. Computing once and threading the
    /// bundle through collapses that to a single resolution.

    var tabBarBackground: Color {
        if let override = overrideTabBarBackground { return override }
        return baseColor ?? Color(uiColor: .systemBackground)
    }

    var selectedBackground: Color {
        if let override = overrideSelectedBackground { return override }
        guard let baseColor else { return Color(uiColor: .secondarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.20)
        }
        return baseColor.lightenedPreservingHue(adaptivePrimaryBlend)
    }

    var unselectedBackground: Color {
        if let override = overrideUnselectedBackground { return override }
        guard let baseColor else { return Color(uiColor: .tertiarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.08)
        }
        return baseColor.lightenedPreservingHue(adaptiveSecondaryBlend)
    }

    var tabText: Color {
        if let override = overrideTabText { return override }
        guard baseColor != nil else { return .primary }
        return isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    var tabSecondaryText: Color {
        if let override = overrideTabSecondaryText { return override }
        guard baseColor != nil else { return .secondary }
        return isLight ? Color(white: 0.4) : Color(white: 0.6)
    }
}

/// Pre-resolved sheet styling for one `MainView.body` evaluation. See
/// `ResolvedTabBarTheme` doc for context — same memoization pattern,
/// applied to the sheet/modifier chain.
struct ResolvedSheetTheme {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    static let none = ResolvedSheetTheme(themeColors: nil, accentColor: nil, colorScheme: nil)
}

// MARK: - Tab Bar Styling

extension MainView {

    /// Background color for selected tab - needs to stand out from the tab bar
    var selectedTabBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.selectedTabBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.20)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptivePrimaryBlend)
            }
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    /// Background color for the tab bar itself
    var tabBarBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.tabBarBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor
        }
        return Color(uiColor: .systemBackground)
    }

    /// Primary text color for tabs - adapts to theme background
    var tabTextColor: Color {
        if let override = effectiveThemeUIOverrides.tabText.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
        }
        return .primary
    }

    /// Secondary text color for tabs - adapts to theme background
    var tabSecondaryTextColor: Color {
        if let override = effectiveThemeUIOverrides.tabSecondaryText.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.4) : Color(white: 0.6)
        }
        return .secondary
    }

    /// Background color for unselected tabs - subtle but visible
    var unselectedTabBackgroundColor: Color {
        if let override = effectiveThemeUIOverrides.unselectedTabBackground.flatMap({ Color(hex: $0) }) {
            return override
        }
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.08)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptiveSecondaryBlend)
            }
        }
        return Color(uiColor: .tertiarySystemBackground)
    }

    /// Compute all derived tab bar styling values once for the current body
    /// evaluation. Replaces the previous pattern of calling 5+ independent
    /// computed properties (`tabBarBackgroundColor`, `tabTextColor`, etc.) that
    /// each re-resolved the override theme and re-extracted UIColor RGB
    /// components. Per body run this collapses ~7 dictionary lookups + ~8
    /// UIColor conversions into 1 of each.
    func resolvedTabBarTheme() -> ResolvedTabBarTheme {
        let themeColors = effectiveThemeColors
        let baseColor = themeColors.flatMap { Color(hex: $0.background) }
        let overrides: ThemeUIOverrides = baseColor != nil
            ? (effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty)
            : .empty
        guard let baseColor else {
            return ResolvedTabBarTheme(
                themeColors: themeColors,
                baseColor: nil,
                isLight: false,
                adaptivePrimaryBlend: 0,
                adaptiveSecondaryBlend: 0,
                overrideTabBarBackground: nil,
                overrideSelectedBackground: nil,
                overrideUnselectedBackground: nil,
                overrideTabText: nil,
                overrideTabSecondaryText: nil
            )
        }
        return ResolvedTabBarTheme(
            themeColors: themeColors,
            baseColor: baseColor,
            isLight: baseColor.isLight,
            adaptivePrimaryBlend: baseColor.adaptivePrimaryBlend,
            adaptiveSecondaryBlend: baseColor.adaptiveSecondaryBlend,
            overrideTabBarBackground: overrides.tabBarBackground.flatMap { Color(hex: $0) },
            overrideSelectedBackground: overrides.selectedTabBackground.flatMap { Color(hex: $0) },
            overrideUnselectedBackground: overrides.unselectedTabBackground.flatMap { Color(hex: $0) },
            overrideTabText: overrides.tabText.flatMap { Color(hex: $0) },
            overrideTabSecondaryText: overrides.tabSecondaryText.flatMap { Color(hex: $0) }
        )
    }

    /// Per-theme overrides for the currently effective theme (or `.empty` if
    /// no theme name is resolved). Used by the legacy individual color
    /// computed properties so a single override change reflects in every
    /// styling code path.
    private var effectiveThemeUIOverrides: ThemeUIOverrides {
        effectiveThemeName.map { themeUIOverridesManager.overrides(for: $0) } ?? .empty
    }

    /// Get the effective theme colors for the currently selected tab
    /// Uses override resolution: Tab > Window > Global
    var effectiveThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        guard terminals.indices.contains(selectedTabIndex) else {
            return themeManager.currentThemeInfo?.colors
        }

        let tabId = terminals[selectedTabIndex].id
        let (themeName, _) = themeOverrideManager.resolveTheme(
            tabId: tabId,
            windowId: windowId
        )

        // If it's the global theme, use cached info
        if themeName == themeManager.currentTheme {
            return themeManager.currentThemeInfo?.colors
        }

        // Otherwise, load the override theme's colors
        return themeManager.themeInfo(for: themeName)?.colors
    }

    /// Name of the currently-effective theme for the selected tab (after tab
    /// and window theme overrides). Used by the per-theme UI color override
    /// lookup so chrome reflects the theme that's actually showing.
    var effectiveThemeName: String? {
        guard terminals.indices.contains(selectedTabIndex) else {
            return themeManager.currentTheme
        }
        let tabId = terminals[selectedTabIndex].id
        let (themeName, _) = themeOverrideManager.resolveTheme(
            tabId: tabId,
            windowId: windowId
        )
        return themeName
    }

    /// Whether the current theme is light (for glassmorphism fallback styling)
    var isLightTheme: Bool {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight
        }
        return false
    }

    /// Whether the device is an iPhone (for AI Agent presentation mode)
    var isPhone: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// Whether tabs are displayed in the titlebar (Catalyst only)
    var usesTitlebarTabs: Bool {
        #if targetEnvironment(macCatalyst)
        return tabsInTitlebarEnabled
        #else
        return false
        #endif
    }

    /// Leading padding for tab bar content (accounts for window controls on Catalyst)
    var tabBarLeadingPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        let basePadding: CGFloat = 8
        if usesTitlebarTabs && !hideWindowTitleBar {
            // Use measured inset from window buttons, with a sensible minimum
            // Standard macOS window buttons (close, minimize, zoom) need ~78pt clearance
            let titlebarMinimum: CGFloat = 78
            let measuredInset = titlebarLayoutManager.leadingInset
            return max(titlebarMinimum, measuredInset)
        }
        return basePadding
        #else
        return 0
        #endif
    }
}
