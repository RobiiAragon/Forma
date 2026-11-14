import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forma

/// Authored pixels with the actual bundled learned model. No camera, user files,
/// fake inference or replacement store; the same cases run in the Mac CLI harness.
final class LocalAICheckpointTests: XCTestCase {
    func testInterruptedAfterFirstAtlasResumesWithoutRepeatingItAndPublishesAtomically() throws {
        let fixture = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try hashes(fixture.source)
        try interrupt(fixture, model: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        let state = try checkpoint(fixture)
        XCTAssertEqual(state["nextAssetIndex"] as? Int, 1)
        let first = fixture.cache.appendingPathComponent("package/first.png")
        let completedHash = try IntegrityManifest.digest(first)
        let events = CheckpointEvents()
        let resumed = try LocalAITextureEnhancer.run(package: fixture.source, output: fixture.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: fixture.cache) { label, _ in events.append(label) }
        XCTAssertTrue(events.values.contains { $0.hasPrefix("Continuando desde 1 ") })
        XCTAssertFalse(events.values.contains { $0.hasPrefix("IA local: first.png") }, "Completed atlas must not be inferred again")
        XCTAssertEqual(resumed.processedTextureCount, 2)
        XCTAssertEqual(resumed.inferenceTileCount, 2, "One committed prediction plus one resumed prediction")
        XCTAssertEqual(try IntegrityManifest.digest(fixture.output.appendingPathComponent("first.png")), completedHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path), "Checkpoint removed only after complete publication")
        XCTAssertEqual(try hashes(fixture.source), before)
        for name in ["modelo.obj", "modelo.mtl"] {
            XCTAssertEqual(try IntegrityManifest.digest(fixture.output.appendingPathComponent(name)), before[name])
        }
        let baseline = fixture.root.appendingPathComponent("baseline")
        let uninterrupted = try LocalAITextureEnhancer.run(package: fixture.source, output: baseline,
            modelURL: model, strength: 0.5, cpuOnly: true)
        XCTAssertEqual(resumed.changedPixels, uninterrupted.changedPixels)
        for name in ["first.png", "second.png"] {
            XCTAssertEqual(try IntegrityManifest.digest(fixture.output.appendingPathComponent(name)),
                           try IntegrityManifest.digest(baseline.appendingPathComponent(name)))
        }
    }

