//
//  TabSidebarEdgeSwipe.swift
//  rootshell
//
//  Pull the vertical tab sidebar in from the left screen edge on iPad, like a
//  native drawer. A `UIPanGestureRecognizer` is installed on the host *window*
//  (not on this representable's view) because the sidebar overlay is
//  `isUserInteractionEnabled = false` while closed and so cannot catch the edge
//  touch itself. A plain pan (rather than `UIScreenEdgePanGestureRecognizer`)
//  is used so we control the activation band ourselves and don't fight the
//  system edge recognizer's hidden margin; the iPad system multitasking edge is
//  yielded to us via `.defersSystemGestures(on: .leading)` on `MainView`.
//
//  For the floating (unpinned) sidebar the drag is interactive: the panel
//  tracks the finger via the `tabSidebarOpenDrag*` notifications that
//  `TabSidebarOverlayViewController` listens for. For the pinned (docked)
//  preference the column can't be finger-tracked (SwiftUI layout), so the
//  gesture just opens it and lets the docked `.move(edge: .leading)`
//  transition play.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if !os(visionOS)

/// How far in from the left edge a drag may start and still open the drawer.
private let edgeActivationWidth: CGFloat = 32

struct TabSidebarEdgeSwipe: UIViewRepresentable {
    @Binding var showingTabSwitcher: Bool
    /// True only when an edge swipe is currently allowed to open the sidebar
    /// (sidebar closed and no blocking sheet/settings presented).
    var canOpen: () -> Bool
    /// The user's pin preference resolves to a docked column: open it directly
    /// instead of running the interactive floating drawer.
    var opensDocked: Bool
    var panelWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            showingTabSwitcher: $showingTabSwitcher,
            canOpen: canOpen,
            opensDocked: opensDocked,
            panelWidth: panelWidth
        )
    }

    func makeUIView(context: Context) -> EdgeSwipeInstallerView {
        let view = EdgeSwipeInstallerView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: EdgeSwipeInstallerView, context: Context) {
        // Refresh the captured inputs each render so the gesture reads current
        // state (open/closed, presented sheets, pin preference).
        context.coordinator.showingTabSwitcher = $showingTabSwitcher
        context.coordinator.canOpen = canOpen
        context.coordinator.opensDocked = opensDocked
        context.coordinator.panelWidth = panelWidth
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var showingTabSwitcher: Binding<Bool>
        var canOpen: () -> Bool
        var opensDocked: Bool
        var panelWidth: CGFloat

        private var interactiveOpenInProgress = false

        init(
            showingTabSwitcher: Binding<Bool>,
            canOpen: @escaping () -> Bool,
            opensDocked: Bool,
            panelWidth: CGFloat
        ) {
            self.showingTabSwitcher = showingTabSwitcher
            self.canOpen = canOpen
            self.opensDocked = opensDocked
            self.panelWidth = panelWidth
        }

        @objc
        func handleEdgePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            // The recognizer lives on the window; scope every post to it so a
            // swipe in one scene never drives another window's overlay.
            let window = gesture.view
            let width = max(panelWidth, 1)

            switch gesture.state {
            case .began:
                // `gestureRecognizerShouldBegin` already gated on `canOpen()`;
                // re-check defensively in case state changed between callbacks.
                guard canOpen() else {
                    interactiveOpenInProgress = false
                    return
                }
                if opensDocked {
                    // Docked column: no finger-tracking, just open.
                    interactiveOpenInProgress = false
                    showingTabSwitcher.wrappedValue = true
                } else {
                    // Floating drawer: arm the overlay to sit hidden, then flip
                    // the binding true so it mounts without auto-springing. The
                    // synchronous post lands before SwiftUI's update cycle.
                    interactiveOpenInProgress = true
                    NotificationCenter.default.post(name: .tabSidebarBeginInteractiveOpen, object: window)
                    showingTabSwitcher.wrappedValue = true
                }

            case .changed:
                guard interactiveOpenInProgress else { return }
                let progress = max(0, min(1, gesture.translation(in: view).x / width))
                NotificationCenter.default.post(
                    name: .tabSidebarOpenDragChanged,
                    object: window,
                    userInfo: ["progress": progress]
                )

            case .ended:
                guard interactiveOpenInProgress else { return }
                interactiveOpenInProgress = false
                let translation = gesture.translation(in: view)
                let velocity = gesture.velocity(in: view)
                let commit = translation.x > width / 3 || velocity.x > 800
                if commit {
                    NotificationCenter.default.post(name: .tabSidebarOpenDragCommit, object: window)
                } else {
                    NotificationCenter.default.post(name: .tabSidebarOpenDragCancel, object: window)
                    showingTabSwitcher.wrappedValue = false
                }

            case .cancelled, .failed:
                guard interactiveOpenInProgress else { return }
                interactiveOpenInProgress = false
                NotificationCenter.default.post(name: .tabSidebarOpenDragCancel, object: window)
                showingTabSwitcher.wrappedValue = false

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            // A plain pan fires anywhere; only claim a drag that STARTED within
            // the left-edge band and is heading right. (Computed from the
            // current point minus accumulated translation — `location` alone is
            // the current finger, not the touch-down.)
            let translation = pan.translation(in: view)
            let location = pan.location(in: view)
            let startX = location.x - translation.x
            let fromEdge = startX <= edgeActivationWidth
            let headingRight = translation.x > 0 && abs(translation.x) >= abs(translation.y)
            return canOpen() && fromEdge && headingRight
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Our edge pan should beat the terminal's tab-swipe recognizers: a
            // left-edge swipe-in reads as a `.right` swipe. Make any sibling
            // swipe wait for the edge pan to fail before it fires. Decoupled —
            // no reference to TerminalView's recognizers needed.
            otherGestureRecognizer is UISwipeGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Permissive: don't let an unrelated recognizer block the edge pan.
            true
        }
    }

    /// A zero-cost passthrough view whose only job is to install the
    /// window-level edge recognizer once it has a window, and to remove it when
    /// it leaves the hierarchy.
    final class EdgeSwipeInstallerView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedWindow: UIWindow?
        private var edgePan: UIPanGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            // iPad only: the phone keeps its bottom-rising panel; visionOS uses
            // a sheet (this type isn't compiled there).
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                removeRecognizer()
                return
            }
            guard window !== installedWindow else { return }
            removeRecognizer()
            guard let window, let coordinator else { return }
            let pan = UIPanGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.handleEdgePan(_:))
            )
            pan.maximumNumberOfTouches = 1
            // Finger-only — like the terminal's tab-swipe recognizers. Without
            // this the window pan steals indirect-pointer (Magic Keyboard
            // trackpad / mouse) drags near the left edge, breaking text
            // selection there.
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.delegate = coordinator
            window.addGestureRecognizer(pan)
            edgePan = pan
            installedWindow = window
        }

        private func removeRecognizer() {
            if let edgePan, let installedWindow {
                installedWindow.removeGestureRecognizer(edgePan)
            }
            edgePan = nil
            installedWindow = nil
        }
    }
}

#endif
