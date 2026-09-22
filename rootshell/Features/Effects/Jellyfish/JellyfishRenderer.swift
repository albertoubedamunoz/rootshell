// JellyfishRenderer.swift
// rootshell

import MetalKit
import UIKit
import os

@MainActor
final class JellyfishRenderer: NSObject, @preconcurrency MTKViewDelegate {
    private enum Failure: Error { case unavailable(String) }
    private struct Draw {
        var instance: JellyfishInstance
        var ribbons: Range<Int>
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let membrane: MTLRenderPipelineState
    private let ribbon: MTLRenderPipelineState
    private let core: MTLRenderPipelineState
    private let mote: MTLRenderPipelineState
    private let threshold: MTLRenderPipelineState
    private let blur: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let bellVertices: MTLBuffer
    private let bellIndices: MTLBuffer
    private let bellIndexCount: Int
    private let ribbonBuffers: [MTLBuffer]
    private static let vertexCapacity = 100_000
    private let inFlight = DispatchSemaphore(value: 3)
    private var bufferIndex = 0
    private var vertices: [JellyfishVertex] = []
    private var draws: [Draw] = []
    private var scene: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var textureSize = SIMD2<Int>.zero

    private let effect: JellyfishEffect
    private let state: JellyfishVisitState
    private var showcase = false
    private var economical = false
    private var reportedFailure = false
    private let logger = Logger(subsystem: "com.rootshell", category: "JellyfishRenderer")

