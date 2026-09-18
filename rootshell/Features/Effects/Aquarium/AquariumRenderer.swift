// AquariumRenderer.swift
// rootshell

import MetalKit
import QuartzCore
import os

/// MTKView invokes its delegate on the view's main-thread display loop. GPU
/// completion handlers touch only the semaphore/logger, never the scene or UI.
@MainActor
final class AquariumRenderer: NSObject, MTKViewDelegate {
    private struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let opaqueCount: Int
    }
    private struct Draw {
        let mesh: Int
        let instance: Int
    }
    private enum Failure: Error { case unavailable(String) }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shadowPipeline: MTLRenderPipelineState
    private let surfacePipeline: MTLRenderPipelineState
    private let finPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let thresholdPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let writeDepth: MTLDepthStencilState
    private let readDepth: MTLDepthStencilState
    private let noDepth: MTLDepthStencilState
    private let meshes: [Mesh]
    private let instanceBuffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: 3)
    private var bufferIndex = 0
    private static let instanceCapacity = 384

    private var sceneTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var shadowTexture: MTLTexture?
    private var textureSize = SIMD2<Int>.zero
    private var currentShadowSize = 0
    private var clock = AquariumClock()
    private var simulation = AquariumSimulation()
    private var environmentInstances: [AquariumInstance] = []
    private var environmentDraws: [Draw] = []
    private var environmentWidth: Float = 0
    private var environmentDensity: Double = -1
    private var configuration = AquariumConfiguration()
    private var palette = AquariumPalette.make(configuration: .init(), background: "#1e1e2e", palette: [])
    private var powerScale: Double = 1
    private var reduceMotion = false
    private let logger = Logger(subsystem: "com.rootshell.aquarium", category: "Renderer")

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            throw Failure.unavailable("Metal queue or default library is unavailable")
        }
        self.queue = queue
        queue.label = "Aquarium command queue"

        func pipeline(vertex: String, fragment: String?, format: MTLPixelFormat,
                      depth: Bool = false, blend: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment ?? vertex
            guard let v = library.makeFunction(name: vertex) else { throw Failure.unavailable(vertex) }
            descriptor.vertexFunction = v
            if let fragment {
                guard let f = library.makeFunction(name: fragment) else { throw Failure.unavailable(fragment) }
                descriptor.fragmentFunction = f
            }
            descriptor.depthAttachmentPixelFormat = depth ? .depth32Float : .invalid
            if format != .invalid {
                let color = descriptor.colorAttachments[0]!
                color.pixelFormat = format
                color.isBlendingEnabled = blend
                if blend {
                    color.sourceRGBBlendFactor = .one
                    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    color.sourceAlphaBlendFactor = .one
                    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        shadowPipeline = try pipeline(vertex: "aquariumShadowVertex", fragment: nil, format: .invalid, depth: true)
        surfacePipeline = try pipeline(vertex: "aquariumVertex", fragment: "aquariumSurfaceFragment", format: .rgba16Float, depth: true)
        finPipeline = try pipeline(vertex: "aquariumVertex", fragment: "aquariumSurfaceFragment", format: .rgba16Float, depth: true, blend: true)
        particlePipeline = try pipeline(vertex: "aquariumVertex", fragment: "aquariumParticleFragment", format: .rgba16Float, depth: true, blend: true)
        waterPipeline = try pipeline(vertex: "aquariumScreenVertex", fragment: "aquariumWaterFragment", format: .rgba16Float, depth: true)
        thresholdPipeline = try pipeline(vertex: "aquariumScreenVertex", fragment: "aquariumBloomThreshold", format: .rgba16Float)
        blurPipeline = try pipeline(vertex: "aquariumScreenVertex", fragment: "aquariumBloomBlur", format: .rgba16Float)
        compositePipeline = try pipeline(vertex: "aquariumScreenVertex", fragment: "aquariumComposite", format: .bgra8Unorm)

        func depthState(write: Bool, compare: MTLCompareFunction) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = write; d.depthCompareFunction = compare
            guard let state = device.makeDepthStencilState(descriptor: d) else { throw Failure.unavailable("Depth state") }
            return state
        }
        writeDepth = try depthState(write: true, compare: .lessEqual)
        readDepth = try depthState(write: false, compare: .lessEqual)
        noDepth = try depthState(write: false, compare: .always)

        let cpuMeshes = AquariumSpecies.allCases.map(AquariumGeometry.fish)
            + [AquariumGeometry.floor(), AquariumGeometry.rock(),
               AquariumGeometry.kelp(seed: 11), AquariumGeometry.kelp(seed: 29),
               AquariumGeometry.kelp(seed: 43), AquariumGeometry.billboard()]
        meshes = try cpuMeshes.enumerated().map { index, mesh in
            let vertexBuffer = mesh.vertices.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
            }
            let indexBuffer = mesh.indices.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
            }
            guard let vertexBuffer, let indexBuffer else { throw Failure.unavailable("Mesh buffer") }
            vertexBuffer.label = "Aquarium mesh \(index) vertices"
            indexBuffer.label = "Aquarium mesh \(index) indices"
            return Mesh(vertices: vertexBuffer, indices: indexBuffer,
                        indexCount: mesh.indices.count, opaqueCount: mesh.opaqueIndexCount)
        }
        instanceBuffers = try (0..<3).map { index in
            guard let buffer = device.makeBuffer(length: Self.instanceCapacity * MemoryLayout<AquariumInstance>.stride,
                                                 options: .storageModeShared) else { throw Failure.unavailable("Instance buffer") }
            buffer.label = "Aquarium instances \(index)"
            return buffer
        }
        super.init()
        assert(MemoryLayout<AquariumVertex>.stride == 48)
        assert(MemoryLayout<AquariumInstance>.stride == 96)
        assert(MemoryLayout<AquariumUniforms>.stride == 272)
    }

    func update(configuration: AquariumConfiguration, palette: AquariumPalette,
                powerScale: Double, reduceMotion: Bool, view: AquariumMTKView) {
        self.configuration = configuration.sanitized()
        self.palette = palette
        self.powerScale = max(powerScale.isFinite ? powerScale : 1, 1)
        self.reduceMotion = reduceMotion
        let quality = effectiveQuality
        view.preferredFramesPerSecond = max(15, Int(Double(quality.framesPerSecond) / self.powerScale))
        resize(view)
        view.freezeAnimation = reduceMotion || configuration.paused || configuration.speed == 0 || configuration.intensity == 0
        view.refreshActivity(redraw: true)
    }

    private var effectiveQuality: AquariumConfiguration.Quality {
        powerScale > 1 ? .economical : configuration.quality
    }

    func suspendClock() { clock.suspend() }

    func resize(_ view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let scale = min(max(Double(view.contentScaleFactor), 1), 2)
        let width = Double(view.bounds.width) * scale
        let height = Double(view.bounds.height) * scale
        let multiplier = min(1, sqrt(effectiveQuality.pixelBudget / max(width * height, 1)), 4096 / max(width, height))
        let size = CGSize(width: max(1, (width * multiplier).rounded(.down)),
                          height: max(1, (height * multiplier).rounded(.down)))
        if view.drawableSize != size { view.drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Attachment replacement happens lazily in draw, and submitted command
        // buffers retain old textures until the GPU has finished using them.
    }

    func draw(in view: MTKView) {
        guard let view = view as? AquariumMTKView, view.canRender,
              view.drawableSize.width >= 1, view.drawableSize.height >= 1 else { return }
        autoreleasepool { drawFrame(view) }
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable(label) }
        texture.label = label
        return texture
    }

    private func ensureTextures(width: Int, height: Int) throws {
        if textureSize != SIMD2(width, height) || sceneTexture == nil {
            // Build all replacements before publishing any of them.
            let color = try makeTexture(width: width, height: height, format: .rgba16Float, label: "Aquarium HDR")
            let depth = try makeTexture(width: width, height: height, format: .depth32Float, label: "Aquarium depth")
            let a = try makeTexture(width: max(1, width / 4), height: max(1, height / 4), format: .rgba16Float, label: "Aquarium bloom A")
            let b = try makeTexture(width: max(1, width / 4), height: max(1, height / 4), format: .rgba16Float, label: "Aquarium bloom B")
            sceneTexture = color; depthTexture = depth; bloomA = a; bloomB = b
            textureSize = SIMD2(width, height)
        }
        let shadowSize = effectiveQuality.shadowSize
        if currentShadowSize != shadowSize || shadowTexture == nil {
            shadowTexture = try makeTexture(width: shadowSize, height: shadowSize, format: .depth32Float, label: "Aquarium shadows")
            currentShadowSize = shadowSize
        }
    }

    private func rebuildEnvironment(halfWidth: Float) {
        guard abs(environmentWidth - halfWidth) > 0.02 || environmentDensity != configuration.kelpDensity else { return }
        environmentWidth = halfWidth; environmentDensity = configuration.kelpDensity
        var random = AquariumRandom(seed: 0x5EA_F00D)
        var records: [AquariumInstance] = []
        var draws: [Draw] = []
        func append(mesh: Int, position: SIMD3<Float>, scale: SIMD3<Float>, kind: Float, seed: Float) {
            draws.append(Draw(mesh: mesh, instance: records.count))
            records.append(AquariumInstance(model: .transform(position: position, scale: scale),
                                            parameters: SIMD4(kind, seed, 0, Float(configuration.currentStrength)),
                                            tint: SIMD4(1, 1, 1, 1)))
        }
        append(mesh: 5, position: .zero, scale: SIMD3(halfWidth + 2, 1, 1), kind: 5, seed: 0)
        for i in 0..<25 {
            let side: Float = i.isMultiple(of: 2) ? -1 : 1
            let x = i < 15 ? side * random.range(0.62, 1.0) * halfWidth : random.range(-halfWidth, halfWidth)
            let size = i < 15 ? random.range(0.45, 1.05) : random.range(0.10, 0.30)
            let z = random.range(-6.0, 1.9)
            append(mesh: 6, position: SIMD3(x, -2.71 + size * 0.2, z),
                   scale: SIMD3(size * random.range(1, 1.7), size * 0.73, size), kind: 7, seed: Float(i))
        }
        let plants = Int((configuration.kelpDensity * 38).rounded())
        for i in 0..<plants {
            let side: Float = i.isMultiple(of: 2) ? -1 : 1
            let back = i % 4 == 0
            let front = i % 7 == 0
            let x = back ? random.range(-0.95, 0.95) * halfWidth : side * random.range(front ? 0.90 : 0.64, 1.04) * halfWidth
            let z = back ? random.range(-6.7, -4.7) : (front ? random.range(1.3, 2.4) : random.range(-3.6, -1.0))
            let size = random.range(back ? 0.48 : 0.70, front ? 1.06 : 0.92)
            append(mesh: 7 + i % 3, position: SIMD3(x, -2.83, z),
                   scale: SIMD3(size, size, size), kind: 6, seed: random.range(0, 20))
        }
        // Contiguous records per mesh permit real instanced draws, including the shadow pass.
        let ordered = draws.sorted { $0.mesh < $1.mesh }
        environmentInstances = ordered.map { records[$0.instance] }
        environmentDraws = ordered.enumerated().map { Draw(mesh: $0.element.mesh, instance: $0.offset) }
    }

    private func addParticles(to instances: inout [AquariumInstance], draws: inout [Draw], time: Double, halfWidth: Float) {
        var random = AquariumRandom(seed: 0xB0BB_1E5)
        let count = (configuration.bubbles ? 36 : 0) + (configuration.particles ? 100 : 0)
        let bubbles = configuration.bubbles ? 36 : 0
        var records: [AquariumInstance] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let bubble = i < bubbles
            let seed = random.range(0, 1)
            let z = random.range(-5.5, 2.5)
            let speed = bubble ? random.range(0.035, 0.065) : random.range(0.003, 0.009)
            let phase = Float((Double(seed) + time * Double(speed)).truncatingRemainder(dividingBy: 1))
            let y = -3.4 + phase * 10.2
            let side: Float = i.isMultiple(of: 2) ? -1 : 1
            let anchor = bubble ? side * halfWidth * 0.78 : random.range(-halfWidth, halfWidth)
            let wobble = Float(sin(time * 0.5 + Double(seed) * 23)) * (bubble ? 0.09 : 0.16)
            let x = anchor + wobble + (bubble ? random.range(-0.16, 0.16) : 0)
            let size = bubble ? random.range(0.025, 0.061) : random.range(0.008, 0.019)
            let fade = min(max((y + 3.1) * 2, 0), 1) * min(max((6.4 - y) * 2, 0), 1)
            let alpha = (bubble ? 0.55 : 0.30) * fade
            records.append(AquariumInstance(model: .transform(position: SIMD3(x, y, z), scale: SIMD3(repeating: size)),
                                            parameters: SIMD4(bubble ? 8 : 9, seed, 0, 0), tint: SIMD4(1, 1, 1, alpha)))
        }
        // Back-to-front transparency, including the slight downward camera tilt.
        records.sort { $0.model.c3.z * 13 + $0.model.c3.y * 1.65 < $1.model.c3.z * 13 + $1.model.c3.y * 1.65 }
        for record in records {
            draws.append(Draw(mesh: 10, instance: instances.count))
            instances.append(record)
        }
    }

    private func drawFrame(_ view: AquariumMTKView) {
        // Never wait on the GPU on the terminal/UI thread. Drop the effect frame instead.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        do { try ensureTextures(width: width, height: height) }
        catch {
            logger.error("Aquarium attachment allocation failed: \(String(describing: error), privacy: .public)")
            view.freezeAnimation = true
            view.refreshActivity(redraw: false)
            return
        }
        guard let sceneTexture, let depthTexture, let bloomA, let bloomB, let shadowTexture,
              let drawable = view.currentDrawable, let outputPass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }
        command.label = "Aquarium frame"
        let delta = clock.advance(now: CACurrentMediaTime(), speed: configuration.speed,
                                  paused: reduceMotion || configuration.paused || configuration.intensity == 0)
        let halfWidth = max(2.1, Float(width) / Float(height) * 4.5)
        simulation.configure(count: configuration.fishCount, halfWidth: halfWidth)
        simulation.advance(delta: delta, current: Float(configuration.currentStrength))
        rebuildEnvironment(halfWidth: halfWidth)
        var instances = environmentInstances
        // Updating the current never rebuilds the plant meshes or changes their seed.
        for i in instances.indices where instances[i].parameters.x == 6 { instances[i].parameters.w = Float(configuration.currentStrength) }
        var solidDraws = environmentDraws
        let fishInstances = simulation.instances
        var fishDraws: [Draw] = []
        for species in AquariumSpecies.allCases {
            for i in fishInstances.indices where simulation.fish[i].species == species {
                let draw = Draw(mesh: species.rawValue, instance: instances.count)
                solidDraws.append(draw); fishDraws.append(draw); instances.append(fishInstances[i])
            }
        }
        fishDraws.sort {
            let a = instances[$0.instance].model.c3, b = instances[$1.instance].model.c3
            return a.z * 13 + a.y * 1.65 < b.z * 13 + b.y * 1.65
        }
        var particleDraws: [Draw] = []
        addParticles(to: &instances, draws: &particleDraws, time: clock.time, halfWidth: halfWidth)
        guard instances.count <= Self.instanceCapacity else { return }
        let instanceBuffer = instanceBuffers[bufferIndex]
        instances.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(instanceBuffer.contents(), base, raw.count) }
        }
        let camera = SIMD3<Float>(0, 2.4, 12)
        let viewMatrix = AquariumMatrix4.lookAt(eye: camera, target: SIMD3(0, 0.75, -1))
        let projection = AquariumMatrix4.orthographic(halfWidth: halfWidth, halfHeight: 4.5, near: 0.1, far: 32)
        let light = aqNormalize(SIMD3(Float(configuration.lightAngle) * 1.65, 1.8, 0.85))
        let lightCenter = SIMD3<Float>(0, 0.3, -1.5)
        let lightView = AquariumMatrix4.lookAt(eye: lightCenter + light * 19, target: lightCenter)
        let lightProjection = AquariumMatrix4.orthographic(halfWidth: halfWidth + 5, halfHeight: 9, near: 0.1, far: 40)
        let phase = Float(clock.time.truncatingRemainder(dividingBy: 512 * Double.pi))
        var uniforms = AquariumUniforms(
            viewProjection: projection * viewMatrix, lightProjection: lightProjection * lightView,
            cameraTime: aqV4(camera, phase), lightDirection: aqV4(light, Float(configuration.lightIntensity)),
            lightColor: aqV4(palette.light, 1), waterColor: aqV4(palette.water, 1), fillColor: aqV4(palette.fill, 1),
            viewport: SIMD4(Float(width), Float(height), 1 / Float(width), 1 / Float(height)),
            optics: SIMD4(Float(configuration.caustics), Float(configuration.haze), Float(configuration.exposure), Float(configuration.saturation)),
            composition: SIMD4(Float(configuration.intensity), Float(configuration.readingProtection), palette.isLight ? 1 : 0, Float(configuration.bloom)),
            environment: SIMD4(halfWidth, 1 / Float(currentShadowSize), Float(configuration.currentStrength), 0))

        func bind(_ encoder: MTLRenderCommandEncoder) {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AquariumUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AquariumUniforms>.stride, index: 2)
            encoder.setCullMode(.none)
        }
        func draw(_ encoder: MTLRenderCommandEncoder, _ item: Draw, finsOnly: Bool = false,
                  shadow: Bool = false, instanceCount: Int = 1) {
            let mesh = meshes[item.mesh]
            let count = shadow ? mesh.indexCount : (finsOnly ? mesh.indexCount - mesh.opaqueCount : mesh.opaqueCount)
            guard count > 0 else { return }
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: item.instance * MemoryLayout<AquariumInstance>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: finsOnly ? mesh.opaqueCount * 4 : 0,
                                          instanceCount: instanceCount)
        }
        func drawBatches(_ encoder: MTLRenderCommandEncoder, _ items: [Draw], shadow: Bool = false) {
            var start = 0
            while start < items.count {
                let item = items[start]
                var end = start + 1
                while end < items.count && items[end].mesh == item.mesh
                        && items[end].instance == item.instance + end - start { end += 1 }
                draw(encoder, item, shadow: shadow, instanceCount: end - start)
                start = end
            }
        }
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowTexture
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        guard let shadowEncoder = command.makeRenderCommandEncoder(descriptor: shadowPass) else { return }
        shadowEncoder.label = "Aquarium soft shadow map"
        shadowEncoder.setRenderPipelineState(shadowPipeline)
        shadowEncoder.setDepthStencilState(writeDepth)
        shadowEncoder.setDepthBias(0.001, slopeScale: 1.5, clamp: 0.01)
        bind(shadowEncoder)
        drawBatches(shadowEncoder, solidDraws, shadow: true)
        shadowEncoder.endEncoding()

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneTexture
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.depthAttachment.texture = depthTexture
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        encoder.label = "Aquarium HDR scene"
        bind(encoder)
        encoder.setDepthStencilState(noDepth)
        encoder.setRenderPipelineState(waterPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setDepthStencilState(writeDepth)
        encoder.setRenderPipelineState(surfacePipeline)
        encoder.setFragmentTexture(shadowTexture, index: 0)
        drawBatches(encoder, solidDraws)
        encoder.setDepthStencilState(readDepth)
        encoder.setRenderPipelineState(finPipeline)
        for item in fishDraws { draw(encoder, item, finsOnly: true) }
        encoder.setRenderPipelineState(particlePipeline)
        drawBatches(encoder, particleDraws)
        encoder.endEncoding()

        func postPass(target: MTLTexture, pipeline: MTLRenderPipelineState,
                      source: MTLTexture, direction: SIMD4<Float>? = nil) -> Bool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            e.setRenderPipelineState(pipeline)
            e.setFragmentTexture(source, index: 0)
            if var direction { e.setFragmentBytes(&direction, length: MemoryLayout<SIMD4<Float>>.stride, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
            return true
        }
        // Skip the expensive bloom work at zero, but always initialize the sampled texture.
        if configuration.bloom > 0 {
            guard postPass(target: bloomA, pipeline: thresholdPipeline, source: sceneTexture),
                  postPass(target: bloomB, pipeline: blurPipeline, source: bloomA, direction: SIMD4(1 / Float(bloomA.width), 0, 0, 0)),
                  postPass(target: bloomA, pipeline: blurPipeline, source: bloomB, direction: SIMD4(0, 1 / Float(bloomB.height), 0, 0)) else { return }
        } else {
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = bloomA
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let e = command.makeRenderCommandEncoder(descriptor: clear) else { return }
            e.endEncoding()
        }
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        guard let composite = command.makeRenderCommandEncoder(descriptor: outputPass) else { return }
        composite.label = "Aquarium theme-aware composite"
        composite.setRenderPipelineState(compositePipeline)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<AquariumUniforms>.stride, index: 2)
        composite.setFragmentTexture(sceneTexture, index: 0)
        composite.setFragmentTexture(bloomA, index: 1)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        let completionLogger = logger
        command.addCompletedHandler { completed in
            defer { semaphore.signal() }
            if let error = completed.error {
                completionLogger.error("Aquarium GPU frame failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        submitted = true
        bufferIndex = (bufferIndex + 1) % instanceBuffers.count
        command.commit()
    }
}
