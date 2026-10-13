// WeatherRenderer.swift
// rootshell

#if !CHINA_BUILD
import Metal
import QuartzCore
import Synchronization
import UIKit
import os

/// Everything the SwiftUI layer hands the renderer; the rest is derived per frame.
nonisolated struct WeatherSceneInput: Equatable, Sendable {
    var coordinate: WeatherCoordinate
    var snapshot: WeatherSnapshot?
    var configuration: LiveWeatherConfiguration
    var previewCondition: WeatherConditionKind?
    var previewTime: WeatherSkyGeometry.PreviewTime?
    var isLight: Bool
    var reduceMotion: Bool
    var dimFlashingLights: Bool
    var powerScale: Double
    /// Points the keyboard covers; the sky fits above them.
    var bottomInset: CGFloat
}

/// How much the scene is moving, which sets the frame rate.
nonisolated enum WeatherFrameDemand: Equatable, Sendable {
    case still      // paused; redrawn every 15 s as the sky turns
    case ambient    // drifting clouds, fog, twinkling stars, a transition
    case active     // rain, snow, lightning
}

/// Sun, moon, and sidereal orientation at the weather location.
nonisolated struct WeatherAstronomy {
    let date: Date
    let coordinate: WeatherCoordinate
    let sunAltitude: Double
    let sunAzimuth: Double
    let moonAltitude: Double
    let moonAzimuth: Double
    let moonIllumination: Double
    let sunAtGround: SIMD3<Float>
    let sunAtClouds: SIMD3<Float>

    init(date: Date, coordinate: WeatherCoordinate) {
        self.date = date
        self.coordinate = coordinate
        let sun = SolarCalculator.calculatePosition(date: date, latitude: coordinate.latitude, longitude: coordinate.longitude)
        let moon = MoonCalculator.calculateMoonData(date: date, latitude: coordinate.latitude, longitude: coordinate.longitude)
        sunAltitude = sun.altitude
        sunAzimuth = sun.azimuth
        moonAltitude = moon.position.altitude
        moonAzimuth = moon.position.azimuth
        moonIllumination = moon.phaseInfo.illumination
        let direction = WeatherSkyGeometry.direction(azimuth: sun.azimuth, altitude: sun.altitude)
        sunAtGround = WeatherSkyGeometry.sunTransmittance(direction: direction, height: 0)
        // Clouds keep catching light for a while after sunset.
        sunAtClouds = WeatherSkyGeometry.sunTransmittance(direction: direction, height: 2)
    }
}

/// What the main thread tells the renderer; read once per sync on the render thread.
nonisolated struct WeatherSurfaceState: Sendable {
    var input: WeatherSceneInput?
    var boundsHeight: CGFloat = 0
    /// The view's scene and the app are foreground-active.
    var active = false
    var redraw = false
}

