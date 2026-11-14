import XCTest
import Foundation
@testable import Forma

final class ProcessingControlTests: XCTestCase {
    func testPauseAcknowledgesAtCheckpointAndResumeContinuesSameWork() throws {
        let started = expectation(description: "first unit completed")
        let paused = expectation(description: "worker acknowledged pause")
        let finished = expectation(description: "same worker finished")
        let proceed = DispatchSemaphore(value: 0), counter = ProcessingTestBox(0)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        DispatchQueue.global().async {
            do {
                try control.checkpoint(); counter.value += 1; started.fulfill()
                proceed.wait()
                try control.checkpoint(); counter.value += 1
                finished.fulfill()
            } catch { XCTFail("Unexpected processing error: \(error)"); finished.fulfill() }
        }
        wait(for: [started], timeout: 2)
        XCTAssertEqual(control.requestPause().phase, .pauseRequested)
        XCTAssertEqual(counter.value, 1)
        proceed.signal()
        wait(for: [paused], timeout: 2)
        XCTAssertEqual(control.snapshot.phase, .paused)
        XCTAssertEqual(counter.value, 1)
        let uiAlive = expectation(description: "main queue remains responsive")
        DispatchQueue.main.async { uiAlive.fulfill() }
        wait(for: [uiAlive], timeout: 2)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(control.resume().phase, .running)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(counter.value, 2, "Resume must not repeat the completed unit")
    }

    func testCancelWakesPausedWorkerAndCannotBeUndoneByResume() {
        let paused = expectation(description: "paused"), ended = expectation(description: "cancelled worker ended")
        let cancelled = ProcessingTestBox(false)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        control.requestPause()
        DispatchQueue.global().async {
            do { try control.checkpoint(); XCTFail("Cancelled checkpoint returned") }
            catch is CancellationError { cancelled.value = true }
            catch { XCTFail("Wrong cancellation error: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        control.cancel()
        wait(for: [ended], timeout: 2)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(control.resume().phase, .cancelled)
    }

    func testTaskCancellationHandlerWakesGate() {
        let paused = expectation(description: "paused"), ended = expectation(description: "task ended")
        let cancelled = ProcessingTestBox(false)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        control.requestPause()
        let worker = Task.detached {
            try await withTaskCancellationHandler(operation: { try control.checkpoint() }, onCancel: { control.cancel() })
        }
        Task {
            do { try await worker.value; XCTFail("Cancelled task returned success") }
            catch is CancellationError { cancelled.value = true }
            catch { XCTFail("Wrong task error: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        worker.cancel()
        wait(for: [ended], timeout: 2)
        XCTAssertTrue(cancelled.value)
    }

    func testNestedOperationsInheritGateWhenControlIsNil() {
        let paused = expectation(description: "inherited gate paused"), ended = expectation(description: "nested gate cancelled")
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        control.requestPause()
        DispatchQueue.global().async {
            do {
                try ProcessingControl.withControl(control) {
                    try ProcessingControl.withControl(nil) { try ProcessingControl.checkpoint() }
                }
                XCTFail("Nested operation bypassed pause")
            } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        control.cancel()
        wait(for: [ended], timeout: 2)
    }

    func testPipelinePauseResumeKeepsCompletedStageAndOriginalSources() throws {
        let root = try dataset()
        let paused = expectation(description: "pipeline paused"), ended = expectation(description: "pipeline completed")
        let starts = ProcessingTestBox(0), output = ProcessingTestBox<CaptureResult?>(nil)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        let mesh = MeshSnapshot(vertices: [SIMD3<Float>(-0.2, -0.2, -2), SIMD3(0.2, -0.2, -2), SIMD3(0, 0.2, -2)], triangles: [0, 1, 2])
        Task.detached {
            do {
                output.value = try await LiDARProcessingPipeline.process(mesh: mesh, datasetDirectory: root, duration: 1, mode: .lidar, control: control) { title, _ in
                    if title == "Uniendo bordes compatibles sin perder superficies" {
                        starts.value += 1; control.requestPause()
                    }
                }
            } catch { XCTFail("Pipeline failed: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        XCTAssertEqual(starts.value, 1)
        XCTAssertNil(output.value)
        control.resume()
        wait(for: [ended], timeout: 3)
        XCTAssertEqual(starts.value, 1, "Resume continues the original invocation")
        let result = try XCTUnwrap(output.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.modelURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dataset.json").path))
    }

    func testPipelineTaskCancellationWhilePausedPreservesDataset() throws {
        let root = try dataset(), original = try Data(contentsOf: root.appendingPathComponent("dataset.json"))
        let paused = expectation(description: "pipeline paused"), ended = expectation(description: "pipeline cancelled")
        let cancelled = ProcessingTestBox(false)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        let mesh = MeshSnapshot(vertices: [SIMD3<Float>(-0.2, -0.2, -2), SIMD3(0.2, -0.2, -2), SIMD3(0, 0.2, -2)], triangles: [0, 1, 2])
        let worker = Task.detached {
            try await LiDARProcessingPipeline.process(mesh: mesh, datasetDirectory: root, duration: 1, mode: .lidar, control: control) { title, _ in
                if title == "Uniendo bordes compatibles sin perder superficies" { control.requestPause() }
            }
        }
        Task {
            do { _ = try await worker.value; XCTFail("Cancelled pipeline returned") }
            catch is CancellationError { cancelled.value = true }
            catch { XCTFail("Wrong pipeline cancellation: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        worker.cancel()
        wait(for: [ended], timeout: 2)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("dataset.json")), original)
    }

    private func dataset() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-GateTests-\(UUID().uuidString)")
        let root = workspace.appendingPathComponent("RGBD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(), frames: []).write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return root
    }
}

final class ProcessingTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
