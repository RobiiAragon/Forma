import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Isolated Mac fixture. Never opens/quits the user's app or uses its scans.
@main struct DesktopAIRecoveryVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(errorDescription: message) }
    }
    static func png(_ url: URL, offset: Int) throws {
        let width = 160, height = 128
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            for c in 0..<3 { bytes[i+c] = UInt8((x*11+y*7+c*37+offset)%220+15) }
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        try require(CGImageDestinationFinalize(output), "PNG fixture must encode")
    }
    static func package(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(directory.appendingPathComponent("a.png"), offset: 0)
        try png(directory.appendingPathComponent("b.png"), offset: 19)
        try """
        mtllib modelo.mtl
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1 1 0
        vt 0 0
        vt 1 0
        vt 0 1
        vt 1 1
        usemtl a
        f 1/1 2/2 3/3
        f 2/2 4/4 3/3
        usemtl b
        f 1/1 2/2 3/3
        f 2/2 4/4 3/3
        """.write(to: directory.appendingPathComponent("modelo.obj"), atomically: true, encoding: .utf8)
        try "newmtl a\nmap_Kd a.png\nnewmtl b\nmap_Kd b.png\n".write(to: directory.appendingPathComponent("modelo.mtl"), atomically: true, encoding: .utf8)
    }
    @MainActor static func waitUntil(_ predicate: () -> Bool, timeout: Double = 45) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(predicate(), "Timed out waiting for the actual desktop controller/queue")
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let args = Array(CommandLine.arguments.dropFirst())
        guard let path = args.first else { throw Failure(errorDescription: "Pass the existing local Core ML mlpackage path (read only).") }
        let root = fm.temporaryDirectory.appendingPathComponent("FormaDesktopAIQA-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let models = root.appendingPathComponent("Models", isDirectory: true)
        try fm.createDirectory(at: models, withIntermediateDirectories: false)
        let model = models.appendingPathComponent("RealESRGAN_general_522_fp16.mlpackage")
        try fm.copyItem(at: URL(fileURLWithPath: path), to: model)
        let input = root.appendingPathComponent("fixture")
        try package(input)
        let library = ScanStore(baseURL: root.appendingPathComponent("Library"))
        guard let sourceRecord = await library.save(CaptureResult(mesh: nil, modelURL: input.appendingPathComponent("modelo.obj"),
            mode: .lidar, duration: 0, modelPackageURL: input)), let source = library.modelURL(for: sourceRecord) else {
            throw Failure(errorDescription: "Source fixture must save: " + (library.error ?? "unknown"))
        }
        let sourceHash = try IntegrityManifest.digest(source)
        let originalAtlasHash = try IntegrityManifest.digest(source.deletingLastPathComponent().appendingPathComponent("a.png"))
        var job = DesktopLocalAIRecovery.Job(id: UUID(), sourceID: sourceRecord.id, strength: 0.35)
        try DesktopLocalAIRecovery.save(job, root: root)
        let work = DesktopLocalAIRecovery.workspace(root: root, sourceID: sourceRecord.id)
        let gate = ProcessingControl()
        let native = Task.detached {
            try ProcessingControl.withControl(gate) {
                try DesktopLocalAIRecovery.bindInputs(work: work, source: source.deletingLastPathComponent(), model: model)
                return try LocalAITextureEnhancer.run(package: source.deletingLastPathComponent(), output: work.appendingPathComponent("modelo"),
                    modelURL: model, strength: job.strength, control: gate, checkpointDirectory: work.appendingPathComponent("checkpoint")) { label, fraction in
                    if label.contains("avance guardado"), fraction >= 0.5 { gate.cancel() }
                }
            }
        }
        do { _ = try await native.value; throw Failure(errorDescription: "Fixture must interrupt after its first committed atlas") }
        catch is CancellationError { }
        let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: work.appendingPathComponent("checkpoint/checkpoint.json"))) as! [String: Any]
        try require(checkpoint["nextAssetIndex"] as? Int == 1, "Exactly one whole atlas must be committed")
        job.state = .manualPaused; job.progress = 0.5
        try DesktopLocalAIRecovery.save(job, root: root)
        let sourceJob = DesktopJob(id: UUID(), sourcePath: input.path, duration: 0, title: "Authored fixture", state: "Completado", progress: 1, resultID: sourceRecord.id)
        try JSONEncoder().encode([sourceJob]).write(to: root.appendingPathComponent("jobs.json"), options: .atomic)
        let pausedStore = DesktopStore(baseURL: root)
        try await Task.sleep(for: .milliseconds(150))
        guard let paused = pausedStore.localAIController(for: sourceJob) else { throw Failure(errorDescription: "Recovered source must have a controller") }
        try require(!paused.busy && !paused.shouldResumeAutomatically && paused.pauseState == .paused, "App startup must preserve a human pause")
        try require(paused.strength == 0.35 && pausedStore.jobs.count == 1, "Strength and original queue must survive restart")
        print("PASS persisted manual pause; unchanged intensity; no automatic inference")

        job.state = .running
        try DesktopLocalAIRecovery.save(job, root: root)
        let store = DesktopStore(baseURL: root)
        try await waitUntil({ store.jobs.contains(where: { $0.resultID != nil && $0.resultID != sourceRecord.id }) })
        try await waitUntil({ !store.localAIBusy })
        guard let derivedJob = store.jobs.first(where: { $0.resultID != nil && $0.resultID != sourceRecord.id }),
              let derived = store.record(derivedJob),
              let reportName = derived.exports.first(where: { $0.hasSuffix("-informe-ia.json") }) else {
            throw Failure(errorDescription: "Auto-resumed controller must publish its actual result: " + (store.error ?? "unknown"))
        }
        let report = try JSONDecoder().decode(LocalAITextureEnhancer.Report.self,
            from: Data(contentsOf: store.library.directory(for: derived).appendingPathComponent(reportName)))
        try require(report.processedTextureCount == 2 && report.inferenceTileCount == 2, "Atlas 1 must not be inferred again; total remains exactly two predictions")
        try require(try IntegrityManifest.digest(source) == sourceHash, "Original geometry must remain byte exact")
        try require(try IntegrityManifest.digest(source.deletingLastPathComponent().appendingPathComponent("a.png")) == originalAtlasHash, "Original texture must remain byte exact")
        try require(derived.sourceScanID == sourceRecord.id && store.jobs.count == 2, "Derived publication must retain its source identity")
        try require(!fm.fileExists(atPath: work.path), "Only a successfully published job may remove its owned workspace")
        print("PASS automatic desktop restart resumes real Core ML at atlas 2; actual library save; originals exact")

        // Simulate termination after library publication but before jobs.json.
        job.state = .saving
        try DesktopLocalAIRecovery.save(job, root: root)
        try JSONEncoder().encode([sourceJob]).write(to: root.appendingPathComponent("jobs.json"), options: .atomic)
        let reconciled = DesktopStore(baseURL: root)
        try await waitUntil({ reconciled.jobs.count == 2 })
        try require(reconciled.jobs.filter({ $0.resultID == derived.id }).count == 1, "Publication crash recovery must link the existing result exactly once")
        try require(reconciled.library.scans.count == 2 && !reconciled.localAIBusy, "Publication recovery must not repeat inference or duplicate the library")
        print("PASS publication/jobs ledger crash window is idempotent")

        let changedRoot = root.appendingPathComponent("invalid-fixtures")
        let sourceCopy = changedRoot.appendingPathComponent("source"), modelCopy = changedRoot.appendingPathComponent("model")
        try fm.createDirectory(at: sourceCopy, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelCopy, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: sourceCopy.appendingPathComponent("source.bin"))
        try Data([4,5,6]).write(to: modelCopy.appendingPathComponent("weights.bin"))
        let invalidJob = DesktopLocalAIRecovery.Job(id: UUID(), sourceID: UUID(), strength: 0.35)
        try DesktopLocalAIRecovery.save(invalidJob, root: changedRoot)
        let invalidWork = DesktopLocalAIRecovery.workspace(root: changedRoot, sourceID: invalidJob.sourceID)
        try DesktopLocalAIRecovery.bindInputs(work: invalidWork, source: sourceCopy, model: modelCopy)
        try Data([7,8,9]).write(to: modelCopy.appendingPathComponent("weights.bin"))
        do {
            try DesktopLocalAIRecovery.bindInputs(work: invalidWork, source: sourceCopy, model: modelCopy)
            throw Failure(errorDescription: "Changed weights must be rejected")
        } catch is Failure { throw Failure(errorDescription: "Changed weights were silently accepted") }
        catch { }
        try require(fm.fileExists(atPath: invalidWork.appendingPathComponent("inputs.json").path), "Rejected configuration must preserve recovery data")
        print("PASS changed weights rejected; checkpoint/metadata preserved")
        try Data([4,5,6]).write(to: modelCopy.appendingPathComponent("weights.bin"))
        try Data([9,9,9]).write(to: sourceCopy.appendingPathComponent("source.bin"))
        do {
            try DesktopLocalAIRecovery.bindInputs(work: invalidWork, source: sourceCopy, model: modelCopy)
            throw Failure(errorDescription: "Changed source must be rejected")
        } catch is Failure { throw Failure(errorDescription: "Changed source was silently accepted") }
        catch { }
        print("PASS changed source rejected without replacing its stored fingerprint")

        let completed = invalidWork.appendingPathComponent("modelo")
        let originalDerived = store.library.modelURL(for: derived)!.deletingLastPathComponent()
        try fm.copyItem(at: originalDerived, to: completed)
        try DesktopLocalAIRecovery.commitResult(work: invalidWork, package: completed)
        try require(try DesktopLocalAIRecovery.restoredReport(work: invalidWork, package: completed, sourceModel: source) != nil,
                    "A completed authenticated result must restore without inference")
        var altered = try Data(contentsOf: completed.appendingPathComponent("a.png"))
        altered[altered.count-1] ^= 1
        try altered.write(to: completed.appendingPathComponent("a.png"))
        do {
            _ = try DesktopLocalAIRecovery.restoredReport(work: invalidWork, package: completed, sourceModel: source)
            throw Failure(errorDescription: "Corrupt result must be rejected")
        } catch is Failure { throw Failure(errorDescription: "Corrupt output was silently accepted") }
        catch { }
        try require(fm.fileExists(atPath: completed.path), "Rejected output must remain available for investigation")
        print("PASS completed-result fast path verifies every byte and rejects tampering without deleting work")

        let metadata = invalidWork.appendingPathComponent(DesktopLocalAIRecovery.metadataName)
        let originalMetadata = invalidWork.appendingPathComponent("metadata-preserved.json")
        try fm.moveItem(at: metadata, to: originalMetadata)
        try fm.createSymbolicLink(at: metadata, withDestinationURL: originalMetadata)
        do {
            _ = try DesktopLocalAIRecovery.load(root: changedRoot, sourceID: invalidJob.sourceID)
            throw Failure(errorDescription: "Symlink metadata must be rejected")
        } catch is Failure { throw Failure(errorDescription: "Symlink metadata was silently accepted") }
        catch { }
        try require(fm.fileExists(atPath: originalMetadata.path), "Symlink target must remain unchanged")
        print("PASS symlink recovery metadata rejected without following or deleting its target")
        print("PASS desktop recovery fixture complete; userImagesIncluded=false userAppOpened=false")
    }
}