    func testChangedStrengthIsRejectedWithoutDeletingCheckpointOrPublishing() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try interrupt(f, model: model)
        let cache = try hashes(f.cache)
        XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.7, cpuOnly: true, checkpointDirectory: f.cache)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Reiniciar"))
        }
        XCTAssertEqual(try hashes(f.cache), cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }

    func testChangedSourceIsRejectedWithoutDeletingCompletedAtlas() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try interrupt(f, model: model)
        let completed = try IntegrityManifest.digest(f.cache.appendingPathComponent("package/first.png"))
        let obj = f.source.appendingPathComponent("modelo.obj")
        try (String(contentsOf: obj, encoding: .utf8) + "# source modified\n").write(to: obj, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache))
        XCTAssertEqual(try IntegrityManifest.digest(f.cache.appendingPathComponent("package/first.png")), completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }

    func testWrongRecordedModelFingerprintIsRejected() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try interrupt(f, model: model)
        var state = try checkpoint(f)
        state["modelFingerprint"] = String(repeating: "0", count: 64)
        try write(state, at: f.cache.appendingPathComponent("checkpoint.json"))
        let before = try hashes(f.cache)
        XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache))
        XCTAssertEqual(try hashes(f.cache), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }

    func testCorruptCompletedAtlasAndGeometryAreNotPublished() throws {
        for name in ["first.png", "modelo.obj"] {
            let f = try fixture(), model = try model()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try interrupt(f, model: model)
            try Data("corrupt cache".utf8).write(to: f.cache.appendingPathComponent("package/" + name))
            XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
                modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("checkpoint.json").path))
        }
    }

    func testUncommittedAtlasIsRestoredFromSourceBeforeRetry() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try interrupt(f, model: model)
        // Simulate termination while writing the second PNG, before committing it.
        try Data("incomplete png".utf8).write(to: f.cache.appendingPathComponent("package/second.png"))
        let report = try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache)
        XCTAssertEqual(report.processedTextureCount, 2)
        XCTAssertEqual(report.inferenceTileCount, 2)
        XCTAssertNotNil(CGImageSourceCreateWithURL(f.output.appendingPathComponent("second.png") as CFURL, nil))
    }

    func testEmptyDedicatedCheckpointDirectoryIsAccepted() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let report = try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache)
        XCTAssertEqual(report.processedTextureCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("ia-local.json").path))
    }

    func testNewCheckpointBelowParentAliasCanCommitAndResume() throws {
        let original = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: original.root) }
        let parent = original.root.appendingPathComponent("real-parent")
        let alias = original.root.appendingPathComponent("parent-alias")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let f = Fixture(root: original.root, source: original.source, output: original.output,
                        cache: alias.appendingPathComponent("new-checkpoint"))
        try interrupt(f, model: model)
        XCTAssertEqual(try checkpoint(f)["nextAssetIndex"] as? Int, 1)
        let report = try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache)
        XCTAssertEqual(report.inferenceTileCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cache.path))
    }

    func testCompletedAtlasSymlinkStillRejectedWithoutTouchingSource() throws {
        let f = try fixture(), model = try model()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try interrupt(f, model: model)
        let before = try hashes(f.source)
        let cached = f.cache.appendingPathComponent("package/first.png")
        let target = f.root.appendingPathComponent("completed-atlas-outside-checkpoint.png")
        try CooperativeFileIO.copyFile(cached, to: target)
        let targetHash = try IntegrityManifest.digest(target)
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: target)
        XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, cpuOnly: true, checkpointDirectory: f.cache)) { error in
            let native = error as NSError
            XCTAssertEqual(native.domain, "FormaLocalAI", error.localizedDescription)
            XCTAssertEqual(native.code, 1, error.localizedDescription)
        }
        XCTAssertEqual(try hashes(f.source), before)
        XCTAssertEqual(try IntegrityManifest.digest(target), targetHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: cached.path),
                         "The rejected symlink must remain for an explicit restart, without modifying its target")
    }

    private struct Fixture { let root: URL; let source: URL; let output: URL; let cache: URL }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FormaAICheckpoint-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let obj = """
        mtllib modelo.mtl
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1 1 0
        vt 0 0
        vt 1 0
        vt 0 1
        vt 1 1
        usemtl first
        f 1/1 2/2 3/3
        f 2/2 4/4 3/3
        usemtl second
        f 1/1 2/2 3/3
        f 2/2 4/4 3/3

        """
        try obj.write(to: source.appendingPathComponent("modelo.obj"), atomically: true, encoding: .utf8)
        try "newmtl first\nmap_Kd first.png\nnewmtl second\nmap_Kd second.png\n".write(to: source.appendingPathComponent("modelo.mtl"), atomically: true, encoding: .utf8)
        for (index, name) in ["first.png", "second.png"].enumerated() {
            let w = 160, h = 128
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i] = UInt8(40 + x / 2 + index * 15)
                bytes[i + 1] = UInt8(25 + y + ((x / 3 + y / 3) % 2) * 25)
                bytes[i + 2] = UInt8(60 + ((x + y) % 64))
            } }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source.appendingPathComponent(name) as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return Fixture(root: root, source: source, output: root.appendingPathComponent("published"), cache: root.appendingPathComponent("checkpoint"))
    }
    private func model() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["FORMA_TEST_COREML_MODEL"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.url(forResource: "RealESRGAN_general_522_fp16", withExtension: "mlmodelc") { return bundled }
        #if os(macOS)
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Forma/Resources/RealESRGAN_general_522_fp16.mlpackage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "Real model required; no substitute or skip")
        return local
        #else
        return try XCTUnwrap(Bundle.main.url(forResource: "RealESRGAN_general_522_fp16", withExtension: "mlpackage"))
        #endif
    }
    private func interrupt(_ f: Fixture, model: URL) throws {
        let control = ProcessingControl()
        let events = CheckpointEvents()
        XCTAssertThrowsError(try LocalAITextureEnhancer.run(package: f.source, output: f.output,
            modelURL: model, strength: 0.5, control: control, cpuOnly: true, checkpointDirectory: f.cache) { label, p in
            events.append("\(p): \(label)")
            if label.hasSuffix("avance guardado") && p == 0.5 { control.cancel() }
        }) { error in
            let native = error as NSError
            XCTAssertTrue(error is CancellationError,
                "Unexpected interruption error: \(String(reflecting: error)); localized=\(error.localizedDescription); domain=\(native.domain) code=\(native.code) userInfo=\(native.userInfo); progress=\(events.values)")
        }
    }
    private func hashes(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try CooperativeFileIO.inventory(folder) where !item.directory { result[item.name] = try IntegrityManifest.digest(item.url) }
        return result
    }
    private func checkpoint(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.cache.appendingPathComponent("checkpoint.json"))) as? [String: Any])
    }
    private func write(_ state: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}

private final class CheckpointEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
