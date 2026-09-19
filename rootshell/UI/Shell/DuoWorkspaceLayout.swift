import SwiftUI

/// Scene-local capabilities, independent of the persisted front-display choice.
struct DuoLayoutContext: Equatable {
    var hasHinge = false
    var isFrontDisplay = false
    var verticalEdge: HorizontalEdge?
    var frontMode: DuoFrontDisplayMode = .sideRail
    var behindCameraShowsTabs = true
    var tabletopDisabled = false

    var usesFullWidth: Bool { isFrontDisplay && frontMode != .sideRail }
    var usesSideRail: Bool { verticalEdge != nil && !usesFullWidth }
    // The front terminal occupies the column beside the system rail. Its
    // rectangular grid can reach both vertical edges in this mode.
    var extendsTerminalToVerticalEdges: Bool { isFrontDisplay && usesSideRail }

    func showsHorizontalTabs(globallyHidden: Bool) -> Bool {
        if usesFullWidth {
            return frontMode == .belowCamera || behindCameraShowsTabs
        }
        return !usesSideRail && !globallyHidden
    }
}

private struct DuoLayoutContextKey: EnvironmentKey {
    static let defaultValue = DuoLayoutContext()
}

extension EnvironmentValues {
    var duoLayout: DuoLayoutContext {
        get { self[DuoLayoutContextKey.self] }
        set { self[DuoLayoutContextKey.self] = newValue }
    }
}

/// All rectangles use the workspace's local, physical coordinate space.
/// Keeping this calculation separate makes transitions testable without a device.
struct DuoWorkspaceLayout: Equatable {
    var headerInsets: EdgeInsets = .init()
    var terminalInsets: EdgeInsets = .init()
    var cameraClearance: CGFloat = 0
    var lowerReservation: CGFloat = 0
    var inputRegion: CGRect?
    var tabletopAvailable = false

    static func resolve(
        bounds: CGRect, safeFrame: CGRect, occlusions: [CGRect], divisions: [CGRect],
        context: DuoLayoutContext, headerHeight: CGFloat, rightToLeft: Bool = false
    ) -> Self {
        guard bounds.width > 0, bounds.height > 0 else { return Self() }
        let left = max(0, safeFrame.minX - bounds.minX)
        let right = max(0, bounds.maxX - safeFrame.maxX)
        let top = max(0, safeFrame.minY - bounds.minY)
        let sideInsets = EdgeInsets(
            top: 0, leading: rightToLeft ? right : left,
            bottom: 0, trailing: rightToLeft ? left : right
        )
        var result = Self()
        result.headerInsets = sideInsets
        result.headerInsets.top = headerHeight > 0 ? top : 0

        if context.usesFullWidth {
            if headerHeight > 0 {
                // Disabling the system side bar can remove its horizontal
                // safe inset. The terminal may reclaim that column, but its
                // header must still stop before the camera's reserved region
                // (which already includes the system's interaction margins).
                // Reserve the column even when the camera sits just below the
                // header: otherwise the last button hugs the rounded corner.
                var headerSegments = [safeFrame.minX...safeFrame.maxX]
                for region in occlusions where !region.isEmpty && !region.isNull && region.intersects(bounds) {
                    headerSegments = headerSegments.flatMap { segment -> [ClosedRange<CGFloat>] in
                        guard region.maxX > segment.lowerBound, region.minX < segment.upperBound else {
                            return [segment]
                        }
                        var remaining: [ClosedRange<CGFloat>] = []
                        if region.minX > segment.lowerBound {
                            remaining.append(segment.lowerBound...region.minX)
                        }
                        if region.maxX < segment.upperBound {
                            remaining.append(region.maxX...segment.upperBound)
                        }
                        return remaining
                    }
                }
                if let segment = headerSegments.max(by: {
                    $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound
                }) {
                    let headerLeft = max(0, segment.lowerBound - bounds.minX)
                    let headerRight = max(0, bounds.maxX - segment.upperBound)
                    result.headerInsets.leading = rightToLeft ? headerRight : headerLeft
                    result.headerInsets.trailing = rightToLeft ? headerLeft : headerRight
                }
            }
            if context.frontMode == .belowCamera {
                let cameraBottom = occlusions.filter {
                    !$0.isEmpty && !$0.isNull && $0.intersects(bounds)
                }.map(\.maxY).max()
                if let cameraBottom, bounds.maxY - cameraBottom >= 120 {
                    result.cameraClearance = max(0, cameraBottom - bounds.minY - top - headerHeight)
                } else {
                    // Geometry can be absent during a display handoff. Keep the
                    // safe rectangle until the camera region is available.
                    result.terminalInsets = sideInsets
                }
            }
        }

        if context.hasHinge && !context.isFrontDisplay,
           let division = divisions.first(where: {
               $0.width > $0.height && $0.minX <= safeFrame.minX && $0.maxX >= safeFrame.maxX
                   && $0.minY - bounds.minY - headerHeight >= 120
                   && bounds.maxY - $0.maxY >= 216
           }) {
            result.tabletopAvailable = true
            if !context.tabletopDisabled {
                result.lowerReservation = bounds.maxY - division.minY
                result.inputRegion = CGRect(
                    x: safeFrame.minX, y: division.maxY,
                    width: safeFrame.width, height: max(0, safeFrame.maxY - division.maxY)
                )
            }
        }
        return result
    }
}
