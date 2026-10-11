//
//  PaneCardClip.swift
//  rootshell
//
//  Rounded Panes card clipping for SwiftUI columns
//

import SwiftUI

extension PaneCardStyle {
    static func shape(rounded: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: rounded ? cornerRadius : 0, style: .continuous)
    }

    /// Right-hand docked columns always round their leading corners; cards
    /// round all four.
    static func trailingColumnShape(rounded: Bool) -> UnevenRoundedRectangle {
        let trailing: CGFloat = rounded ? cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12,
            bottomTrailingRadius: trailing, topTrailingRadius: trailing,
            style: rounded ? .continuous : .circular)
    }
}

/// Clips to a card only while Rounded Panes is on, so the default layout
/// keeps drawing outside its bounds as before.
struct PaneCardClip: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(PaneCardStyle.shape(rounded: true))
        } else {
            content
        }
    }
}

extension View {
    func paneCardClip(_ isEnabled: Bool) -> some View {
        modifier(PaneCardClip(isEnabled: isEnabled))
    }
}

private struct PaneCardBackdropKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Translucent Rounded Panes backdrop that the split view paints only
    /// between its cards (Catalyst); nil when the window root fill covers it.
    var paneCardBackdrop: Color? {
        get { self[PaneCardBackdropKey.self] }
        set { self[PaneCardBackdropKey.self] = newValue }
    }
}

private struct PaneCardRimPaletteKey: EnvironmentKey {
    static let defaultValue: IntegratedTabEdgePalette? = nil
}

extension EnvironmentValues {
    /// Rounded Panes rim colors for the split view's cards: the integrated tab
    /// edge palette, so a joined tab's outline continues the rim exactly.
    var paneCardRimPalette: IntegratedTabEdgePalette? {
        get { self[PaneCardRimPaletteKey.self] }
        set { self[PaneCardRimPaletteKey.self] = newValue }
    }
}

/// A rect with card-shaped holes, filled even-odd, so a translucent backdrop
/// never stacks beneath translucent cards.
struct PaneCardBackdropShape: Shape {
    struct Hole {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    let holes: [Hole]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes where !hole.rect.isEmpty {
            path.addRoundedRect(
                in: hole.rect,
                cornerSize: CGSize(width: hole.cornerRadius, height: hole.cornerRadius),
                style: .continuous)
        }
        return path
    }
}

/// The window-wide effect's docked sidebar card (when the effect spans it;
/// `sidebarWidth` includes its trailing gap) and terminal card.
struct PaneCardEffectShape: Shape {
    var sidebarWidth: CGFloat

    var animatableData: CGFloat {
        get { sidebarWidth }
        set { sidebarWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let corner = CGSize(width: PaneCardStyle.cornerRadius, height: PaneCardStyle.cornerRadius)
        var path = Path()
        let sidebarCard = CGRect(x: 0, y: 0, width: sidebarWidth - PaneCardStyle.gap, height: rect.height)
        if sidebarCard.width > 0 {
            path.addRoundedRect(in: sidebarCard, cornerSize: corner, style: .continuous)
        }
        let terminalCard = CGRect(x: sidebarWidth, y: 0, width: rect.width - sidebarWidth, height: rect.height)
        if terminalCard.width > 0 {
            path.addRoundedRect(in: terminalCard, cornerSize: corner, style: .continuous)
        }
        return path
    }
}

extension View {
    /// Theme fills behind the terminal: full bleed normally, the terminal
    /// card under Rounded Panes so they never square off its corners.
    @ViewBuilder
    func cardFillExtent(_ rounded: Bool) -> some View {
        if rounded {
            clipShape(PaneCardStyle.shape(rounded: true))
        } else {
            ignoresSafeArea()
        }
    }

    /// Clips the effect layer to its cards only while Rounded Panes is on.
    @ViewBuilder
    func paneCardEffectClip(_ isEnabled: Bool, sidebarWidth: CGFloat) -> some View {
        if isEnabled {
            clipShape(PaneCardEffectShape(sidebarWidth: sidebarWidth))
        } else {
            self
        }
    }
}

// MARK: - Depth

extension IntegratedTabEdgePalette {
    /// A card's rim derives from its own surface, as the integrated tab edge does.
    init(cardSurface: Color) {
        self.init(surfaceColor: cardSurface, isLightTheme: cardSurface.isLight)
    }
}

/// Rounded Panes depth for a SwiftUI card: Liquid Glass when given a tint
/// (the card's own fill must then be clear), else a top-lit hairline rim.
private struct PaneCardDepth<CardShape: InsettableShape>: ViewModifier {
    let isEnabled: Bool
    let shape: CardShape
    let palette: IntegratedTabEdgePalette
    let glassTint: Color?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        if isEnabled, let glassTint, TransparencyManager.shared.paneGlassActive {
            content.background { glass(glassTint) }
        } else if isEnabled {
            content.overlay { rim }
        } else {
            content
        }
    }

