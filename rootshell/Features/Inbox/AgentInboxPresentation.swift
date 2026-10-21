import OSLog
import SwiftUI
import UIKit

private let inboxGestureLog = Logger(subsystem: "com.rootshell", category: "InboxGesture")

/// Presents the agent inbox as a drawer that tracks the finger.
///
/// The inbox is a page of its own, but it is not a navigation push: pushing
/// animates the new page in from the trailing edge, which reads backwards when
/// the person is dragging in from the leading edge. Here the page starts
/// off-screen to the left, follows the drag 1:1, and slides back out to the
/// left when it closes, so the movement always matches the gesture.
///
/// Lives in its own modifier because `MainView`'s presentation chain is already
/// at the limit of what the type-checker will resolve in a single expression.
struct AgentInboxSheetModifier: ViewModifier {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    /// False while another sheet owns the screen; the leading edge gesture
    /// must not fight the sidebar or settings.
    var canOpen: () -> Bool = { true }

    /// 0 = fully closed, 1 = fully open. Tracks the finger while a pan runs.
    @State private var progress: CGFloat = 0
    @State private var mounted = false
    @State private var dragging = false
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        if AgentInboxPlatform.isSupported {
            phoneBody(content)
        } else {
            content
        }
    }

    private func phoneBody(_ content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = max(proxy.size.width, 1) }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            width = max(newWidth, 1)
                        }
                }
            )
            .background(alignment: .leading) {
                // iPhone only: on iPad the same leading edge already pulls the
                // vertical tab sidebar in, and that gesture owns the edge.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    EdgePan(
                        enabled: !AgentInboxRouter.shared.isPresented,
                        canBegin: canOpen,
                        onBegan: beginOpening,
                        onChanged: updateOpening,
                        onEnded: finishOpening
                    )
                    .frame(width: 0, height: 0)
                }
            }
            .overlay {
                if mounted {
                    inbox
                        .offset(x: -width * (1 - progress))
                        .background(
                            CloseDrawerPan(
                                enabled: AgentInboxRouter.shared.isPresented,
                                onBegan: beginClosing,
                                onChanged: updateClosing,
                                onEnded: finishClosing
                            )
                            .frame(width: 0, height: 0)
                        )
                }
            }
            // `isPresented` can already be true on the first render — the island
            // deep link sets it while the scene is still being built — and
            // `onChange` never fires for an initial value. Reading it here (and
            // in `onAppear`) is what makes a cold launch from the island land on
            // the inbox instead of the terminal.
            .onAppear { sync(presented: AgentInboxRouter.shared.isPresented, animated: false) }
            .onChange(of: AgentInboxRouter.shared.isPresented) { _, presented in
                guard !dragging else { return }
                sync(presented: presented, animated: true)
            }
    }

    private var inbox: some View {
        AgentInboxView(onClose: { closeDrawer() }, embedsNavigation: true)
            .toolbarColorScheme(themeColors.map { $0.isDarkSurface ? .dark : .light } ?? colorScheme,
                                for: .navigationBar)
            .themedSheet(
                themeColors: themeColors,
                accentColor: accentColor,
                colorScheme: colorScheme
            )
    }

    // MARK: - Leading-edge open

    private func beginOpening() {
        guard !AgentInboxRouter.shared.isPresented else { return }
        dragging = true
        mounted = true
        progress = 0
    }

    private func updateOpening(_ translation: CGFloat) {
        guard dragging, !AgentInboxRouter.shared.isPresented else { return }
        progress = min(1, max(0, translation / width))
    }

    private func finishOpening(_ translation: CGFloat, _ velocity: CGFloat) {
        guard dragging, !AgentInboxRouter.shared.isPresented else {
            dragging = false
            return
        }
        dragging = false
        // A short flick should open even when the travel was small; a slow drag
        // that stopped before halfway should fall back.
        let projected = progress + velocity / width * 0.12
        if projected > 0.35 {
            openDrawer()
        } else {
            closeDrawer()
        }
    }

    // MARK: - Inbox swipe-left close

    private func beginClosing() {
        guard AgentInboxRouter.shared.isPresented else { return }
        dragging = true
    }

    private func updateClosing(_ translation: CGFloat) {
        guard dragging, AgentInboxRouter.shared.isPresented else { return }
        progress = max(0, min(1, 1 + translation / width))
    }

    private func finishClosing(_ translation: CGFloat, _ velocity: CGFloat) {
        guard dragging, AgentInboxRouter.shared.isPresented else {
            dragging = false
            return
        }
        dragging = false
        // Leftward velocity closes; a rightward flick returns to the inbox.
        if progress < 0.65 || velocity < -500 {
            closeDrawer()
        } else {
            openDrawer()
        }
    }

    // MARK: - State

    private func openDrawer() {
        mounted = true
        AgentInboxRouter.shared.isPresented = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            progress = 1
        }
    }

    private func closeDrawer() {
        AgentInboxRouter.shared.isPresented = false
        guard mounted else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            progress = 0
        } completion: {
            guard !AgentInboxRouter.shared.isPresented, progress == 0 else { return }
            mounted = false
        }
    }

    private func sync(presented: Bool, animated: Bool) {
        if presented {
            mounted = true
            if animated {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { progress = 1 }
            } else {
                progress = 1
            }
        } else if mounted {
            if animated {
                closeDrawer()
            } else {
                progress = 0
                mounted = false
            }
        }
    }
}

