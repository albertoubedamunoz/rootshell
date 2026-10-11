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
            PaneCardGlassHost(content: Color.clear.glassEffect(.regular.tint(tint), in: shape))
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

/// Each tab's terminal card frames for the glass layer. Cards come from the
/// split view in its own coordinates and the host frame from SwiftUI before
/// the app-tab swipe offset, so neither goes stale mid-slide.
@Observable
final class PaneCardGlassFrames {
    struct Tab: Equatable {
        var cards: [CGRect] = []
        var hostFrame: CGRect?
    }

    private(set) var tabs: [UUID: Tab] = [:]

    func updateCards(_ cards: [CGRect], for tabID: UUID) {
        guard tabs[tabID, default: Tab()].cards != cards else { return }
        tabs[tabID, default: Tab()].cards = cards
    }

    func updateHostFrame(_ frame: CGRect, for tabID: UUID) {
        guard tabs[tabID]?.hostFrame != frame else { return }
        tabs[tabID, default: Tab()].hostFrame = frame
    }

    func retain(_ tabIDs: Set<UUID>) {
        guard tabs.keys.contains(where: { !tabIDs.contains($0) }) else { return }
        tabs = tabs.filter { tabIDs.contains($0.key) }
    }
}

/// Liquid Glass card fills beneath the window content. A joined Integrated
/// tab and its card are one glass shape, so a single edge runs around both.
struct PaneCardGlassLayer: View {
    let frames: PaneCardGlassFrames
    let swipe: MainView.AppTabSwipeStore
    let tabsModel: TabsModel
    let join: IntegratedTabJoin
    let joinsTab: Bool
    /// The exposé: one card over the whole terminal area in place of the splits.
    let mergesCards: Bool
    let tint: Color

    /// A visible tab's viewport and cards in layer coordinates, before its slide.
    private struct TabGroup: Identifiable {
        let id: UUID
        let host: CGRect
        let cards: [CGRect]
    }

    var body: some View {
        #if !os(visionOS)
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let tab = joinsTab ? join.span?.rect.offsetBy(dx: -origin.x, dy: -origin.y) : nil
                let state = swipe.state
                // Sliding glass clips to its tab's viewport, as the terminals do.
                let isSliding = state != nil
                let visibleTabIDs = state.map { [$0.sourceTabID, $0.targetTabID] }
                    ?? [tabsModel.displayedTabID].compactMap { $0 }
                let groups = visibleTabIDs.compactMap { id -> TabGroup? in
                    guard let entry = frames.tabs[id], let hostFrame = entry.hostFrame else { return nil }
                    let host = hostFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                    return TabGroup(id: id, host: host,
                                    cards: entry.cards.map { $0.offsetBy(dx: host.minX, dy: host.minY) })
                }
                // The tab bar doesn't slide, so the tab joins only at rest.
                let joinedTab = isSliding ? nil : tab
                ZStack(alignment: .topLeading) {
                    ForEach(groups) { group in
                        ZStack(alignment: .topLeading) {
                            cardGlass(group.cards, tab: joinedTab, size: proxy.size)
                                .opacity(mergesCards ? 0 : 1)
                                .animation(Self.splitSwap(mergesCards), value: mergesCards)
                            cardGlass([group.host], tab: joinedTab, size: proxy.size)
                                .opacity(mergesCards ? 1 : 0)
                                .animation(Self.mergeFade, value: mergesCards)
                        }
                        .offset(x: state?.offsetX(for: group.id, width: group.host.width) ?? 0)
                        .clipShape(PaneCardGlassClip(rect: isSliding ? group.host : nil))
                    }
                    // Over a non-glass pane the tab still needs its own glass.
                    if let tab, !(joinedTab != nil && groups.contains(where: { group in
                        group.cards.contains { PaneCardGlassShape.joins(tab: tab, card: $0) }
                    })) {
                        // The merged card joins the tab itself (Screen Sharing tabs have no split glass).
                        let mergedJoinsTab = joinedTab != nil
                            && groups.contains { PaneCardGlassShape.joins(tab: tab, card: $0.host) }
                        GlassEffectContainer(spacing: 0) {
                            glass(PaneCardGlassShape(card: nil, tab: tab))
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        }
                        .opacity(mergesCards && mergedJoinsTab ? 0 : 1)
                        .animation(Self.splitSwap(mergesCards), value: mergesCards)
                    }
                }
            }
            .ignoresSafeArea()
            // Track the finger exactly, as the sliding terminals do.
            .transaction {
                if swipe.state?.isSettling == false { $0.animation = nil }
            }
        }
        #endif
    }

    /// The merged card fades over the split glass, which hides only once it is
    /// opaque and returns before it fades out, so the fill never dips to the backdrop.
    private static let mergeFade = Animation.easeInOut(duration: 0.2)

    private static func splitSwap(_ merging: Bool) -> Animation? {
        merging ? .linear(duration: 0).delay(0.2) : nil
    }

    /// One container renders the cards together; zero spacing keeps them
    /// from merging across the gaps.
    @available(iOS 26.0, *)
    private func cardGlass(_ cards: [CGRect], tab: CGRect?, size: CGSize) -> some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    glass(PaneCardGlassShape(card: card, tab: tab))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
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

/// Hosts pane glass in a window that always reads as active: macOS otherwise
/// renders glass in inactive windows far brighter.
struct PaneCardGlassHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
        host.traitOverrides.activeAppearance = .active
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
    }
}

/// Clips to `rect`, or to the whole frame when nil.
private struct PaneCardGlassClip: Shape {
    let rect: CGRect?

    func path(in bounds: CGRect) -> Path {
        Path(rect ?? bounds)
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
