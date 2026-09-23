#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Cached surfaces for the Phosphor, Beige Box, Neon Grid and Circuit Board
/// styles. Legends stay live UIKit text; only key faces and beds are rasterized.
@MainActor
enum TerminalTouchRetroArtwork {
    typealias RGB = TerminalTouchSteampunkMechanics.RGB
    typealias PhosphorColor = TerminalTouchKeyboardModel.PhosphorColor
    private typealias Brass = TerminalTouchSteampunkArtwork
    enum Design: Int, Sendable { case phosphor, beigeBox, neonGrid, circuitBoard }
    enum Role: Int { case letter, utility, toolbar, preview }
    static let padding: CGFloat = 6

    struct Material: Equatable {
        let design: Design
        let face: RGB
        let ink: RGB
        let accent: RGB
        let highContrast: Bool
        var key: String { "\(design.rawValue)/\(face.cacheKey)/\(ink.cacheKey)/\(accent.cacheKey)/\(highContrast)" }

        init(design: Design, palette: TerminalTouchKeyboardPalette?, traits: UITraitCollection,
             phosphor: PhosphorColor, utility: Bool = false, selected: Bool = false, pressed: Bool = false) {
            let highContrast = UIAccessibility.isDarkerSystemColorsEnabled || traits.accessibilityContrast == .high
            var face: RGB, preferred: RGB
            let accent: RGB
            switch design {
            case .phosphor:
                accent = TerminalTouchRetroArtwork.phosphor(phosphor, palette: palette, traits: traits)
                let glass = RGB(0.02, 0.025, 0.02).mix(accent, 0.05)
                face = selected ? accent : (pressed ? glass.mix(accent, 0.16) : glass)
                preferred = selected ? glass : accent
            case .beigeBox:
                accent = RGB(0.36, 0.34, 0.31)
                face = selected ? RGB(0.24, 0.23, 0.22) : (utility ? RGB(0.50, 0.49, 0.46) : RGB(0.87, 0.84, 0.76))
                if pressed { face = face.mix(.black, 0.06) }
                preferred = face.luminance < 0.3 ? RGB(0.93, 0.91, 0.85) : RGB(0.15, 0.14, 0.13)
            case .neonGrid:
                accent = utility ? RGB(0.0, 0.88, 1.0) : RGB(1.0, 0.22, 0.74)
                let night = RGB(0.12, 0.04, 0.21)
                face = selected ? accent : (pressed ? night.mix(accent, 0.22) : night)
                preferred = selected ? RGB(0.10, 0.02, 0.18) : RGB(1.0, 0.90, 0.98)
            case .circuitBoard:
                accent = RGB(0.86, 0.68, 0.30)
                face = selected ? RGB(0.93, 0.93, 0.88) : (utility ? RGB(0.05, 0.29, 0.14) : RGB(0.84, 0.67, 0.31))
                if pressed { face = face.mix(.white, 0.14) }
                preferred = face.luminance < 0.3 ? RGB(0.95, 0.96, 0.92) : RGB(0.03, 0.15, 0.07)
            }
            self.design = design
            self.face = face
            self.ink = face.ink(preferred: preferred, minimum: highContrast ? 7 : 4.5)
            self.accent = accent
            self.highContrast = highContrast
        }
    }

    static func phosphor(_ color: PhosphorColor, palette: TerminalTouchKeyboardPalette?, traits: UITraitCollection) -> RGB {
        switch color {
        case .green: return RGB(0.33, 1.0, 0.47)
        case .amber: return RGB(1.0, 0.70, 0.18)
        case .white: return RGB(0.86, 0.92, 1.0)
        case .theme:
            guard let palette else { return RGB(0.33, 1.0, 0.47) }
            // Light themes derive dark ink; the glow must stay bright on black glass.
            let ink = RGB(palette.ink, traits: traits)
            return ink.luminance < 0.25 ? ink.mix(.white, 0.55) : ink
        }
    }