    @ViewBuilder
    private func glass(_ tint: Color) -> some View {
        #if !os(visionOS)
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(tint), in: shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #endif
    }

    private var rim: some View {
        let keyline = palette.keyline(increasedContrast: colorSchemeContrast == .increased)
        return shape
            .strokeBorder(
                LinearGradient(
                    colors: [keyline, keyline.opacity(PaneCardStyle.rimBottomFraction)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: IntegratedTabEdgeMetrics.lineWidth(for: displayScale))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func paneCardDepth(_ isEnabled: Bool, shape: some InsettableShape, palette: IntegratedTabEdgePalette,
                       glassTint: Color? = nil) -> some View {
        modifier(PaneCardDepth(isEnabled: isEnabled, shape: shape, palette: palette, glassTint: glassTint))
    }
}

// MARK: - Glass

/// The visible tab's card frames in window coordinates, published by its split
/// view for the glass layer.
@Observable
final class PaneCardGlassFrames {
    private(set) var cards: [CGRect] = []

    func update(_ newCards: [CGRect]) {
        guard newCards != cards else { return }
        cards = newCards
    }
}

/// Liquid Glass card fills beneath the window content. A joined Integrated
/// tab and its card are one glass shape, so a single edge runs around both.
struct PaneCardGlassLayer: View {
    let frames: PaneCardGlassFrames
    let join: IntegratedTabJoin
    let joinsTab: Bool
    let tint: Color

    var body: some View {
        #if !os(visionOS)
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let tab = joinsTab ? join.span?.rect.offsetBy(dx: -origin.x, dy: -origin.y) : nil
                let cards = frames.cards.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                // One container renders the cards together; zero spacing keeps
                // them from merging across the gaps.
                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                            glass(PaneCardGlassShape(card: card, tab: tab))
                        }
                        // Over a non-glass pane the tab still needs its own glass.
                        if let tab, !cards.contains(where: { PaneCardGlassShape.joins(tab: tab, card: $0) }) {
                            glass(PaneCardGlassShape(card: nil, tab: tab))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    /// Sized to the shape, never the window: glass works over its whole frame.
    @available(iOS 26.0, *)
    private func glass(_ shape: PaneCardGlassShape) -> some View {
        let bounds = shape.bounds
        return Color.clear
            .frame(width: bounds.width, height: bounds.height)
            .glassEffect(.regular.tint(tint), in: shape.offset(by: bounds.origin))
            .padding(.leading, max(0, bounds.minX))
            .padding(.top, max(0, bounds.minY))
    }
}

/// A card unioned with the joined tab's silhouette when the tab sits on its
/// top edge. Rects are in layer coordinates; `offset(by:)` moves the path into
/// a view whose origin is `bounds.origin`.
struct PaneCardGlassShape: Shape {
    /// nil draws the tab alone.
    let card: CGRect?
    let tab: CGRect?
    var origin: CGPoint = .zero

    static func joins(tab: CGRect, card: CGRect) -> Bool {
        abs(tab.maxY - card.minY) < 2 && tab.minX < card.maxX && tab.maxX > card.minX
    }

    var bounds: CGRect { layerPath.boundingRect }

    func offset(by point: CGPoint) -> PaneCardGlassShape {
        PaneCardGlassShape(card: card, tab: tab, origin: point)
    }

    func path(in rect: CGRect) -> Path {
        layerPath.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private var layerPath: Path {
        guard let card else {
            return tab.map { IntegratedTabGeometry(in: $0).silhouettePath } ?? Path()
        }
        let corner = CGSize(width: PaneCardStyle.cornerRadius, height: PaneCardStyle.cornerRadius)
        let cardPath = Path(roundedRect: card, cornerSize: corner, style: .continuous)
        guard let tab, Self.joins(tab: tab, card: card) else { return cardPath }
        // Reach a point into the card so the union leaves no seam.
        let silhouette = IntegratedTabGeometry(in: CGRect(
            x: tab.minX, y: tab.minY, width: tab.width, height: card.minY - tab.minY + 1)).silhouettePath
        return cardPath.union(silhouette)
    }
}
