import CoreGraphics
import XCTest

final class SessionPickerGeometryTests: XCTestCase {
    private typealias Geometry = SessionPickerGeometry

    func testCapturedHangMeasurementsDoNotUpdateState() {
        for (previous, measured): (CGFloat, CGFloat) in [
            (116.66666661518991, 116.66666661518974),
            (116.66666661368396, 116.66666661368379),
        ] {
            XCTAssertNil(Geometry.updatedHeight(previous: previous, measured: measured, displayScale: 3))
        }
    }

    func testRepeatedNoiseDoesNotAccumulateIntoStateChanges() throws {
        let retained = try XCTUnwrap(Geometry.updatedHeight(
            previous: nil, measured: 116.66666661518991, displayScale: 3
        ))
        for index in 0..<10_000 {
            let noise: CGFloat = index.isMultiple(of: 2) ? 0.00000000000017 : -0.00000000000017
            XCTAssertNil(Geometry.updatedHeight(previous: retained, measured: retained + noise, displayScale: 3))
        }
    }

    func testNoiseAcrossRoundingBoundaryDoesNotAlternatePixels() throws {
        for scale: CGFloat in [1, 2, 3] {
            let boundary = 120 + 0.5 / scale
            for initialNoise: CGFloat in [-1e-10, 1e-10] {
                let retained = try XCTUnwrap(Geometry.updatedHeight(
                    previous: nil, measured: boundary + initialNoise, displayScale: scale
                ))
                for noise: CGFloat in [-1e-10, 1e-10, -1e-10, 1e-10] {
                    XCTAssertNil(Geometry.updatedHeight(
                        previous: retained, measured: boundary + noise, displayScale: scale
                    ))
                }
            }
        }
    }

    func testMeaningfulChangesAreAcceptedAndPixelAligned() {
        for scale: CGFloat in [1, 2, 3] {
            for direction: CGFloat in [-1, 1] {
                XCTAssertEqual(Geometry.updatedHeight(
                    previous: 120, measured: 120 + direction * 1.25 / scale, displayScale: scale
                ), 120 + direction / scale)
            }
            XCTAssertNil(Geometry.updatedHeight(previous: 120, measured: 120, displayScale: scale))
        }
    }

    func testInitialAndCollapsedMeasurements() {
        XCTAssertEqual(Geometry.updatedHeight(previous: nil, measured: 10.2, displayScale: 3), 31.0 / 3)
        XCTAssertEqual(Geometry.updatedHeight(previous: nil, measured: 0, displayScale: 3), 0)
        XCTAssertEqual(Geometry.updatedHeight(previous: nil, measured: -10, displayScale: 3), 0)
        XCTAssertEqual(Geometry.updatedHeight(previous: 120, measured: 0, displayScale: 3), 0)
        XCTAssertNil(Geometry.updatedHeight(previous: 0, measured: -10, displayScale: 3))
    }

    func testNonfiniteMeasurementsAreIgnored() {
        for measured: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertNil(Geometry.updatedHeight(previous: nil, measured: measured, displayScale: 3))
            XCTAssertNil(Geometry.updatedHeight(previous: 120, measured: measured, displayScale: 3))
        }
    }

    func testInvalidDisplayScaleUsesOnePointPixels() {
        for scale: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(Geometry.updatedHeight(previous: nil, measured: 10.4, displayScale: scale), 10)
            XCTAssertNil(Geometry.updatedHeight(previous: 10, measured: 10.9, displayScale: scale))
            XCTAssertEqual(Geometry.updatedHeight(previous: 10, measured: 11.1, displayScale: scale), 11)
        }
    }

    func testPreviewMeasurementFeedbackSettlesAfterInitialMeasurement() {
        for scale: CGFloat in [1, 2, 3] {
            let viewport: CGFloat = 537.3333333333334
            let metadata: CGFloat = 116.66666666666667
            var retained: CGFloat?
            var writes = 0
            for index in 0..<1_000 {
                let preview = max(100, viewport - (retained ?? viewport))
                let noise: CGFloat = index.isMultiple(of: 2) ? 1e-10 : -1e-10
                let contentHeight = metadata + preview + noise
                if let next = Geometry.updatedHeight(
                    previous: retained, measured: contentHeight - preview, displayScale: scale
                ) {
                    retained = next
                    writes += 1
                }
            }
            XCTAssertEqual(writes, 1, "Feedback should settle at display scale \(scale)")
        }
    }
}
