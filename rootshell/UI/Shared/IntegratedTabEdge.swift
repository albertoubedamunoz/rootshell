//
//  IntegratedTabEdge.swift
//  rootshell
//
//  The Integrated style's border: a hairline running the window's full width
//  along the strip/terminal boundary and up around the active tab.
//
//  Two pieces, not one path, so no tab frame has to reach the strip. They join
//  because both are the same hairline and the shoulder curves are tangent to
//  horizontal exactly where the rule lives.
//

import SwiftUI

// MARK: - Metrics

enum IntegratedTabEdgeMetrics {
    /// One physical pixel. Anything heavier reads as a drawn box, not an edge.
    static func lineWidth(for displayScale: CGFloat) -> CGFloat {
        1 / max(1, displayScale)
    }

    /// For layouts reserving room before a display scale is available (1x case).
    static let reservedThickness: CGFloat = 1
}

/// Theme-derived optical colors for the integrated edge.
///
/// The old white/black alpha stroke inherited some color from its backdrop,
/// but blending toward an achromatic endpoint washed chromatic themes toward
/// gray. These colors are resolved from the terminal surface itself, so a
/// blue-purple surface such as Catppuccin Mocha keeps that hue in its rim.
struct IntegratedTabEdgePalette: Equatable {
    let surfaceColor: Color?
    let isLightTheme: Bool

    static let fallback = IntegratedTabEdgePalette(
        surfaceColor: nil,
        isLightTheme: false
    )

    func keyline(increasedContrast: Bool) -> Color {
        guard let surfaceColor else {
            return Color(uiColor: .separator)
        }
        if isLightTheme {
            return surfaceColor.darkenedPreservingHue(increasedContrast ? 0.36 : 0.26)
        }
        return surfaceColor.lightenedPreservingHue(increasedContrast ? 0.42 : 0.32)
    }
}

// MARK: - Shared silhouette geometry

/// Silhouette metrics, shared by the opaque fill (`BrowserTabShape`) and the
/// hairline outline so the two can never drift.
struct IntegratedTabGeometry {
    /// Tab body below the narrow strip of frame left visible above the tab.
    let tabRect: CGRect
    /// Wider than tall: a 1:1 corner reads as a sharp hook at Retina scale.
    let shoulderWidth: CGFloat
    let shoulderHeight: CGFloat
    let cornerRadius: CGFloat

    static let bezierKappa: CGFloat = 0.552_284_8

    init(in rect: CGRect) {
        let topInset = min(5, rect.height * 0.12)
        tabRect = CGRect(
            x: rect.minX,
            y: rect.minY + topInset,
            width: rect.width,
            height: max(0, rect.height - topInset)
        )
        shoulderWidth = min(16, tabRect.width * 0.12)
        shoulderHeight = min(10, tabRect.height * 0.28)
        cornerRadius = min(10, tabRect.height * 0.28)
    }

    /// Left shoulder → top → right shoulder, open at the bottom. `bottomInset`
    /// lifts the ends so a stroked copy lands on the rule's band, inside the row.
    func outlinePath(bottomInset: CGFloat = 0) -> Path {
        let bottom = tabRect.maxY - bottomInset
        let kappa = Self.bezierKappa
        var path = Path()
        path.move(to: CGPoint(x: tabRect.minX, y: bottom))
        path.addCurve(
            to: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight
            ),
            control1: CGPoint(
                x: tabRect.minX + shoulderWidth * kappa,
                y: bottom
            ),
            control2: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            )
        )
        path.addLine(to: CGPoint(
            x: tabRect.minX + shoulderWidth,
            y: tabRect.minY + cornerRadius
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.minX + shoulderWidth + cornerRadius, y: tabRect.minY),
            control: CGPoint(x: tabRect.minX + shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth - cornerRadius,
            y: tabRect.minY
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY + cornerRadius),
            control: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth,
            y: bottom - shoulderHeight
        ))
        path.addCurve(
            to: CGPoint(x: tabRect.maxX, y: bottom),
            control1: CGPoint(
                x: tabRect.maxX - shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            ),
            control2: CGPoint(
                x: tabRect.maxX - shoulderWidth * kappa,
                y: bottom
            )
        )
        return path
    }

    /// Closed silhouette for the opaque fill. Bottom stays flush so matching the
    /// terminal background reads as one connected surface.
    var silhouettePath: Path {
        var path = outlinePath()
        path.closeSubpath()
        return path
    }
}

// MARK: - Shapes

/// Open path, to be stroked. Not pre-stroked via `strokedPath`: a ribbon's two
/// antialiased edges interfere at hairline width and speckle the shoulders.
struct IntegratedTabOutlineShape: Shape {
    var bottomInset: CGFloat

    func path(in rect: CGRect) -> Path {
        IntegratedTabGeometry(in: rect).outlinePath(bottomInset: bottomInset)
    }
}

/// The horizontal run along the strip/terminal boundary. Centered on the same
/// band as `IntegratedTabOutlineShape`'s open ends so the two abut without a step.
struct IntegratedTabEdgeRule: Shape {
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX,
            y: rect.maxY - lineWidth,
            width: rect.width,
            height: lineWidth
        ))
    }
}

// MARK: - Views

/// The separator across the strip. Keeping this to exactly one physical pixel
/// prevents the shallow active-tab shoulders from appearing to dip below it.
struct IntegratedTabEdgeRuleView: View {
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        IntegratedTabEdgeRule(lineWidth: lineWidth)
            .fill(palette.keyline(increasedContrast: increasedContrast))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Paints the rule's band out across the tab, in the tab's own color. At the
/// shoulder tips the silhouette has not yet climbed clear of that band, so rule
/// and outline would overlap there and composite to double density.
struct IntegratedTabEdgeOccluder: View {
    let color: Color

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: IntegratedTabEdgeMetrics.lineWidth(for: displayScale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The tab's raised edge. A single physical-pixel chromatic stroke keeps its
/// shoulder endpoints flush with the rule without a simulated crest artifact.
struct IntegratedTabOutlineView: View {
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        let keyline = palette.keyline(increasedContrast: increasedContrast)
        IntegratedTabOutlineShape(bottomInset: lineWidth / 2)
            .stroke(
                keyline,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            // The path already ends one half-line-width above the boundary;
            // clipping makes that containment explicit to the renderer.
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
