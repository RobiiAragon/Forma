import XCTest
import ARKit
@testable import Forma

final class CapturePacingTests: XCTestCase {
    func testLiDARCameraReturnsAfterSystemInterruptionWithoutUndoingHumanPauseOrFault() {
        var state = LiDARExecutionState()
        XCTAssertTrue(state.shouldRunCamera)
        state.cameraWasInterrupted()
        XCTAssertFalse(state.shouldRunCamera)
        state.cameraInterruptionEnded()
        XCTAssertTrue(state.shouldRunCamera)
        state.setForeground(false)
        XCTAssertFalse(state.shouldRunCamera)
        state.setForeground(true)
        XCTAssertTrue(state.shouldRunCamera)
        state.setVisible(false)
        XCTAssertFalse(state.shouldRunCamera)
        state.setVisible(true)
        XCTAssertTrue(state.shouldRunCamera)
        state.pauseCameraByUser()
        state.cameraWasInterrupted(); state.setForeground(false)
        state.setForeground(true); state.cameraInterruptionEnded()
        XCTAssertFalse(state.shouldRunCamera, "Foreground recovery must preserve a manual pause")
        state.resumeCameraByUser()
        XCTAssertTrue(state.shouldRunCamera)
        state.cameraFailed(); state.setForeground(false); state.setForeground(true)
        XCTAssertFalse(state.shouldRunCamera, "A real camera/write error remains visible until explicit retry")
        state.resumeCameraByUser()
        XCTAssertTrue(state.shouldRunCamera)
        state.beginProcessing(); state.setForeground(false); state.setForeground(true)
        XCTAssertFalse(state.shouldRunCamera, "Processing must not restart camera acquisition")
        state.close(); state.resumeCameraByUser()
        XCTAssertFalse(state.shouldRunCamera)
    }

    func testLiDARCPUGrantAndForegroundRecoveryPreserveManualPauseAndCancellation() {
        var state = LiDARExecutionState()
        state.beginProcessing()
        state.updateCPUGrant(true); state.setForeground(false)
        XCTAssertFalse(state.shouldHoldProcessing, "An actual CPU grant permits background preparation")
        state.expireCPUGrant()
        XCTAssertTrue(state.processingWaitsForForeground)
        state.updateCPUGrant(true)
        XCTAssertTrue(state.shouldHoldProcessing, "A stale token cannot revive an expired grant")
        state.setForeground(true)
        XCTAssertFalse(state.shouldHoldProcessing, "CPU preparation resumes automatically in foreground")
        state.pauseProcessingByUser(); state.setForeground(false); state.setForeground(true)
        XCTAssertTrue(state.shouldHoldProcessing)
        state.resumeProcessingByUser()
        XCTAssertFalse(state.shouldHoldProcessing)
        state.cancelProcessingByUser(); state.resumeProcessingByUser(); state.updateCPUGrant(true)
        XCTAssertTrue(state.processingCancelled, "Lifecycle or resume events cannot revive cancelled processing")
        state.beginProcessing()
        XCTAssertFalse(state.processingCancelled, "A new explicit preparation attempt owns a fresh gate")
    }

    func testChoosesActualFiveFPSFormatBeforeFasterHigherResolution() {
        let formats = [CapturePacingPolicy.Format(framesPerSecond: 60, width: 4096, height: 2160),
                       .init(framesPerSecond: 30, width: 3840, height: 2160),
                       .init(framesPerSecond: 5, width: 1920, height: 1440)]
        XCTAssertEqual(CapturePacingPolicy.preferredFormatIndex(formats, maximumQuality: true), 2)
    }
    func testDoesNotInventFiveFPSWhenARKitOnlyProvidesTwentyFourOrFaster() throws {
        let formats = [CapturePacingPolicy.Format(framesPerSecond: 60, width: 1920, height: 1440),
                       .init(framesPerSecond: 30, width: 1920, height: 1440),
                       .init(framesPerSecond: 24, width: 3840, height: 2160)]
        let index = CapturePacingPolicy.preferredFormatIndex(formats, maximumQuality: true)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(formats[try XCTUnwrap(index)].framesPerSecond, 24)
        XCTAssertNil(CapturePacingPolicy.preferredFormatIndex([], maximumQuality: true))
    }