    static func radius(size: CGSize, role: Role, design: Design) -> CGFloat {
        let short = min(size.width, size.height)
        switch design {
        case .phosphor: return min(role == .preview ? 8 : 5, short * 0.2)
        case .beigeBox: return min(role == .preview ? 7 : 4.5, short * 0.18)
        case .neonGrid: return min(role == .preview ? 12 : 9, short * 0.3)
        case .circuitBoard: return role == .utility || role == .toolbar ? min(3, short * 0.12) : short * 0.2
        }
    }

    /// The Beige Box cap face sits above its skirt; legends follow the face.
    static func legendOffset(role: Role, design: Design, pressed: Bool) -> CGFloat {
        design == .beigeBox && role != .preview ? -(skirtDepth(role: role, pressed: pressed) / 2) : 0
    }
    private static func skirtDepth(role: Role, pressed: Bool) -> CGFloat {
        pressed ? 1.2 : (role == .toolbar ? 2 : 3.5)
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>()
        value.countLimit = 200
        value.totalCostLimit = 16 * 1024 * 1024
        return value
    }()

    private static func image(_ key: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width > 1, size.height > 1, size.width * scale <= 8192, size.height * scale <= 8192,
              size.width * size.height * scale * scale <= 4_194_304 else { return nil }
        let cacheKey = "\(key)/\(size.width)/\(size.height)/\(scale)" as NSString
        if let existing = cache.object(forKey: cacheKey) { return existing }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let result = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        cache.setObject(result, forKey: cacheKey, cost: result.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return result
    }

    // MARK: - Keycaps

    static func cap(size: CGSize, scale: CGFloat, material: Material, role: Role, pressed: Bool) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 6, size.height > 6,
              scale.isFinite, scale > 0 else { return nil }
        let size = CGSize(width: ceil(size.width * scale) / scale, height: ceil(size.height * scale) / scale)
        let imageSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        return image("retro-cap/\(material.key)/\(role.rawValue)/\(pressed)", size: imageSize, scale: scale) { c in
            let rect = CGRect(origin: CGPoint(x: padding, y: padding), size: size)
            let r = radius(size: size, role: role, design: material.design)
            switch material.design {
            case .phosphor: phosphorCap(c, rect: rect, radius: r, material: material, pressed: pressed)
            case .beigeBox: beigeCap(c, rect: rect, radius: r, material: material, role: role, pressed: pressed)
            case .neonGrid: neonCap(c, rect: rect, radius: r, material: material, pressed: pressed)
            case .circuitBoard: circuitCap(c, rect: rect, radius: r, material: material, role: role, pressed: pressed)
            }
        }
    }

