//
//  MoshRoamBannerHostView.swift
//  rootshell
//
//  UIKit wrapper for hosting MoshRoamBannerView SwiftUI component
//

import UIKit
import SwiftUI

/// UIKit view that hosts the MoshRoamBannerView SwiftUI component
///
/// This wrapper enables embedding the modern SwiftUI roam banner
/// (with liquid glass effect) within the UIKit-based TerminalScrollView.
/// Follows the same pattern as ProgressBarView for consistency.
@MainActor
final class MoshRoamBannerHostView: UIView {

    // MARK: - Properties

    /// The hosting controller for the SwiftUI view
    private var hostingController: UIHostingController<MoshRoamBannerView>?

    /// Parent view controller (needed for hosting controller lifecycle)
    private weak var parentViewController: UIViewController?

    /// Current banner state (readable for cleanup checks)
    private(set) var currentState: MoshRoamBannerState?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false  // Banner is display-only
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Updates the banner with new state
    ///
    /// - Parameter state: The new banner state, or nil to hide the banner
    func update(state: MoshRoamBannerState?) {
        // Early exit if state hasn't changed
        if state == currentState {
            return
        }
        currentState = state

        if let state = state {
            showBanner(with: state)
        } else {
            hideBanner()
        }
    }

    /// Sets the parent view controller for hosting controller lifecycle management
    func setParentViewController(_ viewController: UIViewController?) {
        parentViewController = viewController
    }

    // MARK: - Private Methods

    private func showBanner(with state: MoshRoamBannerState) {
        if let hc = hostingController {
            // Update existing hosting controller's root view
            hc.rootView = MoshRoamBannerView(state: state)
            hc.view.invalidateIntrinsicContentSize()
        } else {
            // Create new hosting controller
            let swiftUIView = MoshRoamBannerView(state: state)
            let hc = UIHostingController(rootView: swiftUIView)
            hc.view.backgroundColor = .clear
            hc.view.translatesAutoresizingMaskIntoConstraints = false

            // Add as child of parent view controller if available
            if let parent = parentViewController {
                parent.addChild(hc)
                addSubview(hc.view)
                hc.didMove(toParent: parent)
            } else {
                addSubview(hc.view)
            }

            // Center the banner horizontally, pin to top
            NSLayoutConstraint.activate([
                hc.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                hc.view.topAnchor.constraint(equalTo: topAnchor)
            ])

            hostingController = hc

            // Animate in
            hc.view.alpha = 0
            hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                hc.view.alpha = 1
                hc.view.transform = .identity
            }
        }
    }

    private func hideBanner() {
        guard let hc = hostingController else { return }

        // Animate out
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            hc.view.alpha = 0
            hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
        } completion: { [weak self] _ in
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            self?.hostingController = nil
        }
    }
}