    init(device: MTLDevice, effect: JellyfishEffect, state: JellyfishVisitState,
         library: MTLLibrary? = nil) throws {
        self.device = device; self.effect = effect; self.state = state
        guard let queue = device.makeCommandQueue(), let library = library ?? device.makeDefaultLibrary() else {
            throw Failure.unavailable("Metal queue or library")
        }
        self.queue = queue
        queue.label = "Jellyfish command queue"
        func pipeline(_ vertex: String, _ fragment: String, output: Bool = false, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw Failure.unavailable(fragment)
            }
            d.vertexFunction = v; d.fragmentFunction = f
            let color = d.colorAttachments[0]!
            color.pixelFormat = output ? .bgra8Unorm : .rgba16Float
            color.isBlendingEnabled = blend
            if blend {
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        membrane = try pipeline("jellyfishBellVertex", "jellyfishMembrane", blend: true)
        ribbon = try pipeline("jellyfishRibbonVertex", "jellyfishRibbon", blend: true)
        core = try pipeline("jellyfishCoreVertex", "jellyfishCore", blend: true)
        mote = try pipeline("jellyfishMoteVertex", "jellyfishMote", blend: true)
        threshold = try pipeline("jellyfishScreenVertex", "jellyfishBloomThreshold")
        blur = try pipeline("jellyfishScreenVertex", "jellyfishBloomBlur")
        composite = try pipeline("jellyfishScreenVertex", "jellyfishComposite", output: true)

        let mesh = JellyfishGeometry.bell()
        func buffer<T>(_ array: [T]) throws -> MTLBuffer {
            guard let result = array.withUnsafeBytes({ bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }) else { throw Failure.unavailable("Geometry buffer") }
            return result
        }
        bellVertices = try buffer(mesh.vertices)
        bellIndices = try buffer(mesh.indices)
        bellIndexCount = mesh.indices.count
        ribbonBuffers = try (0..<3).map { index in
            guard let b = device.makeBuffer(length: Self.vertexCapacity * MemoryLayout<JellyfishVertex>.stride,
                                             options: .storageModeShared) else { throw Failure.unavailable("Ribbon buffer") }
            b.label = "Jellyfish ribbons \(index)"
            return b
        }
        super.init()
        vertices.reserveCapacity(Self.vertexCapacity)
        draws.reserveCapacity(JellyfishVisitState.maximumPopulation)
        assert(MemoryLayout<JellyfishVertex>.stride == 32)
        assert(MemoryLayout<JellyfishInstance>.stride == 80)
        assert(MemoryLayout<JellyfishUniforms>.stride == 32)
    }

    func update(view: JellyfishMTKView, showcase: Bool, powerScale: Double, reduceMotion: Bool) {
        self.showcase = showcase
        let power = max(powerScale.isFinite ? powerScale : 1, 1)
        economical = power > 1 || reduceMotion
        view.preferredFramesPerSecond = max(15, Int((reduceMotion ? 30.0 : 60.0) / power))
        view.visitIdle = state.isIdle || (!showcase && effect.intensity <= 0)
        resize(view)
        view.refreshActivity(redraw: true)
    }

    func resize(_ view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : view.contentScaleFactor
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        let size = JellyfishRenderResolution.drawableSize(bounds: view.bounds.size, displayScale: scale)
        if view.drawableSize != size { view.drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let view = view as? JellyfishMTKView, view.canRender,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        // Never block terminal input waiting for the GPU. Three buffers keep
        // geometry immutable until its command buffer has completed.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        autoreleasepool {
            guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
            let time = state.frameTime(at: .now)
            state.update(frameTime: time)
            do {
                try encode(jellies: state.jellies, time: time, size: view.bounds.size,
                           output: drawable.texture, command: command)
            } catch {
                if !reportedFailure {
                    logger.error("Jellyfish frame unavailable: \(String(describing: error), privacy: .public)")
                    reportedFailure = true
                }
                return
            }
            command.present(drawable)
            let semaphore = inFlight, completionLogger = logger
            command.addCompletedHandler { completed in
                defer { semaphore.signal() }
                if let error = completed.error {
                    completionLogger.error("Jellyfish GPU frame failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            submitted = true
            bufferIndex = (bufferIndex + 1) % ribbonBuffers.count
            command.commit()
            // The last visit submits a transparent frame before suspending.
            view.visitIdle = state.isIdle || (!showcase && effect.intensity <= 0)
            view.refreshActivity(redraw: false)
        }
    }

    private func ensureTextures(width: Int, height: Int) throws {
        guard textureSize != SIMD2(width, height) || scene == nil else { return }
        func texture(_ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw Failure.unavailable(label) }
            t.label = label
            return t
        }
        // Publish replacements together; in-flight frames retain old textures.
        let newScene = try texture(width, height, "Jellyfish HDR tissue")
        let a = try texture(max(1, width / 4), max(1, height / 4), "Jellyfish bloom A")
        let b = try texture(max(1, width / 4), max(1, height / 4), "Jellyfish bloom B")
        scene = newScene; bloomA = a; bloomB = b
        textureSize = SIMD2(width, height)
    }

    /// The same encoder is usable for deterministic, offscreen GPU validation.
    /// Callers outside the display loop must wait for completion before reuse.
    func encode(jellies: [Jellyfish], time: TimeInterval, size: CGSize,
                output: MTLTexture, command: MTLCommandBuffer) throws {
        guard size.width > 0, size.height > 0 else { throw Failure.unavailable("Empty viewport") }
        let isLight = effect.isLightBackground
        let opacity = showcase ? 1 : min(max(effect.intensity.isFinite ? effect.intensity / 0.6 : 0, 0), 1)
        if jellies.isEmpty || opacity == 0 {
            try clear(output: output, command: command)
            return
        }
        let bloom = isLight ? 0 : min(max(effect.bloom.isFinite ? effect.bloom : 0, 0), 1)
        var uniforms = JellyfishUniforms(viewport: SIMD4(Float(size.width), Float(size.height), Float(output.width), Float(output.height)),
                                         composition: SIMD4(Float(opacity), isLight ? 1 : 0, Float(bloom), 0))
        vertices.removeAll(keepingCapacity: true)
        draws.removeAll(keepingCapacity: true)
        // Distant creatures first; each bell then draws rear shell, anatomy,
        // and front shell in order, without opaque depth hiding its organs.
        for jelly in jellies.sorted(by: { $0.visualDepth < $1.visualDepth }).prefix(JellyfishVisitState.maximumPopulation) {
            guard time >= jelly.spawnFrameTime else { continue }
            let position = jelly.renderPosition(at: time, in: size)
            let pad = jelly.bellRadius * 8 + 40
            guard position.x > -pad, position.x < size.width + pad,
                  position.y > -pad, position.y < size.height + pad else { continue }
            let t = jelly.bellTransform(at: time, in: size)
            let tint = effect.linearTint(colorIndex: jelly.colorIndex)
            let shimmer = !isLight && effect.shimmerEnabled && !jelly.calmDrift ? jelly.shimmer(at: time) : nil
            let age = time - jelly.spawnFrameTime
            let appearance = Jellyfish.smootherstep(0, 1.8, age)
            let depth = Float((0.65 + jelly.visualDepth * 0.35) * appearance)
            let instance = JellyfishInstance(
                axisX: SIMD4(Float(t.a), Float(t.c), Float(t.tx), Float(jelly.bellRadius)),
                axisY: SIMD4(Float(t.b), Float(t.d), Float(t.ty), 0),
                tint: SIMD4(tint.x, tint.y, tint.z, depth),
                motion: SIMD4(Float(jelly.pulseValue(at: time) * (jelly.calmDrift ? 0.15 : 1)),
                              Float(age), Float(shimmer?.head ?? -1), Float(shimmer?.strength ?? 0)),
                anatomy: SIMD4(Float(jelly.opticalTilt(at: time)),
                               Float(jelly.pulsePhase0), jelly.calmDrift ? 1 : 0, 0))
            let start = vertices.count
            JellyfishGeometry.appendChains(of: jelly, time: time, size: size, economical: economical, to: &vertices)
            guard vertices.count <= Self.vertexCapacity else { throw Failure.unavailable("Ribbon capacity") }
            draws.append(Draw(instance: instance, ribbons: start..<vertices.count))
        }
        guard !draws.isEmpty else {
            try clear(output: output, command: command)
            return
        }
        try ensureTextures(width: output.width, height: output.height)
        guard let scene, let bloomA, let bloomB else { throw Failure.unavailable("Scene textures") }
        let ribbonBuffer = ribbonBuffers[bufferIndex]
        if !vertices.isEmpty {
            vertices.withUnsafeBytes { bytes in
                ribbonBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        func pass(_ target: MTLTexture, clear: Bool = false) throws -> MTLRenderCommandEncoder {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = target
            p.colorAttachments[0].loadAction = clear ? .clear : .dontCare
            p.colorAttachments[0].storeAction = .store
            p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let e = command.makeRenderCommandEncoder(descriptor: p) else { throw Failure.unavailable("Render encoder") }
            return e
        }
        let e = try pass(scene, clear: true)
        e.label = "Jellyfish translucent anatomy"
        e.setVertexBytes(&uniforms, length: MemoryLayout<JellyfishUniforms>.stride, index: 2)
        e.setFragmentBytes(&uniforms, length: MemoryLayout<JellyfishUniforms>.stride, index: 2)
        e.setFrontFacing(.counterClockwise)
        for draw in draws {
            var instance = draw.instance
            e.setVertexBytes(&instance, length: MemoryLayout<JellyfishInstance>.stride, index: 1)
            e.setFragmentBytes(&instance, length: MemoryLayout<JellyfishInstance>.stride, index: 1)
            e.setCullMode(.none)
            if !economical {
                e.setRenderPipelineState(mote)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 18 * 6)
            }
            func shell(_ cull: MTLCullMode) {
                e.setCullMode(cull)
                e.setRenderPipelineState(membrane)
                e.setVertexBuffer(bellVertices, offset: 0, index: 0)
                e.drawIndexedPrimitives(type: .triangle, indexCount: bellIndexCount, indexType: .uint16,
                                         indexBuffer: bellIndices, indexBufferOffset: 0)
            }
            shell(.front)
            e.setCullMode(.none)
            if !draw.ribbons.isEmpty {
                e.setRenderPipelineState(ribbon)
                e.setVertexBuffer(ribbonBuffer, offset: 0, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: draw.ribbons.lowerBound, vertexCount: draw.ribbons.count)
            }
            e.setRenderPipelineState(core)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            shell(.back)
        }
        e.endEncoding()

        func post(_ target: MTLTexture, _ pipeline: MTLRenderPipelineState, _ source: MTLTexture,
                  direction: SIMD4<Float>? = nil) throws {
            let p = try pass(target)
            p.setRenderPipelineState(pipeline)
            p.setFragmentTexture(source, index: 0)
            if var direction { p.setFragmentBytes(&direction, length: MemoryLayout<SIMD4<Float>>.stride, index: 0) }
            p.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            p.endEncoding()
        }
        if bloom > 0 && !draws.isEmpty {
            try post(bloomA, threshold, scene)
            try post(bloomB, blur, bloomA, direction: SIMD4(1.5 / Float(bloomA.width), 0, 0, 0))
            try post(bloomA, blur, bloomB, direction: SIMD4(0, 1.5 / Float(bloomB.height), 0, 0))
        } else {
            let clear = try pass(bloomA, clear: true)
            clear.endEncoding()
        }
        let final = try pass(output)
        final.label = "Jellyfish theme composite"
        final.setRenderPipelineState(composite)
        final.setFragmentBytes(&uniforms, length: MemoryLayout<JellyfishUniforms>.stride, index: 2)
        final.setFragmentTexture(scene, index: 0)
        final.setFragmentTexture(bloomA, index: 1)
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
    }

    private func clear(output: MTLTexture, command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw Failure.unavailable("Clear encoder")
        }
        encoder.endEncoding()
        // Visits are infrequent. Do not retain a Retina-sized HDR scene and
        // bloom buffers throughout the minutes between them. Submitted GPU
        // commands keep their own references until they finish.
        scene = nil; bloomA = nil; bloomB = nil
        textureSize = .zero
    }
}
