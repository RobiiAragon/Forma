import XCTest
import Foundation
@testable import Forma

/// Exercises the actual control/pacing boundary without a camera, a Metal
/// handle, or user data. Device engine checkpoint/release remains separate QA.
final class GaussianPacingTests: XCTestCase {
    func testPauseInterruptsEnergyRestBeforeWaitingForGPUCheckpointRelease() throws {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: true)
        let policy = clock.policy()
        clock.advance(1)
        clock.onWait = { control.set(.pause) }
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is GaussianTrainingControl.PacingInterruption)
        }
        XCTAssertEqual(clock.waits.count, 1)
        XCTAssertEqual(control.action(), .pause)
        XCTAssertLessThanOrEqual(clock.waits[0], 0.05)

        // The service can checkpoint/release before entering its pause wait;
        // resuming resets suspended wall time rather than creating more debt.
        clock.onWait = nil
        clock.advance(600)
        control.set(.run); policy.resetWorkClock()
        clock.advance(0.1)
        let restBeforeResume = policy.snapshot.restSeconds
        try policy.checkpoint(control: control.energyCancellation,
                              additionalCheck: { try control.checkPacingState() })
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 1.1, accuracy: 1e-6)
        XCTAssertEqual(policy.snapshot.restSeconds - restBeforeResume, 0.1, accuracy: 1e-6)
    }

    func testCancellationInterruptsCriticalCoolingWithinOneWaitQuantum() {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: true)
        let policy = clock.policy(level: .critical)
        clock.onWait = { control.set(.cancel) }
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(control.energyCancellation.snapshot.phase, .cancelled)
        XCTAssertEqual(clock.waits.count, 1)
        XCTAssertLessThanOrEqual(clock.waits[0], 0.05)
    }

    func testBackgroundSuspendsExportAndCoordinatedForegroundResumePreservesExportRequest() throws {
        let control = GaussianTrainingControl(active: true)
        control.set(.export)
        control.setApplicationActive(false)
        XCTAssertEqual(control.action(), .pause)
        XCTAssertFalse(control.isActive)
        XCTAssertThrowsError(try control.checkPacingState())
        control.setApplicationActive(true)
        XCTAssertEqual(control.action(), .pause, "The service must first acknowledge release of its Metal handle")
        XCTAssertThrowsError(try control.checkPacingState())
        XCTAssertTrue(control.resumeIfActive(true))
        XCTAssertEqual(control.action(), .export, "Suspension must not turn a requested export into more training")
        XCTAssertNoThrow(try control.checkPacingState())
    }

    func testContinuousTrainingNeverSchedulesThermalWaitOrCoolingAtAnyThermalLevel() throws {
        for level in [MobileProcessingPolicy.ThermalLevel.nominal, .fair, .serious, .critical] {
            let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: true)
            let policy = clock.policy(level: level, mode: .continuous)
            clock.advance(2)
            try policy.checkpoint(control: control.energyCancellation,
                                  additionalCheck: { try control.checkPacingState() })
            XCTAssertTrue(clock.waits.isEmpty, "Continuous mode cannot add scheduled rests at \(level)")
            XCTAssertFalse(clock.phases.contains(.resting))
            XCTAssertFalse(clock.phases.contains(.cooling))
            XCTAssertEqual(policy.snapshot.phase, .working)
            XCTAssertEqual(policy.snapshot.thermalLevel, level, "The state still records the OS observation")
            XCTAssertEqual(policy.snapshot.targetActiveFraction, 1)
            XCTAssertEqual(control.action(), .run)
        }
    }

    func testContinuousTrainingStillMeasuresActualWorkAcrossBoundariesWithoutAddingRest() throws {
        let clock = GaussianPacingClock()
        let policy = clock.policy(level: .critical, mode: .continuous)
        clock.advance(4)
        try policy.checkpoint()
        clock.advance(2.5)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 6.5, accuracy: 1e-6)
        XCTAssertEqual(policy.snapshot.checkpointCount, 2)
        XCTAssertEqual(policy.snapshot.restSeconds, 0, accuracy: 1e-6)
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testContinuousTrainingHonorsManualPauseBeforeAnyFurtherCompute() {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: true)
        let policy = clock.policy(level: .critical, mode: .continuous)
        control.set(.pause)
        clock.advance(1)
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is GaussianTrainingControl.PacingInterruption)
        }
        XCTAssertEqual(control.action(), .pause)
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testContinuousTrainingHonorsCancellationBeforeAnyFurtherCompute() {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: true)
        let policy = clock.policy(level: .critical, mode: .continuous)
        control.set(.cancel)
        clock.advance(1)
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(control.action(), .cancel)
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testContinuousTrainingCannotStartComputeWhileApplicationIsInactive() {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: false)
        let policy = clock.policy(level: .critical, mode: .continuous)
        clock.advance(1)
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is GaussianTrainingControl.PacingInterruption)
        }
        XCTAssertFalse(control.isActive)
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testManualPauseRemainsPausedWhenReturningToForeground() {
        let control = GaussianTrainingControl(active: true)
        var session = GaussianSessionPauseState()
        session.requestPause(.manual)
        control.set(.pause)
        session.didPause()
        control.setApplicationActive(false)
        control.setApplicationActive(true)
        XCTAssertFalse(session.shouldResumeWhenActive)
        XCTAssertEqual(session.stage, .paused)
        XCTAssertEqual(control.action(), .pause)
        XCTAssertThrowsError(try control.checkPacingState())
    }

    func testRecoveryCheckpointScheduleBecomesDueAfterThirtySecondsAndResetsOnlyOnSave() {
        var schedule = GaussianCheckpointSchedule(now: 10)
        XCTAssertFalse(schedule.isDue(now: 10))
        XCTAssertFalse(schedule.isDue(now: 39.999))
        XCTAssertTrue(schedule.isDue(now: 40))
        XCTAssertTrue(schedule.isDue(now: 50), "Checking the schedule does not mark a failed or pending checkpoint saved")
        XCTAssertFalse(schedule.isDue(now: .nan))
        XCTAssertFalse(schedule.isDue(now: .infinity))
        schedule.didSave(now: 50)
        XCTAssertFalse(schedule.isDue(now: 79.999))
        XCTAssertTrue(schedule.isDue(now: 80))
    }

    func testInactiveWorkerDoesNotBeginEnergyWaitOrPermitCompute() {
        let clock = GaussianPacingClock(), control = GaussianTrainingControl(active: false)
        let policy = clock.policy()
        clock.advance(1)
        XCTAssertThrowsError(try policy.checkpoint(control: control.energyCancellation,
                                                  additionalCheck: { try control.checkPacingState() })) {
            XCTAssertTrue($0 is GaussianTrainingControl.PacingInterruption)
        }
        XCTAssertTrue(clock.waits.isEmpty)
        XCTAssertEqual(control.action(), .pause)
    }

    func testCancellationWakesPausedBackgroundWorker() {
        let control = GaussianTrainingControl(active: false)
        let started = expectation(description: "worker entered its control boundary")
        let ended = expectation(description: "cancellation woke the paused worker")
        DispatchQueue.global().async {
            started.fulfill()
            control.waitUntilResumed()
            ended.fulfill()
        }
        wait(for: [started], timeout: 2)
        control.set(.cancel)
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(control.action(), .cancel)
    }

    func testCancelledControlCannotBeRevivedByLateResumeExportOrPause() {
        let control = GaussianTrainingControl(active: true)
        control.set(.cancel)
        for action in [GaussianTrainingControl.Action.run, .export, .pause] {
            control.set(action)
            XCTAssertEqual(control.action(), .cancel)
            XCTAssertThrowsError(try control.checkPacingState())
        }
        XCTAssertEqual(control.energyCancellation.snapshot.phase, .cancelled)
    }

    func testCompletedIterationCannotOverridePauseOrCancellationWithAutomaticExport() {
        for action in [GaussianTrainingControl.Action.pause, .cancel] {
            let control = GaussianTrainingControl(active: true)
            control.set(action); control.requestAutomaticExport()
            XCTAssertEqual(control.action(), action, "A completed GPU step must still honor the action requested while it was in flight")
        }
        let running = GaussianTrainingControl(active: true)
        running.requestAutomaticExport()
        XCTAssertEqual(running.action(), .export)
    }

    func testRecoveredContinuationCannotPresentOlderPLYAsItsNewCheckpointResult() {
        var session = GaussianRecoverySession(id: UUID(), datasetPath: "synthetic-dataset", targetIterations: 1000,
            downscale: 1, createdAt: .distantPast, step: 100, updatedAt: .distantPast, state: "exported")
        let olderExport: [String: Any] = ["steps": 100, "splats": 5000]
        XCTAssertEqual(GaussianRecoveryExportPolicy.splatCount(session: session, metadata: olderExport), 5000)

        // A continuation leaves that PLY/metadata in place while advancing its
        // recoverable checkpoint. It must offer continuation, not a false result.
        session.step = 200
        for state in ["configured", "checkpointed", "paused", "interrupted"] {
            session.state = state
            XCTAssertNil(GaussianRecoveryExportPolicy.splatCount(session: session, metadata: olderExport))
        }
        session.state = "exported"
        XCTAssertNil(GaussianRecoveryExportPolicy.splatCount(session: session, metadata: olderExport),
                     "Even an exported flag cannot relabel 100-step geometry as a 200-step result")
        XCTAssertNil(GaussianRecoveryExportPolicy.splatCount(session: session, metadata: ["splats": 5000]))
        XCTAssertEqual(GaussianRecoveryExportPolicy.splatCount(session: session, metadata: ["steps": 200, "splats": 6000]), 6000)
    }
}

private final class GaussianPacingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var recordedWaits: [Double] = []
    private var recordedPhases: [MobileProcessingPolicy.Phase] = []
    var onWait: (@Sendable () -> Void)?
    var value: Double { lock.lock(); defer { lock.unlock() }; return time }
    var waits: [Double] { lock.lock(); defer { lock.unlock() }; return recordedWaits }
    var phases: [MobileProcessingPolicy.Phase] { lock.lock(); defer { lock.unlock() }; return recordedPhases }
    func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
    func policy(level: MobileProcessingPolicy.ThermalLevel = .nominal,
                mode: MobileProcessingPolicy.Mode = .adaptive) -> MobileProcessingPolicy {
        MobileProcessingPolicy(platform: .mobile, mode: mode, now: { self.value }, wait: { seconds in
            self.lock.lock(); self.time += seconds; self.recordedWaits.append(seconds); self.lock.unlock()
            self.onWait?()
        }, thermal: { level }, isMainThread: { false }, onStateChange: { snapshot in
            self.lock.lock(); self.recordedPhases.append(snapshot.phase); self.lock.unlock()
        })
    }
}
