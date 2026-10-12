// WeatherGPUContext.swift
// rootshell

#if !CHINA_BUILD
import Metal
import os

/// Pipelines, noise volumes, and the star field, built once and shared by
/// every Live Weather surface. Released when the last renderer goes away.
@MainActor
final class WeatherGPUContext {
    enum Failure: Error { case unavailable(String) }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let skyPipeline: MTLRenderPipelineState
    let cloudPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let starPipeline: MTLRenderPipelineState
    let boltPipeline: MTLRenderPipelineState
    let particlePipeline: MTLRenderPipelineState
    /// 128³ tileable volume: R Perlin-Worley, G Worley fBm.
    let shapeNoise: MTLTexture
    /// 32³ tileable Worley fBm for eroding cloud edges.
    let detailNoise: MTLTexture
    let stars: MTLBuffer
    let starCount: Int

    private static weak var cached: WeatherGPUContext?

    static func shared() throws -> WeatherGPUContext {
        if let cached { return cached }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.unavailable("Metal device") }
        let context = try WeatherGPUContext(device: device)
        cached = context
        return context
    }

    private init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            throw Failure.unavailable("Metal queue or default library")
        }
        self.queue = queue
        queue.label = "Live Weather"

        enum Blend { case none, over, add, max }
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Blend = .none) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw Failure.unavailable(fragment)
            }
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            switch blend {
            case .none:
                color.isBlendingEnabled = false
            case .over:
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .add, .max:
                // Light adds colour but never coverage.
                color.isBlendingEnabled = true
                color.rgbBlendOperation = blend == .max ? .max : .add
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .zero
                color.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        skyPipeline = try pipeline("weatherScreenVertex", "weatherSky", format: .rgba16Float)
        cloudPipeline = try pipeline("weatherScreenVertex", "weatherClouds", format: .rgba16Float)
        compositePipeline = try pipeline("weatherScreenVertex", "weatherComposite", format: .bgra8Unorm)
        starPipeline = try pipeline("weatherStarVertex", "weatherStarFragment", format: .bgra8Unorm, blend: .add)
        boltPipeline = try pipeline("weatherBoltVertex", "weatherBoltFragment", format: .bgra8Unorm, blend: .max)
        particlePipeline = try pipeline("weatherParticleVertex", "weatherParticleFragment", format: .bgra8Unorm, blend: .over)

        func volume(size: Int, format: MTLPixelFormat, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = format
            descriptor.width = size; descriptor.height = size; descriptor.depth = size
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable(label) }
            texture.label = label
            return texture
        }
        shapeNoise = try volume(size: 128, format: .rg8Unorm, label: "Weather shape noise")
        detailNoise = try volume(size: 32, format: .r8Unorm, label: "Weather detail noise")
        guard let shapeKernel = library.makeFunction(name: "weatherShapeNoise"),
              let detailKernel = library.makeFunction(name: "weatherDetailNoise") else {
            throw Failure.unavailable("Noise kernels")
        }
        let shapeState = try device.makeComputePipelineState(function: shapeKernel)
        let detailState = try device.makeComputePipelineState(function: detailKernel)

        let starRecords = Self.makeStars()
        guard let stars = starRecords.withUnsafeBytes({ raw in
            raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
        }) else { throw Failure.unavailable("Star buffer") }
        stars.label = "Weather stars"
        self.stars = stars
        starCount = starRecords.count
        assert(MemoryLayout<WeatherUniforms>.stride == 400)
        assert(MemoryLayout<WeatherStar>.stride == 32)

        // Generated once on the GPU; later passes on this queue run after it.
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.unavailable("Noise command buffer")
        }
        command.label = "Weather noise volumes"
        let group = MTLSize(width: 4, height: 4, depth: 4)
        encoder.setComputePipelineState(shapeState)
        encoder.setTexture(shapeNoise, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 32, height: 32, depth: 32), threadsPerThreadgroup: group)
        encoder.setComputePipelineState(detailState)
        encoder.setTexture(detailNoise, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 8, height: 8, depth: 8), threadsPerThreadgroup: group)
        encoder.endEncoding()
        command.commit()
    }

    /// The bright-star catalogue plus a seeded field of fainter stars that
    /// thickens toward the Milky Way, all in equatorial coordinates.
    private static func makeStars() -> [WeatherStar] {
        var records: [WeatherStar] = []
        records.reserveCapacity(2_600)
        var random = WeatherRandom(seed: 0x57A2_F1E1D)
        for star in StarCatalog.shared.allStars {
            let v = WeatherSkyGeometry.equatorialVector(rightAscension: star.ra, declination: star.dec)
            records.append(Self.star(v, magnitude: star.magnitude, spectral: star.spectralClass, seed: random.unit()))
        }
        let classes: [(SpectralClass, Double)] = [(.B, 0.10), (.A, 0.30), (.F, 0.50), (.G, 0.70), (.K, 0.90), (.M, 1.0)]
        let pole = WeatherSkyGeometry.galacticNorthPole
        // Star counts grow about threefold per magnitude.
        let span = pow(10, 0.47 * 2.6) - 1
        while records.count < 2_600 {
            let z = random.unit() * 2 - 1, angle = random.unit() * 2 * Double.pi
            let r = (1 - z * z).squareRoot()
            let v = SIMD3<Float>(Float(r * cos(angle)), Float(r * sin(angle)), Float(z))
            let latitude = Double(asin(min(max((v * pole).sum(), -1), 1)))
            guard random.unit() < 0.35 + 0.65 * exp(-pow(latitude / 0.3, 2)) else { continue }
            let magnitude = 3.5 + log10(1 + random.unit() * span) / 0.47
            let pick = random.unit()
            let spectral = classes.first { pick < $0.1 }?.0 ?? .G
            records.append(Self.star(v, magnitude: magnitude, spectral: spectral, seed: random.unit()))
        }
        return records
    }

    private static func star(_ v: SIMD3<Float>, magnitude: Double, spectral: SpectralClass, seed: Double) -> WeatherStar {
        let rgb = spectral.color
        let color = SIMD4<Float>(Float(rgb.r), Float(rgb.g), Float(rgb.b), Float(seed))
        return WeatherStar(equatorial: wxV4(v, Float(magnitude)), color: color)
    }
}
#endif
