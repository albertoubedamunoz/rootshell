//
//  AttachmentUploadBannerHostView.swift
//  rootshell
//
//  UIKit wrapper for hosting AttachmentUploadBannerView SwiftUI component.
//  Follows MoshRoamBannerHostView pattern for consistency.
//

import UIKit
import SwiftUI

/// UIKit view that hosts the AttachmentUploadBannerView SwiftUI component
@MainActor
final class AttachmentUploadBannerHostView: UIView {

    // MARK: - Properties

    private var hostingController: UIHostingController<AttachmentUploadBannerView>?
    private weak var parentViewController: UIViewController?
    private(set) var currentState: AttachmentUploadBannerState?
    var onCancel: (() -> Void)?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Updates the banner with new state
    func update(state: AttachmentUploadBannerState?) {
        if state == currentState { return }
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

    private func showBanner(with state: AttachmentUploadBannerState) {
        if let hc = hostingController {
            hc.rootView = AttachmentUploadBannerView(state: state, onCancel: onCancel)
            hc.view.invalidateIntrinsicContentSize()
        } else {
            let swiftUIView = AttachmentUploadBannerView(state: state, onCancel: onCancel)
            let hc = UIHostingController(rootView: swiftUIView)
            hc.view.backgroundColor = .clear
            hc.view.translatesAutoresizingMaskIntoConstraints = false

            if let parent = parentViewController {
                parent.addChild(hc)
                addSubview(hc.view)
                hc.didMove(toParent: parent)
            } else {
                addSubview(hc.view)
            }

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
