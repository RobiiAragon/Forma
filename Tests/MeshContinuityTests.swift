import XCTest
import simd
@testable import Forma

/// Authored boundary fixtures test topology and preservation, not scanner accuracy.
final class MeshContinuityTests: XCTestCase {
    func testAdjacentAnchorBoundariesJoinWithoutChangingFacesOrCoordinates() throws {
        let original = adjacent()
        var result = try MeshContinuity.process(original)
        XCTAssertEqual(result.metrics.verticesMerged, 2)
        XCTAssertEqual(result.mesh.vertices.count, 4)
        XCTAssertEqual(result.metrics.surfaceComponentsBefore, 2)
        XCTAssertEqual(result.metrics.surfaceComponentsAfter, 1)
        XCTAssertEqual(result.metrics.boundaryEdgesBefore, 6)
        XCTAssertEqual(result.metrics.boundaryEdgesAfter, 4)
        XCTAssertEqual(result.metrics.maxDisplacementMeters, 0)
        XCTAssertEqual(result.mesh.faceCount, original.faceCount)
        XCTAssertEqual(result.mesh.triangles, original.triangles.map { result.sourceVertexToOutput[Int($0)] })
        XCTAssertTrue(result.mesh.vertices.allSatisfy { original.vertices.contains($0) })
        XCTAssertEqual(original.vertices.count, 6)
        XCTAssertEqual(original.triangles, [0,1,2,3,4,5])
        result.mesh.vertices[0] = SIMD3(10,10,10)
        XCTAssertEqual(original.vertices[0], SIMD3(-1,0,0), "Derived output must not mutate retained source storage")
    }

    func testExactRadiusSearchChecksNeighboringCellsAndRejectsDiagonalOutsideRadius() throws {
        let mesh = MeshSnapshot(vertices: [SIMD3(0,-1,0), SIMD3(0.00049,0,0), SIMD3(0.00049,1,0),
                                          SIMD3(0.00051,0,0), SIMD3(1,0,0), SIMD3(0.00051,1,0)],
                                triangles: [0,1,2,3,4,5])
        XCTAssertNotEqual(floor(Double(mesh.vertices[1].x) / 0.0005), floor(Double(mesh.vertices[3].x) / 0.0005))
        let joined = try MeshContinuity.process(mesh)
        XCTAssertEqual(joined.metrics.verticesMerged, 2, "Points across a hash-cell border still lie inside the physical radius")
        XCTAssertEqual(joined.metrics.maxDisplacementMeters, 0.00002, accuracy: 1e-9)
        let outside = try MeshContinuity.process(adjacent(offset: SIMD3(0.0004,0.0004,0)))
        XCTAssertEqual(outside.metrics.verticesMerged, 0, "Same/neighboring grid cells do not imply Euclidean proximity")
        let inside = try MeshContinuity.process(adjacent(offset: SIMD3(0.00049,0,0)))
        XCTAssertEqual(inside.metrics.verticesMerged, 2)
        XCTAssertLessThanOrEqual(inside.metrics.maxDisplacementMeters, inside.metrics.toleranceMeters)
    }

    func testSharpCornerAndOppositeFacesRemainSeparate() throws {
        let corner = MeshSnapshot(vertices: [SIMD3(-1,0,0),SIMD3(0,0,0),SIMD3(0,1,0),
                                            SIMD3(0,0,0),SIMD3(0,0,1),SIMD3(0,1,0)],
                                  triangles: [0,1,2,3,4,5])
        let a = try MeshContinuity.process(corner)
        XCTAssertEqual(a.metrics.verticesMerged, 0)
        XCTAssertEqual(a.metrics.surfaceComponentsAfter, 2)
        var opposite = adjacent(offset: SIMD3(0,0,0.000005))
        opposite.triangles.swapAt(4, 5)
        let b = try MeshContinuity.process(opposite)
        XCTAssertEqual(b.metrics.verticesMerged, 0)
        XCTAssertGreaterThan(b.metrics.candidatePairsRejectedForOrientation, 0)
    }

