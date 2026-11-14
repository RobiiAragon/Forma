import XCTest
import Foundation
@testable import Forma

final class LiveActivityControlTests: XCTestCase {
    @MainActor
    func testLiveActivityIntentPausesAndResumesWorkerWithoutOpeningApp() async throws {
        let id = UUID()
        let paused = expectation(description: "Worker acknowledges pause")
        let gate = ProcessingControl { state in
            if state.phase == .paused { paused.fulfill() }
        }
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("FormaProcessingActivityAction"), object: nil, queue: .main) { notification in
            guard notification.userInfo?["jobID"] as? String == id.uuidString else { return }
            if notification.userInfo?["action"] as? String == "pause" { gate.requestPause() }
            if notification.userInfo?["action"] as? String == "resume" { gate.resume() }
        }
        defer { NotificationCenter.default.removeObserver(observer); gate.cancel() }
        _ = try await FormaProcessingActionIntent(jobID: id.uuidString, action: "pause").perform()
        let worker = Task.detached { try gate.checkpoint(); return true }
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(gate.snapshot.phase, .paused)
        _ = try await FormaProcessingActionIntent(jobID: id.uuidString, action: "resume").perform()
        let resumed = try await worker.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(gate.snapshot.phase, .running)
        XCTAssertFalse(FormaProcessingActionIntent.openAppWhenRun)
    }

    @MainActor
    func testMalformedActivityActionsNeverReachProcessingControls() async throws {
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("FormaProcessingActivityAction"), object: nil, queue: .main) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await FormaProcessingActionIntent(jobID: "not-a-job", action: "pause").perform()
        _ = try await FormaProcessingActionIntent(jobID: UUID().uuidString, action: "delete").perform()
        XCTAssertEqual(counter.value, 0)
    }

    func testOptionalSavePacingChecksGateAndDoesNotLeakIntoOtherWork() async throws {
        let counter = Counter(), gate = ProcessingControl()
        try await Task.detached {
            try ProcessingControl.withControl(gate) {
                try ProcessingControl.$workPacing.withValue({ counter.increment(); try gate.checkpoint() }) {
                    try ProcessingControl.checkpoint()
                    try ProcessingControl.checkpoint()
                }
                try ProcessingControl.checkpoint()
            }
        }.value
        XCTAssertEqual(counter.value, 2)
        gate.cancel()
        do {
            try ProcessingControl.withControl(gate) { try ProcessingControl.checkpoint() }
            XCTFail("Cancellation must remain effective without a pacing closure")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
