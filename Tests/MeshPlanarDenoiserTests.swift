import XCTest
import simd
@testable import Forma

/// Synthetic geometry proves bounds and preservation, not scanner accuracy.
final class MeshPlanarDenoiserTests: XCTestCase {
    private var enabled: MeshPlanarDenoiser.Configuration {
        var config = MeshPlanarDenoiser.Configuration()
        config.enabled = true
        return config
    }

    func testNoisyPlaneReducesDeviationPreservingTopologyBoundaryAndSource() throws {
        let source = grid { x, y, noise in SIMD3(x, y, noise) }
        let saved = source.vertices
        var result = try MeshPlanarDenoiser.process(source, configuration: enabled)
        XCTAssertEqual(result.metrics.acceptedRegions, 1)
        XCTAssertGreaterThan(result.metrics.movedVertices, 500)
        XCTAssertLessThan(result.metrics.planeDeviationAfterRMSMeters,
                          result.metrics.planeDeviationBeforeRMSMeters * 0.6)
        XCTAssertLessThanOrEqual(result.metrics.maxDisplacementMeters, enabled.toleranceMeters)
        XCTAssertEqual(result.mesh.triangles, source.triangles)
        XCTAssertEqual(result.mesh.vertexCount, source.vertexCount)
        XCTAssertGreaterThan(result.metrics.planeSupportVertices, 800)
        XCTAssertGreaterThan(result.metrics.processingSeconds, 0)
        for y in 0..<31 { for x in 0..<31 where x <= 1 || y <= 1 || x >= 29 || y >= 29 {
            XCTAssertEqual(result.mesh.vertices[y * 31 + x], source.vertices[y * 31 + x])
        } }
        assertNoFlips(source, result.mesh)
        result.mesh.vertices[0] = SIMD3(9,9,9)
        XCTAssertEqual(source.vertices, saved)
    }

    func testArbitraryPlaneOrientationAndTranslationUseMeters() throws {
        let source = grid { x, y, noise in
            let a = SIMD3<Float>(0.8, 0, 0.6), b = SIMD3<Float>(0, 1, 0)
            return SIMD3<Float>(10, -7, 3) + x * a + y * b + noise * simd_cross(a, b)
        }
        let result = try MeshPlanarDenoiser.process(source, configuration: enabled)
        XCTAssertEqual(result.metrics.acceptedRegions, 1)
        XCTAssertLessThan(result.metrics.planeDeviationAfterRMSMeters,
                          result.metrics.planeDeviationBeforeRMSMeters * 0.6)
        XCTAssertLessThanOrEqual(result.metrics.maxDisplacementMeters, enabled.toleranceMeters)
        assertNoFlips(source, result.mesh)
    }

    func testSharpConnectedCornerRetainsSeamAndFaces() throws {
        var source = grid { x, y, noise in SIMD3(x, y, y == 0 ? 0 : noise) }
        // Second plane shares its first row with the first plane's boundary.
        let second = grid { x, z, noise in SIMD3(x, z == 0 ? 0 : noise, z) }
        var mapping: [UInt32] = []
        for i in second.vertices.indices {
            if i < 31 { mapping.append(UInt32(i)) }
            else { mapping.append(UInt32(source.vertices.count)); source.vertices.append(second.vertices[i]) }
        }
        source.triangles += second.triangles.map { mapping[Int($0)] }
        let result = try MeshPlanarDenoiser.process(source, configuration: enabled)
        XCTAssertEqual(result.mesh.triangles, source.triangles)
        XCTAssertEqual(result.mesh.vertexCount, source.vertexCount)
        for i in 0..<31 { XCTAssertEqual(result.mesh.vertices[i], source.vertices[i]) }
        assertNoFlips(source, result.mesh)
    }

    func testGraduallyCurvedSurfaceAndShallowReliefAreRejected() throws {
        // The entire bend is within displacement tolerance and normal limits;
        // rejection must therefore depend on coherent shape, not just amplitude.
        let bend = grid { x, y, _ in SIMD3(x, y, 0.004 * (x - 0.6) * (x - 0.6)) }
        let relief = grid { x, y, noise in
            let bump = Float(0.0018 * exp(-Double((x-0.6)*(x-0.6) + (y-0.6)*(y-0.6)) / 0.04))
            return SIMD3(x, y, bump + noise * 0.15)
        }
        let step = grid { x, y, noise in SIMD3(x, y, (x > 0.6 ? 0.0012 : 0) + noise * 0.1) }
        for mesh in [bend, relief, step] {
            let result = try MeshPlanarDenoiser.process(mesh, configuration: enabled)
            XCTAssertEqual(result.metrics.acceptedRegions, 0)
            XCTAssertEqual(result.mesh.vertices, mesh.vertices)
            XCTAssertEqual(result.mesh.triangles, mesh.triangles)
        }
    }