    func testLowestRealSensorRateKeepsNativeResolutionAndHighResolutionTieBreaks() throws {
        let formats = [CapturePacingPolicy.Format(framesPerSecond: 30, width: 4096, height: 2160, supportsHighResolution: true),
                       .init(framesPerSecond: 24, width: 1920, height: 1440),
                       .init(framesPerSecond: 24, width: 3840, height: 2160),
                       .init(framesPerSecond: 24, width: 3840, height: 2160, supportsHighResolution: true),
                       .init(framesPerSecond: 0, width: 8192, height: 8192),
                       .init(framesPerSecond: 1, width: 0, height: 0)]
        let quality = try XCTUnwrap(CapturePacingPolicy.preferredFormatIndex(formats, maximumQuality: true))
        XCTAssertEqual(quality, 3, "The lower cadence must retain the highest native raster and HiRes capability at that sensor rate")
        XCTAssertEqual(CapturePacingPolicy.preferredFormatIndex(formats, maximumQuality: false), 1)
        XCTAssertNil(CapturePacingPolicy.preferredFormatIndex([formats[4], formats[5]], maximumQuality: true))
    }

    func testStartupFastAndSlowWritersRespectRequestedCadenceAndBackpressure() {
        for mean in [0.0, 0.01, 0.1, -.infinity, .nan] {
            XCTAssertEqual(CapturePacingPolicy.savedStreamInterval(meanCommitSeconds: mean), 0.2, accuracy: 1e-12,
                           "A fast or not-yet-measured writer cannot exceed five automatic RGB-D frames per second")
        }
        XCTAssertEqual(CapturePacingPolicy.savedStreamInterval(meanCommitSeconds: 0.25), 0.3, accuracy: 1e-12)
        XCTAssertEqual(CapturePacingPolicy.savedStreamInterval(meanCommitSeconds: 1), 0.45, accuracy: 1e-12)
    }

