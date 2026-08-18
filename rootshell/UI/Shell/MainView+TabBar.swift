//
//  MainView+TabBar.swift
//  rootshell
//
//  Tab bar width calculation logic for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import os

// MARK: - Tab Bar Display Mode

extension MainView {

    /// Display mode for the tab bar, determining layout strategy
    enum TabBarDisplayMode: Equatable {
        case singleTab      // Centered title only
        case equalWidth     // Equal-width tabs filling space
        case scrolling      // Scrollable tabs when overflow occurs
    }

    /// Width reserved for action buttons (plus + settings)
    static let actionButtonsWidth: CGFloat = TabMetrics.tabBarHeight * 2

    /// Usable width for tab items after fixed leading chrome and trailing
    /// action buttons are reserved. Per-tab display mode decisions live in
    /// `TabBar`, where reading title/badge/health metadata does not invalidate
    /// `MainView.body`.
    func availableTabBarWidth(in geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - Self.actionButtonsWidth - tabBarLeadingPadding)
    }
}

// MARK: - Tab Bar Content and Tab Helpers

extension MainView {

    // MARK: - Tab Theme Override Helper

    /// Check if a tab has a theme override applied
    func tabHasThemeOverride(_ tabId: UUID) -> Bool {
        themeOverrideManager.hasTabOverride(tabId: tabId)
    }

    // MARK: - Tab Keyboard Shortcut Helper

    /// Returns keyboard shortcut string for a tab at the given index
    /// Only returns shortcuts for tabs 1-9 when the setting is enabled
    func keyboardShortcut(for index: Int) -> String? {
        guard showTabShortcutIndicators, index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    // MARK: - Tab Bar Content

    /// Build tab bar content based on display mode.
    ///
    /// All per-tab Observation reads (`tab.title`, `tab.connectionHealth`,
    /// `tab.activeRoamProtocol`) live inside `TabBar.body`, NOT here, so
    /// network-driven mutations (OSC 0/2 title sequences during reconnect,
    /// keepalive ping health updates, embedded mosh/trzsz session-change
    /// notifications) only invalidate `TabBar.body` and do not propagate
    /// up to MainView. The whole crash family in this project's IPS files
    /// (varying frames; common root: scene-update transactions blow the
    /// 10s/30s FrontBoard budget when MainView re-evaluates) hinges on
    /// this decoupling.
    @ViewBuilder
    func tabBarContent(in geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        TabBar(
            theme: theme,
            availableWidth: availableTabBarWidth(in: geometry),
            tabsModel: tabsModel,
            selectedTabIndex: Binding(
                get: { selectedTabIndex },
                set: { newIndex in
                    selectedTabIndex = newIndex
                }
            ),
            windowId: windowId,
            usesTitlebarTabs: usesTitlebarTabs,
            sshHealthMonitoringEnabled: sshHealthMonitoringEnabled,
            tabNamespace: tabNamespace,
            canAcceptWindowTransferDrop: tabTransferDropOverlayVisible,
            suppressSelectionAnimation: tabIndicator.suppressNextSelectionAnimation,
            wigglingTabIds: $wigglingTabIds,
            tabFrames: $tabFrames,
            onCloseTab: { index in closeTab(at: index) },
            onMoveTab: { from, to in moveTab(from: from, to: to) },
            onSelectTab: { index in
                guard index != selectedTabIndex else { return }
                if tabBarAnimationsDisabled {
                    selectedTabIndex = index
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTabIndex = index
                    }
                }
            },
            keyboardShortcut: { index in keyboardShortcut(for: index) },
            onTabHover: { id, isHovered in tabHover.handleHover(tabId: id, isHovered: isHovered) },
            tabHasThemeOverride: { id in tabHasThemeOverride(id) },
            onClearThemeOverride: { id in themeOverrideManager.clearTabOverride(tabId: id) },
            onShowConnectionInfo: { tab in showConnectionInfo(for: tab) },
            canTransferToNearby: { tab in canTransferTabToNearby(tab) },
            onTransferToNearby: { tab in transferTabToNearby(tab) },
            onMoveTabToNewWindow: { tab in moveTabToNewWindow(tab) },
            onMoveTabsToNewWindow: { ids in moveTabsToNewWindow(ids) },
            onNewTmuxWindow: { tab in requestTmuxNewWindow(for: tab) },
            onShowTmuxSessions: { tab in showTmuxSessions(for: tab) },
            tmuxController: { tab in tmuxControllerForTab(tab) }
        )
    }

    // MARK: - Shared tab context-menu helpers (top bar + vertical sidebar)

    func showConnectionInfo(for tab: TabModel) {
        connectionInfoToShow = tab.connectionInfo
    }

    /// Should the "Transfer to Nearby Device" item appear for this tab?
    func canTransferTabToNearby(_ tab: TabModel) -> Bool {
        guard tab.activeRoamProtocol == .trzsz,
              let leaf = tab.focusedTerminal,
              let trzsz = leaf.session as? TrzszSession,
              trzsz.transferableSessionID != nil else { return false }
        return true
    }

    func transferTabToNearby(_ tab: TabModel) {
        guard let leaf = tab.focusedTerminal else { return }
        startTrzszTransfer(tabId: tab.id, leaf: leaf)
    }

    func moveTabToNewWindow(_ tab: TabModel) {
        guard TabTransferCoordinator.shared.canTransfer(tab) else { return }
        moveTabsToNewWindow([tab.id])
    }

    /// Stage a group / gateway (one or more tabs) and open a fresh window that
    /// claims them on appear. Generalizes `moveTabToNewWindow`.
    func moveTabsToNewWindow(_ tabIDs: [UUID]) {
        guard TabTransferCoordinator.canOfferWindowTransfers, !tabIDs.isEmpty else { return }
        TabTransferCoordinator.shared.prepareMoveTabsToNewWindow(tabIDs, from: windowId)
        #if targetEnvironment(macCatalyst)
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                TabTransferCoordinator.shared.cancelPendingMoveTabsToNewWindow(tabIDs, from: windowId)
                Ghostty.logger.error("Failed to create transfer window: \(error.localizedDescription)")
            }
        )
        #else
        openWindow(id: "main-terminal")
        #endif
    }

    /// Create a new tmux window for either tab kind: gateway tabs route
    /// through the gateway surface, window tabs through their focused pane.
    func requestTmuxNewWindow(for tab: TabModel) {
        if tab.isTmuxGateway {
            tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?
                .requestTmuxNewWindowFromGateway()
        } else {
            tab.focusedTerminal?.requestTmuxNewWindow()
        }
    }

    func showTmuxSessions(for tab: TabModel) {
        if let controller = tmuxControllerForTab(tab) {
            tmuxDashboardRequest = TmuxDashboardRequest(controller: controller)
        }
    }

}