    func testIsolatedDetailPeakAndNoisyParallelSheetsRemainDistinct() throws {
        var detail = grid { x, y, n in SIMD3(x, y, n) }
        let peak = 15 * 31 + 15
        detail.vertices[peak].z = 0.0022
        let result = try MeshPlanarDenoiser.process(detail, configuration: enabled)
        XCTAssertEqual(result.mesh.vertices[peak], detail.vertices[peak])
        XCTAssertEqual(result.mesh.triangles, detail.triangles)

        let a = grid { x, y, n in SIMD3(x, y, n * 0.2) }
        let b = grid { x, y, n in SIMD3(x, y, 0.001 + n * 0.2) }
        var sheets = a
        sheets.vertices += b.vertices
        sheets.triangles += b.triangles.map { $0 + UInt32(a.vertexCount) }
        let filtered = try MeshPlanarDenoiser.process(sheets, configuration: enabled)
        XCTAssertEqual(filtered.metrics.acceptedRegions, 2)
        for i in a.vertices.indices {
            XCTAssertGreaterThan(filtered.mesh.vertices[i + a.vertexCount].z - filtered.mesh.vertices[i].z, 0.0009)
        }
        assertNoFlips(sheets, filtered.mesh)
    }

    func testThinParallelSheetsRetainSeparationAndUnusedVertex() throws {
        let a = grid { x, y, _ in SIMD3(x, y, 0) }
        let b = grid { x, y, _ in SIMD3(x, y, 0.001) }
        var mesh = a
        mesh.vertices += b.vertices
        mesh.triangles += b.triangles.map { $0 + UInt32(a.vertexCount) }
        mesh.vertices.append(SIMD3(99, 99, 99))
        let result = try MeshPlanarDenoiser.process(mesh, configuration: enabled)
        XCTAssertEqual(result.mesh.vertices, mesh.vertices)
        XCTAssertEqual(result.mesh.triangles, mesh.triangles)
        XCTAssertEqual(result.metrics.movedVertices, 0)
    }

    func testSmallRegionAndDefaultDisabledPreserveAllGeometry() throws {
        let mesh = grid { x, y, n in SIMD3(x, y, n) }
        XCTAssertEqual(try MeshPlanarDenoiser.process(mesh).mesh.vertices, mesh.vertices)
        var config = enabled
        config.minimumRegionAreaSquareMeters = 2
        XCTAssertEqual(try MeshPlanarDenoiser.process(mesh, configuration: config).mesh.vertices, mesh.vertices)
        config = enabled
        config.toleranceMeters = 0.00001
        XCTAssertEqual(try MeshPlanarDenoiser.process(mesh, configuration: config).mesh.vertices, mesh.vertices)
    }

    func testCancellationAndInvalidInputsThrowWithoutMutation() throws {
        let mesh = grid { x, y, n in SIMD3(x, y, n) }
        let control = ProcessingControl(); control.cancel()
        XCTAssertThrowsError(try MeshPlanarDenoiser.process(mesh, configuration: enabled, control: control)) {
            XCTAssertTrue($0 is CancellationError)
        }
        // Pacing is invoked at actual processing checkpoints. Cancelling at
        // checkpoint four proves cancellation after work starts, before output.
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let counter = Counter(), midWorkControl = ProcessingControl()
        XCTAssertThrowsError(try ProcessingControl.$workPacing.withValue({
            if counter.increment() == 4 { midWorkControl.cancel() }
        }) {
            try MeshPlanarDenoiser.process(mesh, configuration: enabled, control: midWorkControl)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(counter.count, 4)
        for bad in [MeshSnapshot(vertices: [SIMD3(0,0,0)], triangles: [0,0,0]),
                    MeshSnapshot(vertices: [SIMD3(0,0,0)], triangles: [0,1,2]),
                    MeshSnapshot(vertices: [SIMD3(.nan,0,0)], triangles: []),
                    MeshSnapshot(vertices: [], triangles: [0])] {
            XCTAssertThrowsError(try MeshPlanarDenoiser.process(bad, configuration: enabled))
        }
        for tolerance in [0.0, -.infinity, .nan] {
            var config = enabled; config.toleranceMeters = tolerance
            XCTAssertThrowsError(try MeshPlanarDenoiser.process(mesh, configuration: config))
        }
        XCTAssertEqual(mesh.vertexCount, 961)
    }

    private func grid(_ position: (Float, Float, Float) -> SIMD3<Float>) -> MeshSnapshot {
        var vertices: [SIMD3<Float>] = [], triangles: [UInt32] = []
        var random: UInt64 = 173
        for y in 0..<31 { for x in 0..<31 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Float((random >> 32) & 65535) / 65535 - 0.5) * 0.0016
            vertices.append(position(Float(x) * 0.04, Float(y) * 0.04, noise))
        } }
        for y in 0..<30 { for x in 0..<30 {
            let a = UInt32(y * 31 + x), b = a + 1, c = a + 31, d = c + 1
            triangles += [a,b,c,b,d,c]
        } }
        return MeshSnapshot(vertices: vertices, triangles: triangles)
    }

    private func assertNoFlips(_ source: MeshSnapshot, _ output: MeshSnapshot,
                               file: StaticString = #filePath, line: UInt = #line) {
        for i in stride(from: 0, to: source.triangles.count, by: 3) {
            let ids = source.triangles[i..<i+3].map(Int.init)
            func cross(_ mesh: MeshSnapshot) -> SIMD3<Float> {
                simd_cross(mesh.vertices[ids[1]] - mesh.vertices[ids[0]], mesh.vertices[ids[2]] - mesh.vertices[ids[0]])
            }
            XCTAssertGreaterThan(simd_dot(cross(source), cross(output)), 0, file: file, line: line)
        }
    }
}
