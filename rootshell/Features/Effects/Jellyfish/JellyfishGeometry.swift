// JellyfishGeometry.swift
// rootshell

import Foundation
import CoreGraphics
import simd

/// All GPU records use float4 fields to keep Swift/Metal alignment explicit.
struct JellyfishVertex {
    var position: SIMD4<Float> // xy: point-space position; w: membrane/arm/filament
    var uv: SIMD4<Float>       // across, along, chain phase, reserved
}

struct JellyfishInstance {
    var axisX: SIMD4<Float>    // affine x row, radius
    var axisY: SIMD4<Float>    // affine y row, reserved
    var tint: SIMD4<Float>     // linear RGB, depth attenuation
    var motion: SIMD4<Float>   // contraction, local time, shimmer head, shimmer strength
    var anatomy: SIMD4<Float>  // view tilt, seed, calm motion, reserved
}

struct JellyfishUniforms {
    var viewport: SIMD4<Float>    // point width/height, drawable width/height
    var composition: SIMD4<Float> // opacity, light theme, bloom, reserved
}

enum JellyfishGeometry {
    /// A closed azimuth seam and an open, scalloped bell margin. The shader
    /// evaluates the surface and its derivatives after deformation.
    static func bell(segments: Int = 80, rings: Int = 28) -> (vertices: [JellyfishVertex], indices: [UInt16]) {
        var vertices: [JellyfishVertex] = []
        var indices: [UInt16] = []
        for ring in 0...rings {
            for segment in 0...segments {
                vertices.append(JellyfishVertex(position: .zero,
                    uv: SIMD4(Float(segment) / Float(segments), Float(ring) / Float(rings), 0, 0)))
            }
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt16(ring * (segments + 1) + segment)
                let b = a + UInt16(segments + 1)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return (vertices, indices)
    }

    /// Sample the simulated centerline with Catmull–Rom interpolation, then
    /// skin it with a tapering ribbon. Arms have folded cross-sections and
    /// ruffled edges; filaments use a single antialiased strip. Both end at
    /// the exact physics anchor, including during a contraction or avoidance.
    static func appendChains(of jelly: Jellyfish, time: TimeInterval, size: CGSize,
                             economical: Bool, to vertices: inout [JellyfishVertex]) {
        guard jelly.lastSimTime != nil else { return }
        let transform = jelly.bellTransform(at: time, in: size)
        let radius = Float(jelly.bellRadius)
        let elapsed = Float(time - jelly.spawnFrameTime)

        func append(nodes: [CGPoint], count: Int, nodesPer: Int, arm: Bool) {
            let divisions = economical ? 3 : 5
            let columns = arm ? (economical ? 4 : 6) : 1
            for chain in 0..<count {
                let localAnchor = arm ? CGPoint(x: jelly.oralArmAnchorX[chain], y: 0.08)
                    : jelly.tentacleAnchor(chain, at: time)
                let anchor = localAnchor.applying(transform)
                func point(_ index: Int) -> SIMD2<Float> {
                    let p = index <= 0 ? anchor : nodes[chain * nodesPer + min(index - 1, nodesPer - 1)]
                    return SIMD2(Float(p.x), Float(p.y))
                }
                func center(_ t: Float) -> SIMD2<Float> {
                    let f = min(t * Float(nodesPer), Float(nodesPer) - 0.0001)
                    let k = Int(f), u = f - Float(k)
                    let p0 = point(k - 1), p1 = point(k), p2 = point(k + 1), p3 = point(k + 2)
                    let a = 2 * p1
                    let b = (p2 - p0) * u
                    let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * (u * u)
                    let d = (-p0 + 3 * p1 - 3 * p2 + p3) * (u * u * u)
                    return (a + b + c + d) * 0.5
                }
                let phase = Float(chain) * 2.399 + Float(jelly.pulsePhase0)
                let steps = nodesPer * divisions
                func vertex(step: Int, column: Int) -> JellyfishVertex {
                    let v = Float(step) / Float(steps)
                    let u = Float(column) / Float(columns) * 2 - 1
                    let p = center(v)
                    let tangent = center(min(1, v + 0.003)) - center(max(0, v - 0.003))
                    let length = max(simd_length(tangent), 0.0001)
                    let normal = SIMD2(-tangent.y, tangent.x) / length
                    let taper = pow(max(0, 1 - v), arm ? 0.65 : 0.45)
                    let wave = v * 52 - elapsed * (jelly.calmDrift ? 0.12 : 0.8) + phase
                    let width: Float
                    let fold: Float
                    if arm {
                        // The frill grows away from the attachment, then
                        // tapers to a thread, so the bell never wears a cuff.
                        width = radius * (0.06 + 0.10 * sin(min(v * 5, .pi / 2))) * taper
                        fold = sin(wave + abs(u) * 3.4) * abs(u) * abs(u)
                    } else {
                        width = max(0.42, radius * 0.013) * taper + 0.16
                        fold = 0
                    }
                    let xy = p + normal * (u * width * (1 + fold * 0.38))
                    return JellyfishVertex(position: SIMD4(xy.x, xy.y, fold * width * 0.7, arm ? 1 : 2),
                                            uv: SIMD4(u, v, phase, 0))
                }
                var previous = (0...columns).map { vertex(step: 0, column: $0) }
                var next = previous
                for step in 1...steps {
                    for column in 0...columns { next[column] = vertex(step: step, column: column) }
                    for column in 0..<columns {
                        let a = previous[column], b = next[column]
                        let c = previous[column + 1], d = next[column + 1]
                        vertices.append(contentsOf: [a, b, c, c, b, d])
                    }
                    swap(&previous, &next)
                }
            }
        }
        // Fine marginal filaments sit behind the denser central oral arms.
        append(nodes: jelly.tentacleNodes, count: jelly.tentacleCount, nodesPer: jelly.tentacleNodesPer, arm: false)
        append(nodes: jelly.oralArmNodes, count: jelly.oralArmCount, nodesPer: jelly.oralArmNodesPer, arm: true)
    }
}
