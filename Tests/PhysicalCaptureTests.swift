import XCTest
import ARKit
import AVFoundation
import ImageIO
@testable import Forma

final class PhysicalCaptureTests: XCTestCase {
    /// Optional sensor integration test. It never requests permission or attaches a captured image.
    @MainActor
    func testAuthorizedPhysicalLiDARRGBDFramePreservesNativeCalibrationAndDepth() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Una prueba del sensor necesita un iPhone físico; el simulador no aporta datos RGB-D reales.")
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Cámara no autorizada previamente. La prueba no solicita permiso.")
        }
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            throw XCTSkip("Este dispositivo físico no admite la combinación LiDAR mesh y sceneDepth.")
        }
        let session = ARSession()
        let observer = PhysicalRGBDObserver()
        let received = expectation(description: "Frame real con seguimiento normal y profundidad LiDAR")
        observer.onFinish = { received.fulfill() }
        session.delegate = observer
        session.delegateQueue = .main
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics = [.sceneDepth]
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            configuration.videoFormat = format
        }
        defer { session.pause(); session.delegate = nil }
        session.run(configuration)
        await fulfillment(of: [received], timeout: 20)
        session.pause()
        session.delegate = nil
        if let error = observer.error { throw error }
        let frame = try XCTUnwrap(observer.frame, "No llegó un frame RGB-D real válido en 20 segundos")
        let recording = try RGBDRecording()
        let workspace = recording.directory.deletingLastPathComponent()
        do {
            let saved = try await recording.append(frame)
            try await recording.flush()
            let manifest = try RGBDDatasetManifest.load(from: recording.directory)
            XCTAssertEqual(manifest.frames.count, 1)
            XCTAssertEqual(saved.imageWidth, CVPixelBufferGetWidth(frame.image))
            XCTAssertEqual(saved.imageHeight, CVPixelBufferGetHeight(frame.image))
            XCTAssertEqual(saved.imageWidth, Int(configuration.videoFormat.imageResolution.width))
            XCTAssertEqual(saved.imageHeight, Int(configuration.videoFormat.imageResolution.height))
            XCTAssertEqual(saved.intrinsics.count, 9)
            XCTAssertTrue(saved.intrinsics.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(saved.intrinsics[0], 0)
            XCTAssertGreaterThan(saved.intrinsics[4], 0)
            XCTAssertEqual(saved.cameraToWorld.count, 16)
            XCTAssertTrue(saved.cameraToWorld.allSatisfy(\.isFinite))
            XCTAssertTrue(saved.timestamp.isFinite)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(recording.directory.appendingPathComponent(saved.rgbFile) as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, saved.imageWidth)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, saved.imageHeight)
            let depthPath = try XCTUnwrap(saved.depthFile)
            let depthWidth = try XCTUnwrap(saved.depthWidth), depthHeight = try XCTUnwrap(saved.depthHeight)
            let depthBytes = try Data(contentsOf: recording.directory.appendingPathComponent(depthPath))
            XCTAssertEqual(depthBytes.count, depthWidth * depthHeight * MemoryLayout<Float>.size)
            let depths = stride(from: 0, to: depthBytes.count, by: 4).map { offset in
                depthBytes.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            }
            XCTAssertTrue(depths.contains { $0.isFinite && $0 > 0 }, "El sensor debe aportar al menos una profundidad física positiva")
            if let confidence = saved.confidenceFile {
                let confidenceBytes = try Data(contentsOf: recording.directory.appendingPathComponent(confidence))
                XCTAssertEqual(confidenceBytes.count, depthWidth * depthHeight)
                XCTAssertTrue(confidenceBytes.allSatisfy { $0 <= 2 })
            }
            await recording.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "La imagen real de prueba se elimina sin publicarla")
        } catch {
            await recording.discard()
            throw error
        }
        #endif
    }
}

#if !targetEnvironment(simulator)
@MainActor
private final class PhysicalRGBDObserver: NSObject, @preconcurrency ARSessionDelegate {
    var onFinish: (() -> Void)?
    private(set) var frame: RGBDRecordingFrame?
    private(set) var error: Error?
    private var finished = false

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !finished, frame.sceneDepth != nil, case .normal = frame.camera.trackingState else { return }
        finished = true
        self.frame = RGBDRecordingFrame(frame: frame, source: "physicalTest")
        session.pause()
        onFinish?()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard !finished else { return }
        finished = true
        self.error = error
        session.pause()
        onFinish?()
    }
}
#endif
