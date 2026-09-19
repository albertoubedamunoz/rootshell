import SwiftUI

/// The navigation container is installed once for the lifetime of the scene;
/// folding only changes its chrome, never the identity of MainView.
struct DuoSceneHost<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            NavigationStack {
                DuoSceneContext(content: content)
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
@available(iOS 27.1, *)
private struct DuoSceneContext<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Setting(Settings.Tabs.duoFrontDisplayMode) private var mode
    @Setting(Settings.Tabs.duoBehindCameraShowsTabs) private var showsTabs
    @State private var hasHinge = false
    @State private var isClosed = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.duoLayout, DuoLayoutContext(
                hasHinge: hasHinge, isFrontDisplay: isClosed,
                verticalEdge: verticalEdge, frontMode: mode,
                behindCameraShowsTabs: showsTabs
            ))
            .toolbarVerticalBehavior(isClosed && mode != .sideRail ? .disabled : .automatic)
            .onHingeChange { _, update in
                // Status selects a user preference; layout still comes from
                // reserved regions, never from the continuous hinge angle.
                hasHinge = update.hinge != nil
                isClosed = update.hinge?.status == .closed
            }
    }
}
#endif

struct DuoWorkspaceGeometry<Content: View>: View {
    let context: DuoLayoutContext
    let headerHeight: CGFloat
    var headerConnectsToTerminal = false
    @ViewBuilder var content: (GeometryProxy, DuoWorkspaceLayout) -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { safe in
            GeometryReader { expanded in
                content(expanded, layout(safe: safe, expanded: expanded))
            }
            .ignoresSafeArea(.container, edges: ignoredEdges)
        }
    }

    private var ignoredEdges: Edge.Set {
        if context.extendsTerminalToVerticalEdges { return .vertical }
        guard context.usesFullWidth else { return [] }
        return context.frontMode == .behindCamera && headerHeight == 0
            ? [.horizontal, .top] : .horizontal
    }

    private func layout(safe: GeometryProxy, expanded: GeometryProxy) -> DuoWorkspaceLayout {
        let frame = expanded.frame(in: .global)
        let safeFrame = safe.frame(in: .global).offsetBy(dx: -frame.minX, dy: -frame.minY)
        var occlusions: [CGRect] = []
        var divisions: [CGRect] = []
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            occlusions = expanded.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed).map(\.frame)
            divisions = expanded.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).map(\.frame)
        }
        #endif
        return .resolve(
            bounds: CGRect(origin: .zero, size: expanded.size), safeFrame: safeFrame,
            occlusions: occlusions, divisions: divisions, context: context,
            headerHeight: headerHeight, rightToLeft: layoutDirection == .rightToLeft,
            headerConnectsToTerminal: headerConnectsToTerminal
        )
    }
}

/// Camera underlap belongs only to the terminal canvas. Floating controls use
/// a separate region-aware container even when their terminal is full bleed.
struct DuoControlClearance: ViewModifier {
    @Environment(\.duoLayout) private var layout

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ZStack { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, clearance(in: proxy))
        }
    }

    private func clearance(in proxy: GeometryProxy) -> CGFloat {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), layout.usesFullWidth {
            return max(0, proxy.reservedRegions(kind: .occlusion).filter {
                $0.frame.intersects(CGRect(origin: .zero, size: proxy.size))
            }.map(\.frame.maxY).max() ?? 0)
        }
        #endif
        return 0
    }
}
