import XCTest
@testable import Forma

final class LocalAIJobControlTests: XCTestCase {
    func testRepeatedMemoryWarningsNeverChangeRunningOrPausedIntent() {
        var state = LocalAIJobControlState()
        for _ in 0..<10_000 { state.receiveMemoryWarning() }
        XCTAssertEqual(state.memoryWarningCount, 10_000)
        XCTAssertEqual(state.intent, .running)
        XCTAssertFalse(state.shouldHoldWorker)
        XCTAssertFalse(state.needsSystemRecovery)
        state.pauseByUser()
        for _ in 0..<10_000 { state.receiveMemoryWarning() }
        XCTAssertEqual(state.memoryWarningCount, 20_000)
        XCTAssertEqual(state.intent, .paused)
        XCTAssertTrue(state.shouldHoldWorker, "A memory warning must not undo a human pause either")
    }

    func testMissingBackgroundGrantResumesAtForegroundWithoutOverridingHumanPause() {
        var state = LocalAIJobControlState()
        state.setForeground(false)
        XCTAssertTrue(state.waitsForForeground)
        XCTAssertTrue(state.shouldHoldWorker)
        XCTAssertEqual(state.intent, .running)
        state.setForeground(true)
        XCTAssertFalse(state.shouldHoldWorker, "Returning to foreground needs no extra Resume tap")
        state.pauseByUser()
        state.setForeground(false)
        state.setCPUBackgroundGrant(true)
        state.setForeground(true)
        XCTAssertTrue(state.isManuallyPaused)
        XCTAssertTrue(state.shouldHoldWorker)
        state.resumeByUser()
        XCTAssertFalse(state.shouldHoldWorker)
    }

    func testGrantExpirationInForegroundKeepsCPUWorkerWhileBackgroundNeedsRecovery() {
        var state = LocalAIJobControlState()
        state.setCPUBackgroundGrant(true)
        XCTAssertFalse(state.executionExpired(), "An active CPU worker does not need a background grant")
        XCTAssertFalse(state.needsSystemRecovery)
        XCTAssertFalse(state.shouldHoldWorker)
        state.setCPUBackgroundGrant(true)
        state.setForeground(false)
        XCTAssertFalse(state.shouldHoldWorker)
        XCTAssertTrue(state.executionExpired(), "A real background expiration must be honored")
        XCTAssertTrue(state.needsSystemRecovery)
        XCTAssertEqual(state.recoveryAction(hasPendingResult: false), .none)
        state.setForeground(true)
        XCTAssertEqual(state.recoveryAction(hasPendingResult: false), .resumeInference)
        XCTAssertEqual(state.recoveryAction(hasPendingResult: true), .retrySave,
                       "A finished model must be saved without repeating inference")
        state.receiveMemoryWarning()
        state.begin(explicitUserAction: false)
        XCTAssertFalse(state.needsSystemRecovery)
        XCTAssertEqual(state.memoryWarningCount, 1, "Automatic worker replacement retains job telemetry")
    }

    func testHumanPauseAndCancellationWinRacesWithSystemRecovery() {
        var paused = LocalAIJobControlState()
        paused.setForeground(false)
        XCTAssertTrue(paused.executionExpired())
        paused.pauseByUser()
        paused.setForeground(true)
        XCTAssertEqual(paused.recoveryAction(hasPendingResult: false), .none)
        paused.resumeByUser()
        XCTAssertEqual(paused.recoveryAction(hasPendingResult: false), .resumeInference)

        var cancelled = LocalAIJobControlState()
        cancelled.setForeground(false)
        XCTAssertTrue(cancelled.executionExpired())
        cancelled.cancelByUser()
        cancelled.setForeground(true)
        cancelled.resumeByUser()
        cancelled.setCPUBackgroundGrant(true)
        XCTAssertFalse(cancelled.executionExpired())
        XCTAssertEqual(cancelled.intent, .cancelled)
        XCTAssertEqual(cancelled.recoveryAction(hasPendingResult: true), .none)
        cancelled.begin(explicitUserAction: true)
        XCTAssertEqual(cancelled.intent, .running, "Only a new explicit job starts after cancellation")
    }

    func testDurableWorkConfigurationRejectsDifferentSourceOrSettingsAndRoundTrips() throws {
        let sourceID = UUID()
        let configuration = LocalAITextureWorkConfiguration(sourceID: sourceID, strength: 0.35)
        XCTAssertTrue(configuration.matches(sourceID: sourceID, strength: 0.35))
        XCTAssertFalse(configuration.matches(sourceID: UUID(), strength: 0.35))
        XCTAssertFalse(configuration.matches(sourceID: sourceID, strength: 0.36))
        for value in [Double.nan, .infinity, -0.01, 1.01] {
            XCTAssertFalse(LocalAITextureWorkConfiguration(sourceID: sourceID, strength: value).isValid)
        }
        let recovered = try JSONDecoder().decode(LocalAITextureWorkConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(recovered, configuration)
        XCTAssertTrue(recovered.matches(sourceID: sourceID, strength: 0.35))
        // Configuration checking performs no filesystem operation. Existing atlas
        // checkpoints and original sources are retained by the running pipeline.
    }
}
