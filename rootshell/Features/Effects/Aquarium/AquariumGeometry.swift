// AquariumGeometry.swift
// rootshell
// Original procedural geometry. No downloaded models, textures, or asset licenses.

import Foundation

enum AquariumSpecies: Int, CaseIterable, Sendable {
    case clownfish, blueTang, butterflyfish, angelfish, neonTetra
    var bodyHeight: Float {
        switch self {
        case .clownfish: return 0.39
        case .blueTang: return 0.56
        case .butterflyfish: return 0.65
        case .angelfish: return 0.68
        case .neonTetra: return 0.23
        }
    }
    var thickness: Float { self == .angelfish ? 0.15 : (self == .neonTetra ? 0.14 : 0.23) }
    var scale: Float { self == .neonTetra ? 0.34 : (self == .angelfish ? 0.66 : 0.62) }
    var cruisingSpeed: Float { self == .neonTetra ? 0.66 : (self == .angelfish ? 0.32 : 0.44) }
}

struct AquariumMesh: Sendable {
    var vertices: [AquariumVertex] = []
    var indices: [UInt32] = []
    /// Fish fins follow the solid indices; all other meshes are fully opaque.
    var opaqueIndexCount: Int = 0

    mutating func surface(uSegments: Int, vSegments: Int, part: Float = 0,
                          point: (Float, Float) -> SIMD3<Float>) {
        let base = UInt32(vertices.count)
        for i in 0...uSegments {
            let u = Float(i) / Float(uSegments)
            for j in 0...vSegments {
                let v = Float(j) / Float(vSegments)
                let p = point(u, v)
                let u0 = max(u - 0.001, 0), u1 = min(u + 0.001, 1)
                let v0 = max(v - 0.001, 0), v1 = min(v + 0.001, 1)
                // Differentiate, rather than crossing tiny finite differences:
                // small blades/stalks otherwise fall below the normalization epsilon.
                let du = (point(u1, v) - point(u0, v)) / (u1 - u0)
                let dv = (point(u, v1) - point(u, v0)) / (v1 - v0)
                let n = aqNormalize(aqCross(du, dv), fallback: aqNormalize(p, fallback: SIMD3(0, 1, 0)))
                vertices.append(AquariumVertex(position: aqV4(p, part), normal: aqV4(n, 0), uv: SIMD4(u, v, 0, 0)))
            }
        }
        let stride = UInt32(vSegments + 1)
        for i in 0..<uSegments {
            for j in 0..<vSegments {
                let a = base + UInt32(i) * stride + UInt32(j)
                let b = a + stride
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        opaqueIndexCount = indices.count
    }

    mutating func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, part: Float, detail: Int = 12) {
        surface(uSegments: detail * 2, vSegments: detail, part: part) { u, v in
            let phi = u * 2 * Float.pi
            let theta = v * Float.pi
            return center + SIMD3(cos(phi) * sin(theta), cos(theta), sin(phi) * sin(theta)) * radii
        }
    }
}

enum AquariumGeometry {
    private static func profile(_ u: Float, species: AquariumSpecies) -> Float {
        // A narrow caudal peduncle, rounded shoulder, and a tapered but non-pointed snout.
        let shape = pow(max(sin(Float.pi * (0.04 + 0.92 * u)), 0), 0.75)
        return (0.13 + 0.87 * shape) * (0.79 + 0.21 * u)
    }

