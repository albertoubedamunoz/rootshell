//
//  SSHAuthBannerCardHostView.swift
//  rootshell
//
//  UIKit wrapper hosting the SwiftUI SSH auth-banner card inside the
//  UIKit-based TerminalScrollView. Interactive (open/copy/collapse actions)
//  and re-homeable so a mid-auth window transfer keeps the child view
//  controller chain valid.
//

import SwiftUI
import UIKit

@MainActor
final class SSHAuthBannerCardHostView: SwiftUIBannerHostView<SSHAuthBannerCardView> {

    // MARK: - Properties

    /// Current card state (readable for stacking/cleanup checks).
    private(set) var currentState: SSHAuthBannerCardState?

    /// Collapse lives here, not in SwiftUI @State: the rootView is replaced on
    /// every state update, which would silently reset view-local state.
    private var isCollapsed = false

    /// Opens a banner URL. Injected so the host stays testable/preview-safe;
    /// defaults to the platform browser via UIApplication.
    var onOpenURL: (URL) -> Void = { url in
        UIApplication.shared.open(url)
    }

    /// Copies a banner URL, recording it in clipboard history like the
    /// terminal's own Copy Link action.
    var onCopyURL: (URL) -> Void = { url in
        UIPasteboard.general.string = url.absoluteString
        ClipboardHistoryManager.shared.record(url.absoluteString, source: .copyLink)
    }

    /// Retires the card in the owning session's model. The host hides itself
    /// first for immediacy; this makes the dismissal stick across pane
    /// switches and window transfers, which replay from that model.
    var onDismissRequested: () -> Void = {}

    // MARK: - Initialization

    init() {
        super.init(layout: .fill)
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Updates the card with new state; nil hides and tears down.
    func update(state: SSHAuthBannerCardState?) {
        if state == currentState { return }
        // New banner content must be seen: force-expand when items grow.
        if let state, state.items.count > (currentState?.items.count ?? 0), isCollapsed {
            isCollapsed = false
        }
        currentState = state

        if let state {
            show(rootView(for: state))
            UIAccessibility.post(notification: .layoutChanged, argument: hostingController?.view)
        } else {
            isCollapsed = false
            hide()
        }
    }

    // MARK: - Private Methods

    private func rootView(for state: SSHAuthBannerCardState) -> SSHAuthBannerCardView {
        SSHAuthBannerCardView(
            state: state,
            isCollapsed: isCollapsed,
            onToggleCollapse: { [weak self] in
                guard let self else { return }
                self.isCollapsed.toggle()
                if let current = self.currentState {
                    self.show(self.rootView(for: current))
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                // Hide locally first so the animation is immediate; the model
                // clear that follows re-broadcasts nil, which update(state:)
                // no-ops on via its state == currentState early return.
                self.update(state: nil)
                self.onDismissRequested()
            },
            onOpenURL: { [weak self] url in self?.onOpenURL(url) },
            onCopyURL: { [weak self] url in self?.onCopyURL(url) }
        )
    }
}
