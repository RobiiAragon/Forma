import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

// Schema-identical queue value. The actual controller and persistence code are
// compiled below; unrelated photogrammetry/AI/network services are not needed.
struct DesktopJob: Identifiable, Codable {
    var id: UUID
    var sourcePath: String
    var duration: TimeInterval
    var title: String
    var state = "En cola"
    var progress = 0.0
    var status = "Fuentes originales conservadas"
    var resultID: UUID?
}

/// Real Metal/controller/library integration; only authored fixtures are used.
@main struct DesktopGaussianVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(errorDescription: message) }
    }
    static func dictionary(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(errorDescription: "Invalid JSON object: " + url.path)
        }
        return value
    }
    static func hashes(_ root: URL) throws -> [String: String] {
        let names = FileManager.default.enumerator(atPath: root.path)!
        var result: [String: String] = [:]
        while let name = names.nextObject() as? String {
            let file = root.appendingPathComponent(name)
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[name] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    static func png(_ url: URL, offset: Int) throws {
        let width = 32, height = 32
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            bytes[index] = UInt8((x * 7 + y * 3 + offset) % 256)
            bytes[index + 1] = UInt8((y * 7 + x * 3 + offset) % 256)
            bytes[index + 2] = 128
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        try require(CGImageDestinationFinalize(output), "Authored PNG must encode")
    }
    static func dataset(_ source: URL) throws {
        let dataset = source.appendingPathComponent("dataset"), images = dataset.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var frames: [RGBDFrameRecord] = []
        var imageRecords = ""
        for index in 1...3 {
            let name = "frame-\(index).png"
            try png(images.appendingPathComponent(name), offset: index * 3)
            let translation = Float(index - 2) * 0.08
            frames.append(RGBDFrameRecord(id: String(index), timestamp: Double(index), rgbFile: "images/" + name,
                imageWidth: 32, imageHeight: 32,
                cameraToWorld: [1,0,0,0, 0,-1,0,0, 0,0,-1,0, -translation,0,-2,1],
                intrinsics: [28,0,0, 0,28,0, 16,16,1], source: "authored-test"))
            imageRecords += "\(index) 1 0 0 0 \(translation) 0 2 1 \(name)\n\n"
        }
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: frames).write(to: dataset)
        try "1 PINHOLE 32 32 28 28 16 16\n".write(to: dataset.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try imageRecords.write(to: dataset.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        var points = ""
        for index in 0..<256 {
            points += "\(index + 1) \(Float(index % 16 - 8) * 0.0125) \(Float(index / 16 - 8) * 0.0125) 0 128 128 128 0\n"
        }
        try points.write(to: dataset.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: source.appendingPathComponent("modelo.obj"), atomically: true, encoding: .utf8)
    }
    @MainActor static func waitUntil(_ reason: String, timeout: Double = 30,
                                     _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(predicate(), "Timed out: " + reason)
    }
    static func iteration(_ status: URL) -> Int {
        (try? dictionary(status)["iteration"] as? Int) ?? -1
    }
    static func cleanupWorker(_ base: URL, helper: URL) {
        guard let config = try? dictionary(base.appendingPathComponent("config.json")),
              let workspace = config["workspacePath"] as? String,
              let status = try? dictionary(URL(fileURLWithPath: workspace).appendingPathComponent("status.json")),
              let number = status["pid"] as? NSNumber else { return }
        let pid = number.int32Value
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress!, UInt32($0.count)) }
        guard count > 0, URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath() == helper.resolvingSymlinksInPath() else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<100 { if kill(pid, 0) != 0 { return }; usleep(20_000) }
        _ = kill(pid, SIGKILL)
    }
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw Failure(errorDescription: "Usage: verify-desktop-gaussian WORKER METALLIB NEW_OWNED_OUTPUT")
        }
        let helper = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let shaders = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "Use a fresh owned output folder")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("authored-source")
        try dataset(source)
        let originalHashes = try hashes(source)
        let libraryRoot = root.appendingPathComponent("Library")
        let library = ScanStore(baseURL: libraryRoot)
        guard let original = await library.save(CaptureResult(mesh: nil, modelURL: source.appendingPathComponent("modelo.obj"),
            mode: .lidar, duration: 1, captureDatasetURL: source.appendingPathComponent("dataset"))) else {
            throw Failure(errorDescription: "Source fixture library save failed: " + (library.error ?? "unknown"))
        }
        let sourceRecordHashes = try hashes(library.directory(for: original))
        let job = DesktopJob(id: UUID(), sourcePath: source.path, duration: 1, title: "Authored Gaussian fixture", resultID: original.id)
        let base = root.appendingPathComponent("Work/Gaussian-" + job.id.uuidString)
        defer { cleanupWorker(base, helper: helper) }
        var savedCallbacks: [UUID] = []
        var busyEvents: [Bool] = []
        func makeController(_ store: ScanStore) -> DesktopGaussian {
            DesktopGaussian(job: job, library: store, root: root, canStart: { true },
                setBusy: { busyEvents.append($0) }, onSave: { savedCallbacks.append($0.id) },
                helperURL: helper, shadersURL: shaders)
        }
        var controller: DesktopGaussian? = makeController(library)
        controller!.iterations = "100000" // Test escape horizon, never a product quota.
        controller!.downscale = "1"
        controller!.start()
        try await waitUntil("real controller begins Metal training; " + controller!.notice) {
            controller!.iteration >= 3 && controller!.phase == "running" && controller!.busy
        }
        let config = try dictionary(base.appendingPathComponent("config.json"))
        let workspace = URL(fileURLWithPath: config["workspacePath"] as! String)
        let statusFile = workspace.appendingPathComponent("status.json")
        let beforeDisconnect = iteration(statusFile)
        weak var releasedController = controller
        controller = nil
        try await waitUntil("disconnected UI controller releases its polling task", timeout: 3) { releasedController == nil }
        try await waitUntil("helper advances with no UI controller") { iteration(statusFile) >= beforeDisconnect + 10 }
        let disconnectedIteration = iteration(statusFile)
        let reconnected = makeController(library)
        reconnected.resumeExisting()
        try await waitUntil("recreated controller attaches to the same live worker") {
            reconnected.busy && reconnected.iteration >= disconnectedIteration && reconnected.phase == "running"
        }
        reconnected.command("pause")
        try await waitUntil("manual pause confirms safe checkpoint") { reconnected.phase == "paused" }
        let paused = iteration(statusFile)
        let pausedStatus = try dictionary(statusFile)
        try require((pausedStatus["checkpointStep"] as? Int) == paused, "Pause must commit the current iteration")
        try await Task.sleep(for: .milliseconds(700))
        try require(iteration(statusFile) == paused, "Confirmed manual pause must hold iteration stable")
        try require(fm.fileExists(atPath: pausedStatus["checkpointPath"] as! String), "Pause checkpoint must exist")
        reconnected.command("resume")
        try await waitUntil("manual resume advances training") { reconnected.phase == "running" && reconnected.iteration >= paused + 5 }
        reconnected.command("export")
        try await waitUntil("export publishes to the actual ScanStore; " + reconnected.notice, timeout: 45) {
            reconnected.saved != nil && !reconnected.saving && !reconnected.busy
        }
        let saved = reconnected.saved!
        try require(saved.sourceScanID == original.id && saved.gaussianModelFile != nil, "Saved Gaussian must link its source record")
        try require(library.scans.filter { $0.gaussianModelFile != nil }.count == 1, "Exactly one Gaussian must be saved")
        try require(try await library.verify(saved), "Published ScanStore integrity must validate")
        let ply = try Data(contentsOf: library.gaussianURL(for: saved)!)
        guard let end = ply.range(of: Data("end_header\n".utf8)),
              let header = String(data: ply[..<end.upperBound], encoding: .utf8) else {
            throw Failure(errorDescription: "Actual exported PLY header is missing")
        }
        try require(header.contains("property float f_rest_44") && header.contains("property float f_dc_2"), "Actual PLY must preserve all 45 SH-rest coefficients (SH3)")
        let publicationURL = workspace.appendingPathComponent("publication.json")
        let publication = try dictionary(publicationURL)
        try require((publication["resultID"] as? String).flatMap(UUID.init(uuidString:)) == saved.id, "Publication resultID must be the actual saved record ID")
        try require(publication["resultPath"] as? String == (try dictionary(statusFile))["resultPath"] as? String, "Publication must bind the actual exported package")
        try require(try hashes(source) == originalHashes, "All authored source bytes must remain unchanged")
        try require(try hashes(library.directory(for: original)) == sourceRecordHashes, "Original library capture bytes must remain unchanged")

        // A controller/library restart links the existing publication once.
        let restoredLibrary = ScanStore(baseURL: libraryRoot)
        let restored = makeController(restoredLibrary)
        restored.resumeExisting()
        try await waitUntil("completed publication reconnects") { restored.saved?.id == saved.id }
        try require(restoredLibrary.scans.filter { $0.gaussianModelFile != nil }.count == 1 && !restored.busy,
                    "Reconnecting a completed job must not save another Gaussian")
        // Simulate the publication-ledger crash window; the library marker is the
        // recovery identity. Only this fixture's owned metadata is removed.
        try fm.removeItem(at: publicationURL)
        let markerLibrary = ScanStore(baseURL: libraryRoot)
        let markerRecovery = makeController(markerLibrary)
        markerRecovery.resumeExisting()
        try await waitUntil("auxiliary marker recovers a missing publication ledger") { markerRecovery.saved?.id == saved.id }
        try require(markerLibrary.scans.filter { $0.gaussianModelFile != nil }.count == 1 && !markerRecovery.busy,
                    "Marker reconciliation must preserve one saved Gaussian")
        let report: [String: Any] = ["status": "passed", "fixture": "Authored 32x32 PNG/COLMAP/calibrated manifest; 256 seeds",
            "userImagesIncluded": false, "userAppOpened": false, "networkUsed": false,
            "realProductionController": true, "realNativeMetal": true, "realScanStore": true,
            "uiControllerReleased": true, "continuedWithoutUI": true, "recreatedControllerAttached": true,
            "manualPauseCheckpointHeld": true, "manualResumeAdvanced": true, "exportedPLYSHDegree": 3,
            "savedGaussianCount": 1, "publicationResultID": saved.id.uuidString,
            "publicationResultIDMatchesActualRecord": true, "markerDedupAfterLedgerLoss": true,
            "sourceSHA256Unchanged": true, "sourceLibrarySHA256Unchanged": true,
            "pausedIteration": paused, "exportedIteration": saved.statistics?["steps"] ?? -1,
            "busyEvents": busyEvents, "onSaveCallbacks": savedCallbacks.map(\.uuidString)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("verification.json"), options: .atomic)
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
