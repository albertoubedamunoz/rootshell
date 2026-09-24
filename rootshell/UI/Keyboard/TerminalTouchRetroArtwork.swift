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

    /// The paired terminal theme's surfaces, or system defaults when the keyboard
    /// doesn't follow the theme. Each style keeps its signature colors and
    /// blends its neutrals toward these, with a light and a dark variant.
    struct Theme: Equatable {
        let dark: Bool
        let base: RGB
        let key: RGB
        let ink: RGB
        var cacheKey: String { "\(dark)/\(base.cacheKey)/\(key.cacheKey)/\(ink.cacheKey)" }

        init(palette: TerminalTouchKeyboardPalette?, traits: UITraitCollection) {
            if let palette {
                dark = !palette.isLight
                base = RGB(palette.background, traits: traits)
                key = RGB(palette.key, traits: traits)
                ink = RGB(palette.ink, traits: traits)
            } else {
                dark = traits.userInterfaceStyle == .dark
                base = RGB(TerminalTouchKeyboardAppearance.background, traits: traits)
                key = RGB(UIColor.secondarySystemBackground, traits: traits)
                ink = RGB(UIColor.label, traits: traits)
            }
        }
    }

    struct Material: Equatable {
        let design: Design
        let face: RGB
        let ink: RGB
        let accent: RGB
        /// Secondary signature color: Circuit Board's gold plating.
        let detail: RGB
        let dark: Bool
        let highContrast: Bool
        var key: String {
            "\(design.rawValue)/\(face.cacheKey)/\(ink.cacheKey)/\(accent.cacheKey)/\(detail.cacheKey)/\(dark)/\(highContrast)"
        }

        init(design: Design, palette: TerminalTouchKeyboardPalette?, traits: UITraitCollection,
             phosphor: PhosphorColor, utility: Bool = false, selected: Bool = false, pressed: Bool = false) {
            let highContrast = UIAccessibility.isDarkerSystemColorsEnabled || traits.accessibilityContrast == .high
            let theme = Theme(palette: palette, traits: traits)
            let dark = theme.dark
            var face: RGB, preferred: RGB
            let accent: RGB
            var detail: RGB?
            switch design {
            case .phosphor:
                // CRT glass stays dark in every theme; only its tint follows the theme.
                accent = TerminalTouchRetroArtwork.phosphor(phosphor, palette: palette, traits: traits)
                let glass = theme.base.mix(.black, dark ? 0.85 : 0.82).mix(accent, 0.05)
                face = selected ? accent : (pressed ? glass.mix(accent, 0.16) : glass)
                preferred = selected ? glass : accent
            case .beigeBox:
                accent = RGB(0.36, 0.34, 0.31)
                let beige = RGB(0.87, 0.84, 0.76)
                if dark {
                    // Dimmed so the alphas don't glare against a dark terminal.
                    let plastic = utility ? RGB(0.34, 0.33, 0.31) : beige.mix(.black, 0.28)
                    face = selected ? RGB(0.93, 0.91, 0.85) : plastic.mix(theme.base, 0.15)
                } else {
                    let plastic = utility ? RGB(0.50, 0.49, 0.46) : beige
                    face = selected ? RGB(0.24, 0.23, 0.22) : plastic.mix(theme.base, 0.1)
                }
                if pressed { face = face.mix(.black, 0.06) }
                preferred = face.luminance < 0.3 ? RGB(0.93, 0.91, 0.85) : RGB(0.15, 0.14, 0.13)
            case .neonGrid:
                accent = utility ? Neon.cyan(dark: dark) : Neon.pink(dark: dark)
                let night = theme.base.mix(dark ? RGB(0.12, 0.04, 0.21) : RGB(1.0, 0.95, 1.0), 0.7)
                face = selected ? accent : (pressed ? night.mix(accent, dark ? 0.22 : 0.14) : night)
                preferred = selected ? (dark ? RGB(0.10, 0.02, 0.18) : .white)
                    : (dark ? RGB(1.0, 0.90, 0.98) : RGB(0.28, 0.05, 0.36))
            case .circuitBoard:
                let board = Board(theme)
                accent = board.silk
                detail = board.gold
                face = selected ? board.silk : (utility ? board.utility : board.package)
                if pressed && !selected { face = face.mix(board.silk, dark ? 0.16 : 0.12) }
                preferred = selected ? board.mask : (utility ? board.silk : theme.ink)
            }
            self.design = design
            self.face = face
            self.ink = face.ink(preferred: preferred, minimum: highContrast ? 7 : 4.5)
            self.accent = accent
            self.detail = detail ?? accent
            self.dark = dark
            self.highContrast = highContrast
        }
    }

    /// Synthwave pink and cyan, deepened on light themes to hold their color on a pale sky.
    enum Neon {
        static func pink(dark: Bool) -> RGB { dark ? RGB(1.0, 0.22, 0.74) : RGB(0.86, 0.10, 0.58) }
        static func cyan(dark: Bool) -> RGB { dark ? RGB(0.0, 0.88, 1.0) : RGB(0.0, 0.56, 0.72) }
    }

    /// Solder mask derived from the theme: matte black on dark themes, white on
    /// light ones. Gold plating and a lavender-tinted silkscreen are the constants.
    struct Board {
        let mask: RGB
        let package: RGB
        let utility: RGB
        let copper: RGB
        let silk: RGB
        let gold: RGB

        init(_ theme: Theme) {
            let lavender = theme.dark ? RGB(0.706, 0.745, 0.996) : RGB(0.447, 0.529, 0.992)
            silk = theme.ink.mix(lavender, 0.6)
            gold = theme.dark ? RGB(0.976, 0.886, 0.686).mix(.black, 0.18) : RGB(0.80, 0.62, 0.28)
            if theme.dark {
                mask = theme.base.mix(.black, 0.35)
                package = theme.key.mix(theme.base, 0.2)
                utility = theme.base.mix(theme.key, 0.2)
            } else {
                mask = theme.base.mix(.black, 0.04)
                package = theme.key.mix(.white, 0.4)
                utility = theme.base.mix(.white, 0.45)
            }
            copper = mask.mix(theme.ink, 0.12)
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
        case .circuitBoard: return min(role == .preview ? 6 : 3.5, short * 0.14)
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
                        color: material.accent.ui.withAlphaComponent((pressed ? 0.95 : 0.6) * (material.dark ? 1 : 0.6)).cgColor)
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
        let minimum = material.highContrast ? 7.0 : 4.5
        // A selected key is solid silkscreen color.
        let selected = material.face == material.accent
        let edge: RGB = material.dark ? .white : .black
        // Letter keys are IC packages: gold gull-wing leads peek out of both sides.
        if role == .letter, !selected, !material.highContrast, rect.height > 24 {
            let count = rect.height > 40 ? 4 : 3
            let step = rect.height / CGFloat(count + 1)
            for index in 1...count {
                let y = rect.minY + step * CGFloat(index) - 0.6
                for x in [rect.minX - 1.6, rect.maxX - 0.4] {
                    Brass.fill(c, rect: CGRect(x: x, y: y, width: 2, height: 1.2), radius: 0.3,
                               color: material.detail.ui.withAlphaComponent(0.8))
                }
            }
        }
        c.saveGState()
        if pressed && !material.highContrast {
            c.setShadow(offset: .zero, blur: 6, color: material.accent.ui.withAlphaComponent(material.dark ? 0.7 : 0.45).cgColor)
        } else {
            c.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5,
                        color: UIColor.black.withAlphaComponent(material.dark ? 0.55 : 0.22).cgColor)
        }
        material.face.ui.setFill(); outline.fill()
        c.restoreGState()
        c.saveGState(); outline.addClip()
        vertical(c, colors: [material.face.lit(toward: .white, amount: 0.06, ink: material.ink, minimum: minimum).ui,
                             material.face.ui,
                             material.face.lit(toward: .black, amount: 0.08, ink: material.ink, minimum: minimum).ui], rect: rect)
        c.restoreGState()
        if material.highContrast {
            Brass.stroke(c, path: outline, color: material.ink.ui, width: 1.5)
            return
        }
        Brass.line(c, from: CGPoint(x: rect.minX + radius, y: rect.minY + 0.5), to: CGPoint(x: rect.maxX - radius, y: rect.minY + 0.5),
                   color: UIColor.white.withAlphaComponent(selected ? 0.35 : 0.1), width: 0.6)
        guard !selected else { return }
        let large = role != .toolbar && rect.width > 30 && rect.height > 24
        if role == .letter {
            Brass.stroke(c, path: outline, color: material.face.mix(edge, pressed ? 0.3 : 0.12).ui, width: 0.8)
            if large {
                // Pin-1 marker.
                Brass.fill(c, rect: CGRect(x: rect.minX + 3.5, y: rect.minY + 3.5, width: 2.4, height: 2.4), radius: 1.2,
                           color: material.accent.ui.withAlphaComponent(0.45))
            }
        } else {
            // Silkscreened footprint with a plated corner via.
            let silk = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: max(0, radius - 1))
            Brass.stroke(c, path: silk, color: material.accent.ui.withAlphaComponent(pressed ? 0.9 : 0.5), width: 0.8)
            if large {
                via(c, center: CGPoint(x: rect.maxX - 6, y: rect.minY + 6), radius: 1.6, gold: material.detail, hole: material.face)
            }
        }
    }

    // MARK: - Beds

    static func bed(size: CGSize, scale: CGFloat, design: Design, accent: RGB, rows: [CGRect], theme: Theme,
                    solid: Bool, highContrast: Bool) -> UIImage? {
        let geometry = rows.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }.joined(separator: ";")
        let key = "retro-bed/\(design.rawValue)/\(accent.cacheKey)/\(geometry)/\(theme.cacheKey)/\(solid)/\(highContrast)"
        let dark = theme.dark
        return image(key, size: size, scale: scale) { c in
            let bounds = CGRect(origin: .zero, size: size)
            let alpha: CGFloat = solid ? 1 : 0.9
            switch design {
            case .phosphor:
                guard dark else {
                    // Light themes get a plastic bezel around the dark CRT keys.
                    Brass.fill(c, rect: bounds, radius: 0, color: theme.base.mix(.black, 0.07).ui.withAlphaComponent(alpha))
                    return
                }
                Brass.fill(c, rect: bounds, radius: 0, color: theme.base.mix(.black, 0.9).mix(accent, 0.03).ui.withAlphaComponent(alpha))
                guard !highContrast else { return }
                for y in stride(from: CGFloat(1), to: size.height, by: 3) {
                    Brass.line(c, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                               color: accent.ui.withAlphaComponent(0.035), width: 0.6)
                }
                radial(c, center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(size.width, size.height) * 0.75,
                       colors: [UIColor.clear, UIColor.black.withAlphaComponent(0.45)])
            case .beigeBox:
                let shell = dark ? theme.base.mix(RGB(0.30, 0.29, 0.27), 0.6) : theme.base.mix(RGB(0.80, 0.78, 0.71), 0.7)
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
                // Night synthwave on dark themes, a pastel vaporwave dusk on light ones.
                let sky = dark ? [theme.base.mix(RGB(0.03, 0.01, 0.09), 0.8), RGB(0.24, 0.04, 0.32), RGB(0.55, 0.08, 0.42)]
                    : [theme.base.mix(RGB(0.78, 0.86, 1.0), 0.7), RGB(1.0, 0.82, 0.92), RGB(1.0, 0.70, 0.80)]
                vertical(c, colors: sky.map { $0.ui.withAlphaComponent(alpha) },
                         rect: CGRect(x: 0, y: 0, width: size.width, height: horizon))
                if !highContrast {
                    neonSun(c, center: CGPoint(x: size.width / 2, y: horizon), radius: min(horizon * 0.9, size.width * 0.14),
                            stripe: dark ? RGB(0.45, 0.07, 0.40) : RGB(1.0, 0.76, 0.86))
                }
                c.restoreGState()
                let floor = theme.base.mix(dark ? RGB(0.05, 0.01, 0.10) : RGB(0.97, 0.92, 1.0), 0.7)
                Brass.fill(c, rect: CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon), radius: 0,
                           color: floor.ui.withAlphaComponent(alpha))
                if !highContrast {
                    let pink = Neon.pink(dark: dark)
                    c.saveGState()
                    c.setShadow(offset: .zero, blur: 4, color: pink.ui.withAlphaComponent(dark ? 1 : 0.5).cgColor)
                    Brass.line(c, from: CGPoint(x: 0, y: horizon), to: CGPoint(x: size.width, y: horizon),
                               color: dark ? RGB(1.0, 0.55, 0.9).ui : pink.ui, width: 1)
                    c.restoreGState()
                }
            case .circuitBoard:
                let board = Board(theme)
                Brass.fill(c, rect: bounds, radius: 0, color: board.mask.ui.withAlphaComponent(alpha))
                guard !highContrast else { return }
                circuitTraces(c, size: size, rows: rows, board: board)
            }
        }
    }

    static func neonHorizon(rows: [CGRect], height: CGFloat) -> CGFloat {
        guard let toolbar = rows.first else { return height * 0.3 }
        return rows.count > 1 ? toolbar.maxY : max(1, toolbar.maxY * 0.8)
    }

    private static func neonSun(_ c: CGContext, center: CGPoint, radius: CGFloat, stripe: RGB) {
        guard radius > 4 else { return }
        let disc = UIBezierPath(arcCenter: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
        c.saveGState(); disc.addClip()
        vertical(c, colors: [RGB(1.0, 0.85, 0.30).ui, RGB(1.0, 0.35, 0.55).ui],
                 rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius))
        // Stripes widen toward the horizon.
        c.setFillColor(stripe.ui.cgColor)
        var y = center.y - radius * 0.45, gap: CGFloat = 1
        while y < center.y {
            c.fill(CGRect(x: center.x - radius, y: y, width: radius * 2, height: gap))
            y += gap + radius * 0.12; gap += 0.8
        }
        c.restoreGState()
    }

    /// Copper under the mask: differential-pair buses along each row gap, with
    /// 45° stubs to the next bus ending in gold vias.
    private static func circuitTraces(_ c: CGContext, size: CGSize, rows: [CGRect], board: Board) {
        let trace = board.copper.ui
        var seed: UInt32 = 0x2545_F491
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 16 & 0xFFFF) / 65535
        }
        for (index, band) in rows.enumerated() {
            let y = band.maxY - 1
            for offset: CGFloat in [-1.2, 1.2] {
                Brass.line(c, from: CGPoint(x: 0, y: y + offset), to: CGPoint(x: size.width, y: y + offset), color: trace, width: 0.9)
            }
            guard index + 1 < rows.count else { continue }
            let target = rows[index + 1].maxY - 1
            var x = 14 + next() * 20
            while x < size.width - 14 {
                let path = UIBezierPath()
                let jog = min(6, (target - y) / 3)
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + (target - y) / 2 - jog))
                path.addLine(to: CGPoint(x: x + jog, y: y + (target - y) / 2))
                path.addLine(to: CGPoint(x: x + jog, y: target))
                Brass.stroke(c, path: path, color: trace.withAlphaComponent(0.85), width: 0.8)
                via(c, center: CGPoint(x: x, y: y), radius: 1.6, gold: board.gold, hole: board.mask)
                x += 38 + next() * 46
            }
        }
    }

    private static func via(_ c: CGContext, center: CGPoint, radius: CGFloat, gold: RGB, hole fill: RGB) {
        Brass.fill(c, rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                   radius: radius, color: gold.ui.withAlphaComponent(0.85))
        let hole = radius * 0.45
        Brass.fill(c, rect: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2),
                   radius: hole, color: fill.ui)
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