    func testThirtyAndSixtyHzCallbacksDoNotTriggerExtraAutomaticOrMeshProcessing() {
        for incomingFPS in [30, 60] {
            for interval in [CapturePacingPolicy.automaticKeyframeEvaluationInterval, CapturePacingPolicy.meshPreviewInterval] {
                var accepted: [TimeInterval] = []
                for frame in 0...(incomingFPS * 10) {
                    let timestamp = 250_000 + Double(frame) / Double(incomingFPS)
                    if CapturePacingPolicy.hasElapsed(interval, since: accepted.last, at: timestamp) { accepted.append(timestamp) }
                }
                XCTAssertEqual(accepted.count, 51, "Ten seconds plus the initial sample should trigger exactly fifty cadence intervals")
                for (a, b) in zip(accepted, accepted.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b - a, 0.2 - 1e-9)
                }
            }
        }
    }

    func testCadenceRejectsEarlyDuplicateInvalidAndRegressingTimestamps() {
        let interval = CapturePacingPolicy.automaticKeyframeEvaluationInterval
        XCTAssertTrue(CapturePacingPolicy.hasElapsed(interval, since: nil, at: 10))
        for timestamp in [10.0, 9.0, 10.199, .nan, .infinity] {
            XCTAssertFalse(CapturePacingPolicy.hasElapsed(interval, since: 10, at: timestamp))
        }
        XCTAssertTrue(CapturePacingPolicy.hasElapsed(interval, since: 10, at: 10.2))
        XCTAssertFalse(CapturePacingPolicy.hasElapsed(interval, since: nil, at: .nan))
    }

    func testEvaluationAndStreamGatesDoNotHalveCadenceAtFloatingPointBoundaries() {
        var lastEvaluation: TimeInterval?, lastStream: TimeInterval?
        var savedTimestamps: [TimeInterval] = []
        for frame in 0...600 {
            let timestamp = 250_000 + Double(frame) / 60
            guard CapturePacingPolicy.hasElapsed(CapturePacingPolicy.automaticKeyframeEvaluationInterval,
                                                since: lastEvaluation, at: timestamp) else { continue }
            lastEvaluation = timestamp
            if CapturePacingPolicy.hasElapsed(CapturePacingPolicy.savedStreamInterval(meanCommitSeconds: 0.01),
                                             since: lastStream, at: timestamp) {
                lastStream = timestamp; savedTimestamps.append(timestamp)
            }
        }
        XCTAssertEqual(savedTimestamps.count, 51, "Two cadence checks must not accidentally turn the requested 5 FPS into roughly 2.5 FPS")
    }
    func testPhysicalFormatSelectionReportsARKitMinimumInsteadOfAnInventedSensorRate() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator does not expose the phone's physical camera formats.")
        #else
        let available = ARWorldTrackingConfiguration.supportedVideoFormats
        guard !available.isEmpty else { throw XCTSkip("No ARKit video formats on this device.") }
        let descriptors = available.map { CapturePacingPolicy.Format(framesPerSecond:$0.framesPerSecond,
            width:Int($0.imageResolution.width),height:Int($0.imageResolution.height),
            supportsHighResolution:$0.isRecommendedForHighResolutionFrameCapturing) }
        let selected = try XCTUnwrap(CapturePacingPolicy.preferredFormatIndex(descriptors,maximumQuality:true))
        let minimum = try XCTUnwrap(descriptors.map(\.framesPerSecond).min())
        XCTAssertEqual(descriptors[selected].framesPerSecond, minimum)
        print("FORMA_REAL_AR_FORMATS " + descriptors.map { "\($0.width)x\($0.height)@\($0.framesPerSecond)" }.joined(separator:","))
        print("FORMA_SELECTED_SENSOR_FPS \(descriptors[selected].framesPerSecond), PHONE_PREVIEW_TARGET \(CapturePacingPolicy.phonePreviewFPS)")
        let evidence: [String: Any] = [
            "availableFormats": descriptors.map { ["width": $0.width, "height": $0.height, "fps": $0.framesPerSecond, "supportsHighResolution": $0.supportsHighResolution] as [String: Any] },
            "selectedFormatIndex": selected,
            "selectedSensorFPS": descriptors[selected].framesPerSecond,
            "minimumSupportedSensorFPS": minimum,
            "requestedPreviewFPS": CapturePacingPolicy.phonePreviewFPS,
            "maximumMeshPreviewUpdatesPerAnchorPerSecond": CapturePacingPolicy.meshPreviewFPS,
            "maximumAutomaticKeyframeEvaluationsPerSecond": CapturePacingPolicy.automaticKeyframeEvaluationFPS,
            "maximumAutomaticRGBDFramesPerSecond": CapturePacingPolicy.maximumSavedStreamFPS,
            "cameraStartedByThisTest": false,
            "doesNotMeasure": ["actual presented frames", "sensor energy use", "scan completeness"]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "lidar-five-fps-policy.json"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }
    func testHybridCaptureKeepsSourcesWithoutBakingOrCreatingFakeTexture() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dataset = workspace.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(), frames: []).write(to: dataset)
        let mesh = MeshSnapshot(vertices: [.init(0,0,0), .init(1,0,0), .init(0,1,0)], triangles: [0,1,2])
        let result = try await HybridCapturePreparation.prepare(mesh: mesh, datasetDirectory: dataset, duration: 1, mode: .lidar)
        XCTAssertEqual(result.statistics?["remoteProcessingPending"], 1)
        XCTAssertEqual(result.statistics?["texturedFaces"], 0)
        XCTAssertEqual(result.captureDatasetURL, dataset)
        XCTAssertNil(result.modelPackageURL)
        let original = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: dataset.appendingPathComponent("malla-original.json")))
        XCTAssertEqual(original.vertices, mesh.vertices)
        XCTAssertEqual(original.triangles, mesh.triangles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ModeloTexturizado").path))
    }
}
