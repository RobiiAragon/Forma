import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import UIKit
import ActivityKit
@testable import Forma

/// Runs the bundled learned model on authored pixels, never a camera or a user capture.
final class LocalAITextureTests: XCTestCase {
    func testRealBundledCoreMLRestoresInteriorKeepingNativeGeometryPixelsAndAlpha() async throws {
        let model = try bundledModel()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let beforeOBJ = try Data(contentsOf: fixture.obj)
        let beforeMTL = try Data(contentsOf: fixture.mtl)
        let beforePNG = try Data(contentsOf: fixture.png)
        let original = try pixels(fixture.png)
        let destination = fixture.root.appendingPathComponent("restored", isDirectory: true)
        let gate = ProcessingControl()
        let package = fixture.package
        let worker = Task.detached(priority: .userInitiated) {
            try LocalAITextureEnhancer.run(package: package, output: destination,
                modelURL: model, strength: 1, control: gate)
        }
        let report = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            gate.cancel(); worker.cancel()
        })
        let restored = try pixels(destination.appendingPathComponent("texture.png"))
        XCTAssertEqual(report.inferenceTileCount, 1, "The fixture fits one real 522-pixel inference tile")
        XCTAssertGreaterThan(report.changedPixels, 0, "A copied image or a shader is not learned-model inference")
        XCTAssertGreaterThan(report.eligiblePixels, 1024)
        XCTAssertEqual(report.processedTextureCount, 1)
        XCTAssertEqual(report.totalTexturePixels, Int64(160 * 128))
        XCTAssertGreaterThan(report.firstPredictionSeconds, 0)
        XCTAssertEqual(report.modelFingerprint.count, 64)
        XCTAssertEqual(restored.width, original.width)
        XCTAssertEqual(restored.height, original.height)
        XCTAssertEqual(restored.width, 160)
        XCTAssertEqual(restored.height, 128)

        let alphaMismatches = stride(from: 3, to: original.rgba.count, by: 4)
            .filter { original.rgba[$0] != restored.rgba[$0] }.count
        var protectedBorderMismatches = 0
        var changedOpaquePixels = 0
        for y in 0..<original.height {
            for x in 0..<original.width {
                let i = (y * original.width + x) * 4
                let before = original.rgba[i..<(i + 4)], after = restored.rgba[i..<(i + 4)]
                if x < 2 || y < 2 || x >= original.width - 2 || y >= original.height - 2 {
                    if !before.elementsEqual(after) { protectedBorderMismatches += 1 }
                } else if original.rgba[i + 3] == 255 && !before.elementsEqual(after) {
                    changedOpaquePixels += 1
                }
            }
        }
        XCTAssertEqual(alphaMismatches, 0, "Alpha must survive native PNG export exactly")
        XCTAssertEqual(protectedBorderMismatches, 0, "Protected borders cannot be restored or cross UV boundaries")
        XCTAssertGreaterThan(changedOpaquePixels, 0, "Decoded output must contain a real appearance change")
        XCTAssertEqual(Int64(changedOpaquePixels), report.changedPixels)
        XCTAssertEqual(try Data(contentsOf: report.modelURL), beforeOBJ, "Geometry, UVs, winding and normals remain byte-exact")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("modelo.mtl")), beforeMTL)
        XCTAssertEqual(try Data(contentsOf: fixture.obj), beforeOBJ)
        XCTAssertEqual(try Data(contentsOf: fixture.mtl), beforeMTL)
        XCTAssertEqual(try Data(contentsOf: fixture.png), beforePNG, "The source PNG must not be overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("ia-local.json").path))

        #if targetEnvironment(simulator)
        let environment = "iOS simulator"
        #else
        let environment = "physical iOS device"
        #endif
        let evidence: [String: Any] = [
            "test": "real-bundled-CoreML-native-texture-restoration",
            "environment": environment,
            "hardwareIdentifier": hardwareIdentifier(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "modelResource": model.lastPathComponent,
            "modelFingerprint": report.modelFingerprint,
            "fixture": "authored sRGB gradient with deterministic fine pattern, UV quad, no scene shader",
            "sourceDimensions": [original.width, original.height],
            "outputDimensions": [restored.width, restored.height],
            "inferenceTileCount": report.inferenceTileCount,
            "eligiblePixels": report.eligiblePixels,
            "changedPixels": report.changedPixels,
            "decodedChangedOpaquePixels": changedOpaquePixels,
            "firstPredictionSeconds": report.firstPredictionSeconds,
            "totalSeconds": report.totalSeconds,
            "alphaMismatches": alphaMismatches,
            "protectedTwoPixelBorderMismatches": protectedBorderMismatches,
            "sourcePNGSHA256": SHA256.hash(data: beforePNG).map { String(format: "%02x", $0) }.joined(),
            "originalBytesPreserved": try Data(contentsOf: fixture.png) == beforePNG &&
                Data(contentsOf: fixture.obj) == beforeOBJ && Data(contentsOf: fixture.mtl) == beforeMTL,
            "cameraUsed": false,
            "userImagesIncluded": false,
            "notMeasured": ["photographic quality improvement", "geometric accuracy", "viewer FPS"]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = "local-ai-real-coreml-inference.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCancellationBeforeProcessingDoesNotPublishOrChangeSources() async throws {
        let model = try bundledModel()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceFiles = [fixture.obj, fixture.mtl, fixture.png]
        let originalBytes = try sourceFiles.map { try Data(contentsOf: $0) }
        let gate = ProcessingControl()
        gate.cancel()
        let destination = fixture.root.appendingPathComponent("cancelled-output", isDirectory: true)
        let package = fixture.package
        let worker = Task.detached(priority: .userInitiated) {
            try LocalAITextureEnhancer.run(package: package, output: destination,
                modelURL: model, strength: 1, control: gate)
        }
        do {
            _ = try await worker.value
            XCTFail("Pre-cancelled work must throw without publishing an output")
        } catch { XCTAssertTrue(error is CancellationError, "Unexpected failure: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".local-ai-") })
        for (url, bytes) in zip(sourceFiles, originalBytes) {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    /// Physical acceptance fixture: real CPU Core ML under an actual continued
    /// processing grant. A reviewer can leave the app/lock the phone during this
    /// case; UIKit state observations distinguish that from foreground execution.
    @MainActor
    func testPhysicalContinuedCoreMLAndLiveActivityPauseIntent() async throws {
        try await runContinuedCoreMLFixture(inferences: 120, requireBackgroundObservation: false)
    }

    @MainActor
    func testPhysicalManualBackgroundWithPrioritizedLiveActivity() async throws {
        try await runContinuedCoreMLFixture(inferences: 72, requireBackgroundObservation: true)
    }

    @MainActor
    private func runContinuedCoreMLFixture(inferences: Int, requireBackgroundObservation: Bool) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing and lock-screen ActivityKit require a physical iPhone.")
        #else
        guard #available(iOS 26, *) else { throw XCTSkip("Continued processing requires iOS 26 or later.") }
        let foregroundDeadline = ProcessInfo.processInfo.systemUptime + 5
        while UIApplication.shared.applicationState != .active && ProcessInfo.processInfo.systemUptime < foregroundDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let fixture = try makeFixture()
        let model = try bundledModel()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let paused = expectation(description: "Pause intent acknowledged by real worker")
        let gate = ProcessingControl { state in
            if state.phase == .paused && state.revision == 2 { paused.fulfill() }
        }
        let coordinator = ProcessingActivityCoordinator.shared
        let lease = await coordinator.begin(id: id, title: "Forma · Prueba IA", onAction: { action in
            if action == "pause" { gate.requestPause() } else if action == "resume" { gate.resume() }
        }, onExpiration: { gate.cancel() })
        defer { gate.cancel(); coordinator.finish(id: id, success: false, status: "Prueba finalizada") }
        guard lease.canContinueInBackground else {
            let note = XCTAttachment(string: lease.backgroundReason); note.name = "continued-processing-unavailable"; note.lifetime = .keepAlways; add(note)
            throw XCTSkip("No grant from iOS: \(lease.backgroundReason)")
        }
        XCTAssertTrue(lease.shouldUseCPUOnly)
        print("Forma CPU fixture activity: \(lease.liveActivityAvailable), \(lease.liveActivityStatus)")
        let policy = MobileProcessingPolicy()
        let worker = Task.detached(priority: .utility) {
            policy.resetWorkClock()
            var changed: Int64 = 0, inBackground = 0, completed = 0
            let started = ProcessInfo.processInfo.systemUptime
            for index in 0..<inferences {
                try gate.checkpoint()
                let output = fixture.root.appendingPathComponent("iteration-\(index)")
                let report = try LocalAITextureEnhancer.run(package: fixture.package, output: output,
                    modelURL: model, strength: 0.35, control: gate,
                    pacing: { try policy.checkpoint(control: gate) }, cpuOnly: true)
                changed += report.changedPixels; completed += 1
                let background = await MainActor.run { UIApplication.shared.applicationState == .background }
                if background { inBackground += 1 }
                await MainActor.run {
                    coordinator.update(id: id, progress: Double(index + 1) / Double(inferences),
                        status: "Bloque \(index + 1) de \(inferences)", phase: "running", energyLabel: "Prueba CPU · actividad objetivo 50 %")
                }
                try FileManager.default.removeItem(at: output)
            }
            return (completed, inBackground, changed, ProcessInfo.processInfo.systemUptime - started, policy.snapshot)
        }
        try await Task.sleep(for: .seconds(2))
        _ = try await FormaProcessingActionIntent(jobID: id.uuidString, action: "pause").perform()
        await fulfillment(of: [paused], timeout: 20)
        let acknowledgedPause = gate.snapshot.phase == .paused
        XCTAssertTrue(acknowledgedPause)
        coordinator.update(id: id, progress: 0, status: "Pausa de prueba confirmada", phase: "paused", energyLabel: "Actividad objetivo 50 %")
        _ = try await FormaProcessingActionIntent(jobID: id.uuidString, action: "resume").perform()
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { gate.cancel(); worker.cancel() })
        XCTAssertEqual(result.0, inferences)
        if requireBackgroundObservation { XCTAssertGreaterThan(result.1, 0, "Manual acceptance requires sending Forma to Home while the fixture runs") }
        XCTAssertGreaterThan(result.2, 0)
        let evidence: [String: Any] = ["hardwareIdentifier": hardwareIdentifier(), "continuedProcessingGranted": true,
            "cpuOnly": true, "completedInferences": result.0, "inferencesFinishedWhileAppBackgrounded": result.1,
            "changedPixels": result.2, "secondsIncludingPacing": result.3,
            "measuredWorkSeconds": result.4.measuredWorkSeconds, "restSeconds": result.4.restSeconds,
            "intentPauseAcknowledged": acknowledgedPause, "intentResumeCompleted": gate.snapshot.phase == .running,
            "customActivityRequested": lease.liveActivityAvailable, "customActivityStatus": lease.liveActivityStatus,
            "userImagesIncluded": false]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = "physical-continued-processing.json"; attachment.lifetime = .keepAlways; add(attachment)
        coordinator.finish(id: id, success: true, status: "\(inferences) bloques Core ML completados")
        #endif
    }

    @MainActor
    func testPhysicalLiveActivityAvailabilityAndGPUForegroundFallback() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live Activity presentation requires physical validation.")
        #else
        try await Task.sleep(for: .seconds(2))
        let id = UUID(), gate = ProcessingControl()
        let coordinator = ProcessingActivityCoordinator.shared
        let lease = await coordinator.begin(id: id, title: "Forma · Prueba de pausa", requiresGPU: true,
            onAction: { action in
                if action == "pause" { gate.requestPause() } else { gate.resume() }
            }, onExpiration: { gate.cancel() })
        defer { gate.cancel(); coordinator.finish(id: id, success: true, status: "Control de prueba finalizado") }
        XCTAssertFalse(lease.canContinueInBackground, "A CPU grant must never authorize background Metal")
        print("Forma Live Activity availability: \(lease.liveActivityAvailable), \(lease.liveActivityStatus)")
        let evidence: [String: Any] = ["customActivityRequested": lease.liveActivityAvailable,
            "status": lease.liveActivityStatus, "GPUBackgroundAuthorized": lease.canContinueInBackground,
            "applicationStateAtRequest": UIApplication.shared.applicationState.rawValue, "hardwareIdentifier": hardwareIdentifier()]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = "physical-live-activity-availability.json"; attachment.lifetime = .keepAlways; add(attachment)
        coordinator.update(id: id, progress: 0, status: "Prueba de controles · sin generar un escaneo", phase: "running", energyLabel: "Actividad objetivo 50 %")
        try await Task.sleep(for: .seconds(25))
        XCTAssertTrue(lease.liveActivityAvailable, lease.liveActivityStatus)
        #endif
    }

    private func bundledModel() throws -> URL {
        let model = ["mlmodelc", "mlpackage"].compactMap {
            Bundle.main.url(forResource: "RealESRGAN_general_522_fp16", withExtension: $0)
        }.first
        return try XCTUnwrap(model, "The real bundled RealESRGAN model is required; this test never skips or substitutes a fake")
    }

    private struct Fixture {
        var root: URL
        var package: URL
        var obj: URL
        var mtl: URL
        var png: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FormaLocalAITextureTests-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let obj = package.appendingPathComponent("modelo.obj"), mtl = package.appendingPathComponent("modelo.mtl")
        let png = package.appendingPathComponent("texture.png")
        do {
            try """
            mtllib modelo.mtl
            v 0 0 0
            v 1 0 0
            v 1 1 0
            v 0 1 0
            vt 0 0
            vt 1 0
            vt 1 1
            vt 0 1
            vn 0 0 1
            usemtl observed
            f 1/1/1 2/2/1 3/3/1 4/4/1

            """.write(to: obj, atomically: true, encoding: .utf8)
            try "newmtl observed\nKd 1 1 1\nmap_Kd texture.png\n".write(to: mtl, atomically: true, encoding: .utf8)
            let width = 160, height = 128
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                if y < 2 || y >= height - 2 {
                    rgba[i + 3] = 0
                } else if x < 2 || x >= width - 2 {
                    // Black premultiplied color avoids rounding ambiguity at partial alpha.
                    rgba[i + 3] = 128
                } else {
                    rgba[i] = UInt8(32 + x * 180 / (width - 1))
                    rgba[i + 1] = UInt8(24 + y * 176 / (height - 1))
                    rgba[i + 2] = UInt8(32 + (x + y) * 128 / (width + height - 2) + 12 * ((x / 3 + y / 3) % 2))
                    rgba[i + 3] = 255
                }
            } }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(encoder, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(encoder))
            return Fixture(root: root, package: package, obj: obj, mtl: mtl, png: png)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private struct Raster { var width: Int; var height: Int; var rgba: [UInt8] }

    private func pixels(_ url: URL) throws -> Raster {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, rgba: rgba)
    }

    private func hardwareIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
