import XCTest
import Combine
import simd
@testable import Forma

final class ScanRefinementViewModelTests: XCTestCase {
    @MainActor
    func testViewModelPublishesDerivedRecordAndKeepsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(baseURL: root)
        let originalSave = await store.save(CaptureResult(mesh: triangle, mode: .lidar, duration: 1))
        let original = try XCTUnwrap(originalSave)
        let originalFile = store.directory(for: original).appendingPathComponent("malla.json")
        let originalBytes = try Data(contentsOf: originalFile)
        let model = ScanRefinementViewModel(), done = expectation(description: "Published copy")
        var began = false
        let observation = model.$isRunning.sink { running in
            if running { began = true } else if began { done.fulfill() }
        }
        model.start(scan: original, store: store)
        model.start(scan: original, store: store) // One owned task despite repeated taps.
        await fulfillment(of: [done], timeout: 15)
        withExtendedLifetime(observation) {}
        XCTAssertNil(model.error)
        XCTAssertEqual(model.saved?.sourceScanID, original.id)
        XCTAssertEqual(model.progress, 1)
        XCTAssertEqual(store.scans.count, 2)
        XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes)
    }

    @MainActor
    func testCancelAndInvalidInputDoNotCreateCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(baseURL: root)
        let originalSave = await store.save(CaptureResult(mesh: triangle, mode: .lidar, duration: 1))
        let original = try XCTUnwrap(originalSave)
        let model = ScanRefinementViewModel()
        model.quality.planarToleranceMeters = 0
        model.start(scan: original, store: store)
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.error)
        model.quality.planarToleranceMeters = 0.003
        let done = expectation(description: "Cancelled task")
        var began = false
        let observation = model.$isRunning.sink { running in
            if running { began = true } else if began { done.fulfill() }
        }
        model.start(scan: original, store: store)
        model.cancel()
        await fulfillment(of: [done], timeout: 15)
        withExtendedLifetime(observation) {}
        XCTAssertNil(model.saved)
        XCTAssertNil(model.error)
        XCTAssertEqual(store.scans.count, 1)
        XCTAssertNil(store.pendingCapture)
    }

    func testCleanupRejectsAnUnownedDirectory() throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("UserOriginal-\(UUID())")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: original) }
        let file = original.appendingPathComponent("keep.txt")
        try Data([1,2,3]).write(to: file)
        let result = CaptureResult(mesh: triangle, mode: .lidar, duration: 1, cleanupDirectory: original)
        SavedScanRefinement.discardUnpublished(result)
        XCTAssertEqual(try Data(contentsOf: file), Data([1,2,3]))
    }

    private var triangle: MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
    }
}
