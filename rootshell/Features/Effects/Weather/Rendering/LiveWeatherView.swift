// LiveWeatherView.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI
import MetalKit
import MediaAccessibility
import os

struct LiveWeatherView: View {
    @ObservedObject var effect: LiveWeatherEffect
    var showcase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimFlashingLights = MADimFlashingLightsEnabled()
    @State private var unavailable = false

    private struct HoldKey: Hashable {
        var selection: WeatherLocationSelection
        var fetching: Bool
    }

    var body: some View {
        let store = WeatherStore.shared
        let configuration = presentationConfiguration
        let selection = configuration.selection
        let input = WeatherSceneInput(
            coordinate: store.coordinate(for: selection), snapshot: store.snapshot(for: selection),
            configuration: configuration, previewCondition: effect.previewCondition, previewTime: effect.previewTime,
            isLight: effect.isLightBackground, reduceMotion: reduceMotion, dimFlashingLights: dimFlashingLights,
            powerScale: PowerManager.shared.effectIntervalScale)
        let fetching = scenePhase != .background && !configuration.demo
        ZStack {
            if unavailable {
                // A static sky if Metal can't start.
                LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.52), Color(red: 0.55, green: 0.66, blue: 0.78)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(configuration.intensity * 0.5)
            } else {
                WeatherMetalView(input: input) { unavailable = true }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: HoldKey(selection: selection, fetching: fetching)) {
            guard fetching else { return }
            await store.hold(selection)
        }
        .task {
            let name = Notification.Name(kMADimFlashingLightsChangedNotification as String)
            for await _ in NotificationCenter.default.notifications(named: name) {
                dimFlashingLights = MADimFlashingLightsEnabled()
            }
        }
    }

    private var presentationConfiguration: LiveWeatherConfiguration {
        var configuration = effect.configuration
        if showcase {
            configuration.intensity = 0.9
            configuration.readingProtection = 0
        }
        return configuration
    }
}

private struct WeatherMetalView: UIViewRepresentable {
    let input: WeatherSceneInput
    let onUnavailable: () -> Void

    final class Coordinator {
        var renderer: WeatherRenderer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WeatherMTKView {
        let gpu: WeatherGPUContext
        do {
            gpu = try WeatherGPUContext.shared()
        } catch {
            Logger(subsystem: "com.rootshell.weather", category: "Renderer")
                .error("Live Weather unavailable: \(String(describing: error), privacy: .public)")
            // Report after this update transaction.
            let report = onUnavailable
            Task { @MainActor in report() }
            return WeatherMTKView(frame: .zero, device: nil)
        }
        let view = WeatherMTKView(frame: .zero, device: gpu.device)
        view.colorPixelFormat = .bgra8Unorm // The shader encodes sRGB exactly once.
        view.depthStencilPixelFormat = .invalid
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            // The drawable is budget-sized; smooth the upscale.
            layer.magnificationFilter = .linear
        }
        let renderer = WeatherRenderer(context: gpu)
        context.coordinator.renderer = renderer
        view.weatherRenderer = renderer
        view.delegate = renderer
        renderer.update(input, view: view)
        return view
    }

    func updateUIView(_ view: WeatherMTKView, context: Context) {
        context.coordinator.renderer?.update(input, view: view)
    }

    static func dismantleUIView(_ view: WeatherMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.tearDown()
        view.delegate = nil
        view.weatherRenderer = nil
        coordinator.renderer = nil
    }
}
#endif
