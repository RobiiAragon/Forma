import XCTest
@testable import Forma

@MainActor
final class AIWorkspaceCleanupTests: XCTestCase {
    func testSuccessfulRetryRemovesOwnedAIWorkOnlyAfterCommitAndPreservesOriginal() async throws {
        var fixture = try await makeFixture()
        let missing = fixture.base.appendingPathComponent("retry-data.txt")
        fixture.result.auxiliaryURLs = [missing]
        let failed = await fixture.store.save(fixture.result)
        XCTAssertNil(failed)
        XCTAssertEqual(fixture.store.pendingCapture?.id, fixture.result.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace.path))
        XCTAssertEqual(try Data(contentsOf: fixture.originalModel), fixture.modelBytes)

        try Data("retry now has its auxiliary payload".utf8).write(to: missing)
        let retried = await fixture.store.save(fixture.result)
        let saved = try XCTUnwrap(retried, fixture.store.error ?? "Save failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
        XCTAssertNil(fixture.store.pendingCapture)
        XCTAssertEqual(saved.sourceScanID, fixture.original.id)
        XCTAssertEqual(fixture.store.scans.count, 2)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(fixture.store.modelURL(for: saved))), fixture.modelBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.originalModel), fixture.modelBytes)
        let verified = try await fixture.store.verify(saved)
        let originalVerified = try await fixture.store.verify(fixture.original)
        XCTAssertTrue(verified)
        XCTAssertTrue(originalVerified)
    }

    func testDiscardRemovesOnlyItsPendingAIWorkspaceAndKeepsOriginalAndNeighbor() async throws {
        var fixture = try await makeFixture()
        let neighbor = fixture.workspace.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let marker = neighbor.appendingPathComponent("keep.txt")
        try Data("other pending work".utf8).write(to: marker)
        addTeardownBlock { try? FileManager.default.removeItem(at: neighbor) }
        fixture.result.auxiliaryURLs = [fixture.base.appendingPathComponent("missing.txt")]
        let failed = await fixture.store.save(fixture.result)
        XCTAssertNil(failed)
        fixture.store.discardPendingCapture()
        XCTAssertNil(fixture.store.pendingCapture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("other pending work".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.originalModel), fixture.modelBytes)
        XCTAssertEqual(fixture.store.scans.map(\.id), [fixture.original.id])
    }

    func testCleanupRejectsMismatchedOwnershipContainerPackageAndSymlinks() async throws {
        enum Scenario: CaseIterable {
            case sourceID, metadataOwner, container, package, malformedMetadata, linkedWorkspace, linkedMetadata
        }
        for scenario in Scenario.allCases {
            var fixture = try await makeFixture()
            let metadata = fixture.workspace.appendingPathComponent("trabajo.json")
            switch scenario {
            case .sourceID:
                fixture.result.sourceScanID = UUID()
            case .metadataOwner:
                try writeOwner(UUID(), to: metadata)
            case .container:
                fixture.result.cleanupDirectory = fixture.workspace.deletingLastPathComponent()
            case .package:
                let other = fixture.workspace.appendingPathComponent("otro-modelo")
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                let model = other.appendingPathComponent("modelo.obj")
                try fixture.modelBytes.write(to: model)
                fixture.result.modelPackageURL = other
                fixture.result.modelURL = model
            case .malformedMetadata:
                try Data("not valid ownership metadata".utf8).write(to: metadata)
            case .linkedWorkspace:
                let target = fixture.base.appendingPathComponent("Forma-untouched-target")
                try FileManager.default.moveItem(at: fixture.workspace, to: target)
                try FileManager.default.createSymbolicLink(at: fixture.workspace, withDestinationURL: target)
            case .linkedMetadata:
                let target = fixture.base.appendingPathComponent("owner.json")
                try FileManager.default.moveItem(at: metadata, to: target)
                try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
            }
            let savedValue = await fixture.store.save(fixture.result)
            let saved = try XCTUnwrap(savedValue, "\(scenario): \(fixture.store.error ?? "Save failed")")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace.path), "\(scenario) cannot authorize cleanup")
            XCTAssertEqual(try Data(contentsOf: fixture.originalModel), fixture.modelBytes)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(fixture.store.modelURL(for: saved))), fixture.modelBytes)
            // Discard has to apply the same ownership checks after a later failed save.
            var pending = fixture.result
            pending.auxiliaryURLs = [fixture.base.appendingPathComponent("missing-after-commit.txt")]
            let failed = await fixture.store.save(pending)
            XCTAssertNil(failed)
            fixture.store.discardPendingCapture()
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace.path), "\(scenario): discard cannot delete unowned work")
        }
    }

    private struct Fixture {
        var store: ScanStore
        var base: URL
        var workspace: URL
        var original: ScanRecord
        var originalModel: URL
        var modelBytes: Data
        var result: CaptureResult
    }

    private func makeFixture() async throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ScanStore(baseURL: base)
        let mesh = MeshSnapshot(vertices: [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)], triangles: [0, 1, 2])
        let originalValue = await store.save(CaptureResult(mesh: mesh, mode: .lidar, duration: 1))
        let original = try XCTUnwrap(originalValue, store.error ?? "Original save failed")
        let originalModel = try XCTUnwrap(store.modelURL(for: original))
        let bytes = try Data(contentsOf: originalModel)
        let workspace = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FormaAIWork", isDirectory: true)
            .appendingPathComponent(original.id.uuidString, isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: workspace.path), "Fixture UUID must never reuse existing work")
        let package = workspace.appendingPathComponent("modelo", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: base)
        }
        try writeOwner(original.id, to: workspace.appendingPathComponent("trabajo.json"))
        let model = package.appendingPathComponent("modelo.obj")
        try bytes.write(to: model)
        var result = CaptureResult(mesh: nil, modelURL: model, mode: .lidar, duration: 1,
                                   cleanupDirectory: workspace, modelPackageURL: package)
        result.sourceScanID = original.id
        return Fixture(store: store, base: base, workspace: workspace, original: original,
                       originalModel: originalModel, modelBytes: bytes, result: result)
    }

    private func writeOwner(_ id: UUID, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: ["sourceID": id.uuidString, "strength": 0.35])
            .write(to: url, options: .atomic)
    }
}
