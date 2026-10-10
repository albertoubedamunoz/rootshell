//
//  ThemeGradientBackdropView.swift
//  rootshell
//
//  Theme Gradient window backdrop. Draws ThemeGradient.metal's shading into
//  its own Metal layer at a low frame rate and reduced resolution, outside
//  SwiftUI, so Drift costs little more than a still gradient.
//

import SwiftUI
import MetalKit
import UIKit
import os

/// Window backdrop view; falls back to the SwiftUI shader without Metal.
struct ThemeGradientBackdropView: View {
    @ObservedObject var effect: ThemeGradientEffect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metalUnavailable = false

    var body: some View {
        if metalUnavailable {
            ThemeGradientView(effect: effect)
        } else {
            ThemeGradientMetalView(palette: effect.palette,
                                   speed: effect.speed,
                                   drift: effect.drift && !reduceMotion,
                                   powerScale: PowerManager.shared.effectIntervalScale) {
                metalUnavailable = true
            }
            .allowsHitTesting(false)
        }
    }
}

private struct ThemeGradientMetalView: UIViewRepresentable {
    let palette: ThemeGradientPalette
    let speed: Double
    let drift: Bool
    let powerScale: Double
    let onUnavailable: () -> Void

    final class Coordinator {
        var renderer: ThemeGradientBackdropRenderer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ThemeGradientBackdropMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = ThemeGradientBackdropMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.backgroundColor = .clear
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.magnificationFilter = .linear
        }
        do {
            guard let device else { throw CocoaError(.featureUnsupported) }
            let renderer = try ThemeGradientBackdropRenderer(device: device, palette: palette)
            context.coordinator.renderer = renderer
            view.renderer = renderer
            view.delegate = renderer
            renderer.update(view: view, palette: palette, speed: speed, drift: drift, powerScale: powerScale)
        } catch {
            Logger(subsystem: "com.rootshell", category: "ThemeGradientBackdrop")
                .error("Using SwiftUI backdrop: \(String(describing: error), privacy: .public)")
            // Not inside makeUIView's update transaction
            Task { @MainActor in onUnavailable() }
        }
        return view
    }

    func updateUIView(_ view: ThemeGradientBackdropMTKView, context: Context) {
        context.coordinator.renderer?.update(view: view, palette: palette, speed: speed,
                                             drift: drift, powerScale: powerScale)
    }

    static func dismantleUIView(_ view: ThemeGradientBackdropMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.renderer = nil
        coordinator.renderer = nil
    }
}

// MARK: - View

/// Draws a still frame in any foreground scene; drifts only in the active one,
/// so unfocused windows and an inactive app cost nothing.
@MainActor
final class ThemeGradientBackdropMTKView: MTKView {
    weak var renderer: ThemeGradientBackdropRenderer?
    var wantsDrift = false
    private var sceneSuppressed = false
    private var appSuppressed = false
    private var redrawPending = false

    var canDraw: Bool {
        guard window != nil, !isHidden, let state = window?.windowScene?.activationState else { return false }
        return (state == .foregroundActive || state == .foregroundInactive)
            && UIApplication.shared.applicationState != .background
    }

