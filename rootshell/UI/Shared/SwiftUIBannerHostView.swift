//
//  SwiftUIBannerHostView.swift
//  rootshell
//
//  Generic UIKit host for a SwiftUI banner embedded in TerminalScrollView.
//  Owns the hosting controller's parent chain and the show/hide animation;
//  subclasses own the state model and build the root view.
//

import SwiftUI
import UIKit

@MainActor
class SwiftUIBannerHostView<Content: View>: UIView {

    enum Layout {
        /// Pinned to the top, centered horizontally; sized by SwiftUI.
        case topCentered
        /// Pinned to all four edges of the host.
        case fill
    }

    private let layout: Layout
    private(set) var hostingController: UIHostingController<Content>?
    private weak var parentViewController: UIViewController?

    /// True between show and hide; the hide completion tears down only if
    /// no show has intervened.
    private var isPresented = false

    init(layout: Layout = .topCentered) {
        self.layout = layout
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Parent

    /// Sets (or re-homes to) the parent view controller. An existing hosting
    /// controller is moved so a window transfer doesn't strand the child VC.
    func setParentViewController(_ viewController: UIViewController?) {
        guard parentViewController !== viewController else { return }
        parentViewController = viewController
        guard let hc = hostingController else { return }
        hc.willMove(toParent: nil)
        hc.removeFromParent()
        if let parent = viewController {
            parent.addChild(hc)
            hc.didMove(toParent: parent)
        }
    }

    // MARK: - Show / hide

    /// Shows `content`, or animates out and tears down when nil.
    func update(content: Content?) {
        if let content {
            show(content)
        } else {
            hide()
        }
    }

    func show(_ content: Content) {
        isPresented = true
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        if let hc = hostingController {
            hc.rootView = content
            hc.view.invalidateIntrinsicContentSize()
            // Reverse an in-flight hide; the hide completion then sees
            // isPresented and skips teardown.
            if hc.view.alpha < 1 {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    hc.view.alpha = 1
                    hc.view.transform = .identity
                }
            }
            return
        }

        let hc = UIHostingController(rootView: content)
        hc.view.backgroundColor = .clear
        hc.view.translatesAutoresizingMaskIntoConstraints = false

        if let parent = parentViewController {
            parent.addChild(hc)
            addSubview(hc.view)
            hc.didMove(toParent: parent)
        } else {
            addSubview(hc.view)
        }

        switch layout {
        case .topCentered:
            NSLayoutConstraint.activate([
                hc.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                hc.view.topAnchor.constraint(equalTo: topAnchor),
            ])
        case .fill:
            NSLayoutConstraint.activate([
                hc.view.topAnchor.constraint(equalTo: topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: bottomAnchor),
                hc.view.leadingAnchor.constraint(equalTo: leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        hostingController = hc

        hc.view.alpha = 0
        if !reduceMotion {
            hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            hc.view.alpha = 1
            hc.view.transform = .identity
        }
    }

    func hide() {
        isPresented = false
        guard let hc = hostingController else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            hc.view.alpha = 0
            if !reduceMotion {
                hc.view.transform = CGAffineTransform(translationX: 0, y: -10)
            }
        } completion: { [weak self] _ in
            // A live host that re-showed keeps its controller; a released
            // host still detaches the child so the parent VC drops it.
            if let self, self.hostingController === hc, self.isPresented { return }
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            if self?.hostingController === hc { self?.hostingController = nil }
        }
    }
}
