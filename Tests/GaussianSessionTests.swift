import XCTest
@testable import Forma

/// This is the pause domain used by GaussianTrainerService. Memory warnings
/// are telemetry; lifecycle snapshots and explicit actions control the session.
final class GaussianSessionTests: XCTestCase {
    func testRepeatedMemoryWarningsDoNotPauseRunningSession() {
        var session = GaussianSessionPauseState()
        for _ in 0..<100 { session.observeMemoryWarning() }
        XCTAssertEqual(session.stage, .running)
        XCTAssertNil(session.cause)
        XCTAssertEqual(session.memoryWarningCount, 100)
    }

    func testMemoryWarningsDoNotAlterPendingManualPause() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual)
        for _ in 0..<3 { session.observeMemoryWarning() }
        XCTAssertEqual(session.stage, .pauseRequested)
        XCTAssertEqual(session.cause, .manual)
        XCTAssertEqual(session.memoryWarningCount, 3)
    }

    func testMemoryWarningsDoNotResumeOrHideConfirmedManualPause() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual)
        session.didPause()
        for _ in 0..<5 {
            session.observeMemoryWarning()
            XCTAssertEqual(session.stage, .paused)
            XCTAssertEqual(session.cause, .manual)
        }
        XCTAssertEqual(session.memoryWarningCount, 5)
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: true)), .allowed)
        session.didResume()
        XCTAssertEqual(session.stage, .running)
        XCTAssertNil(session.cause)
        XCTAssertEqual(session.memoryWarningCount, 5, "Resuming retains useful diagnostics")
    }

    func testManualResumeRequiresForegroundAndNoAdditionalResourceGate() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual); session.didPause()
        session.observeMemoryWarning()
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: false)), .requiresForeground)
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: true)), .allowed)
        XCTAssertEqual(session.stage, .paused)
        XCTAssertEqual(session.cause, .manual)
    }

    func testLifecycleNotificationsCannotReplaceManualPauseCause() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual)
        session.requestPause(.applicationInactive)
        session.requestPause(.executionExpired)
        session.didPause()
        XCTAssertEqual(session.cause, .manual)
        XCTAssertTrue(session.confirmedMessage(hasCheckpoint: true).contains("Pausa solicitada"))
    }

    func testExplicitPauseOverridesPreviousLifecyclePauseCause() {
        var session = GaussianSessionPauseState()
        session.requestPause(.applicationInactive)
        session.requestPause(.manual)
        session.didPause()
        XCTAssertEqual(session.cause, .manual)
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: false)), .requiresForeground)
        XCTAssertEqual(session.stage, .paused)
    }

    func testPauseWithoutCheckpointDoesNotClaimOneWasSaved() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual); session.didPause()
        let message = session.confirmedMessage(hasCheckpoint: false)
        XCTAssertTrue(message.contains("no completó un checkpoint nuevo"))
        XCTAssertFalse(message.contains("Checkpoint guardado"))
        XCTAssertEqual(session.stage, .paused)
    }

    func testNoResumeBeforeWorkerAcknowledgesPause() {
        var session = GaussianSessionPauseState()
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: true)), .notPaused)
        session.requestPause(.manual)
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: true)), .notPaused)
        session.didPause()
        XCTAssertEqual(session.resumeDecision(.init(applicationActive: true)), .allowed)
    }

    func testExplicitExportClearsManualCauseSoLaterSystemSuspensionCanResume() {
        var session = GaussianSessionPauseState()
        session.requestPause(.manual); session.didPause()
        session.didResume() // Export is an explicit new execution action.
        session.requestPause(.applicationInactive); session.didPause()
        XCTAssertEqual(session.cause, .applicationInactive)
        XCTAssertTrue(session.shouldResumeWhenActive)
    }

    func testResumeAtomicallyRefreshesStaleInactiveControlBeforeWorkerRuns() throws {
        let control = GaussianTrainingControl(active: false)
        XCTAssertEqual(control.action(), .pause)
        XCTAssertFalse(control.isActive)
        XCTAssertTrue(control.resumeIfActive(true))
        XCTAssertTrue(control.isActive)
        XCTAssertEqual(control.action(), .run)
        XCTAssertNoThrow(try control.checkPacingState())
    }

    func testResumeCannotReviveCancelledControlOrStartInactiveMetal() {
        let inactive = GaussianTrainingControl(active: false)
        XCTAssertFalse(inactive.resumeIfActive(false))
        XCTAssertFalse(inactive.isActive)
        XCTAssertEqual(inactive.action(), .pause)

        let cancelled = GaussianTrainingControl(active: true)
        cancelled.set(.cancel)
        XCTAssertFalse(cancelled.resumeIfActive(true))
        XCTAssertEqual(cancelled.action(), .cancel)
        XCTAssertThrowsError(try cancelled.checkPacingState())
    }
}