    var canDrift: Bool {
        canDraw && !sceneSuppressed && !appSuppressed
            && window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillEnterForeground(_:)), name: UIScene.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillDeactivate), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidActivate), name: UIApplication.didBecomeActiveNotification, object: nil)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: ThemeGradientBackdropMTKView, _: UITraitCollection) in
            view.renderer?.resize(view)
            view.refreshActivity(redraw: true)
        }
    }
    required init(coder: NSCoder) { fatalError("ThemeGradientBackdropMTKView is created programmatically") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneSuppressed = window?.windowScene?.activationState != .foregroundActive
        appSuppressed = UIApplication.shared.applicationState != .active
        renderer?.resize(self)
        refreshActivity(redraw: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.resize(self)
        refreshActivity(redraw: true)
    }

    /// A running loop picks up changes on its next frame; a paused one draws once.
    func refreshActivity(redraw: Bool) {
        isPaused = !(wantsDrift && canDrift) || renderer == nil
        guard redraw, isPaused, renderer != nil, !redrawPending else { return }
        redrawPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.redrawPending = false
            if self.canDraw && self.renderer != nil { self.draw() }
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
    @objc private func sceneWillEnterForeground(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        // Changes made while in the background were never drawn
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

// MARK: - Renderer

/// Matches ThemeGradientBackdropUniforms in ThemeGradient.metal
private struct ThemeGradientBackdropUniforms {
    var size: SIMD2<Float>
    var pixelScale: Float
    var lightMode: Float
    var offsetsA: SIMD4<Float>
    var offsetsB: SIMD4<Float>
    var primary: SIMD4<Float>
    var accent: SIMD4<Float>
    var mid: SIMD4<Float>
}

@MainActor
final class ThemeGradientBackdropRenderer: NSObject, MTKViewDelegate {
    private enum Failure: Error { case unavailable(String) }

    /// Fraction of the screen's pixel density drawn; the gradient upscales invisibly.
    static let renderScale: CGFloat = 0.5
    /// Drift peaks around 40 pt/s, so a few points per frame reads as smooth.
    private static let driftFramesPerSecond = 10.0
    private static let crossfadeFramesPerSecond = 30

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let clock = ThemeGradientClock()
    private var palette: ThemeGradientPalette
    private var speed = 1.0
    private var drift = true
    private var driftFramesPerSecond = 10

    init(device: MTLDevice, palette: ThemeGradientPalette) throws {
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "themeGradientBackdropVertex"),
              let fragment = library.makeFunction(name: "themeGradientBackdropFragment") else {
            throw Failure.unavailable("Metal queue, library or functions")
        }
        queue.label = "Theme Gradient backdrop"
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "themeGradientBackdrop"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.palette = palette
        super.init()
        assert(MemoryLayout<ThemeGradientBackdropUniforms>.stride == 96)
    }

    func update(view: ThemeGradientBackdropMTKView, palette: ThemeGradientPalette,
                speed: Double, drift: Bool, powerScale: Double) {
        self.palette = palette
        self.speed = speed
        self.drift = drift
        let power = max(powerScale.isFinite ? powerScale : 1, 1)
        driftFramesPerSecond = max(1, Int((Self.driftFramesPerSecond / power).rounded()))
        view.preferredFramesPerSecond = clock.isCrossfading ? Self.crossfadeFramesPerSecond : driftFramesPerSecond
        view.wantsDrift = drift
        resize(view)
        view.refreshActivity(redraw: true)
    }

    func resize(_ view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : view.contentScaleFactor
        let size = CGSize(width: (view.bounds.width * scale * Self.renderScale).rounded(.up),
                          height: (view.bounds.height * scale * Self.renderScale).rounded(.up))
        if view.drawableSize != size { view.drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let view = view as? ThemeGradientBackdropMTKView, view.canDraw,
              view.bounds.width > 0, view.drawableSize.width > 0 else { return }
        let now = Date()
        let running = drift && view.canDrift
        let offsets = clock.offsets(at: now, speed: speed, running: running)
        let colors = clock.colors(for: palette, at: now, animated: running)
        // Palette crossfades get a smoother rate, then drop back
        let fps = clock.isCrossfading ? Self.crossfadeFramesPerSecond : driftFramesPerSecond
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }

        func color(_ c: SIMD3<Double>) -> SIMD4<Float> { SIMD4(Float(c.x), Float(c.y), Float(c.z), 1) }
        var uniforms = ThemeGradientBackdropUniforms(
            size: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
            pixelScale: Float(view.drawableSize.width / view.bounds.width),
            lightMode: palette.isLight ? 1 : 0,
            offsetsA: SIMD4(Float(offsets[0].x), Float(offsets[0].y), Float(offsets[1].x), Float(offsets[1].y)),
            offsetsB: SIMD4(Float(offsets[2].x), Float(offsets[2].y), Float(offsets[3].x), Float(offsets[3].y)),
            primary: color(colors[0]),
            accent: color(colors[1]),
            mid: color(colors[2]))

        autoreleasepool {
            guard let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer() else { return }
            pass.colorAttachments[0].loadAction = .dontCare
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ThemeGradientBackdropUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}