#if canImport(UIKit)
/// Window-level leading-edge pan. The terminal is a UIKit view that takes every
/// touch inside it, so this cannot be a SwiftUI `DragGesture`.
private struct EdgePan: UIViewRepresentable {
    let enabled: Bool
    let canBegin: () -> Bool
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, canBegin: canBegin,
                    onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view, attempts: 12)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.canBegin = canBegin
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.recognizer?.isEnabled = enabled
        context.coordinator.attach(from: uiView, attempts: 12)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        var canBegin: () -> Bool
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var host: UIView?
        private(set) var recognizer: UIScreenEdgePanGestureRecognizer?
        private var attached = false

        init(enabled: Bool, canBegin: @escaping () -> Bool,
             onBegan: @escaping () -> Void,
             onChanged: @escaping (CGFloat) -> Void,
             onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.enabled = enabled
            self.canBegin = canBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

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
                pan.delegate = self
                pan.isEnabled = self.enabled
                window.addGestureRecognizer(pan)
                self.host = window
                self.recognizer = pan
                self.attached = true
                inboxGestureLog.info("edge pan attached")
            }
        }

        func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
            attached = false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, canBegin(), recognizer?.state != .began else { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // Inward and clearly horizontal: a vertical drag near the edge is a
            // scroll, not the drawer.
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }

        @objc private func handle(_ pan: UIScreenEdgePanGestureRecognizer) {
            guard enabled, let view = pan.view else { return }
            let translation = pan.translation(in: view).x
            switch pan.state {
            case .began:
                onBegan()
            case .changed:
                onChanged(translation)
            case .ended, .cancelled, .failed:
                onEnded(translation, pan.velocity(in: view).x)
            default:
                break
            }
        }
    }
}

/// Page-level pan that only starts on a leftward horizontal drag. The pan has
/// to live on the page's own view controller, and it has to be allowed to run
/// alongside scrolling or vertical drags stop working.
private struct CloseDrawerPan: UIViewRepresentable {
    let enabled: Bool
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(from: view, attempts: 12)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.recognizer?.isEnabled = enabled
        context.coordinator.attach(from: uiView, attempts: 12)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var host: UIView?
        private(set) var recognizer: UIPanGestureRecognizer?
        private var attached = false
        private var began = false

        init(enabled: Bool,
             onBegan: @escaping () -> Void,
             onChanged: @escaping (CGFloat) -> Void,
             onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.enabled = enabled
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(from view: UIView, attempts: Int) {
            guard !attached, attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                guard let host = view.parentViewController?.view ?? view.window else {
                    self.attach(from: view, attempts: attempts - 1)
                    return
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(Self.handle(_:)))
                pan.delegate = self
                pan.cancelsTouchesInView = false
                pan.isEnabled = self.enabled
                host.addGestureRecognizer(pan)
                self.host = host
                self.recognizer = pan
                self.attached = true
                inboxGestureLog.info("close pan attached to \(type(of: host), privacy: .public)")
            }
        }

        func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
            attached = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Only a leftward horizontal drag belongs to the drawer; everything
            // else stays with the list's own scrolling.
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard enabled, let view = pan.view else { return }
            let translation = pan.translation(in: view).x
            let velocity = pan.velocity(in: view).x
            switch pan.state {
            case .began:
                began = true
                onBegan()
            case .changed:
                guard began else { return }
                onChanged(translation)
            case .ended, .cancelled, .failed:
                guard began else { return }
                began = false
                onEnded(translation, velocity)
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
