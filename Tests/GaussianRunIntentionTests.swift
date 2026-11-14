import XCTest
@testable import Forma

final class GaussianRunIntentionTests: XCTestCase {
    func testCheckpointCommitCannotOverwriteManualPauseOrStopIntent() throws {
        let dataset = GaussianRecovery.documentsDirectory.appendingPathComponent("IntentionSources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataset) }
        let owned = try GaussianRecovery.create(datasetURL: dataset, iterations: 3000, downscale: 1)
        defer { try? GaussianRecovery.remove(owned.session) }
        for intent in [GaussianRunIntention.Intent.manuallyPaused, .stopped] {
            try GaussianRunIntention.save(intent, exportRequested: false, to: owned.workspaceURL)
            _ = try GaussianRecovery.update(session: owned.session, workspaceURL: owned.workspaceURL, step: 100)
            let recovered = try GaussianRunIntention.load(from: owned.workspaceURL)
            XCTAssertEqual(recovered.intent, intent)
            XCTAssertFalse(recovered.shouldRecover(sessionState: "checkpointed"))
        }
    }

    func testOnlyRunningIntentRecoversAcrossSystemInterruption() throws {
        for intent in [GaussianRunIntention.Intent.running, .manuallyPaused, .stopped, .completed, .failed] {
            let value = GaussianRunIntention(intent: intent, exportRequested: true, updatedAt: Date())
            XCTAssertEqual(value.shouldRecover(sessionState: "checkpointed"), intent == .running)
            XCTAssertEqual(value.shouldRecover(sessionState: "interrupted"), intent == .running)
            XCTAssertFalse(value.shouldRecover(sessionState: "exported"))
            let restored = try JSONDecoder().decode(GaussianRunIntention.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(restored, value)
            XCTAssertTrue(restored.exportRequested)
        }
    }

    func testUncheckpointedInitializationIsDiscoverableWithoutChangingLegacyList() throws {
        let dataset = GaussianRecovery.documentsDirectory.appendingPathComponent("IntentionSources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataset) }
        let owned = try GaussianRecovery.create(datasetURL: dataset, iterations: 3000, downscale: 1)
        defer { try? GaussianRecovery.remove(owned.session) }
        XCTAssertFalse(GaussianRecovery.sessions().contains { $0.id == owned.session.id })
        XCTAssertTrue(GaussianRecovery.sessions(requireCheckpoint: false).contains { $0.id == owned.session.id })
        XCTAssertThrowsError(try GaussianRunIntention.load(from: owned.workspaceURL))
        try GaussianRunIntention.save(.running, exportRequested: false, to: owned.workspaceURL)
        XCTAssertTrue(try GaussianRunIntention.load(from: owned.workspaceURL).shouldRecover(sessionState: "created"))
    }
}
