//
//  VisorContentView.swift
//  rootshell
//
//  Content for the visor WindowGroup: a single local-shell TerminalContainer
//  with no tab strip and an embedded VisorWindowAccessor that reconfigures
//  the underlying NSWindow as a non-activating floating panel.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import SwiftUI

struct VisorContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @StateObject private var controller = VisorController.shared

    var body: some View {
        ZStack {
            // Visible content is gated on controller.contentRevealed so the
            // prewarm openWindow at app launch never flashes a black panel.
            // The accessor stays always-mounted (it needs to attach to the
            // UIWindow regardless of visibility).
            Group {
                Color.clear.ignoresSafeArea()

                MainView(overrideWindowId: "visor")
                    .environmentObject(ghosttyApp)
                    .ignoresSafeArea()
            }
            .opacity(controller.contentRevealed ? 1 : 0)

            // Hidden — reconfigures the underlying NSWindow on appear.
            VisorWindowAccessor()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }
}

#endif
