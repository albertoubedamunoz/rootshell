import Foundation
import CoreGraphics
import IOSurface

/// Insertion can create a surface partway through a host layout. Reconcile
/// after that pass, when its cell metrics are available, without scheduling
/// one refresh per pane or retaining a host that has been dismantled.
@MainActor
final class HerdrLayoutRefresh {
    private var pending = false
    private var generation: UInt64 = 0

    func request(_ refresh: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        pending = true
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pending = false
            refresh()
        }
    }

    func cancel() {
        generation &+= 1
        pending = false
    }
}

/// Geometry for the UIKit Ghostty surfaces used by herdr panes, including
/// Catalyst. Ghostty's iOS/visionOS font backend uses 96 DPI; its configured
/// window padding is in 72-DPI typographic points, not UIKit points.
nonisolated enum HerdrGeometry {
    static func frameMatches(_ contents: Any, width: UInt32, height: UInt32) -> Bool {
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return false }
        let frame = unsafeBitCast(contents as CFTypeRef, to: IOSurfaceRef.self)
        return IOSurfaceGetWidth(frame) == Int(width) && IOSurfaceGetHeight(frame) == Int(height)
    }

    static func padding(_ configured: Int, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        // Match Surface.DerivedConfig.scaledPadding: floor each edge in pixels
        // before converting back to the native layout's points.
        let pixels = floor(Float(configured) * (Float(scale) * 96) / 72)
        return CGFloat(pixels) / scale
    }

    static func chrome(paddingX: Int, paddingY: Int, scale: CGFloat, bottomInsetPixels: Double) -> CGSize {
        guard scale > 0 else { return .zero }
        // Match Surface.setBottomInset's pixel rounding and clamp.
        let bottom = bottomInsetPixels.isFinite ? min(max(bottomInsetPixels.rounded(), 0), 10_000) : 0
        return CGSize(
            width: padding(paddingX, scale: scale) * 2,
            height: padding(paddingY, scale: scale) * 2 + CGFloat(bottom) / scale
        )
    }

    static func cellBudget(extent: CGFloat, chrome: CGFloat, cell: CGFloat) -> Int {
        guard cell > 0 else { return 1 }
        // A pixel divided by a 3x scale can land infinitesimally below the
        // exact cell boundary. Discard only floating-point roundoff.
        return max(1, Int(floor((extent - chrome) / cell + 1e-9)))
    }

    /// Keep the fractional-cell remainder inside the drawable. Only a full
    /// additional cell needs clamping; trimming to the minimum extent exposes
    /// the host behind the terminal, outside Ghostty's effects.
    static func clampedExtent(_ extent: CGFloat, cells: Int, cellPixels: UInt32,
                              chrome: CGFloat, scale: CGFloat) -> CGFloat {
        guard cells > 0, cellPixels > 0, scale > 0 else { return extent }
        let minimumPixels = CGFloat(cells) * CGFloat(cellPixels) + (chrome * scale).rounded()
        var minimum = minimumPixels / scale
        // Division by a 3x scale must not lose a pixel when set_size truncates.
        if floor(minimum * scale) < minimumPixels { minimum = minimum.nextUp }
        // Recover the existing split math's sub-point shortfall into the divider.
        // A larger shortfall is a real resize and must reach the server.
        let fitted = minimum <= extent + 1 ? max(extent, minimum) : extent
        let maximum = (minimumPixels + CGFloat(cellPixels) - 1) / scale
        return min(fitted, maximum)
    }

    /// The smallest extent that yields exactly `cells` after Ghostty's
    /// truncating pixel math.
    static func requiredExtent(cells: Int, cellPixels: UInt32, chrome: CGFloat, scale: CGFloat) -> CGFloat {
        guard cells > 0, cellPixels > 0, scale > 0 else { return 0 }
        let minimumPixels = CGFloat(cells) * CGFloat(cellPixels) + (chrome * scale).rounded()
        var minimum = minimumPixels / scale
        if floor(minimum * scale) < minimumPixels { minimum = minimum.nextUp }
        return minimum
    }

    /// The split ratios use a whole-cell rectangle. Its outer panes still own
    /// the remaining pixels out to the viewport edge; internal dividers stay put.
    static func extendingTrailingEdges(_ frame: CGRect, layout: CGRect, viewport: CGRect) -> CGRect {
        var result = frame
        // A layout larger than the viewport (another client's size) keeps
        // its own extent and is clipped, never shrunk.
        if frame.maxX >= layout.maxX {
            result.size.width = max(frame.width, viewport.maxX - frame.minX)
        }
        if frame.maxY >= layout.maxY {
            result.size.height = max(frame.height, viewport.maxY - frame.minY)
        }
        return result
    }
}

/// One tab's geometry negotiation. Visibility is deliberately absent: a
/// hosted background tab can prepare exactly like the selected tab.
nonisolated struct HerdrTabGeometryState {
    struct Size: Equatable, Sendable {
        let cols: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int
    }

    struct Request: Equatable, Sendable {
        let id = UUID()
        let size: Size
    }

    /// Who sizes this tab on the server, as far as the last layout said.
    enum Ownership: Equatable, Sendable {
        /// Protocol 1 server, or no layout seen yet: behave as the sole client.
        case unknown
        case none
        case mine
        case other(connectionId: UInt64?, kind: String?)
    }

    private(set) var desired: Size?
    private(set) var confirmed: Size?
    private(set) var inFlight: Request?
    private(set) var hasRequested = false
    private(set) var ownership: Ownership = .unknown

    var isConfirmed: Bool {
        desired != nil && desired == confirmed && inFlight == nil
    }

    /// Whether a geometry push may take the tab. While another client owns
    /// it, pushes only store our size for the server's interaction rule.
    var mayClaim: Bool {
        if case .other = ownership { return false }
        return true
    }

    var isOwnedElsewhere: Bool { !mayClaim }

    mutating func update(_ size: Size) {
        desired = size
    }

    mutating func beginRequest() -> Request? {
        guard let desired, !isConfirmed, inFlight == nil else { return nil }
        let request = Request(size: desired)
        inFlight = request
        hasRequested = true
        return request
    }

    /// Forget what the server confirmed: the next push resends our size.
    /// Used when the user takes a tab back on a single-owner server, where
    /// no ownership signal exists to do it for us.
    mutating func invalidate() {
        confirmed = nil
        inFlight = nil
    }

    /// The server laid the tab out at our desired size on its own (a hand-off
    /// applied the stored size): nothing to send.
    mutating func noteServerApplied(_ size: Size) {
        guard desired == size, inFlight == nil else { return }
        confirmed = size
        hasRequested = true
    }

    /// Returns true when ownership changed. Gaining the tab (or losing it)
    /// invalidates the last confirmation so the next push carries the right
    /// claim flag; a request in flight can no longer confirm anything.
    @discardableResult
    mutating func setOwnership(_ new: Ownership) -> Bool {
        guard ownership != new else { return false }
        let wasOwnedElsewhere = isOwnedElsewhere
        ownership = new
        if isOwnedElsewhere != wasOwnedElsewhere {
            confirmed = nil
            inFlight = nil
        }
        return true
    }

    /// An old stream/tab's completion cannot confirm a new request, even
    /// if its dimensions happen to match. A newer desired size stays pending.
    @discardableResult
    mutating func finish(_ request: Request, succeeded: Bool) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        confirmed = succeeded ? request.size : nil
        return true
    }
}
