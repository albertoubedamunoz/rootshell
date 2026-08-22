//
//  TabSidebarEdgeSwipe.swift
//  rootshell
//
//  Pull the vertical tab sidebar in from the left screen edge on iPad, like a
//  native drawer. Built on `InteractiveEdgePanRecognizer` (a window-level pan,
//  since the sidebar overlay is `isUserInteractionEnabled = false` while closed
//  and cannot catch the edge touch itself); the iPad system multitasking edge
//  is yielded to us via `.defersSystemGestures(on: .leading)` on `MainView`.
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
    final class Coordinator {
        var showingTabSwitcher: Binding<Bool>
        var canOpen: () -> Bool
        var opensDocked: Bool
        var panelWidth: CGFloat

        private var interactiveOpenInProgress = false
        private(set) lazy var recognizer: InteractiveEdgePanRecognizer = makeRecognizer()

        private func makeRecognizer() -> InteractiveEdgePanRecognizer {
            var configuration = InteractiveEdgePanRecognizer.Configuration(
                axis: .horizontal,
                // iPad only: the phone keeps its bottom-rising panel.
                idioms: [.pad]
            )
            configuration.touches = 1
            // Our edge pan should beat the terminal's tab-swipe recognizers: a
            // left-edge swipe-in reads as a `.right` swipe.
            configuration.beatsSiblingRecognizers = { $0 is UISwipeGestureRecognizer }

            let isInBand: (CGPoint, UIWindow) -> Bool = { start, _ in
                start.x <= edgeActivationWidth
            }
            let shouldBegin: (CGPoint, CGPoint, UIWindow) -> Bool = { [weak self] _, translation, _ in
                guard let self else { return false }
                let headingRight = translation.x > 0 && abs(translation.x) >= abs(translation.y)
                return self.canOpen() && headingRight
            }
            let callbacks = InteractiveEdgePanRecognizer.Callbacks(
                isInActivationBand: isInBand,
                shouldBegin: shouldBegin,
                length: { [weak self] in max(self?.panelWidth ?? 1, 1) },
                onBegin: { [weak self] window in self?.begin(window: window) },
                onChange: { [weak self] progress in self?.change(progress: progress) },
                onEnd: { [weak self] progress, velocity in self?.end(progress: progress, velocity: velocity) },
                onCancel: { [weak self] in self?.cancel() }
            )
            return InteractiveEdgePanRecognizer(configuration: configuration, callbacks: callbacks)
        }

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

        // Every post is scoped to the window so a swipe in one scene never
        // drives another window's overlay.
        private weak var window: UIWindow?

        private func begin(window: UIWindow) {
            self.window = window
            // `shouldBegin` already gated on `canOpen()`; re-check defensively.
            guard canOpen() else {
                interactiveOpenInProgress = false
                return
            }
            if opensDocked {
                // Docked column: no finger-tracking, just open.
                interactiveOpenInProgress = false
                showingTabSwitcher.wrappedValue = true
            } else {
                // Floating drawer: arm the overlay to sit hidden, then flip the
                // binding true so it mounts without auto-springing. The
                // synchronous post lands before SwiftUI's update cycle.
                interactiveOpenInProgress = true
                NotificationCenter.default.post(name: .tabSidebarBeginInteractiveOpen, object: window)
                showingTabSwitcher.wrappedValue = true
            }
        }

        private func change(progress: CGFloat) {
            guard interactiveOpenInProgress else { return }
            NotificationCenter.default.post(
                name: .tabSidebarOpenDragChanged,
                object: window,
                userInfo: ["progress": max(0, min(1, progress))]
            )
        }

        private func end(progress: CGFloat, velocity: CGFloat) {
            guard interactiveOpenInProgress else { return }
            interactiveOpenInProgress = false
            if progress > 1 / 3 || velocity > 800 {
                NotificationCenter.default.post(name: .tabSidebarOpenDragCommit, object: window)
            } else {
                NotificationCenter.default.post(name: .tabSidebarOpenDragCancel, object: window)
                showingTabSwitcher.wrappedValue = false
            }
        }

        private func cancel() {
            guard interactiveOpenInProgress else { return }
            interactiveOpenInProgress = false
            NotificationCenter.default.post(name: .tabSidebarOpenDragCancel, object: window)
            showingTabSwitcher.wrappedValue = false
        }
    }

    /// A zero-cost passthrough view whose only job is to install the
    /// window-level edge recognizer once it has a window, and to remove it when
    /// it leaves the hierarchy.
    final class EdgeSwipeInstallerView: UIView {
        weak var coordinator: Coordinator?

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
            coordinator?.recognizer.install(on: window)
        }
    }
}

#endif
