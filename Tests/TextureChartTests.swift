import XCTest
import simd
@testable import Forma

final class TextureChartTests: XCTestCase {
    func testAdjacentDenseTrianglesShareOneChartAndKeepArbitraryFaceIDs() throws {
        let a = face(73, 4, SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1))
        let b = face(11, 4, SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1))
        let result = try TextureChartBuilder.build(faces: [a, b], dimensions: [4: SIMD2(32, 24)])
        XCTAssertEqual(result.connectedIslandCount, 1)
        XCTAssertEqual(result.charts.count, 1)
        XCTAssertEqual(result.faceChartIDs, [0, 0])
        XCTAssertEqual(result.charts[0].faceIndices.sorted(), [0, 1])
        XCTAssertEqual(result.charts[0].crop, .init(x: 0, y: 0, width: 32, height: 24))
        XCTAssertEqual(a.id, 73)
        XCTAssertEqual(b.id, 11)
    }

    func testDistantObservedIslandsAvoidEmptyPhotographicRectangle() throws {
        let faces = [face(0, 3, SIMD2(0.01, 0.01), SIMD2(0.04, 0.01), SIMD2(0.01, 0.04)),
                     face(1, 3, SIMD2(0.91, 0.91), SIMD2(0.95, 0.91), SIMD2(0.91, 0.95))]
        let result = try TextureChartBuilder.build(faces: faces, dimensions: [3: SIMD2(1000, 1000)])
        XCTAssertEqual(result.connectedIslandCount, 2)
        XCTAssertEqual(result.charts.count, 2)
        XCTAssertNotEqual(result.faceChartIDs[0], result.faceChartIDs[1])
        let pixels = result.charts.reduce(0) { $0 + $1.crop.width * $1.crop.height }
        XCTAssertLessThan(pixels, 4000, "Distant islands must not claim the unobserved center of the photo")
        for chart in result.charts {
            for i in chart.faceIndices {
                for uv in [faces[i].a, faces[i].b, faces[i].c] {
                    let x = Double(uv.x) * 1000 - 0.5, y = (1 - Double(uv.y)) * 1000 - 0.5
                    XCTAssertLessThanOrEqual(Double(chart.crop.x), x)
                    XCTAssertGreaterThanOrEqual(Double(chart.crop.x + chart.crop.width - 1), x)
                    XCTAssertLessThanOrEqual(Double(chart.crop.y), y)
                    XCTAssertGreaterThanOrEqual(Double(chart.crop.y + chart.crop.height - 1), y)
                }
            }
        }
    }

    func testConnectedConcaveRegionSplitsWholeFacesWhenStorageCostDecreases() throws {
        var faces: [TextureChartBuilder.Face] = []
        for y in 0..<8 { for x in 0..<8 where x == 0 || y == 0 {
            let a = SIMD2<Float>(Float(x) / 10, Float(y) / 10)
            let b = SIMD2<Float>(Float(x + 1) / 10, a.y)
            let c = SIMD2<Float>(a.x, Float(y + 1) / 10)
            let d = SIMD2<Float>(b.x, c.y)
            faces.append(face(faces.count, 0, a, b, c))
            faces.append(face(faces.count, 0, b, d, c))
        } }
        let original = faces
        let result = try TextureChartBuilder.build(faces: faces, dimensions: [0: SIMD2(100, 100)], padding: 1)
        XCTAssertEqual(result.connectedIslandCount, 1)
        XCTAssertGreaterThan(result.charts.count, 1)
        XCTAssertEqual(result.charts.flatMap(\.faceIndices).sorted(), Array(faces.indices))
        XCTAssertEqual(Set(result.charts.flatMap(\.faceIndices)).count, faces.count)
        let padded = result.charts.reduce(0) { $0 + ($1.crop.width + 2) * ($1.crop.height + 2) }
        XCTAssertLessThan(padded, 82 * 82)
        for i in faces.indices {
            XCTAssertEqual(faces[i].a, original[i].a)
            XCTAssertEqual(faces[i].b, original[i].b)
            XCTAssertEqual(faces[i].c, original[i].c)
        }
    }

    func testSourceIdentityAndPointTouchDoNotInventUVAdjacency() throws {
        let a = face(0, 1, SIMD2(0, 0), SIMD2(0.2, 0), SIMD2(0, 0.2))
        let differentPhoto = face(1, 2, a.a, a.b, a.c)
        let touchingPoint = face(2, 1, a.c, SIMD2(0.1, 0.3), SIMD2(0, 0.3))
        let result = try TextureChartBuilder.build(faces: [a, differentPhoto, touchingPoint], dimensions: [1: SIMD2(100, 100), 2: SIMD2(100, 100)])
        XCTAssertEqual(result.connectedIslandCount, 3)
        XCTAssertEqual(Set(result.faceChartIDs).count, 3)
    }

    func testNearlyEqualEdgesAreNotQuantizedOrJoinedAndZeroSignIsCanonical() throws {
        let a = face(0, 1, SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0, 0.5))
        let close = face(1, 1, SIMD2(Float(0.5).nextUp, 0), SIMD2(0.5, 0.5), a.c)
        let result = try TextureChartBuilder.build(faces: [a, close], dimensions: [1: SIMD2(100, 100)])
        XCTAssertEqual(result.connectedIslandCount, 2)
        let b = face(2, 1, SIMD2(0.5, -0.0), SIMD2(0.5, 0.5), SIMD2(-0.0, 0.5))
        let joined = try TextureChartBuilder.build(faces: [a, b], dimensions: [1: SIMD2(100, 100)])
        XCTAssertEqual(joined.connectedIslandCount, 1)
    }

    func testInvalidFacesDimensionsAndDuplicateIDsAreRejected() throws {
        let good = face(5, 0, SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1))
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [good, good], dimensions: [0: SIMD2(10, 10)]))
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [good], dimensions: [:]))
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [good], dimensions: [0: SIMD2(0, 10)]))
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [good], dimensions: [0: SIMD2(Int.max, 10)]))
        var invalid = good
        invalid.a.x = .nan
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [invalid], dimensions: [0: SIMD2(10, 10)]))
    }

    func testCancellationAndEmptyInputDoNotProducePartialCharts() throws {
        let good = face(0, 0, SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1))
        XCTAssertThrowsError(try TextureChartBuilder.build(faces: [good], dimensions: [0: SIMD2(10, 10)],
            checkCancellation: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        let empty = try TextureChartBuilder.build(faces: [], dimensions: [:])
        XCTAssertTrue(empty.charts.isEmpty)
        XCTAssertTrue(empty.faceChartIDs.isEmpty)
    }

    private func face(_ id: Int, _ source: Int, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> TextureChartBuilder.Face {
        .init(id: id, sourceID: source, a: a, b: b, c: c)
    }
}