    static func fish(_ species: AquariumSpecies) -> AquariumMesh {
        var mesh = AquariumMesh()
        let h = species.bodyHeight
        let w = species.thickness
        mesh.surface(uSegments: 40, vSegments: 32) { u, v in
            let angle = -v * 2 * Float.pi
            let radius = profile(u, species: species)
            let x = -0.86 + 1.80 * u
            return SIMD3(x, h * radius * cos(angle), w * radius * sin(angle))
        }
        // Close the small mouth and tail openings with rounded caps.
        mesh.ellipsoid(center: SIMD3(0.925, 0, 0), radii: SIMD3(0.055, h * 0.36, w * 0.36), part: 0, detail: 8)
        mesh.ellipsoid(center: SIMD3(-0.85, 0, 0), radii: SIMD3(0.045, h * 0.22, w * 0.22), part: 0, detail: 6)
        for side: Float in [-1, 1] {
            let eyeY = h * 0.22
            let eyeZ = w * 0.84 * side
            mesh.ellipsoid(center: SIMD3(0.58, eyeY, eyeZ),
                           radii: SIMD3(0.087, 0.087, 0.038), part: 3, detail: 9)
            mesh.ellipsoid(center: SIMD3(0.596, eyeY, eyeZ + side * 0.026),
                           radii: SIMD3(0.051, 0.055, 0.027), part: 2, detail: 9)
        }
        let opaque = mesh.indices.count
        // Caudal fin: forked for fast swimmers, rounded for the clownfish.
        mesh.surface(uSegments: 12, vSegments: 24, part: 1) { u, v in
            let spread = 2 * v - 1
            let fork: Float = species == .clownfish ? 0.035 : 0.24
            let tip = -1.52 + fork * (1 - abs(spread))
            let tailH: Float = species == .neonTetra ? 0.36 : 0.50
            let x = -0.84 + (tip + 0.84) * u
            return SIMD3(x, spread * (0.045 + tailH * u), sin(v * Float.pi * 2) * 0.04 * u)
        }
        // Dorsal and anal fins. Angelfish have the characteristic tall triangular sail.
        for side: Float in [-1, 1] {
            mesh.surface(uSegments: 26, vSegments: 8, part: 1) { u, v in
                let x = -0.73 + u * 1.12
                let bodyU = (x + 0.86) / 1.80
                let root = h * profile(bodyU, species: species) * 0.90
                let sail = pow(max(sin(u * Float.pi), 0), species == .angelfish ? 1.8 : 0.75)
                let extensionHeight: Float = species == .angelfish ? 0.87 : 0.21
                let y = side * (root + v * sail * extensionHeight)
                return SIMD3(x - v * sail * 0.25, y, sin(u * 7) * v * 0.025)
            }
            // Paired pectoral fins, swept backward and cupped rather than flat triangles.
            mesh.surface(uSegments: 12, vSegments: 12, part: 1) { u, v in
                let spread = (v - 0.5) * Float.pi * 0.85
                return SIMD3(0.26 - u * (0.34 + cos(spread) * 0.20),
                             -h * 0.25 - u * (0.08 + sin(spread) * 0.23),
                             side * (w * 0.77 + sin(u * 1.6) * 0.28))
            }
            // Long ventral feelers make the angelfish silhouette recognizable.
            if species == .angelfish {
                mesh.surface(uSegments: 18, vSegments: 2, part: 1) { u, v in
                    SIMD3(0.12 - 0.34 * u + (v - 0.5) * (1 - u) * 0.035,
                          -0.39 - 1.02 * u, side * 0.065 + sin(u * 5) * 0.025)
                }
            }
        }
        mesh.opaqueIndexCount = opaque
        return mesh
    }

    static func floor() -> AquariumMesh {
        var mesh = AquariumMesh()
        mesh.surface(uSegments: 72, vSegments: 48) { u, v in
            let x = u * 2 - 1
            let z = 3.5 - v * 12
            let y = -2.73 + 0.08 * sin(x * 11 + z * 0.65) + 0.035 * sin(x * 29 - z * 1.4)
            return SIMD3(x, y, z)
        }
        return mesh
    }

    static func rock() -> AquariumMesh {
        var mesh = AquariumMesh()
        mesh.surface(uSegments: 32, vSegments: 20) { u, v in
            let a = u * 2 * Float.pi
            let b = v * Float.pi
            let p = SIMD3(cos(a) * sin(b), cos(b), sin(a) * sin(b))
            let n = 1 + 0.13 * sin(p.x * 8 + p.z * 3) * sin(p.y * 7 - p.x * 4)
                + 0.045 * cos(p.z * 19 + p.y * 11)
            return p * n
        }
        return mesh
    }

    static func kelp(seed: UInt64) -> AquariumMesh {
        var rng = AquariumRandom(seed: seed)
        var mesh = AquariumMesh()
        let height = rng.range(3.8, 5.7)
        func center(_ t: Float) -> SIMD3<Float> {
            SIMD3(0.17 * sin(t * 6) * t, t * height, 0.12 * sin(t * 4) * t)
        }
        // A tapered three-dimensional stipe.
        mesh.surface(uSegments: 28, vSegments: 8) { u, v in
            let a = v * 2 * Float.pi
            let radius = 0.023 * (1 - 0.72 * u)
            return center(u) + SIMD3(cos(a) * radius, 0, sin(a) * radius)
        }
        // Laminaria-like ruffled blades in alternating pairs; broad enough to read in silhouette.
        for index in 0..<15 {
            let t = 0.16 + Float(index) / 15 * 0.79
            let side: Float = index.isMultiple(of: 2) ? -1 : 1
            let length = rng.range(0.55, 1.20) * (1.1 - 0.45 * t)
            let width = rng.range(0.10, 0.18)
            let twist = rng.range(-0.9, 0.9)
            let origin = center(t)
            mesh.surface(uSegments: 16, vSegments: 5) { u, v in
                let outline = pow(max(sin(u * Float.pi), 0), 0.65)
                let lateral = (2 * v - 1) * width * outline
                let ruffle = sin(u * 28 + v * 3) * 0.045 * outline * abs(2 * v - 1)
                return origin + SIMD3(side * length * u + lateral * 0.18,
                                      0.24 * sin(u * Float.pi) + 0.22 * u + lateral * cos(twist + u * 2.6),
                                      0.20 * sin(u * 3) + lateral * sin(twist + u * 2.6) + ruffle)
            }
        }
        return mesh
    }

    static func billboard() -> AquariumMesh {
        var mesh = AquariumMesh()
        mesh.surface(uSegments: 1, vSegments: 1) { u, v in SIMD3(u * 2 - 1, v * 2 - 1, 0) }
        return mesh
    }
}
