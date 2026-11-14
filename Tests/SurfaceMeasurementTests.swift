import XCTest
import simd
@testable import Forma

final class SurfaceMeasurementTests: XCTestCase {
    func testConvexMetricRectangleAndReversedOrder() throws {
        let rectangle: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(3,2,0), SIMD3(0,2,0)]
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(rectangle), 6, accuracy: 0.00001)
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(Array(rectangle.reversed())), 6, accuracy: 0.00001)
        let vertical: [SIMD3<Float>] = [SIMD3(0,2,0), SIMD3(4,2,0), SIMD3(4,2,3), SIMD3(0,2,3)]
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(vertical), 12, accuracy: 0.00001)
    }

    func testConcavePolygonUsesItsBoundaryRatherThanItsConvexHull() throws {
        // A 3 × 3 m square with a 2 × 2 m corner removed: 9 - 4 = 5 m².
        let lShape: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(3,1,0),
                                    SIMD3(1,1,0), SIMD3(1,3,0), SIMD3(0,3,0)]
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(lShape), 5, accuracy: 0.00001)
    }

    func testRotationTranslationAndMetricScaleProduceSquareMeterUnits() throws {
        let rectangle: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(3,2,0), SIMD3(0,2,0)]
        let rotation = simd_quatf(angle: 0.73, axis: simd_normalize(SIMD3<Float>(1,2,3)))
        let transformed = rectangle.map { rotation.act($0 * 2.5) + SIMD3<Float>(1200,-45,79) }
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(transformed), 37.5, accuracy: 0.002,
                       "A 2.5× metric scale must scale area by 6.25, independently of its world pose")
    }

    func testRejectsNonPlanarSelectionAndAllowsDocumentedMillimeterNoise() throws {
        let bent: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(2,0,0), SIMD3(2,2,0.4), SIMD3(0,2,0)]
        XCTAssertThrowsError(try SurfaceMeasurement.polygonArea(bent)) { error in
            guard case SurfaceMeasurement.Failure.nonPlanar(let deviation, let tolerance) = error else {
                return XCTFail("Expected a clear non-planar selection error, got \(error)")
            }
            XCTAssertGreaterThan(deviation, tolerance)
            XCTAssertGreaterThanOrEqual(tolerance, 0.005)
        }
        let noisy: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0.008), SIMD3(0,1,0)]
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(noisy), 1, accuracy: 0.0001,
                       "Sub-tolerance mesh noise is projected onto the estimated plane")
    }

    func testRejectsCrossingsAndCollinearFoldedEdges() {
        let bowTie: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(2,2,0), SIMD3(0,2,0), SIMD3(2,0,0)]
        assertFailure(.selfIntersection, points: bowTie)
        let folded: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(3,0,0), SIMD3(1,0,0), SIMD3(1,2,0), SIMD3(0,2,0)]
        assertFailure(.selfIntersection, points: folded)
        let touching: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(2,0,0), SIMD3(2,2,0),
                                      SIMD3(1,1,0), SIMD3(0,2,0), SIMD3(1,1,0)]
        assertFailure(.selfIntersection, points: touching)
    }

    func testRejectsInsufficientNonFiniteRepeatedAndCollinearPoints() {
        assertFailure(.insufficientPoints, points: [SIMD3(0,0,0), SIMD3(1,0,0)])
        assertFailure(.nonFinite, points: [SIMD3(0,0,0), SIMD3(.nan,0,0), SIMD3(0,1,0)])
        assertFailure(.nonFinite, points: [SIMD3(0,0,0), SIMD3(.infinity,0,0), SIMD3(0,1,0)])
        assertFailure(.degenerate, points: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(2,0,0)])
        assertFailure(.degenerate, points: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,0,0), SIMD3(0,1,0)])
        assertFailure(.degenerate, points: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,0)])
    }

    func testAllowsStraightCollinearBoundarySubdivisionWithoutFolding() throws {
        let points: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(2,0,0), SIMD3(2,1,0), SIMD3(0,1,0)]
        XCTAssertEqual(try SurfaceMeasurement.polygonArea(points), 2, accuracy: 0.00001)
    }

    private func assertFailure(_ expected: SurfaceMeasurement.Failure, points: [SIMD3<Float>],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SurfaceMeasurement.polygonArea(points), file: file, line: line) { error in
            XCTAssertEqual(error as? SurfaceMeasurement.Failure, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }
}
