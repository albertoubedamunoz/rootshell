//
//  TabHoverPreviewAnchor.swift
//  rootshell
//
//  Where a tab's hover preview should point. Each tab button / sidebar row
//  mounts an inert UIView behind itself and registers it here; the preview
//  card converts that view's bounds to window coordinates whenever it needs
//  the anchor, so scrolling, reflow and the sidebar's own hosting window all
//  resolve correctly without SwiftUI coordinate-space plumbing.
//

import SwiftUI
import UIKit

/// Which tab surface a hover came from; each mounts its own anchor per tab.
enum TabHoverPreviewSource: Hashable {
    case topBar
    case sidebar
}

@MainActor
final class TabHoverPreviewAnchorRegistry {
    private struct Key: Hashable {
        let tabID: UUID
        let source: TabHoverPreviewSource
    }

    private struct Weak {
        weak var view: TabHoverPreviewAnchorView?
    }

    /// Several anchors can share a key: the floating tab sidebar stays
    /// mounted off screen while closed, so a pinned column and the hidden
    /// floating copy both register every row. Lookup picks the visible one.
    private var anchors: [Key: [Weak]] = [:]

    func register(_ view: TabHoverPreviewAnchorView) {
        let key = Key(tabID: view.tabID, source: view.source)
        var list = anchors[key]?.filter { $0.view != nil && $0.view !== view } ?? []
        list.append(Weak(view: view))
        anchors[key] = list
    }

    func unregister(_ view: TabHoverPreviewAnchorView) {
        let key = Key(tabID: view.tabID, source: view.source)
        let list = anchors[key]?.filter { $0.view != nil && $0.view !== view } ?? []
        anchors[key] = list.isEmpty ? nil : list
    }

    /// The window and window-coordinate frame of an on-screen anchor for the
    /// tab; nil when no mounted button / row for it is visible.
    func windowFrame(for tabID: UUID, source: TabHoverPreviewSource) -> (window: UIWindow, frame: CGRect)? {
        for entry in anchors[Key(tabID: tabID, source: source)] ?? [] {
            guard let view = entry.view, let window = view.window,
                  view.bounds.width > 0, view.bounds.height > 0, view.isVisibleInHierarchy else { continue }
            let frame = view.convert(view.bounds, to: window)
            guard frame.intersects(window.bounds) else { continue }
            return (window, frame)
        }
        return nil
    }
}

private extension UIView {
    /// Not hidden or fully transparent anywhere up the chain (a closed
    /// floating panel is only transformed away, so the frame test above
    /// catches that case).
    var isVisibleInHierarchy: Bool {
        var current: UIView? = self
        while let view = current {
            if view.isHidden || view.alpha < 0.01 { return false }
            current = view.superview
        }
        return true
    }
}

/// Inert; never hit-tested so it can't steal the SwiftUI tab's hover or taps.
@MainActor
final class TabHoverPreviewAnchorView: UIView {
    var tabID: UUID
    var source: TabHoverPreviewSource
    weak var registry: TabHoverPreviewAnchorRegistry?

    init(tabID: UUID, source: TabHoverPreviewSource, registry: TabHoverPreviewAnchorRegistry) {
        self.tabID = tabID
        self.source = source
        self.registry = registry
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Mount as `.background` of a tab button or sidebar row.
struct TabHoverPreviewAnchor: UIViewRepresentable {
    let tabID: UUID
    let source: TabHoverPreviewSource
    let registry: TabHoverPreviewAnchorRegistry

    func makeUIView(context: Context) -> TabHoverPreviewAnchorView {
        let view = TabHoverPreviewAnchorView(tabID: tabID, source: source, registry: registry)
        registry.register(view)
        return view
    }

    func updateUIView(_ uiView: TabHoverPreviewAnchorView, context: Context) {
        guard uiView.tabID != tabID || uiView.source != source || uiView.registry !== registry else { return }
        uiView.registry?.unregister(uiView)
        uiView.tabID = tabID
        uiView.source = source
        uiView.registry = registry
        registry.register(uiView)
    }

    static func dismantleUIView(_ uiView: TabHoverPreviewAnchorView, coordinator: ()) {
        uiView.registry?.unregister(uiView)
    }
}