/// Renders on EffectRenderThread, driven by a CAMetalDisplayLink, so frames
/// never block the main thread. Everything but `state` is confined to that
/// thread; GPU completion handlers touch only the semaphore and logger.
nonisolated final class WeatherRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private nonisolated struct TargetKey: Equatable {
        var fetchedAt: Date?
        var demoKind: WeatherConditionKind?
        var coordinate: WeatherCoordinate
    }
    private nonisolated enum Failure: Error { case unavailable(String) }

    private static let demoCycle: [WeatherConditionKind] = [
        .clear, .partlyCloudy, .cloudy, .drizzle, .rain, .heavyRain, .thunderstorm,
        .sleet, .snow, .heavySnow, .fog, .haze, .smoke, .windy
    ]
    private static let demoHold: Double = 12

    private let context: WeatherGPUContext
    private let layer: CAMetalLayer
    private let thread = EffectRenderThread.shared
    private let state = Mutex(WeatherSurfaceState())
    private let inFlight = DispatchSemaphore(value: 3)
    private let logger = Logger(subsystem: "com.rootshell.weather", category: "Renderer")
    private var input: WeatherSceneInput?
    private var boundsHeight: CGFloat = 0
    private var active = false
    private var demand = WeatherFrameDemand.ambient
    private var framesPerSecond = 0
    private var link: CAMetalDisplayLink?
    private var drawOnce = false
    private var stillTimer: Timer?
    private var releaseTimer: Timer?

    private var skyTexture: MTLTexture?
    private var cloudTextures: [MTLTexture] = []
    private var cloudIndex = 0
    private var textureSize = SIMD2<Int>.zero
    private var historyValid = false
    private var cloudsCleared = false
    private let skyPass = MTLRenderPassDescriptor()
    private let cloudPass = MTLRenderPassDescriptor()

    private var clock = WeatherClock()
    private var lastSkyTime = -Double.infinity
    private var skyAzimuth = Double.nan
    private var skyFraction = 1.0
    private var cloudFraction = 1.0
    private var sceneFraction = EffectSceneFraction()
    private var lastCloudTime = -Double.infinity
    private var cloudDrift = SIMD2<Double>.zero
    private var driftAtCloudRender = SIMD2<Double>.zero
    private var frameIndex: Float = 0

    private var astronomy: WeatherAstronomy?
    private var previewDate: Date?
    private var animator = WeatherVisualAnimator()
    private var displayed = WeatherVisualState()
    private var targetKey: TargetKey?
    private var lastTarget: WeatherVisualState?
    private var boltSegments: [LightningSegment] = []
    private var boltSeed: UInt64?

    init(context: WeatherGPUContext, layer: CAMetalLayer) {
        self.context = context
        self.layer = layer
        super.init()
        boltSegments.reserveCapacity(128)
        for pass in [skyPass, cloudPass] {
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
        }
        assert(MemoryLayout<LightningSegment>.stride == 32)
        thread.perform { [self] in attach() }
    }

    // MARK: Main thread

    /// Applies a main-thread change and has the render thread pick it up.
    func post(_ change: (inout WeatherSurfaceState) -> Void) {
        state.withLock { change(&$0) }
        thread.perform { [self] in sync() }
    }

    func stop() {
        thread.perform { [self] in
            link?.invalidate()
            link = nil
            stillTimer?.invalidate(); stillTimer = nil
            releaseTimer?.invalidate(); releaseTimer = nil
        }
    }

    /// The budget-sized drawable for a view of this size.
    static func drawableSize(bounds: CGSize, scale: CGFloat, input: WeatherSceneInput?) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(max(Double(scale), 1), 2)
        let width = Double(bounds.width) * scale
        let height = Double(bounds.height) * scale
        let multiplier = min(1, sqrt(effectiveQuality(input).pixelBudget / max(width * height, 1)), 4096 / max(width, height))
        return CGSize(width: max(1, (width * multiplier).rounded(.down)),
                      height: max(1, (height * multiplier).rounded(.down)))
    }

    private static func effectiveQuality(_ input: WeatherSceneInput?) -> LiveWeatherConfiguration.Quality {
        (input?.powerScale ?? 1) > 1 ? .economical : (input?.configuration.quality ?? .cinematic)
    }

    // MARK: Render thread

    private func attach() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.isPaused = true
        link.add(to: thread.runLoop, forMode: .default)
        self.link = link
        sync()
    }

    private func sync() {
        let posted = state.withLock { state in
            defer { state.redraw = false }
            return state
        }
        boundsHeight = posted.boundsHeight
        active = posted.active
        if let next = posted.input, next != input {
            let previous = input
            input = next
            if previous?.previewTime != next.previewTime || previous?.coordinate != next.coordinate
                || previous?.configuration.demo != next.configuration.demo {
                previewDate = nil
                astronomy = nil
                lastSkyTime = -.infinity
            }
            // Any input change may alter the clouds; re-render them on the next frame.
            lastCloudTime = -.infinity
        }
        refreshActivity(redraw: posted.redraw)
    }

    private func refreshActivity(redraw: Bool) {
        guard let link else { return }
        let running = active && input != nil && demand != .still
        link.isPaused = !running
        scheduleStillRedraws(active && input != nil && demand == .still)
        scheduleRelease(!active)
        if redraw && active && !running { drawNow() }
    }

    private func apply(_ demand: WeatherFrameDemand, framesPerSecond: Int) {
        if framesPerSecond != self.framesPerSecond, let link {
            self.framesPerSecond = framesPerSecond
            let fps = Float(framesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        }
        guard demand != self.demand else { return }
        self.demand = demand
        refreshActivity(redraw: false)
    }

    /// The layer's drawables belong to the link, so a still frame runs the
    /// paused link for one update.
    private func drawNow() {
        guard let link else { return }
        drawOnce = true
        link.isPaused = false
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        if active { autoreleasepool { drawFrame(update.drawable) } }
        guard drawOnce else { return }
        drawOnce = false
        link.isPaused = !(active && input != nil && demand != .still)
    }

    /// A still sky still turns: redraw it every 15 s without the display link.
    private func scheduleStillRedraws(_ enabled: Bool) {
        guard enabled else { stillTimer?.invalidate(); stillTimer = nil; return }
        guard stillTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.drawNow() }
        thread.runLoop.add(timer, forMode: .default)
        stillTimer = timer
    }

    /// Frees the size-dependent targets while the view is hidden for a while.
    private func scheduleRelease(_ enabled: Bool) {
        guard enabled else { releaseTimer?.invalidate(); releaseTimer = nil; return }
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.releaseTimer = nil
            guard !self.active else { return }
            self.skyTexture = nil
            self.cloudTextures = []
            self.textureSize = .zero
            self.historyValid = false
            self.cloudsCleared = false
        }
        thread.runLoop.add(timer, forMode: .default)
        releaseTimer = timer
    }

    // MARK: Frame

    private func drawFrame(_ drawable: CAMetalDrawable) {
        guard let input else { return }
        // Drop the frame rather than queue behind the GPU.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        let width = drawable.texture.width, height = drawable.texture.height
        guard width >= 1, height >= 1 else { return }
        do { try ensureTextures(width: width, height: height) } catch {
            logger.error("Live Weather attachments failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let skyTexture, cloudTextures.count == 2, let command = context.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        command.label = "Live Weather frame"

        let now = CACurrentMediaTime()
        let frozen = input.reduceMotion
        let delta = clock.advance(now: now, paused: frozen)
        let configuration = input.configuration
        let quality = Self.effectiveQuality(input)
        let wall = Date()
        // The sky fits above the keyboard and carries on beneath it.
        sceneFraction.retarget(EffectSceneFraction.visible(height: boundsHeight, bottomInset: input.bottomInset),
                               at: now, animated: !frozen)
        let fraction = sceneFraction.value(at: now)
        let reframing = sceneFraction.isAnimating(at: now)

        let date = renderDate(input, wall: wall)
        if astronomy == nil || astronomy?.coordinate != input.coordinate
            || abs((astronomy?.date ?? .distantPast).timeIntervalSince(date)) > 1 {
            astronomy = WeatherAstronomy(date: date, coordinate: input.coordinate)
        }
        guard let astronomy else { return }

        let (target, key) = weatherTarget(input, wall: wall)
        // A new fetch fades in, and so does a station report that changes the sky.
        let jumped = lastTarget.map { target.distance(to: $0) > 0.02 } ?? false
        if (targetKey != nil && targetKey != key) || jumped {
            animator.begin(from: displayed, at: now, duration: frozen ? 0 : (configuration.demo ? 3 : 45))
        }
        targetKey = key
        lastTarget = target
        displayed = animator.apply(target, at: now)
        let state = displayed

        let lightningEnabled = configuration.lightningFlashes && !frozen && !input.dimFlashingLights && state.lightning > 0.01
        var strike: LightningStrike?
        var flash = 0.0
        if lightningEnabled {
            let t = wall.timeIntervalSinceReferenceDate
            strike = LightningSchedule.activeStrike(at: t, rate: state.lightning)
            if let strike { flash = LightningSchedule.flash(at: t, strike: strike) }
        }

        let aspect = Double(width) / max(Double(height) * fraction, 1)
        let azimuth = WeatherSkyGeometry.cameraAzimuth(latitude: input.coordinate.latitude, sunAzimuth: astronomy.sunAzimuth,
                                                       sunAltitude: astronomy.sunAltitude, halfWidth: WeatherCamera.halfWidthDegrees(aspect: aspect))
        let camera = WeatherCamera(aspect: aspect, azimuth: azimuth)
        // Drift is exaggerated (tens of m/s) so it reads as motion behind text.
        let toward = SIMD2(state.windEast, -state.windNorth)
        let length = (toward * toward).sum().squareRoot()
        let heading = length > 0.001 ? toward / length : SIMD2(1, 0)
        cloudDrift += heading * (0.006 + 0.05 * state.windStrength) * delta
        if abs(cloudDrift.x) > 10_000 || abs(cloudDrift.y) > 10_000 {
            cloudDrift = .zero
            driftAtCloudRender = .zero
        }

        if let strike, strike.showsBolt, boltSeed != strike.seed {
            boltSeed = strike.seed
            LightningSchedule.buildBolt(seed: strike.seed, top: SIMD2(strike.position, strike.top),
                                        bottomY: 1.04, into: &boltSegments)
        }

        var uniforms = makeUniforms(input: input, state: state, astronomy: astronomy, camera: camera,
                                    flash: flash, strike: strike, fraction: fraction,
                                    width: width, height: height, quality: quality)

        let skyDue = now - lastSkyTime > 15 || skyAzimuth.isNaN || abs(WeatherSkyGeometry.wrap180(azimuth - skyAzimuth)) > 0.4
            || skyFraction != fraction
        if skyDue {
            encodeSky(command, target: skyTexture, uniforms: &uniforms)
            lastSkyTime = now
            skyAzimuth = azimuth
            skyFraction = fraction
        }

        let cloudsVisible = state.cloudLow > 0.003 || state.cloudHigh > 0.003
        // Clouds rendered for another scene height no longer line up.
        let reframed = cloudsVisible && cloudFraction != fraction
        if reframed { historyValid = false }
        var cloudPasses = 0
        if cloudsVisible {
            if reframing {
                cloudPasses = 1
            } else if frozen || reframed {
                // A still or newly settled frame accumulates several jittered passes at once.
                cloudPasses = (skyDue || lastCloudTime == -.infinity || animator.isActive(at: now) || reframed) ? 4 : 0
            } else if now - lastCloudTime >= 1 / quality.cloudRate || !historyValid {
                cloudPasses = 1
            }
        } else if !cloudsCleared {
            clearClouds(command)
        }
        // Cloud shifts are in scene uv; the cloud textures are in screen uv.
        let toScreen = SIMD2<Float>(1, Float(fraction))
        for _ in 0..<cloudPasses {
            var cloudUniforms = uniforms
            let shift = camera.cloudShift(world: SIMD2<Float>(cloudDrift - driftAtCloudRender)) * toScreen
            cloudUniforms.cloudShift = SIMD4(shift.x, shift.y, frameIndex, historyValid ? 1 : 0)
            encodeClouds(command, uniforms: &cloudUniforms)
            driftAtCloudRender = cloudDrift
            frameIndex += 1
        }
        if cloudPasses > 0 {
            lastCloudTime = now
            cloudFraction = fraction
        }

        let shift = camera.cloudShift(world: SIMD2<Float>(cloudDrift - driftAtCloudRender)) * toScreen
        uniforms.cloudShift = SIMD4(shift.x, shift.y, frameIndex, 0)
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Live Weather composite"
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 2)
        encoder.setFragmentTexture(skyTexture, index: 0)
        encoder.setFragmentTexture(cloudTextures[cloudIndex], index: 1)
        encoder.setFragmentTexture(context.shapeNoise, index: 2)
        encoder.setRenderPipelineState(context.compositePipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        let starsVisible = uniforms.atmosphere.w > 0.01
        if starsVisible {
            encoder.setRenderPipelineState(context.starPipeline)
            encoder.setVertexBuffer(context.stars, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: context.starCount)
        }
        if flash > 0.01, strike?.showsBolt == true, !input.isLight, !boltSegments.isEmpty {
            encoder.setRenderPipelineState(context.boltPipeline)
            boltSegments.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setVertexBytes(base, length: raw.count, index: 0) }
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: boltSegments.count)
        }
        if state.hasPrecipitation {
            encoder.setRenderPipelineState(context.particlePipeline)
            let rain = Float(quality.maxRaindrops) * Float(min(state.rain * 1.15, 1) * (1 - state.sleetMix * 0.5))
            let pellets = Float(quality.maxRaindrops) * Float(0.4 * max(state.rain, state.snow) * state.sleetMix)
            let snow = Float(quality.maxSnowflakes) * Float(min(state.snow * 1.1, 1))
            for (kind, count) in [(Float(0), rain), (Float(2), pellets), (Float(1), snow)] where count >= 0.5 {
                var parameters = SIMD4<Float>(kind, count, 0, 0)
                encoder.setVertexBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: Int(count.rounded(.up)))
            }
        }
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        let completionLogger = logger
        command.addCompletedHandler { completed in
            defer { semaphore.signal() }
            if let error = completed.error {
                completionLogger.error("Live Weather GPU frame failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        submitted = true
        command.commit()

        let demand: WeatherFrameDemand
        if frozen {
            demand = .still
        } else if state.hasPrecipitation || flash > 0 || lightningEnabled || reframing {
            demand = .active
        } else if animator.isActive(at: now) || cloudsVisible || state.fog > 0.02 || starsVisible || configuration.demo {
            demand = .ambient
        } else {
            demand = .still
        }
        let base = demand == .active ? quality.activeFramesPerSecond : quality.ambientFramesPerSecond
        apply(demand, framesPerSecond: max(8, Int(Double(base) / max(input.powerScale, 1))))
    }

    // MARK: Scene

    private func renderDate(_ input: WeatherSceneInput, wall: Date) -> Date {
        guard input.configuration.demo, let preview = input.previewTime else { return wall }
        if let previewDate { return previewDate }
        let coordinate = input.coordinate
        let date = WeatherSkyGeometry.previewDate(preview, around: wall) {
            SolarCalculator.calculatePosition(date: $0, latitude: coordinate.latitude, longitude: coordinate.longitude).altitude
        }
        previewDate = date
        return date
    }

    private func weatherTarget(_ input: WeatherSceneInput, wall: Date) -> (WeatherVisualState, TargetKey) {
        if input.configuration.demo {
            let index = Int(clock.time / Self.demoHold) % Self.demoCycle.count
            let kind = input.previewCondition ?? Self.demoCycle[index]
            return (.target(for: WeatherVisualState.demoSample(kind, date: wall)),
                    TargetKey(fetchedAt: nil, demoKind: kind, coordinate: input.coordinate))
        }
        if let snapshot = input.snapshot {
            return (WeatherTimeline.target(at: wall, snapshot: snapshot),
                    TargetKey(fetchedAt: snapshot.fetchedAt, demoKind: nil, coordinate: snapshot.coordinate))
        }
        return (WeatherVisualState(), TargetKey(fetchedAt: nil, demoKind: nil, coordinate: input.coordinate))
    }

    private func makeUniforms(input: WeatherSceneInput, state: WeatherVisualState, astronomy: WeatherAstronomy,
                              camera: WeatherCamera, flash: Double, strike: LightningStrike?, fraction: Double,
                              width: Int, height: Int, quality: LiveWeatherConfiguration.Quality) -> WeatherUniforms {
        let configuration = input.configuration
        let coordinate = input.coordinate
        let sunAltitude = astronomy.sunAltitude
        let sun = WeatherSkyGeometry.direction(azimuth: astronomy.sunAzimuth, altitude: sunAltitude)
        let moon = WeatherSkyGeometry.direction(azimuth: astronomy.moonAzimuth, altitude: astronomy.moonAltitude)
        let moonVisible = Float(astronomy.moonIllumination * WeatherSkyGeometry.smoothstep(-2, 1, astronomy.moonAltitude))
        let exposure = WeatherSkyGeometry.exposure(sunAltitude: sunAltitude)
        let moonKey = SIMD3<Float>(0.55, 0.62, 0.78) * (20 * 0.0006 * moonVisible)
        let keyWeight = Float(WeatherSkyGeometry.smoothstep(-6, -1, sunAltitude))
        var key = moon + (sun - moon) * keyWeight
        let keyLength = (key * key).sum().squareRoot()
        key = keyLength > 0.001 ? key / keyLength : sun
        let stars = configuration.showStars && !input.isLight
        let starVisibility = stars ? Float(WeatherSkyGeometry.starVisibility(sunAltitude: sunAltitude)) : 0
        let milkyWay = starVisibility * starVisibility * (1 - moonVisible * 0.6)
        let rows = WeatherSkyGeometry.equatorialRows(date: astronomy.date, latitude: coordinate.latitude, longitude: coordinate.longitude)
        let pole = WeatherSkyGeometry.apply(rows, WeatherSkyGeometry.galacticNorthPole)
        let center = WeatherSkyGeometry.apply(rows, WeatherSkyGeometry.galacticCenter)
        let windWorld = SIMD3<Float>(Float(state.windEast), 0, Float(-state.windNorth))
        let windX = (windWorld * camera.right).sum()
        let dayLight = Float(WeatherSkyGeometry.smoothstep(-8, 6, sunAltitude))
        let flashLevel = Float(flash)
        let rainColor: SIMD3<Float> = input.isLight
            ? SIMD3(0.16, 0.20, 0.28)
            : SIMD3(0.70, 0.76, 0.86) * (0.7 + 0.3 * dayLight + 0.6 * flashLevel)
        let snowColor: SIMD3<Float> = input.isLight
            ? SIMD3(0.40, 0.46, 0.56)
            : SIMD3(0.92, 0.94, 0.98) * (0.75 + 0.25 * dayLight + 0.4 * flashLevel)
        let strikeUniform = strike.map { SIMD4<Float>($0.position, $0.top + 0.04, 0.16, flashLevel * 0.8 / exposure) } ?? .zero
        let sunRadius: Float = 1.5 * .pi / 180
        let moonRadius: Float = 1.7 * .pi / 180
        return WeatherUniforms(
            cameraForward: wxV4(camera.forward, camera.tanHalfWidth),
            cameraRight: wxV4(camera.right, camera.tanHalfHeight),
            cameraUp: wxV4(camera.up, Float(clock.time.truncatingRemainder(dividingBy: 4_096))),
            sunDirection: wxV4(sun, Float(sunAltitude * .pi / 180)),
            moonDirection: wxV4(moon, moonVisible),
            sunRadiance: wxV4(astronomy.sunAtGround * 20, sunRadius),
            keyLight: wxV4(key, moonRadius),
            keyColor: wxV4(astronomy.sunAtClouds * 20 + moonKey, exposure),
            clouds: SIMD4(Float(state.cloudLow), Float(state.cloudHigh), Float(state.cloudDensity), Float(state.towering)),
            precipitation: SIMD4(Float(state.rain), Float(state.snow), Float(state.sleetMix), Float(state.gustiness)),
            atmosphere: SIMD4(Float(state.fog), Float(state.haze), flashLevel, starVisibility),
            hazeTint: SIMD4(Float(state.hazeTint.x), Float(state.hazeTint.y), Float(state.hazeTint.z), milkyWay),
            wind: SIMD4(Float(cloudDrift.x), Float(cloudDrift.y), windX, Float(state.windStrength)),
            cloudShift: .zero,
            strike: strikeUniform,
            viewport: SIMD4(Float(width), Float(height), 1 / Float(width), 1 / Float(height)),
            composition: SIMD4(Float(configuration.intensity), Float(configuration.readingProtection),
                               input.isLight ? 1 : 0, configuration.showSunAndMoon ? 1 : 0),
            equatorialX: wxV4(rows.0, 0), equatorialY: wxV4(rows.1, 0), equatorialZ: wxV4(rows.2, 0),
            galaxy: wxV4(pole, Float(quality.cloudSteps)),
            galaxyCenter: wxV4(center, 0),
            rainColor: wxV4(rainColor, 0),
            snowColor: wxV4(snowColor, 0),
            scene: SIMD4(Float(fraction), Float(1 / fraction), 0, 0))
    }

    // MARK: Passes

    private func makeTexture(width: Int, height: Int, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable(label) }
        texture.label = label
        return texture
    }

    private func ensureTextures(width: Int, height: Int) throws {
        guard textureSize != SIMD2(width, height) || skyTexture == nil || cloudTextures.count != 2 else { return }
        // Build every replacement before publishing any of them.
        let sky = try makeTexture(width: max(8, width / 4), height: max(8, height / 4), label: "Weather sky")
        let a = try makeTexture(width: max(8, width / 2), height: max(8, height / 2), label: "Weather clouds A")
        let b = try makeTexture(width: max(8, width / 2), height: max(8, height / 2), label: "Weather clouds B")
        skyTexture = sky
        cloudTextures = [a, b]
        textureSize = SIMD2(width, height)
        historyValid = false
        cloudsCleared = false
        lastSkyTime = -.infinity
        lastCloudTime = -.infinity
    }

    private func encodeSky(_ command: MTLCommandBuffer, target: MTLTexture, uniforms: inout WeatherUniforms) {
        skyPass.colorAttachments[0].texture = target
        guard let encoder = command.makeRenderCommandEncoder(descriptor: skyPass) else { return }
        encoder.label = "Live Weather sky"
        encoder.setRenderPipelineState(context.skyPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 2)
        encoder.setFragmentTexture(context.shapeNoise, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeClouds(_ command: MTLCommandBuffer, uniforms: inout WeatherUniforms) {
        guard let skyTexture else { return }
        let history = cloudTextures[cloudIndex]
        let target = cloudTextures[1 - cloudIndex]
        cloudPass.colorAttachments[0].texture = target
        guard let encoder = command.makeRenderCommandEncoder(descriptor: cloudPass) else { return }
        encoder.label = "Live Weather clouds"
        encoder.setRenderPipelineState(context.cloudPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 2)
        encoder.setFragmentTexture(context.shapeNoise, index: 0)
        encoder.setFragmentTexture(context.detailNoise, index: 1)
        encoder.setFragmentTexture(skyTexture, index: 2)
        encoder.setFragmentTexture(history, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cloudIndex = 1 - cloudIndex
        historyValid = true
        cloudsCleared = false
    }

    private func clearClouds(_ command: MTLCommandBuffer) {
        for texture in cloudTextures {
            cloudPass.colorAttachments[0].texture = texture
            cloudPass.colorAttachments[0].loadAction = .clear
            cloudPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            command.makeRenderCommandEncoder(descriptor: cloudPass)?.endEncoding()
        }
        cloudPass.colorAttachments[0].loadAction = .dontCare
        cloudsCleared = true
        historyValid = false
    }
}

/// Hosts the renderer's CAMetalLayer and reports layout and activity to it.
/// It watches its own scene, so another window can't pause it.
final class WeatherSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var renderer: WeatherRenderer?
    private var input: WeatherSceneInput?
    private var sceneSuppressed = false
    private var appSuppressed = false
    private var postedHeight: CGFloat = -1

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var canRender: Bool {
        window != nil && !isHidden && !sceneSuppressed && !appSuppressed
            && window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    /// A nil `context` makes an inert view for when Metal is unavailable.
    init(context: WeatherGPUContext?) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        guard let context else { return }
        metalLayer.device = context.device
        metalLayer.pixelFormat = .bgra8Unorm // The shader encodes sRGB exactly once.
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // The drawable is budget-sized; smooth the upscale.
        metalLayer.magnificationFilter = .linear
        renderer = WeatherRenderer(context: context, layer: metalLayer)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillDeactivate), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidActivate), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    required init(coder: NSCoder) { fatalError("WeatherSurfaceView is created programmatically") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(_ input: WeatherSceneInput) {
        let previous = self.input
        guard input != previous else { return }
        self.input = input
        if previous?.configuration.quality != input.configuration.quality || previous?.powerScale != input.powerScale {
            resizeDrawable()
        }
        renderer?.post { $0.input = input; $0.redraw = true }
    }

    func tearDown() {
        renderer?.post { $0.active = false }
        renderer?.stop()
        renderer = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneSuppressed = window?.windowScene?.activationState != .foregroundActive
        appSuppressed = UIApplication.shared.applicationState != .active
        resizeDrawable()
        refreshActivity(redraw: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layout passes during scrolling leave the size alone; only a change redraws.
        let height = bounds.height
        guard resizeDrawable() || height != postedHeight else { return }
        postedHeight = height
        renderer?.post { $0.boundsHeight = height; $0.redraw = true }
    }

    /// Returns whether the drawable size changed.
    @discardableResult
    private func resizeDrawable() -> Bool {
        guard renderer != nil else { return false }
        let size = WeatherRenderer.drawableSize(bounds: bounds.size, scale: contentScaleFactor, input: input)
        guard size.width >= 1, metalLayer.drawableSize != size else { return false }
        metalLayer.drawableSize = size
        return true
    }

    private func refreshActivity(redraw: Bool) {
        let active = canRender
        let height = bounds.height
        renderer?.post {
            $0.active = active
            $0.boundsHeight = height
            if redraw { $0.redraw = true }
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
#endif