    func testThinParallelSheetsAndOverlappingSameWindingCopiesRemainSeparate() throws {
        let thin = try MeshContinuity.process(adjacent(offset: SIMD3(0,0,0.0002)))
        XCTAssertEqual(thin.metrics.verticesMerged, 0, "A close parallel depth layer is not a tangential anchor seam")
        let copy = MeshSnapshot(vertices: [SIMD3(-1,0,0),SIMD3(0,0,0),SIMD3(0,1,0),
                                          SIMD3(-1,0,0),SIMD3(0,0,0),SIMD3(0,1,0)],
                                triangles: [0,1,2,3,4,5])
        let overlap = try MeshContinuity.process(copy)
        XCTAssertEqual(overlap.metrics.verticesMerged, 0, "Coincident sheets with the same directed boundary are not an adjacent seam")
        XCTAssertEqual(overlap.mesh.faceCount, 2)
    }

    func testSmallFeatureAndUnusedSourceVertexAreNotRemoved() throws {
        var mesh = adjacent()
        mesh.vertices += [SIMD3(3,0,0),SIMD3(3.0001,0,0),SIMD3(3,0.0001,0),SIMD3(9,9,9)]
        mesh.triangles += [6,7,8]
        let result = try MeshContinuity.process(mesh)
        XCTAssertEqual(result.metrics.verticesMerged, 2)
        XCTAssertEqual(result.mesh.faceCount, 3)
        XCTAssertEqual(result.metrics.isolatedVerticesBefore, 1)
        XCTAssertEqual(result.metrics.isolatedVerticesAfter, 1)
        XCTAssertEqual(result.metrics.surfaceComponentsBefore, 3)
        XCTAssertEqual(result.metrics.surfaceComponentsAfter, 2)
        for index in 6..<10 { XCTAssertEqual(result.mesh.vertices[Int(result.sourceVertexToOutput[index])], mesh.vertices[index]) }
        let indices = result.mesh.triangles.suffix(3).map(Int.init)
        XCTAssertGreaterThan(simd_length(simd_cross(result.mesh.vertices[indices[1]] - result.mesh.vertices[indices[0]],
                                                   result.mesh.vertices[indices[2]] - result.mesh.vertices[indices[0]])), 0)
    }

    func testPointContactWithoutMatchingBoundaryEdgeDoesNotJoinComponents() throws {
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0),
                                          SIMD3(0,0,0),SIMD3(-1,0,0),SIMD3(0,-1,0)],
                                triangles: [0,1,2,3,4,5])
        XCTAssertEqual(try MeshContinuity.process(mesh).metrics.verticesMerged, 0)
    }

    func testInvalidInputIsRejectedWithoutSilentlyDroppingFaces() throws {
        for mesh in [MeshSnapshot(vertices: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(2,0,0)], triangles: [0,1,2]),
                     MeshSnapshot(vertices: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)], triangles: [0,1,9]),
                     MeshSnapshot(vertices: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)], triangles: [0,1,1]),
                     MeshSnapshot(vertices: [SIMD3(Float.nan,0,0),SIMD3(1,0,0),SIMD3(0,1,0)], triangles: [0,1,2])] {
            let savedIndices = mesh.triangles
            XCTAssertThrowsError(try MeshContinuity.process(mesh))
            XCTAssertEqual(mesh.triangles, savedIndices)
        }
    }

    func testCancellationBeforeAndDuringProcessingNeverReturnsPartialOutput() async throws {
        let mesh = adjacent()
        let before = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MeshContinuity.process(mesh)
        }
        do { _ = try await before.value; XCTFail("Cancelled work must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let during = Task.detached {
            try MeshContinuity.process(mesh) { fraction in
                if fraction >= 0.15 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await during.value; XCTFail("Cancellation at the processing boundary must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(mesh.vertices.count, 6)
    }

    private func adjacent(offset: SIMD3<Float> = .zero) -> MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(-1,0,0),SIMD3(0,0,0),SIMD3(0,1,0),
                                SIMD3(0,0,0) + offset,SIMD3(1,0,0) + offset,SIMD3(0,1,0) + offset],
                     triangles: [0,1,2,3,4,5])
    }
}
