// AquariumView.swift
// rootshell

import SwiftUI
import MetalKit
import QuartzCore
import UIKit
import os

struct AquariumView: View {
    @ObservedObject var effect: AquariumEffect
    var showcase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = effect.aquariumPalette
        let powerScale = PowerManager.shared.effectIntervalScale
        let configuration = presentationConfiguration
        ZStack {
            // A low-cost, noninteractive fallback remains if Metal initialization fails.
            LinearGradient(colors: [Color(red: 0.025, green: 0.09, blue: 0.12), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(configuration.intensity * 0.12)
            AquariumMetalView(configuration: configuration, palette: palette,
                              powerScale: powerScale, reduceMotion: reduceMotion)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    private var presentationConfiguration: AquariumConfiguration {
        var configuration = effect.configuration
        if showcase {
            configuration.intensity = 0.9
            configuration.readingProtection = 0
        }
        return configuration
    }
}

private struct AquariumMetalView: UIViewRepresentable {
    let configuration: AquariumConfiguration
    let palette: AquariumPalette
    let powerScale: Double
    let reduceMotion: Bool

    final class Coordinator {
        var renderer: AquariumRenderer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AquariumMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = AquariumMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm // Shader explicitly encodes sRGB, exactly once.
        view.depthStencilPixelFormat = .invalid
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer { layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        if let device {
            do {
                let renderer = try AquariumRenderer(device: device)
                context.coordinator.renderer = renderer
                view.aquariumRenderer = renderer
                view.delegate = renderer
                renderer.update(configuration: configuration, palette: palette,
                                powerScale: powerScale, reduceMotion: reduceMotion, view: view)
            } catch {
                Logger(subsystem: "com.rootshell.aquarium", category: "Renderer")
                    .error("Aquarium unavailable; using static water: \(String(describing: error), privacy: .public)")
            }
        }
        return view
    }
    func updateUIView(_ view: AquariumMTKView, context: Context) {
        context.coordinator.renderer?.update(configuration: configuration, palette: palette,
                                             powerScale: powerScale, reduceMotion: reduceMotion, view: view)
    }
    static func dismantleUIView(_ view: AquariumMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.aquariumRenderer?.suspendClock()
        view.delegate = nil
        view.aquariumRenderer = nil
        coordinator.renderer = nil
    }
}

/// Lifecycle observation is isolated to this leaf UIKit view, not MainView's
/// SwiftUI subtree. Observe the owning scene so another window cannot pause it.
@MainActor
final class AquariumMTKView: MTKView {
    weak var aquariumRenderer: AquariumRenderer?
    var freezeAnimation = false
    private var sceneSuppressed = false
    private var appSuppressed = false

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
    }
    required init(coder: NSCoder) { fatalError("AquariumMTKView is created programmatically") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneSuppressed = window?.windowScene?.activationState != .foregroundActive
        appSuppressed = UIApplication.shared.applicationState != .active
        aquariumRenderer?.resize(self)
        aquariumRenderer?.suspendClock()
        refreshActivity(redraw: true)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        aquariumRenderer?.resize(self)
        if isPaused { refreshActivity(redraw: true) }
    }
    func refreshActivity(redraw: Bool) {
        let nextPaused = !canRender || freezeAnimation || aquariumRenderer == nil
        if nextPaused != isPaused { aquariumRenderer?.suspendClock() }
        isPaused = nextPaused
        if redraw && canRender && aquariumRenderer != nil { draw() }
    }
    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        sceneSuppressed = true
        aquariumRenderer?.suspendClock()
        refreshActivity(redraw: false)
    }
    @objc private func sceneDidActivate(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
        sceneSuppressed = false
        refreshActivity(redraw: true)
    }
    @objc private func appWillDeactivate() {
        appSuppressed = true
        aquariumRenderer?.suspendClock()
        refreshActivity(redraw: false)
    }
    @objc private func appDidActivate() {
        appSuppressed = false
        refreshActivity(redraw: true)
    }
}
