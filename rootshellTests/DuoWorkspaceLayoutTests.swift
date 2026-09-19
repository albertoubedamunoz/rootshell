import SwiftUI
import XCTest

final class DuoWorkspaceLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 40, y: 70, width: 600, height: 900)
    private let safeFrame = CGRect(x: 56, y: 90, width: 490, height: 846)
    private let camera = CGRect(x: 560, y: 104, width: 44, height: 44)

    private func front(_ mode: DuoFrontDisplayMode, showsTabs: Bool = true) -> DuoLayoutContext {
        DuoLayoutContext(hasHinge: true, isFrontDisplay: true, verticalEdge: .trailing,
                         frontMode: mode, behindCameraShowsTabs: showsTabs)
    }

    func testPersistedModeIdentitiesAreStableAndRejectUnknownValues() {
        XCTAssertEqual(DuoFrontDisplayMode.allCases.map(\.rawValue), ["sideRail", "belowCamera", "behindCamera"])
        for mode in DuoFrontDisplayMode.allCases {
            XCTAssertEqual(DuoFrontDisplayMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(DuoFrontDisplayMode(rawValue: "unknown"))
    }

    func testFrontModeControlsOverrideGlobalTabVisibilityOnlyWhereIntended() {
        XCTAssertTrue(front(.sideRail).usesSideRail)
        XCTAssertFalse(front(.sideRail).usesFullWidth)
        XCTAssertFalse(front(.sideRail).showsHorizontalTabs(globallyHidden: false))
        for hidden in [true, false] {
            XCTAssertTrue(front(.belowCamera).showsHorizontalTabs(globallyHidden: hidden))
            XCTAssertTrue(front(.behindCamera).showsHorizontalTabs(globallyHidden: hidden))
            XCTAssertFalse(front(.behindCamera, showsTabs: false).showsHorizontalTabs(globallyHidden: hidden))
        }
        XCTAssertFalse(front(.belowCamera).usesSideRail)
        XCTAssertTrue(front(.behindCamera).usesFullWidth)
    }

    func testUnfoldingStopsApplyingFrontDisplayPreference() {
        for mode in DuoFrontDisplayMode.allCases {
            var context = front(mode, showsTabs: false)
            context.isFrontDisplay = false
            XCTAssertFalse(context.extendsTerminalToVerticalEdges)
            XCTAssertFalse(context.usesFullWidth)
            XCTAssertTrue(context.usesSideRail)
            context.verticalEdge = nil
            XCTAssertTrue(context.showsHorizontalTabs(globallyHidden: false))
            XCTAssertFalse(context.showsHorizontalTabs(globallyHidden: true))
        }
    }

    func testOnlyFrontSideRailExtendsTerminalToVerticalEdges() {
        XCTAssertTrue(front(.sideRail).extendsTerminalToVerticalEdges)
        XCTAssertFalse(front(.belowCamera).extendsTerminalToVerticalEdges)
        XCTAssertFalse(front(.behindCamera).extendsTerminalToVerticalEdges)
        var unresolved = front(.sideRail)
        unresolved.verticalEdge = nil
        XCTAssertFalse(unresolved.extendsTerminalToVerticalEdges)
        XCTAssertFalse(DuoLayoutContext().extendsTerminalToVerticalEdges)
    }

    func testBelowCameraStartsBelowHeaderAndOcclusionAtFullWidth() {
        for headerHeight: CGFloat in [44, 100] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [camera], divisions: [],
                context: front(.belowCamera), headerHeight: headerHeight
            )
            let terminalTop = bounds.minY + layout.headerInsets.top + headerHeight + layout.cameraClearance
            XCTAssertEqual(terminalTop, max(camera.maxY, safeFrame.minY + headerHeight))
            XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            XCTAssertEqual(layout.headerInsets.leading, 16)
            XCTAssertEqual(layout.headerInsets.trailing, 94)
        }
    }

    func testBehindCameraDoesNotReserveOcclusionAndHiddenHeaderReachesTop() {
        for headerHeight: CGFloat in [0, 44] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [camera], divisions: [],
                context: front(.behindCamera, showsTabs: headerHeight > 0), headerHeight: headerHeight
            )
            XCTAssertEqual(layout.cameraClearance, 0)
            XCTAssertEqual(layout.terminalInsets, EdgeInsets())
            XCTAssertEqual(layout.headerInsets.top, headerHeight == 0 ? 0 : 20)
        }
    }

    func testIntegratedHeaderMeetsTerminalWithoutMovingItsOrigin() {
        let display = CGRect(x: 0, y: 0, width: 600, height: 900)
        for cameraOnLeft in [false, true] {
            let region = CGRect(x: cameraOnLeft ? 0 : 520, y: 48, width: 80, height: 60)
            for rtl in [false, true] {
                for headerHeight: CGFloat in [44, 120] {
                    let ordinary = DuoWorkspaceLayout.resolve(
                        bounds: display, safeFrame: display, occlusions: [region], divisions: [],
                        context: front(.belowCamera), headerHeight: headerHeight, rightToLeft: rtl
                    )
                    let integrated = DuoWorkspaceLayout.resolve(
                        bounds: display, safeFrame: display, occlusions: [region], divisions: [],
                        context: front(.belowCamera), headerHeight: headerHeight, rightToLeft: rtl,
                        headerConnectsToTerminal: true
                    )
                    XCTAssertEqual(integrated.cameraClearance, 0)
                    XCTAssertEqual(integrated.headerInsets.top + headerHeight,
                                   ordinary.headerInsets.top + headerHeight + ordinary.cameraClearance)
                    XCTAssertGreaterThanOrEqual(integrated.headerInsets.top + headerHeight, region.maxY)
                    XCTAssertEqual(integrated.headerInsets.leading, ordinary.headerInsets.leading)
                    XCTAssertEqual(integrated.headerInsets.trailing, ordinary.headerInsets.trailing)
                    XCTAssertEqual(integrated.terminalInsets, EdgeInsets())
                }
            }
        }
    }

    func testFullWidthTerminalDoesNotPullHeaderButtonsIntoCameraColumn() {
        // Vertical bars are disabled: the ordinary safe frame can span the
        // full width even though the header still needs camera clearance.
        let display = CGRect(x: 0, y: 0, width: 600, height: 900)
        for mode in [DuoFrontDisplayMode.belowCamera, .behindCamera] {
            for cameraOnLeft in [false, true] {
                let region = CGRect(x: cameraOnLeft ? 0 : 520, y: 48, width: 80, height: 60)
                for rtl in [false, true] {
                    let layout = DuoWorkspaceLayout.resolve(
                        bounds: display, safeFrame: display, occlusions: [region], divisions: [],
                        context: front(mode), headerHeight: 44, rightToLeft: rtl
                    )
                    let left = rtl ? layout.headerInsets.trailing : layout.headerInsets.leading
                    let right = rtl ? layout.headerInsets.leading : layout.headerInsets.trailing
                    if cameraOnLeft {
                        XCTAssertEqual(left, region.maxX)
                        XCTAssertEqual(right, 0)
                    } else {
                        XCTAssertEqual(left, 0)
                        XCTAssertEqual(display.maxX - right, region.minX)
                    }
                    XCTAssertEqual(layout.terminalInsets, EdgeInsets())
                    XCTAssertEqual(layout.cameraClearance, mode == .belowCamera ? 64 : 0)
                }
            }
        }
    }

    func testMissingOrUnusableCameraGeometryKeepsAsymmetricSafeWidth() {
        for regions: [CGRect] in [[], [.null], [.zero], [CGRect(x: 800, y: 0, width: 50, height: 50)],
                                  [CGRect(x: 560, y: 900, width: 44, height: 44)]] {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: regions, divisions: [],
                context: front(.belowCamera), headerHeight: 44
            )
            XCTAssertEqual(layout.cameraClearance, 0)
            XCTAssertEqual(layout.terminalInsets.leading, 16)
            XCTAssertEqual(layout.terminalInsets.trailing, 94)
        }
    }

    func testRTLMapsPhysicalAsymmetricInsetsWithoutChangingCameraClearance() {
        let ltr = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [],
            context: front(.belowCamera), headerHeight: 44
        )
        let rtl = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [],
            context: front(.belowCamera), headerHeight: 44, rightToLeft: true
        )
        XCTAssertEqual(rtl.headerInsets.leading, ltr.headerInsets.trailing)
        XCTAssertEqual(rtl.headerInsets.trailing, ltr.headerInsets.leading)
        XCTAssertEqual(rtl.terminalInsets.leading, ltr.terminalInsets.trailing)
        XCTAssertEqual(rtl.terminalInsets.trailing, ltr.terminalInsets.leading)
        XCTAssertEqual(rtl.cameraClearance, ltr.cameraClearance)
    }

    func testTabletopKeepsTerminalAboveDivisionAndInputInsideSafeLowerRegion() {
        let division = CGRect(x: 40, y: 500, width: 600, height: 20)
        let layout = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [division],
            context: DuoLayoutContext(hasHinge: true), headerHeight: 44
        )
        XCTAssertTrue(layout.tabletopAvailable)
        XCTAssertEqual(bounds.maxY - layout.lowerReservation, division.minY)
        XCTAssertEqual(layout.inputRegion, CGRect(x: 56, y: 520, width: 490, height: 416))
    }

    func testTabletopOverrideKeepsToggleAvailableWithoutReservingSpace() {
        let division = CGRect(x: 40, y: 500, width: 600, height: 20)
        var context = DuoLayoutContext(hasHinge: true)
        context.tabletopDisabled = true
        let layout = DuoWorkspaceLayout.resolve(
            bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: [division],
            context: context, headerHeight: 44
        )
        XCTAssertTrue(layout.tabletopAvailable)
        XCTAssertEqual(layout.lowerReservation, 0)
        XCTAssertNil(layout.inputRegion)
    }

    func testTabletopPoseExitClearsAvailabilityAndAllReservations() {
        let horizontal = CGRect(x: 40, y: 500, width: 600, height: 20)
        let context = DuoLayoutContext(hasHinge: true)
        let scenarios: [(DuoLayoutContext, [CGRect])] = [
            (context, []),
            (context, [CGRect(x: 320, y: 70, width: 20, height: 900)]),
            (context, [CGRect(x: 40, y: 150, width: 600, height: 20)]),
            (context, [CGRect(x: 40, y: 800, width: 600, height: 20)]),
            (context, [CGRect(x: 100, y: 500, width: 500, height: 20)]),
            (front(.sideRail), [horizontal]),
            (DuoLayoutContext(), [horizontal]),
        ]
        for (context, divisions) in scenarios {
            let layout = DuoWorkspaceLayout.resolve(
                bounds: bounds, safeFrame: safeFrame, occlusions: [], divisions: divisions,
                context: context, headerHeight: 44
            )
            XCTAssertFalse(layout.tabletopAvailable)
            XCTAssertEqual(layout.lowerReservation, 0)
            XCTAssertNil(layout.inputRegion)
        }
    }

    func testZeroSizeDuringDisplayHandoffProducesNoReservations() {
        XCTAssertEqual(DuoWorkspaceLayout.resolve(
            bounds: .zero, safeFrame: .zero, occlusions: [camera], divisions: [],
            context: front(.belowCamera), headerHeight: 44
        ), DuoWorkspaceLayout())
    }
}
