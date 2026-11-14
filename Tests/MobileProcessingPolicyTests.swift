import XCTest
import Foundation
@testable import Forma

final class MobileProcessingPolicyTests: XCTestCase {
    func testNominalDutyCycleAddsEqualRestWithoutChangingWork() throws {
        let clock = PacingTestClock()
        let policy = clock.policy()
        for work in [0.1, 0.4, 0.05] {
            clock.advance(work)
            try policy.checkpoint()
        }
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 0.55, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 0.55, accuracy: 0.000_001)
        XCTAssertEqual(clock.value, 1.1, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.checkpointCount, 3)
        XCTAssertTrue(clock.waits.allSatisfy { $0 <= 0.05 && $0 > 0 })
        XCTAssertEqual(policy.snapshot.targetActiveFraction, 0.5)
    }

    func testFairAndSeriousReduceDutyCycleUsingMeasuredWork() throws {
        for (level, fraction) in [(MobileProcessingPolicy.ThermalLevel.fair, 0.35), (.serious, 0.2)] {
            let clock = PacingTestClock(level: level), work = 0.21
            let policy = clock.policy()
            clock.advance(work)
            try policy.checkpoint()
            XCTAssertEqual(policy.snapshot.measuredWorkSeconds, work, accuracy: 0.000_001)
            XCTAssertEqual(policy.snapshot.restSeconds, work * (1 / fraction - 1), accuracy: 0.000_001)
            XCTAssertEqual(policy.snapshot.targetActiveFraction, fraction)
        }
    }

    func testMacPassesThroughEvenWhenCriticalAndChecksCancellation() throws {
        let clock = PacingTestClock(level: .critical)
        let policy = clock.policy(platform: .desktop)
        clock.advance(100)
        try policy.checkpoint()
        XCTAssertTrue(clock.waits.isEmpty)
        XCTAssertEqual(policy.snapshot.phase, .disabled)
        XCTAssertEqual(policy.snapshot.targetActiveFraction, 1)
        XCTAssertEqual(policy.snapshot.restSeconds, 0)
        let control = ProcessingControl(); control.cancel()
        XCTAssertThrowsError(try policy.checkpoint(control: control)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCriticalWaitsForCoolingAndReportsStateToUI() throws {
        let clock = PacingTestClock(level: .critical), phases = PacingTestValues<MobileProcessingPolicy.Snapshot>()
        let policy = clock.policy(onStateChange: { phases.append($0) })
        clock.onWait = { if clock.value >= 0.15 { clock.level = .nominal } }
        try policy.checkpoint()
        XCTAssertGreaterThanOrEqual(clock.value, 0.15)
        XCTAssertTrue(phases.values.contains { $0.phase == .cooling && $0.targetActiveFraction == 0 && $0.thermalLevel == .critical })
        XCTAssertEqual(phases.values.last?.phase, .working)
        XCTAssertEqual(policy.snapshot.targetActiveFraction, 0.5)
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 0)
    }

    func testThermalEscalationDuringRestExtendsCoolingInsteadOfStartingNextBlock() throws {
        let clock = PacingTestClock(), policy = clock.policy()
        clock.onWait = { clock.level = .serious }
        clock.advance(0.1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.restSeconds, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.thermalLevel, .serious)
    }

    func testPauseDurationDoesNotBecomeWorkOrDuplicateCoolingDebt() throws {
        let clock = PacingTestClock(), policy = clock.policy()
        let holder = PacingControlHolder()
        let control = ProcessingControl { state in
            if state.phase == .paused { clock.advance(10); holder.value?.resume() }
        }
        holder.value = control
        defer { holder.value = nil }
        clock.advance(1); control.requestPause()
        let finished = expectation(description: "same worker resumed without new cooling debt")
        let first = PacingTestValues<MobileProcessingPolicy.Snapshot>()
        let waitsAfterPause = PacingTestValues<Int>()
        DispatchQueue.global().async {
            do {
                try policy.checkpoint(control: control)
                first.append(policy.snapshot); waitsAfterPause.append(clock.waits.count)
                clock.advance(1)
                try policy.checkpoint(control: control)
            } catch { XCTFail("Unexpected \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try XCTUnwrap(first.values.first).measuredWorkSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(first.values.first).restSeconds, 10, accuracy: 0.000_001)
        XCTAssertEqual(waitsAfterPause.values, [0], "Ten seconds paused already paid the one-second cooling debt")
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 11, accuracy: 0.000_001)
    }

    func testCancellationDuringRestStopsWithinOneWaitQuantum() throws {
        let clock = PacingTestClock(), policy = clock.policy(), control = ProcessingControl()
        clock.onWait = { control.cancel() }
        clock.advance(20)
        XCTAssertThrowsError(try policy.checkpoint(control: control)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(clock.waits.count, 1)
        XCTAssertLessThanOrEqual(policy.snapshot.restSeconds, 0.05 + 0.000_001)
    }

    func testCriticalCoolingCanBeCancelledAndPauseGateStillWorks() throws {
        let clock = PacingTestClock(level: .critical), policy = clock.policy()
        let paused = expectation(description: "pause inside critical cooling"), ended = expectation(description: "cancel woke cooling gate")
        let workerControl = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        clock.onWait = { workerControl.requestPause() }
        DispatchQueue.global().async {
            do { try policy.checkpoint(control: workerControl); XCTFail("Cancelled cooling returned") }
            catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        workerControl.cancel()
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(workerControl.snapshot.phase, .cancelled)
        XCTAssertEqual(clock.waits.count, 1)
    }

    func testMobileMainThreadCannotBeBlockedByPacing() {
        let clock = PacingTestClock()
        let policy = clock.policy(isMainThread: { true })
        clock.advance(1)
        XCTAssertThrowsError(try policy.checkpoint()) { XCTAssertTrue($0 is ProcessingControl.ControlError) }
        XCTAssertTrue(clock.waits.isEmpty)
    }

    func testResumeClockDoesNotCountSuspendedWallTimeAsProcessing() throws {
        let clock = PacingTestClock(), policy = clock.policy()
        clock.advance(600)
        policy.resetWorkClock()
        clock.advance(0.1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 0.1, accuracy: 0.000_001)
    }

    func testObservedPauseBetweenPolicyCallsIsExcludedAndAlreadyPaysCooling() throws {
        let clock = PacingTestClock(), policy = clock.policy()
        clock.advance(1)
        policy.observeControlState(.init(phase: .pauseRequested, revision: 1))
        clock.advance(1)
        policy.observeControlState(.init(phase: .paused, revision: 2))
        clock.advance(10)
        policy.observeControlState(.init(phase: .running, revision: 3))
        clock.advance(1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 10, accuracy: 0.000_001)
        XCTAssertTrue(clock.waits.isEmpty)
        clock.advance(0.1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 3.1, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 10.1, accuracy: 0.000_001)
    }

    func testLifecycleResetIsNonblockingEvenFromStateCallback() throws {
        let clock = PacingTestClock(), holder = PacingPolicyHolder()
        let policy = clock.policy(onStateChange: { _ in holder.value?.resetWorkClock() })
        holder.value = policy
        defer { holder.value = nil }
        clock.advance(0.1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.restSeconds, 0.1, accuracy: 0.000_001)
    }

    func testCustomGateCanCancelCriticalCoolingWithoutProcessingControl() {
        let clock = PacingTestClock(level: .critical), policy = clock.policy()
        XCTAssertThrowsError(try policy.checkpoint(additionalCheck: {
            if clock.waits.count >= 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(clock.waits.count, 2)
    }

    func testOutOfOrderControlCallbacksCannotLeavePhantomPause() throws {
        let clock = PacingTestClock(), policy = clock.policy()
        policy.observeControlState(.init(phase: .running, revision: 3))
        policy.observeControlState(.init(phase: .paused, revision: 2))
        clock.advance(0.1)
        try policy.checkpoint()
        XCTAssertEqual(policy.snapshot.measuredWorkSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(policy.snapshot.restSeconds, 0.1, accuracy: 0.000_001)
    }
}

private final class PacingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    private var storedLevel: MobileProcessingPolicy.ThermalLevel
    private var storedWaits: [Double] = []
    var onWait: (@Sendable () -> Void)?
    init(level: MobileProcessingPolicy.ThermalLevel = .nominal) { storedLevel = level }
    var value: Double { lock.lock(); defer { lock.unlock() }; return time }
    var waits: [Double] { lock.lock(); defer { lock.unlock() }; return storedWaits }
    var level: MobileProcessingPolicy.ThermalLevel {
        get { lock.lock(); defer { lock.unlock() }; return storedLevel }
        set { lock.lock(); storedLevel = newValue; lock.unlock() }
    }
    func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
    func policy(platform: MobileProcessingPolicy.Platform = .mobile,
                isMainThread: @escaping @Sendable () -> Bool = { false },
                onStateChange: (@Sendable (MobileProcessingPolicy.Snapshot) -> Void)? = nil) -> MobileProcessingPolicy {
        MobileProcessingPolicy(platform: platform, now: { self.value }, wait: { seconds in
            self.lock.lock(); self.time += seconds; self.storedWaits.append(seconds); self.lock.unlock()
            self.onWait?()
        }, thermal: { self.level }, isMainThread: isMainThread, onStateChange: onStateChange)
    }
}

private final class PacingTestValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class PacingPolicyHolder: @unchecked Sendable {
    var value: MobileProcessingPolicy?
}

private final class PacingControlHolder: @unchecked Sendable {
    var value: ProcessingControl?
}