    private static func phosphorCap(_ c: CGContext, rect: CGRect, radius: CGFloat, material: Material, pressed: Bool) {
        let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
        if !material.highContrast {
            c.saveGState()
            c.setShadow(offset: .zero, blur: pressed ? 7 : 4,
                        color: material.accent.ui.withAlphaComponent(pressed ? 0.85 : 0.45).cgColor)
            Brass.stroke(c, path: outline, color: material.accent.ui, width: 1.2)
            c.restoreGState()
        }
        material.face.ui.setFill(); outline.fill()
        c.saveGState(); outline.addClip()
        let lineColor = material.face.luminance > 0.3 ? UIColor.black.withAlphaComponent(0.07)
            : material.accent.ui.withAlphaComponent(0.04)
        for y in stride(from: rect.minY + 1, to: rect.maxY, by: 2) {
            Brass.line(c, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y), color: lineColor, width: 0.5)
        }
        c.restoreGState()
        Brass.stroke(c, path: outline, color: material.accent.ui.withAlphaComponent(material.highContrast ? 1 : 0.85),
                     width: material.highContrast ? 1.5 : 1)
    }

    private static func beigeCap(_ c: CGContext, rect: CGRect, radius: CGFloat, material: Material, role: Role, pressed: Bool) {
        let depth = role == .preview ? 0 : skirtDepth(role: role, pressed: pressed)
        let skirt = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: pressed ? 0.8 : 1.6,
                    color: UIColor.black.withAlphaComponent(0.35).cgColor)
        material.face.mix(.black, 0.26).ui.setFill(); skirt.fill()
        c.restoreGState()
        c.saveGState(); skirt.addClip()
        vertical(c, colors: [material.face.mix(.black, 0.12).ui, material.face.mix(.black, 0.32).ui], rect: rect)
        c.restoreGState()
        // A narrower top face over a flared skirt reads as a tall cylindrical cap.
        let side: CGFloat = role == .toolbar ? 1.5 : 2.5
        let top = CGRect(x: rect.minX + side, y: rect.minY + 1, width: rect.width - side * 2,
                         height: max(1, rect.height - 1 - depth - side))
        let face = UIBezierPath(roundedRect: top, cornerRadius: max(1, radius - 1))
        c.saveGState(); face.addClip()
        let minimum = material.highContrast ? 7.0 : 4.5
        vertical(c, colors: [material.face.lit(toward: .white, amount: 0.05, ink: material.ink, minimum: minimum).ui,
                             material.face.ui,
                             material.face.lit(toward: .black, amount: 0.05, ink: material.ink, minimum: minimum).ui], rect: top)
        c.restoreGState()
        Brass.line(c, from: CGPoint(x: top.minX + radius, y: top.minY + 0.5), to: CGPoint(x: top.maxX - radius, y: top.minY + 0.5),
                   color: UIColor.white.withAlphaComponent(0.45), width: 0.6)
        Brass.stroke(c, path: skirt, color: material.highContrast ? material.ink.ui : UIColor.black.withAlphaComponent(0.4),
                     width: material.highContrast ? 1 : 0.5)
    }

    private static func neonCap(_ c: CGContext, rect: CGRect, radius: CGFloat, material: Material, pressed: Bool) {
        let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerRadius: radius)
        if !material.highContrast {
            c.saveGState()
            c.setShadow(offset: .zero, blur: pressed ? 9 : 5,
                        color: material.accent.ui.withAlphaComponent(pressed ? 0.95 : 0.6).cgColor)
            Brass.stroke(c, path: outline, color: material.accent.ui, width: 1.3)
            c.restoreGState()
        }
        c.saveGState(); outline.addClip()
        let minimum = material.highContrast ? 7.0 : 4.5
        vertical(c, colors: [material.face.lit(toward: .white, amount: 0.08, ink: material.ink, minimum: minimum).ui,
                             material.face.ui, material.face.ui], rect: rect)
        c.restoreGState()
        Brass.stroke(c, path: outline, color: material.highContrast ? material.ink.ui : material.accent.ui.withAlphaComponent(0.9),
                     width: material.highContrast ? 1.5 : 1)
    }

    private static func circuitCap(_ c: CGContext, rect: CGRect, radius: CGFloat, material: Material, role: Role, pressed: Bool) {
        let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 1, color: UIColor.black.withAlphaComponent(0.4).cgColor)
        material.face.ui.setFill(); outline.fill()
        c.restoreGState()
        let minimum = material.highContrast ? 7.0 : 4.5
        let pad = material.face.luminance >= 0.3
        if pad {
            // Plated pad: a soft sheen with a darker tinned rim.
            c.saveGState(); outline.addClip()
            vertical(c, colors: [material.face.lit(toward: .white, amount: 0.12, ink: material.ink, minimum: minimum).ui,
                                 material.face.ui,
                                 material.face.lit(toward: .black, amount: 0.06, ink: material.ink, minimum: minimum).ui], rect: rect)
            c.restoreGState()
            Brass.stroke(c, path: outline, color: material.highContrast ? material.ink.ui : material.accent.mix(.black, 0.35).ui,
                         width: material.highContrast ? 1.5 : 1)
        } else {
            // Solder-mask key with a silkscreened outline and a plated corner via.
            let silk = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: max(0, radius - 1))
            Brass.stroke(c, path: silk, color: material.highContrast ? material.ink.ui : material.accent.ui.withAlphaComponent(0.85),
                         width: material.highContrast ? 1.5 : 1)
            if role != .toolbar, rect.width > 30, rect.height > 24, !material.highContrast {
                via(c, center: CGPoint(x: rect.maxX - 6, y: rect.minY + 6), radius: 1.6, gold: material.accent)
            }
        }
        if pressed && !material.highContrast {
            Brass.stroke(c, path: outline, color: UIColor.white.withAlphaComponent(0.45), width: 1)
        }
    }

    // MARK: - Beds

    static func bed(size: CGSize, scale: CGFloat, design: Design, accent: RGB, rows: [CGRect], dark: Bool,
                    solid: Bool, highContrast: Bool) -> UIImage? {
        let geometry = rows.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }.joined(separator: ";")
        let key = "retro-bed/\(design.rawValue)/\(accent.cacheKey)/\(geometry)/\(dark)/\(solid)/\(highContrast)"
        return image(key, size: size, scale: scale) { c in
            let bounds = CGRect(origin: .zero, size: size)
            let alpha: CGFloat = solid ? 1 : 0.9
            switch design {
            case .phosphor:
                Brass.fill(c, rect: bounds, radius: 0, color: RGB(0.012, 0.016, 0.012).mix(accent, 0.03).ui.withAlphaComponent(alpha))
                guard !highContrast else { return }
                for y in stride(from: CGFloat(1), to: size.height, by: 3) {
                    Brass.line(c, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                               color: accent.ui.withAlphaComponent(0.035), width: 0.6)
                }
                radial(c, center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(size.width, size.height) * 0.75,
                       colors: [UIColor.clear, UIColor.black.withAlphaComponent(0.45)])
            case .beigeBox:
                let shell = dark ? RGB(0.30, 0.29, 0.27) : RGB(0.80, 0.78, 0.71)
                Brass.fill(c, rect: bounds, radius: 0, color: shell.ui.withAlphaComponent(alpha))
                guard !highContrast else { return }
                // Deterministic speckle for textured plastic, identical on every render.
                var seed: UInt32 = 0x9E37_79B9
                for _ in 0..<Int(min(2400, size.width * size.height / 60)) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let x = CGFloat(seed >> 16 & 0xFFFF) / 65535 * size.width
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let y = CGFloat(seed >> 16 & 0xFFFF) / 65535 * size.height
                    let light = seed & 1 == 0
                    Brass.fill(c, rect: CGRect(x: x, y: y, width: 0.8, height: 0.8), radius: 0,
                               color: (light ? UIColor.white : UIColor.black).withAlphaComponent(0.05))
                }
                for band in rows.dropFirst() {
                    Brass.line(c, from: CGPoint(x: band.minX, y: band.minY + 0.5), to: CGPoint(x: band.maxX, y: band.minY + 0.5),
                               color: UIColor.black.withAlphaComponent(0.08), width: 1)
                }
            case .neonGrid:
                let horizon = neonHorizon(rows: rows, height: size.height)
                c.saveGState(); c.clip(to: CGRect(x: 0, y: 0, width: size.width, height: horizon))
                vertical(c, colors: [RGB(0.03, 0.01, 0.09).ui.withAlphaComponent(alpha), RGB(0.24, 0.04, 0.32).ui.withAlphaComponent(alpha),
                                     RGB(0.55, 0.08, 0.42).ui.withAlphaComponent(alpha)],
                         rect: CGRect(x: 0, y: 0, width: size.width, height: horizon))
                if !highContrast { neonSun(c, center: CGPoint(x: size.width / 2, y: horizon), radius: min(horizon * 0.9, size.width * 0.14)) }
                c.restoreGState()
                Brass.fill(c, rect: CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon), radius: 0,
                           color: RGB(0.05, 0.01, 0.10).ui.withAlphaComponent(alpha))
                if !highContrast {
                    c.saveGState()
                    c.setShadow(offset: .zero, blur: 4, color: RGB(1.0, 0.3, 0.8).ui.cgColor)
                    Brass.line(c, from: CGPoint(x: 0, y: horizon), to: CGPoint(x: size.width, y: horizon),
                               color: RGB(1.0, 0.55, 0.9).ui, width: 1)
                    c.restoreGState()
                }
            case .circuitBoard:
                Brass.fill(c, rect: bounds, radius: 0, color: RGB(0.035, 0.21, 0.10).ui.withAlphaComponent(alpha))
                guard !highContrast else { return }
                circuitTraces(c, size: size, rows: rows, gold: accent)
            }
        }
    }

    static func neonHorizon(rows: [CGRect], height: CGFloat) -> CGFloat {
        guard let toolbar = rows.first else { return height * 0.3 }
        return rows.count > 1 ? toolbar.maxY : max(1, toolbar.maxY * 0.8)
    }

    private static func neonSun(_ c: CGContext, center: CGPoint, radius: CGFloat) {
        guard radius > 4 else { return }
        let disc = UIBezierPath(arcCenter: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
        c.saveGState(); disc.addClip()
        vertical(c, colors: [RGB(1.0, 0.85, 0.30).ui, RGB(1.0, 0.35, 0.55).ui],
                 rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius))
        // Stripes widen toward the horizon.
        c.setFillColor(RGB(0.45, 0.07, 0.40).ui.cgColor)
        var y = center.y - radius * 0.45, gap: CGFloat = 1
        while y < center.y {
            c.fill(CGRect(x: center.x - radius, y: y, width: radius * 2, height: gap))
            y += gap + radius * 0.12; gap += 0.8
        }
        c.restoreGState()
    }

    private static func circuitTraces(_ c: CGContext, size: CGSize, rows: [CGRect], gold: RGB) {
        let trace = RGB(0.10, 0.44, 0.22).ui
        var seed: UInt32 = 0x2545_F491
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 16 & 0xFFFF) / 65535
        }
        for (index, band) in rows.enumerated() {
            let y = band.maxY - 1
            Brass.line(c, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y), color: trace, width: 1.4)
            guard index + 1 < rows.count else { continue }
            let target = rows[index + 1].maxY - 1
            // Stubs drop to the next bus with a 45° jog, ending in a via.
            var x = 14 + next() * 20
            while x < size.width - 14 {
                let path = UIBezierPath()
                let jog = min(6, (target - y) / 3)
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + (target - y) / 2 - jog))
                path.addLine(to: CGPoint(x: x + jog, y: y + (target - y) / 2))
                path.addLine(to: CGPoint(x: x + jog, y: target))
                Brass.stroke(c, path: path, color: trace.withAlphaComponent(0.8), width: 1)
                via(c, center: CGPoint(x: x, y: y), radius: 1.8, gold: gold)
                x += 38 + next() * 46
            }
        }
    }

    private static func via(_ c: CGContext, center: CGPoint, radius: CGFloat, gold: RGB) {
        Brass.fill(c, rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                   radius: radius, color: gold.ui)
        let hole = radius * 0.45
        Brass.fill(c, rect: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2),
                   radius: hole, color: RGB(0.02, 0.08, 0.04).ui)
    }

    static func pulse(scale: CGFloat, color: RGB) -> UIImage? {
        image("retro-pulse/\(color.cacheKey)", size: CGSize(width: 16, height: 16), scale: scale) { c in
            radial(c, center: CGPoint(x: 8, y: 8), radius: 8,
                   colors: [UIColor.white, color.ui.withAlphaComponent(0.8), color.ui.withAlphaComponent(0)])
        }
    }

    // MARK: - Helpers

    private static func vertical(_ c: CGContext, colors: [UIColor], rect: CGRect) {
        let stops = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
                                        locations: stops) else { return }
        c.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ c: CGContext, center: CGPoint, radius: CGFloat, colors: [UIColor]) {
        let stops = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
                                        locations: stops) else { return }
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                             options: [.drawsAfterEndLocation])
    }
}
#endif
