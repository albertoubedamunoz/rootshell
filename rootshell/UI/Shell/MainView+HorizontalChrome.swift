import SwiftUI

extension MainView {
    func horizontalTabHeader(geometry: GeometryProxy, resolvedTheme: ResolvedTabBarTheme) -> some View {
        HStack(spacing: 0) {
            tabBarLeadingSpacer(geometry: geometry, theme: resolvedTheme)

            // Tab bar - switches between display modes
            //
            // The previous design carried a `tabBarVersion`
            // counter that was bumped from drop completions
            // and notification observers, with `.id(tabBarVersion)`
            // forcing a structural rebuild of the entire tab
            // bar subtree on every increment. With per-tab
            // observation via `TabModel`, the tab bar
            // re-evaluates only on the property reads it
            // actually performs, so no manual refresh signal
            // is needed.
            tabBarTrack(in: geometry, theme: resolvedTheme)
                .layoutPriority(0)
                // Toggling grouped mode changes `navigationTabs`,
                // which can flip the tab-bar display mode (e.g.
                // equalWidth→singleTab when two tabs live in
                // different groups). Animating that structural
                // swap makes the selected tab's glass capsule
                // morph for ~1s, during which the roam "R" badge
                // composites against the unsettled glass and looks
                // washed out. Snap the layout for grouped-mode
                // toggles so the badge is correct immediately;
                // ordinary tab add/remove + resize still animate
                // (this innermost transaction only fires when
                // `isGroupedModeEnabled` itself changes).
                .transaction(value: tabsModel.isGroupedModeEnabled) { $0.animation = nil }
                .animation(.easeInOut(duration: 0.25), value: terminals.count)
#if targetEnvironment(macCatalyst)
                .blockWindowDrag(when: usesTitlebarTabs)
#endif

            if duoTabletopAvailable && !showsDuoSideRail {
                duoTabletopButton
            }
            if usesCompactTabSpacing {
                tabBarAddButton(theme: resolvedTheme)
                integratedTabBarDragRegion()
                    .layoutPriority(-1)
                tabBarSettingsButton(theme: resolvedTheme)
            } else {
                TabStyleContextMenuRegion(
                    selectedStyleRawValue: topTabStyleRawValueBinding
                )
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
                tabBarActionButtons(theme: resolvedTheme)
            }
        }
        .frame(height: TabMetrics.tabBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                tabBarChromeBackground(resolvedTheme)

                // Background layer on purpose: the active tab
                // occludes the run beneath it, so the line
                // reads as rising around that tab.
                if topTabStyle.usesStripLayout {
                    IntegratedTabEdgeRuleView(
                        palette: resolvedTheme.integratedEdgePalette
                    )
                }
            }
            // Visual chrome must not own an interaction behind
            // every foreground tab, button, and empty-space menu.
            .allowsHitTesting(false)
        }
        .overlayPreferenceValue(IntegratedActiveTabBoundsPreferenceKey.self) { bounds in
            integratedOSCProgressEdge(activeTabBounds: bounds)
        }
        .modifier(ContainerCornerModifier())
#if targetEnvironment(macCatalyst)
        .catalystCursorRegion()
#endif
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            // Tab frame preferences are only used by Catalyst
            // titlebar dragging. Guard and defer the write so
            // selection animations don't feed layout-pass
            // preferences back into MainView every frame.
            DispatchQueue.main.async {
                if tabFrames != frames {
                    tabFrames = frames
                }
            }
        }
    }
}
