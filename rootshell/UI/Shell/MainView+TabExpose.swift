//
//  MainView+TabExpose.swift
//  rootshell
//
//  Hosts the tab exposé over the terminal content area and wires its
//  controller to this window's tabs: occlusion while presented, the real
//  tab switch on select, key routing from the focused terminal.
//

import SwiftUI
import UIKit

extension MainView {

    /// Top layer of `terminalContentZStack`; always mounted, inert while hidden.
    @ViewBuilder
    func tabExposeHost(geometry: GeometryProxy, width: CGFloat) -> some View {
        TabExposeHost(
            controller: tabExpose,
            configuration: tabExposeConfiguration(),
            appearance: tabExposeAppearance()
        )
        .frame(width: width)
        .onAppear { installTabExposeHooks() }
    }

    private func tabExposeConfiguration() -> TabExposeView.Configuration {
        var config = TabExposeView.Configuration()
        config.gestureEnabled = { TabExposeSettings.gestureEnabled() }
        config.canBeginReveal = { !isAnySheetPresented && appTabSwipeState == nil }
        // Nothing above the terminal: let the pull start in its top strip.
        config.fallbackBandHeight = { tabBarHidden ? 28 : 0 }
        #if !targetEnvironment(macCatalyst)
        // Touch: one finger from the tab bar strip itself.
        config.oneFingerBandHeight = { tabBarHidden ? 0 : TabMetrics.tabBarHeight }
        #endif
        return config
    }

    private func tabExposeAppearance() -> TabExposeView.Appearance {
        var appearance = TabExposeView.Appearance()
        let theme = resolvedTabBarTheme()
        if let hex = effectiveThemeColors?.background, let color = UIColor(hex: hex) {
            appearance.backgroundColor = color
        } else {
            appearance.backgroundColor = UIColor(theme.tabBarBackground)
        }
        appearance.textColor = UIColor(theme.tabText)
        if let accent = sheetAccentColor {
            appearance.accentColor = UIColor(accent)
        }
        appearance.showsCaptions = TabExposeSettings.showsCaptions()
        let palette = TmuxTabBadgePalette(theme: theme)
        let textColor = theme.tabText
        let compact = UIDevice.current.userInterfaceIdiom == .phone
        let attentionDots = UserDefaults.standard.object(forKey: AgentAttentionSettings.badgesEnabledKey) as? Bool ?? true
        appearance.captionProvider = { tab, index in
            AnyView(
                TabTitleLine(
                    tab: tab,
                    allTabs: terminals,
                    tmuxBadgePalette: palette,
                    keyboardShortcut: compact ? nil : keyboardShortcut(for: index),
                    titleFont: .system(size: compact ? 12 : 13, weight: .semibold),
                    shortcutFont: .system(size: compact ? 11 : 12, weight: .medium),
                    textColor: textColor.opacity(0.85),
                    showsBadges: !compact,
                    showsAttentionDot: attentionDots
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 4)
            )
        }
        return appearance
    }

    /// One-time wiring; the closures read live state through the property wrappers.
    func installTabExposeHooks() {
        tabExpose.tabsModel = tabsModel
        tabExpose.reduceMotion = {
            UserDefaults.standard.bool(forKey: "tabBarAnimationsDisabled") || UIAccessibility.isReduceMotionEnabled
        }
        tabExpose.onWillPresent = { ids in
            // Wake every scope tab's renderer so the mirrors are live. The
            // secure-draw latch may drop these; the foreground reconcile
            // re-asserts them (it treats exposé tabs as visible).
            for id in ids { setTabOcclusion(tabID: id, visible: true) }
            installTabExposeKeyHandler()
        }
        tabExpose.onDidDismiss = {
            removeTabExposeKeyHandler()
            reconcileSurfaceOcclusion(reason: "tabExpose")
            reassertSelectedTabVisibility(reason: "tabExpose")
        }
        tabExpose.onScopeDidChange = { ids in
            // Newcomers must render live; the reconcile re-occludes leavers
            // (it treats the controller's current scope as visible).
            for id in ids { setTabOcclusion(tabID: id, visible: true) }
            reconcileSurfaceOcclusion(reason: "tabExposeScope")
        }
        tabExpose.onSelect = { id in
            if tabBarHidden && id != tabsModel.selectedTabID {
                tabIndicator.suppressNextHiddenIndicator = true
            }
            selectTab(id: id)
        }
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        tabExpose.onCommitHaptic = {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    func toggleTabExpose() {
        guard !isAnySheetPresented || tabExpose.isActive else { return }
        if !tabExpose.isActive, showingTabSwitcher, !tabSidebarIsDocked {
            showingTabSwitcher = false
        }
        tabExpose.toggle()
    }

    // MARK: - Keys (the terminal stays first responder)

    private func installTabExposeKeyHandler() {
        let tab = tabsModel.selectedTab
        let focused = tab?.focusedPane
        guard let terminal = focused?.asTerminal ?? tab?.splitTree.terminalLeaves.first else {
            // Non-terminal focus (VNC): the exposé view takes first responder
            // itself and the pane yields keyboard capture meanwhile.
            tabExpose.wantsFirstResponderFallback = true
            focused?.setOverlayOwnsKeyboard(true)
            return
        }
        tabExpose.wantsFirstResponderFallback = false
        let controller = tabExpose
        terminal.presentedOverlayKeyHandler = { key in
            guard controller.isActive else { return false }
            if key.isModifierOnly { return false }
            if controller.handleKey(key) { return true }
            // Anything else: get out of the way and let the key through.
            controller.cancel()
            return false
        }
        tabExpose.keyHandlerTerminal = terminal
    }

    private func removeTabExposeKeyHandler() {
        tabExpose.keyHandlerTerminal?.presentedOverlayKeyHandler = nil
        tabExpose.keyHandlerTerminal = nil
        if tabExpose.wantsFirstResponderFallback {
            tabExpose.wantsFirstResponderFallback = false
            if let focused = tabsModel.selectedTab?.focusedPane {
                focused.setOverlayOwnsKeyboard(isAnySheetPresented)
                _ = focused.focusDidChange(true)
            }
        }
    }
}
