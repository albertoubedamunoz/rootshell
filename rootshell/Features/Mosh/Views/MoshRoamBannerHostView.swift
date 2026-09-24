//
//  MoshRoamBannerHostView.swift
//  rootshell
//
//  UIKit wrapper for hosting MoshRoamBannerView inside TerminalScrollView.
//

import SwiftUI
import UIKit

@MainActor
final class MoshRoamBannerHostView: SwiftUIBannerHostView<MoshRoamBannerView> {

    /// Current banner state (readable for cleanup checks)
    private(set) var currentState: MoshRoamBannerState?

    var rebuildJumpConnection: (() -> Void)? {
        didSet {
            isUserInteractionEnabled = rebuildJumpConnection != nil
            if let currentState { show(rootView(for: currentState)) }
        }
    }

    init() {
        super.init(layout: .topCentered)
        isUserInteractionEnabled = false  // Banner is display-only
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the banner with new state; nil hides it.
    func update(state: MoshRoamBannerState?) {
        if state == currentState { return }
        currentState = state
        update(content: state.map(rootView(for:)))
    }

    private func rootView(for state: MoshRoamBannerState) -> MoshRoamBannerView {
        MoshRoamBannerView(state: state, rebuildJumpConnection: rebuildJumpConnection)
    }
}
