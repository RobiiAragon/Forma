import XCTest
@testable import Forma

final class GaussianRecoveryTests: XCTestCase {
    func testCheckpointRecoveryPreservesRelativeDatasetPathAndNeverDeletesSources() throws {
        let dataset = GaussianRecovery.documentsDirectory.appendingPathComponent("RecoverySources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        let original = dataset.appendingPathComponent("original.txt")
        try Data("source must survive recovery removal".utf8).write(to: original)
        addTeardownBlock { try? FileManager.default.removeItem(at: dataset) }
        let created = try GaussianRecovery.create(datasetURL: dataset, iterations: 3000, downscale: 1)
        addTeardownBlock { try? GaussianRecovery.remove(created.session) }
        XCTAssertFalse(created.session.datasetPath.hasPrefix("/"), "A Documents source path must survive container-UUID changes")
        XCTAssertEqual(created.session.datasetURL.standardizedFileURL.resolvingSymlinksInPath(), dataset.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertFalse(GaussianRecovery.sessions().contains { $0.id == created.session.id }, "An uncheckpointed job is not recoverable")
        // This test covers discovery/lifecycle metadata; tensor validation belongs to the engine.
        try Data("checkpoint discovery fixture".utf8).write(to: created.session.checkpointURL, options: .atomic)
        let updated = try GaussianRecovery.update(session: created.session, workspaceURL: created.workspaceURL, step: 23, state: "paused")
        let recovered = try XCTUnwrap(GaussianRecovery.sessions().first { $0.id == updated.id })
        XCTAssertEqual(recovered.step, 23)
        XCTAssertEqual(recovered.state, "paused")
        XCTAssertEqual(recovered.targetIterations, 3000)
        XCTAssertEqual(recovered.checkpointURL, created.session.checkpointURL)
        try GaussianRecovery.remove(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.workspaceURL.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("source must survive recovery removal".utf8))
    }

    func testRecoveryRejectsInvalidWorkspaceAndIgnoresEmptyCheckpoint() throws {
        let dataset = GaussianRecovery.documentsDirectory.appendingPathComponent("RecoverySources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dataset) }
        let first = try GaussianRecovery.create(datasetURL: dataset, iterations: 10, downscale: 1)
        let second = try GaussianRecovery.create(datasetURL: dataset, iterations: 20, downscale: 2)
        addTeardownBlock { try? GaussianRecovery.remove(first.session); try? GaussianRecovery.remove(second.session) }
        XCTAssertThrowsError(try GaussianRecovery.update(session: first.session, workspaceURL: second.workspaceURL, step: 1))
        XCTAssertThrowsError(try GaussianRecovery.update(session: first.session, workspaceURL: first.workspaceURL, step: -1))
        try Data().write(to: first.session.checkpointURL)
        XCTAssertFalse(GaussianRecovery.sessions().contains { $0.id == first.session.id })
        XCTAssertThrowsError(try GaussianRecovery.create(datasetURL: dataset, iterations: 0, downscale: 1))
        XCTAssertThrowsError(try GaussianRecovery.create(datasetURL: dataset, iterations: 5, downscale: .nan))
    }
}
