import XCTest
import UIKit
import os
import FormaGaussianCore
@testable import Forma

/// Physical acceptance on the preserved room. All writes go to a temporary
/// workspace; the user's dataset, recovery index and checkpoint are read-only.
final class GaussianRoomContinuationTests: XCTestCase {
    @MainActor
    func testProductionTrainerKeepsRunningAfterMemoryWarningsAndHonorsManualPause() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical phone's preserved room and Metal.")
        #else
        let originalFolder = GaussianRecovery.sessionsDirectory.appendingPathComponent("41707E7D-0C2D-4F39-968C-622CA40C3CAB")
        let index = originalFolder.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: index.path) else { throw XCTSkip("Private room fixture not installed.") }
        let originalIndex = try Data(contentsOf: index)
        let original = try JSONDecoder().decode(GaussianRecoverySession.self, from: originalIndex)
        let originalHash = try IntegrityManifest.digest(original.checkpointURL)
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Foreground Metal execution is required.") }
        let owned = try GaussianRecovery.create(datasetURL: original.datasetURL, iterations: max(3000, original.step + 300), downscale: 1)
        let availableMemoryAtStart = os_proc_available_memory()
        let trainer = GaussianTrainerService(session: owned.session)
        // All outputs belong to this new fixture session; user sources are read-only.
        defer {
            if trainer.phase == .settings || trainer.phase == .failed || trainer.phase == .ready {
                try? GaussianRecovery.remove(owned.session)
            }
        }
        trainer.start(datasetURL: original.datasetURL, iterations: owned.session.targetIterations, downscale: 1,
                      resumeURL: original.checkpointURL)
        do {
            try await waitForTrainer(trainer, timeout: 90) { trainer.iteration >= original.step + 5 }
            let before = trainer.iteration
            for _ in 0..<10 {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            }
            try await waitForTrainer(trainer, timeout: 90) {
                trainer.memoryWarningCount >= 10 && trainer.iteration >= before + 100
            }
            XCTAssertEqual(trainer.phase, .running)
            XCTAssertFalse(trainer.pauseRequested)
            XCTAssertNil(trainer.pauseCause)
            let afterWarnings = trainer.iteration
            let warningCount = trainer.memoryWarningCount
            trainer.pause()
            try await waitForTrainer(trainer, timeout: 30) { trainer.phase == .paused }
            XCTAssertEqual(trainer.pauseCause, .manual)
            let saved = try XCTUnwrap(trainer.checkpointURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
            let paused = trainer.iteration
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(trainer.iteration, paused)
            trainer.resume()
            try await waitForTrainer(trainer, timeout: 60) { trainer.iteration >= paused + 5 }
            trainer.pause()
            try await waitForTrainer(trainer, timeout: 30) { trainer.phase == .paused }
            let exportedStep = trainer.iteration
            // Reproduce a checkpoint grace expiration after a manual pause.
            // The old control is terminal; Export must start a new worker.
            trainer.checkpointAllowanceExpired()
            trainer.stopAndExport()
            try await waitForTrainer(trainer, timeout: 60) { trainer.phase == .ready }
            XCTAssertNotNil(trainer.result)
            XCTAssertEqual(trainer.iteration, exportedStep)
            let intention = try GaussianRunIntention.load(from: owned.workspaceURL)
            XCTAssertEqual(intention.intent, .completed)
            let evidence: [String: Any] = [
                "productionGaussianTrainerService": true, "continuousMode": true,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "processAvailableMemoryAtStartBytes": availableMemoryAtStart,
                "processAvailableMemoryAtEndBytes": os_proc_available_memory(),
                "originalStep": original.step, "warningInjectionStep": before,
                "stepAfterWarnings": afterWarnings, "injectedWarnings": 10,
                "receivedWarnings": warningCount, "manualPauseAndResumePassed": true,
                "exportAfterCheckpointExpirationPassed": true,
                "originalCheckpointUnchanged": try IntegrityManifest.digest(original.checkpointURL) == originalHash,
                "originalIndexUnchanged": try Data(contentsOf: index) == originalIndex,
                "downscaleFactor": 1, "userImagesUploaded": false
            ]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                          uniformTypeIdentifier: "public.json")
            attachment.name = "gaussian-production-continuous-warnings.json"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(try IntegrityManifest.digest(original.checkpointURL), originalHash)
            XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        } catch {
            let diagnostic = XCTAttachment(string: "step=\(trainer.iteration) phase=\(trainer.phase) warnings=\(trainer.memoryWarningCount) pauseRequested=\(trainer.pauseRequested) cause=\(String(describing: trainer.pauseCause)) error=\(error)")
            diagnostic.name = "production-trainer-failure-state"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            trainer.cancel()
            // Let the actual native worker finish saving before removing its own workspace.
            try? await waitForTrainer(trainer, timeout: 30) { trainer.phase == .settings || trainer.phase == .failed }
            throw error
        }
        #endif
    }

    @MainActor
    private func waitForTrainer(_ trainer: GaussianTrainerService, timeout: TimeInterval,
                                until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if trainer.phase == .failed { throw RoomError.engine(trainer.message) }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw RoomError.interrupted("Timed out at step \(trainer.iteration), phase \(trainer.phase): \(trainer.message)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testPreservedRoomContinuesAtNativeResolutionWithoutMemoryWarning() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical phone's preserved room and Metal.")
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionURL = docs.appendingPathComponent("FormaTraining/41707E7D-0C2D-4F39-968C-622CA40C3CAB/session.json")
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw XCTSkip("The private room acceptance fixture is not installed on this phone.")
        }
        let session = try JSONDecoder().decode(GaussianRecoverySession.self, from: Data(contentsOf: sessionURL))
        let dataset = session.datasetURL
        let originalCheckpoint = sessionURL.deletingLastPathComponent().appendingPathComponent("entrenamiento.ckpt")
        let originalHash = try IntegrityManifest.digest(originalCheckpoint)
        let originalIndex = try Data(contentsOf: sessionURL)
        let library = try XCTUnwrap(Bundle.main.url(forResource: "msplat-ios", withExtension: "metallib"))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while UIApplication.shared.applicationState != .active && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Foreground Metal execution is required.") }
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let observations = Observations()
        let memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { _ in observations.memoryWarning() }
        let inactiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { _ in observations.becameInactive() }
        defer {
            NotificationCenter.default.removeObserver(memoryObserver)
            NotificationCenter.default.removeObserver(inactiveObserver)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-GaussianRoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        setenv("MSPLAT_MEM_LOG_EVERY", "5", 1)
        let target = session.targetIterations, downscale = session.downscale
        let worker = Task.detached(priority: .utility) {
            var error = [CChar](repeating: 0, count: 2048)
            let policy = MobileProcessingPolicy()
            guard let handle = dataset.path.withCString({ data in
                library.path.withCString { metal in forma_gaussian_create(data, metal, Int32(target), downscale, &error, error.count) }
            }) else { throw RoomError.engine(String(cString: error)) }
            defer { forma_gaussian_destroy(handle) }
            var resumed: Int32 = 0
            guard originalCheckpoint.path.withCString({ forma_gaussian_resume(handle, $0, &resumed, &error, error.count) }) else {
                throw RoomError.engine(String(cString: error))
            }
            var stats = FormaGaussianStats(iteration: resumed, splats: 0, milliseconds: 0)
            var completed = 0, interruption = ""
            let started = ProcessInfo.processInfo.systemUptime
            policy.resetWorkClock()
            for _ in 0..<min(80, max(0, target - Int(resumed))) {
                do {
                    try policy.checkpoint(additionalCheck: {
                        try Task.checkCancellation()
                        let state = observations.snapshot
                        if state.warnings > 0 { throw RoomError.interrupted("iOS memory warning") }
                        if state.inactive { throw RoomError.interrupted("App left foreground") }
                        if MobileProcessingPolicy.ThermalLevel.current == .critical {
                            throw RoomError.interrupted("Critical thermal state")
                        }
                    })
                } catch { interruption = error.localizedDescription; break }
                guard forma_gaussian_step(handle, &stats, &error, error.count) else {
                    throw RoomError.engine(String(cString: error))
                }
                completed += 1
            }
            let saved = output.appendingPathComponent("acceptance.ckpt")
            guard saved.path.withCString({ forma_gaussian_checkpoint(handle, $0, &error, error.count) }) else {
                throw RoomError.engine(String(cString: error))
            }
            return (Int(resumed), Int(stats.iteration), Int(stats.splats), completed,
                    ProcessInfo.processInfo.systemUptime - started, policy.snapshot, interruption)
        }
        let r = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        let evidence: [String: Any] = [
            "startStep": r.0, "endStep": r.1, "splats": r.2, "completedSteps": r.3,
            "downscaleFactor": downscale, "targetIterations": target,
            "secondsIncludingPacing": r.4, "measuredWorkSeconds": r.5.measuredWorkSeconds,
            "restSeconds": r.5.restSeconds, "memoryWarnings": observations.snapshot.warnings,
            "interruption": r.6, "userCheckpointSHA256Unchanged": try IntegrityManifest.digest(originalCheckpoint) == originalHash,
            "userSessionIndexUnchanged": try Data(contentsOf: sessionURL) == originalIndex,
            "userImagesUploaded": false, "writesOnlyToOwnedTemporaryWorkspace": true
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "gaussian-room-native-resolution.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(downscale, 1, "This acceptance must exercise the user's native resolution.")
        XCTAssertEqual(r.3, min(80, target - r.0), r.6)
        XCTAssertGreaterThan(r.3, 5, "Must advance beyond the old five-step pause boundary.")
        XCTAssertEqual(observations.snapshot.warnings, 0)
        XCTAssertEqual(try IntegrityManifest.digest(originalCheckpoint), originalHash)
        XCTAssertEqual(try Data(contentsOf: sessionURL), originalIndex)
        #endif
    }

    private enum RoomError: LocalizedError {
        case engine(String), interrupted(String)
        var errorDescription: String? {
            switch self { case .engine(let message), .interrupted(let message): return message }
        }
    }
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var warnings = 0, inactive = false
        var snapshot: (warnings: Int, inactive: Bool) {
            lock.lock(); defer { lock.unlock() }; return (warnings, inactive)
        }
        func memoryWarning() { lock.lock(); warnings += 1; lock.unlock() }
        func becameInactive() { lock.lock(); inactive = true; lock.unlock() }
    }
}
