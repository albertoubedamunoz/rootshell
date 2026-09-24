// JellyfishMetalView.swift
// rootshell

import SwiftUI
import MetalKit
import UIKit
import os

struct JellyfishMetalView: UIViewRepresentable {
    let effect: JellyfishEffect
    let state: JellyfishVisitState
    let showcase: Bool
    let powerScale: Double
    let reduceMotion: Bool
    let onUnavailable: () -> Void

    final class Coordinator {
        var renderer: JellyfishRenderer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> JellyfishMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = JellyfishMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer { layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        do {
            guard let device else { throw CocoaError(.featureUnsupported) }
            let renderer = try JellyfishRenderer(device: device, effect: effect, state: state)
            context.coordinator.renderer = renderer
            view.jellyfishRenderer = renderer
            view.delegate = renderer
            renderer.update(view: view, showcase: showcase, powerScale: powerScale, reduceMotion: reduceMotion)
        } catch {
            Logger(subsystem: "com.rootshell", category: "JellyfishRenderer")
                .error("Using Canvas jellyfish: \(String(describing: error), privacy: .public)")
            // Changing SwiftUI state during makeUIView would invalidate its
            // update transaction. Deliver fallback selection on the next turn.
            Task { @MainActor in onUnavailable() }
        }
        return view
    }

    func updateUIView(_ view: JellyfishMTKView, context: Context) {
        context.coordinator.renderer?.update(view: view, showcase: showcase,
                                             powerScale: powerScale, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: JellyfishMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.jellyfishRenderer = nil
        coordinator.renderer = nil
    }
}

/// The display loop belongs to the leaf view. An inactive scene cannot keep
/// rendering merely because a different rootshell window is still active.
@MainActor
final class JellyfishMTKView: MTKView {
    weak var jellyfishRenderer: JellyfishRenderer?
    var visitIdle = true
    private var sceneSuppressed = false
    private var appSuppressed = false
    private var redrawPending = false

    var canRender: Bool {
        window != nil && !isHidden && !sceneSuppressed && !appSuppressed
            && window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillDeactivate), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidActivate), name: UIApplication.didBecomeActiveNotification, object: nil)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: JellyfishMTKView, _: UITraitCollection) in
            view.jellyfishRenderer?.resize(view)
            view.refreshActivity(redraw: true)
        }
    }
    required init(coder: NSCoder) { fatalError("JellyfishMTKView is created programmatically") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneSuppressed = window?.windowScene?.activationState != .foregroundActive
        appSuppressed = UIApplication.shared.applicationState != .active
        jellyfishRenderer?.resize(self)
        refreshActivity(redraw: true)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        jellyfishRenderer?.resize(self)
        if isPaused { refreshActivity(redraw: true) }
    }
    func refreshActivity(redraw: Bool) {
        isPaused = !canRender || visitIdle || jellyfishRenderer == nil
        if redraw && canRender && jellyfishRenderer != nil && !redrawPending {
            redrawPending = true
            // Draw outside UIViewRepresentable's update transaction; a frame
            // may end a visit and publish isIdle back into SwiftUI.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.redrawPending = false
                if self.canRender && self.jellyfishRenderer != nil { self.draw() }
            }
        }
    }
    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        sceneSuppressed = true
        refreshActivity(redraw: false)
    }
    @objc private func sceneDidActivate(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        sceneSuppressed = false
        refreshActivity(redraw: true)
    }
    @objc private func appWillDeactivate() {
        appSuppressed = true
        refreshActivity(redraw: false)
    }
    @objc private func appDidActivate() {
        appSuppressed = false
        refreshActivity(redraw: true)
    }
}
