//
//  ThemePaletteCube.swift
//  rootshell
//
//  Builds a CIColorCube LUT that remaps image colors toward the current
//  theme's palette using RBF-weighted Gaussian blending (gowall-style).
//

import Foundation
import CoreImage

enum ThemePaletteCube {

    private static let dimension = 32
    private static let sigma: Double = 50.0

    private nonisolated struct CacheKey: Hashable {
        let paletteHash: Int
        let amountBucket: Int
    }

    nonisolated(unsafe) private static var cache: [CacheKey: Data] = [:]
    nonisolated(unsafe) private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 6
    private static let lock = NSLock()

    static func makeFilter(themeColors: EffectThemeColors, amount: Double) -> CIFilter? {
        let clamped = max(0.0, min(1.0, amount))
        guard clamped > 0 else { return nil }

        let palette = palette(from: themeColors)
        guard !palette.isEmpty else { return nil }

        var hasher = Hasher()
        for c in palette {
            hasher.combine(c.r)
            hasher.combine(c.g)
            hasher.combine(c.b)
        }
        let key = CacheKey(
            paletteHash: hasher.finalize(),
            amountBucket: Int((clamped * 100).rounded())
        )

        let data = cachedCube(for: key, palette: palette, amount: clamped)

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        return filter
    }

    private static func cachedCube(for key: CacheKey, palette: [RGB], amount: Double) -> Data {
        lock.lock()
        if let hit = cache[key] {
            if let idx = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: idx)
            }
            cacheOrder.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let fresh = buildCube(palette: palette, amount: amount)

        lock.lock()
        cache[key] = fresh
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
        return fresh
    }

    private struct RGB { let r: Double; let g: Double; let b: Double }

    private static func buildCube(palette: [RGB], amount: Double) -> Data {
        let n = dimension
        let entries = n * n * n
        var buffer = [Float](repeating: 0, count: entries * 4)

        let twoSigmaSq = 2.0 * sigma * sigma
        let scale = 255.0 / Double(n - 1)

        for b in 0..<n {
            let srcB = Double(b) * scale
            for g in 0..<n {
                let srcG = Double(g) * scale
                for r in 0..<n {
                    let srcR = Double(r) * scale

                    var numR = 0.0, numG = 0.0, numB = 0.0, denom = 0.0
                    for p in palette {
                        let dr = srcR - p.r
                        let dg = srcG - p.g
                        let db = srcB - p.b
                        let weight = exp(-(dr*dr + dg*dg + db*db) / twoSigmaSq)
                        numR += p.r * weight
                        numG += p.g * weight
                        numB += p.b * weight
                        denom += weight
                    }

                    let tintR: Double, tintG: Double, tintB: Double
                    if denom > 0 {
                        tintR = numR / denom
                        tintG = numG / denom
                        tintB = numB / denom
                    } else {
                        tintR = srcR; tintG = srcG; tintB = srcB
                    }

                    let outR = srcR + (tintR - srcR) * amount
                    let outG = srcG + (tintG - srcG) * amount
                    let outB = srcB + (tintB - srcB) * amount

                    let offset = (b * n * n + g * n + r) * 4
                    buffer[offset + 0] = Float(outR / 255.0)
                    buffer[offset + 1] = Float(outG / 255.0)
                    buffer[offset + 2] = Float(outB / 255.0)
                    buffer[offset + 3] = 1.0
                }
            }
        }

        return buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func palette(from themeColors: EffectThemeColors) -> [RGB] {
        var hexes: [String] = []
        hexes.append(themeColors.background)
        hexes.append(themeColors.foreground)
        hexes.append(contentsOf: themeColors.palette)

        var seen = Set<String>()
        var result: [RGB] = []
        for hex in hexes {
            let normalized = hex.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            if let rgb = parseHex(hex) {
                result.append(rgb)
            }
        }
        return result
    }

    private static func parseHex(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return RGB(
            r: Double((value >> 16) & 0xFF),
            g: Double((value >> 8) & 0xFF),
            b: Double(value & 0xFF)
        )
    }
}
