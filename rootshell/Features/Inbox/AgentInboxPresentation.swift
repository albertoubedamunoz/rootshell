import OSLog
import SwiftUI
import UIKit

private let inboxGestureLog = Logger(subsystem: "com.rootshell", category: "InboxGesture")

/// Presents the agent inbox as a pushed page and provides the swipe entries.
///
/// Lives in its own modifier because `MainView`'s presentation chain is already
/// at the limit of what the type-checker will resolve in a single expression.
enum AgentInboxRoute: Hashable { case inbox }

struct AgentInboxSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    @State private var path: [AgentInboxRoute] = []

    func body(content: Content) -> some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .navigationBar)
                // Swipe right from the leading edge opens the inbox. The terminal
                // is a UIKit view that takes every touch inside it, so this has to
                // be a screen-edge recogniser rather than a SwiftUI gesture.
                .background(
                    ScreenEdgePan(edge: .left, enabled: path.isEmpty) {
                        isPresented = true
                    }
                    .frame(width: 0, height: 0)
                )
                .navigationDestination(for: AgentInboxRoute.self) { _ in
                    AgentInboxView(onClose: { isPresented = false }, embedsNavigation: false)
                        // The bar belongs to this pushed view, so its colour
                        // scheme has to be set here as well; setting it only on
                        // the stack's root left the title rendering in the
                        // system scheme (black on a dark bar).
                        .toolbarColorScheme(themeColors.map { $0.isDarkSurface ? .dark : .light } ?? colorScheme,
                                            for: .navigationBar)
                        .themedSheet(
                            themeColors: themeColors,
                            accentColor: accentColor,
                            colorScheme: colorScheme
                        )
                }
        }
        // `isPresented` can already be true on the first render — the island deep
        // link sets it while the scene is still being built — and `onChange` never
        // fires for an initial value. That is why a tap used to land on the
        // terminal with no inbox in sight.
        .onAppear { sync(presented: isPresented) }
        .onChange(of: isPresented) { _, presented in sync(presented: presented) }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty, isPresented { isPresented = false }
        }
    }

    private func sync(presented: Bool) {
        if presented {
            if path.isEmpty { path = [.inbox] }
        } else if !path.isEmpty {
            path.removeAll()
        }
    }
}

// MARK: - Swipe to go back

extension View {
    /// Swipe **left** anywhere on the page to go back to the main screen.
    ///
    /// A SwiftUI `DragGesture` loses this to the list's scroll recogniser, and a
    /// `UISwipeGestureRecognizer` attached to the window never sees the touch:
    /// the pan has to live on the page's own view controller, and it has to be
    /// allowed to run *alongside* scrolling or vertical drags stop working.
    func agentInboxSwipeBack(_ action: @escaping () -> Void) -> some View {
        background(
            HorizontalPan(onSwipeLeft: action)
                .frame(width: 0, height: 0)
        )
    }
}

#if canImport(UIKit)
private struct ScreenEdgePan: UIViewRepresentable {
    let edge: UIRectEdge
    let enabled: Bool
    let onTrigger: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTrigger: onTrigger) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view, attempts: 12)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTrigger = onTrigger
        context.coordinator.recognizer?.isEnabled = enabled
        context.coordinator.attach(from: uiView, attempts: 12)
    }

    final class Coordinator: NSObject {
        var onTrigger: () -> Void
        weak var host: UIView?
        var recognizer: UIScreenEdgePanGestureRecognizer?
        private var attached = false

        init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

        func attach(from view: UIView, attempts: Int) {
            guard !attached, attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                guard let window = view.window else {
                    self.attach(from: view, attempts: attempts - 1)
                    return
                }
                let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(Self.handle(_:)))
                pan.edges = .left
                pan.cancelsTouchesInView = false
                window.addGestureRecognizer(pan)
                self.host = window
                self.recognizer = pan
                self.attached = true
            }
        }

        @objc private func handle(_ pan: UIScreenEdgePanGestureRecognizer) {
            guard pan.state == .ended, let view = pan.view else { return }
            let translation = pan.translation(in: view)
            guard translation.x > 50, abs(translation.y) < 90 else { return }
            onTrigger()
        }
    }
}

private struct HorizontalPan: UIViewRepresentable {
    let onSwipeLeft: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipeLeft: onSwipeLeft) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view, attempts: 12)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipeLeft = onSwipeLeft
        context.coordinator.attach(from: uiView, attempts: 12)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipeLeft: () -> Void
        weak var host: UIView?
        private var recognizer: UIPanGestureRecognizer?
        private var attached = false
        private var fired = false

        init(onSwipeLeft: @escaping () -> Void) { self.onSwipeLeft = onSwipeLeft }

        func attach(from view: UIView, attempts: Int) {
            guard !attached, attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                // The page's own view controller: a pan added here sees touches
                // over the list as well, which a window-level recogniser does not.
                guard let host = view.parentViewController?.view ?? view.window else {
                    self.attach(from: view, attempts: attempts - 1)
                    return
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(Self.handle(_:)))
                pan.delegate = self
                pan.cancelsTouchesInView = false
                host.addGestureRecognizer(pan)
                self.host = host
                self.recognizer = pan
                self.attached = true
                inboxGestureLog.info("pan attached to \(type(of: host), privacy: .public)")
            }
        }

        func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
            attached = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let translation = pan.translation(in: view)
            inboxGestureLog.debug("pan \(pan.state.rawValue) dx=\(translation.x) dy=\(translation.y)")
            switch pan.state {
            case .began:
                fired = false
            case .changed, .ended:
                // Leftward and clearly horizontal: the person is moving to the
                // next page, not scrolling the list.
                if !fired,
                   translation.x < -70,
                   abs(translation.x) > abs(translation.y) * 1.5 {
                    fired = true
                    onSwipeLeft()
                }
            default:
                break
            }
        }
    }
}

private extension UIView {
    /// Nearest enclosing view controller, without a global responder walk.
    var parentViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
#endif
