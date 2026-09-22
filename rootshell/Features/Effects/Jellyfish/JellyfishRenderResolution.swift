// JellyfishRenderResolution.swift
// rootshell

import Foundation
import CoreGraphics

enum JellyfishRenderResolution {
    static func drawableSize(bounds: CGSize, displayScale: CGFloat) -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let width = bounds.width * scale, height = bounds.height * scale
        // Native backing resolution on phones, tablets, and Macs. A fixed
        // low pixel budget magnifies texels across fine canals and tentacles.
        // Battery Saver reduces mesh detail and frame rate instead. Only
        // exceptionally large surfaces hit these allocation safety limits.
        let budget: Double = 24_000_000
        let maximumDimension: Double = 8192
        let multiplier = min(1, sqrt(budget / max(width * height, 1)), maximumDimension / max(width, height))
        return CGSize(width: max(1, floor(width * multiplier)), height: max(1, floor(height * multiplier)))
    }
}
