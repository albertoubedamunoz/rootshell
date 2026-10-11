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

/// Rounded Panes depth for a SwiftUI card: a top-lit hairline rim.
private struct PaneCardDepth<CardShape: InsettableShape>: ViewModifier {
    let isEnabled: Bool
    let shape: CardShape
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        if isEnabled {
            content.overlay { rim }
        } else {
            content
        }
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
    func paneCardDepth(_ isEnabled: Bool, shape: some InsettableShape, palette: IntegratedTabEdgePalette) -> some View {
        modifier(PaneCardDepth(isEnabled: isEnabled, shape: shape, palette: palette))
    }
}

/// A SwiftUI card's rim drawn by `CardRimView`, so it opens under a joined
/// Integrated tab as the split view's does. Covers the whole card.
struct JoinedCardRim: UIViewRepresentable {
    let palette: IntegratedTabEdgePalette
    let integratedTabJoin: IntegratedTabJoin?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeUIView(context: Context) -> JoinedCardRimView {
        JoinedCardRimView()
    }

    func updateUIView(_ uiView: JoinedCardRimView, context: Context) {
        uiView.palette = palette
        uiView.increasedContrast = colorSchemeContrast == .increased
        uiView.integratedTabJoin = integratedTabJoin
        uiView.updateRim()
    }

    static func dismantleUIView(_ uiView: JoinedCardRimView, coordinator: ()) {
        uiView.integratedTabJoin = nil
    }
}

final class JoinedCardRimView: UIView, IntegratedTabJoinObserver {
    var palette: IntegratedTabEdgePalette = .fallback
    var increasedContrast = false
    var integratedTabJoin: IntegratedTabJoin? {
        didSet {
            guard oldValue !== integratedTabJoin else { return }
            oldValue?.removeObserver(self)
            integratedTabJoin?.addObserver(self)
        }
    }

    private let rim = CardRimView()
    private var joinedTabID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(rim)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateRim()
    }

    // The opening is converted from window coordinates.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRim()
    }

    func integratedTabJoinDidChange() {
        updateRim(followsJoinedTab: true)
    }

    func updateRim(followsJoinedTab: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        rim.frame = bounds
        let span = integratedTabJoin?.span
        let opening: ClosedRange<CGFloat>? = span.flatMap { span in
            guard window != nil else { return nil }
            let rect = convert(span.rect, from: nil)
            return rect.minX...rect.maxX
        }
        let slides = followsJoinedTab && span?.animatesSelection == true
            && joinedTabID != nil && span?.tabID != joinedTabID
        joinedTabID = span?.tabID
        rim.update(
            cards: bounds.isEmpty ? [] : [bounds],
            color: UIColor(palette.keyline(increasedContrast: increasedContrast))
                .resolvedColor(with: traitCollection),
            lineWidth: 1 / max(1, traitCollection.displayScale),
            opening: opening,
            openingEdgeY: bounds.minY,
            animated: slides)
    }
}
