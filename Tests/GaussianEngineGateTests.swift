import XCTest
@testable import Forma

/// Exercises production admission and control without constructing a Metal engine.
final class GaussianEngineGateTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var stored = false
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    }
    private struct Timeout: Error {}
    private func wait(_ flag: Flag) async throws {
        for _ in 0..<500 { if flag.value { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Timeout()
    }
    private func acquire(_ gate: GaussianEngineGate, _ ticket: GaussianEngineGate.Ticket,
                         completed: Flag = Flag()) -> (Task<GaussianEngineGate.Lease?, Never>, Flag) {
        let task = Task.detached { let lease = await gate.acquire(ticket); completed.value = true; return lease }
        return (task, completed)
    }

    func testSynchronousRecoveryRegistrationKeepsFIFOEvenWhenWorkersArriveBackwards() async throws {
        let gate = GaussianEngineGate(), a = UUID(), b = UUID(), c = UUID()
        let first = gate.enqueue(jobID: a, canRun: { true })
        let second = gate.enqueue(jobID: b, canRun: { true })
        let third = gate.enqueue(jobID: c, canRun: { true })
        let (cTask, cDone) = acquire(gate, third), (bTask, bDone) = acquire(gate, second)
        defer { cTask.cancel(); bTask.cancel(); gate.interrupt(jobID: a); gate.interrupt(jobID: b); gate.interrupt(jobID: c) }
        await Task.yield()
        XCTAssertFalse(bDone.value); XCTAssertFalse(cDone.value)
        let aValue = await gate.acquire(first), aLease = try XCTUnwrap(aValue)
        XCTAssertEqual(aLease.jobID, a)
        XCTAssertFalse(bDone.value); XCTAssertFalse(cDone.value)
        aLease.release()
        try await wait(bDone)
        let bValue = await bTask.value, bLease = try XCTUnwrap(bValue)
        XCTAssertEqual(bLease.jobID, b); XCTAssertFalse(cDone.value)
        // Releasing an old lease again must not revoke the current owner.
        aLease.release(); await Task.yield(); XCTAssertFalse(cDone.value)
        bLease.release()
        try await wait(cDone)
        let cValue = await cTask.value, cLease = try XCTUnwrap(cValue)
        XCTAssertEqual(cLease.jobID, c); cLease.release()
    }

    func testPausedWaiterIsWithdrawnAndDoesNotAutomaticallyRevive() async throws {
        let gate = GaussianEngineGate(), a = UUID(), b = UUID(), c = UUID()
        let ownerValue = await gate.acquire(gate.enqueue(jobID: a, canRun: { true }))
        let owner = try XCTUnwrap(ownerValue)
        let (pausedTask, pausedDone) = acquire(gate, gate.enqueue(jobID: b, canRun: { true }))
        let (nextTask, nextDone) = acquire(gate, gate.enqueue(jobID: c, canRun: { true }))
        defer { pausedTask.cancel(); nextTask.cancel(); owner.release(); gate.interrupt(jobID: b); gate.interrupt(jobID: c) }
        gate.interrupt(jobID: b)
        try await wait(pausedDone)
        let pausedValue = await pausedTask.value
        XCTAssertNil(pausedValue); XCTAssertFalse(nextDone.value)
        owner.release(); try await wait(nextDone)
        let nextValue = await nextTask.value, next = try XCTUnwrap(nextValue)
        XCTAssertEqual(next.jobID, c)
        // No queued request remains for B after releasing another session.
        next.release(); await Task.yield(); XCTAssertNil(pausedValue)
    }

    func testTaskCancellationAndOwnerFailureReleaseAdmissionWithoutStartingCancelledWork() async throws {
        let gate = GaussianEngineGate(), a = UUID(), b = UUID(), c = UUID()
        var owner = await gate.acquire(gate.enqueue(jobID: a, canRun: { true }))
        XCTAssertNotNil(owner)
        let (cancelled, done) = acquire(gate, gate.enqueue(jobID: b, canRun: { true }))
        let (nextTask, nextDone) = acquire(gate, gate.enqueue(jobID: c, canRun: { true }))
        defer { cancelled.cancel(); nextTask.cancel(); owner?.release(); gate.interrupt(jobID: b); gate.interrupt(jobID: c) }
        cancelled.cancel(); try await wait(done)
        let cancelledValue = await cancelled.value
        XCTAssertNil(cancelledValue); XCTAssertFalse(nextDone.value)
        // Dropping the sole lease models an exception before/native initialization.
        owner = nil
        try await wait(nextDone)
        let nextValue = await nextTask.value, next = try XCTUnwrap(nextValue)
        XCTAssertEqual(next.jobID, c); next.release()
    }

    func testManualResumeRequeuesABehindBAndCancelDoesNotRestart() async throws {
        let a = UUID(), b = UUID(), gate = GaussianEngineGate.shared
        let first = GaussianTrainingControl(active: true, engineJobID: a)
        let second = GaussianTrainingControl(active: true, engineJobID: b)
        defer { first.set(.cancel); second.set(.cancel) }
        first.prepareEngineRequest(); second.prepareEngineRequest()
        let aRequest = try XCTUnwrap(first.takeEngineRequest()), bRequest = try XCTUnwrap(second.takeEngineRequest())
        let aValue = await gate.acquire(aRequest), aLease = try XCTUnwrap(aValue)
        let (bTask, bDone) = acquire(gate, bRequest)
        defer { bTask.cancel(); aLease.release() }
        first.set(.pause)
        XCTAssertEqual(first.action(), .pause)
        await Task.yield(); XCTAssertFalse(bDone.value, "The next engine must wait until native destruction releases the current lease")
        aLease.release(); try await wait(bDone)
        let bValue = await bTask.value, bLease = try XCTUnwrap(bValue)
        first.prepareEngineRequest(); XCTAssertTrue(first.resumeIfActive(true))
        let resumedRequest = try XCTUnwrap(first.takeEngineRequest())
        let (resumedTask, resumedDone) = acquire(gate, resumedRequest)
        defer { resumedTask.cancel(); bLease.release() }
        await Task.yield(); XCTAssertFalse(resumedDone.value)
        first.set(.cancel); try await wait(resumedDone)
        let resumedValue = await resumedTask.value
        XCTAssertNil(resumedValue)
        XCTAssertFalse(first.resumeIfActive(true))
        first.prepareEngineRequest(); XCTAssertNil(first.takeEngineRequest())
        bLease.release()
    }

    func testLifecycleWithdrawalRequiresNewEligibleRequestAndKeepsManualPause() async throws {
        let job = UUID(), control = GaussianTrainingControl(active: true, engineJobID: job), gate = GaussianEngineGate.shared
        defer { control.set(.cancel) }
        control.prepareEngineRequest()
        let original = try XCTUnwrap(control.takeEngineRequest())
        control.setApplicationActive(false)
        let backgroundValue = await gate.acquire(original)
        XCTAssertNil(backgroundValue)
        XCTAssertFalse(control.resumeIfActive(false))
        XCTAssertEqual(control.action(), .pause)
        control.setApplicationActive(true)
        XCTAssertEqual(control.action(), .pause, "A gate must not override the caller's pause intent")
        control.prepareEngineRequest(); XCTAssertTrue(control.resumeIfActive(true))
        let fresh = try XCTUnwrap(control.takeEngineRequest())
        let resumedValue = await gate.acquire(fresh), resumed = try XCTUnwrap(resumedValue)
        XCTAssertEqual(resumed.jobID, job); resumed.release()
    }

    func testUnstartedPlaceholderCanBeCancelledAndForeignGateCannotConsumeTicket() async throws {
        let gate = GaussianEngineGate(), other = GaussianEngineGate(), a = UUID(), b = UUID()
        let unstarted = gate.enqueue(jobID: a, canRun: { true })
        let ticket = gate.enqueue(jobID: b, canRun: { true })
        let foreign = await other.acquire(ticket)
        XCTAssertNil(foreign)
        let (worker, done) = acquire(gate, ticket)
        defer { worker.cancel(); gate.interrupt(jobID: a); gate.interrupt(jobID: b) }
        await Task.yield(); XCTAssertFalse(done.value)
        gate.withdraw(unstarted)
        try await wait(done)
        let value = await worker.value, lease = try XCTUnwrap(value)
        XCTAssertEqual(lease.jobID, b); lease.release()
        let invalid = await gate.acquire(unstarted)
        XCTAssertNil(invalid)
    }
    func testManyManualPausesParkAsynchronouslyAndWakeOnlyOnResumeOrCancel() async throws {
        let controls = (0..<128).map { _ in GaussianTrainingControl(active: true) }
        let completed = controls.map { _ in Flag() }
        let workers = zip(controls, completed).map { control, flag in
            control.set(.pause)
            return Task.detached { await control.waitUntilResumedAsync(); flag.value = true }
        }
        defer { for control in controls { control.set(.cancel) }; for worker in workers { worker.cancel() } }
        await Task.yield()
        XCTAssertFalse(completed.contains { $0.value })
        XCTAssertTrue(controls[0].resumeIfActive(true))
        controls[1].set(.cancel)
        try await wait(completed[0]); try await wait(completed[1])
        XCTAssertFalse(completed.dropFirst(2).contains { $0.value })
        for control in controls.dropFirst(2) { control.set(.cancel) }
        for worker in workers { await worker.value }
        XCTAssertTrue(completed.allSatisfy { $0.value })
    }

    func testManualResumeSuccessfullyAcquiresAfterOtherSessionFinishes() async throws {
        let a = UUID(), b = UUID(), gate = GaussianEngineGate.shared
        let first = GaussianTrainingControl(active: true, engineJobID: a)
        let second = GaussianTrainingControl(active: true, engineJobID: b)
        defer { first.set(.cancel); second.set(.cancel) }
        first.prepareEngineRequest(); second.prepareEngineRequest()
        let aValue = await gate.acquire(try XCTUnwrap(first.takeEngineRequest()))
        let aLease = try XCTUnwrap(aValue)
        let (bTask, bDone) = acquire(gate, try XCTUnwrap(second.takeEngineRequest()))
        defer { bTask.cancel(); aLease.release() }
        first.set(.pause); aLease.release()
        try await wait(bDone)
        let bValue = await bTask.value, bLease = try XCTUnwrap(bValue)
        first.prepareEngineRequest(); XCTAssertTrue(first.resumeIfActive(true))
        let (resumedTask, resumedDone) = acquire(gate, try XCTUnwrap(first.takeEngineRequest()))
        defer { resumedTask.cancel(); bLease.release() }
        await Task.yield(); XCTAssertFalse(resumedDone.value)
        bLease.release(); try await wait(resumedDone)
        let resumedValue = await resumedTask.value, resumed = try XCTUnwrap(resumedValue)
        XCTAssertEqual(resumed.jobID, a)
        XCTAssertEqual(first.action(), .run)
        resumed.release()
    }

}
