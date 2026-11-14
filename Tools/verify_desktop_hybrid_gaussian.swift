import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Authored-fixture integration of the actual queue, independent helper and library.
#if !FORMA_HYBRID_REMOTE_HARNESS
@main
#endif
struct DesktopHybridGaussianVerification {
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
        // Incoming hybrid captures need no precomputed COLMAP text files.
        for name in ["cameras.txt", "images.txt", "points3D.txt"] { try FileManager.default.removeItem(at: dataset.appendingPathComponent(name)) }
        var vertices: [SIMD3<Float>] = []
        for index in 0..<256 {
            let x = Float(index % 16 - 8) * Float(0.0125)
            let y = Float(index / 16 - 8) * Float(0.0125)
            vertices.append(SIMD3<Float>(x, y, 0))
        }
        try JSONEncoder().encode(MeshSnapshot(vertices: vertices, triangles: [0,1,16])).write(to: source.appendingPathComponent("malla-original.json"))
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


    @MainActor static func verifyInterruptedCPUPause(root: URL, helper: URL, shaders: URL) async throws {
        let fm=FileManager.default,id=UUID()
        let source=root.appendingPathComponent("Incoming/"+id.uuidString)
        try dataset(source)
        let request=HybridTransfer.ProcessingRequest(kind:.gaussian,iterations:100000,downscale:1)
        let job=DesktopJob(id:id,sourcePath:source.path,duration:1,title:"Authored CPU pause crash window",
                           state:"Pausando",processingRequest:request)
        try JSONEncoder().encode([job]).write(to:root.appendingPathComponent("jobs.json"))
        let store=DesktopStore(baseURL:root,gaussianHelperURL:helper,gaussianShadersURL:shaders)
        let base=root.appendingPathComponent("Work/Gaussian-"+id.uuidString)
        defer { store.cancel(); cleanupWorker(base,helper:helper) }
        try await Task.sleep(for:.milliseconds(750))
        let remote=store.remoteStatus(for:id)
        print("FORMA_CPU_PAUSE_RECOVERY observedState=\(remote.state) queueState=\(store.jobs.first?.state ?? "missing") workerConfigurationExists=\(fm.fileExists(atPath:base.appendingPathComponent("config.json").path))")
        fflush(stdout)
        try require(remote.state=="paused" && store.jobs.first?.state=="Pausado" && !store.gaussianBusy,
                    "An acknowledged or requested human CPU pause must not be changed into an automatic queue restart")
        try require(!fm.fileExists(atPath:base.appendingPathComponent("config.json").path),
                    "Restoring a manual CPU pause may not create a GPU worker")
        let report:[String:Any]=["status":"passed","realProductionDesktopStore":true,"persistedIntent":"Pausando",
            "recoveredIntent":"Pausado","remoteState":remote.state,"workerStarted":false,"phoneUsed":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("cpu-pause-verification.json"),options:.atomic)
    }

    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw Failure(errorDescription:"Usage: verify-desktop-hybrid-gaussian WORKER METALLIB NEW_OWNED_OUTPUT") }
        let helper = URL(fileURLWithPath:args[0]).standardizedFileURL
        let shaders = URL(fileURLWithPath:args[1]).standardizedFileURL
        let root = URL(fileURLWithPath:args[2]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath:root.path),"Use a fresh owned output directory")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        if ProcessInfo.processInfo.environment["FORMA_VERIFY_CPU_PAUSE_RECOVERY_ONLY"] == "1" {
            try await verifyInterruptedCPUPause(root:root,helper:helper,shaders:shaders)
            return
        }
        let firstID=UUID(),secondID=UUID(),invalidID=UUID()
        let first=root.appendingPathComponent("Incoming/"+firstID.uuidString),second=root.appendingPathComponent("Incoming/"+secondID.uuidString)
        try dataset(first);try dataset(second)
        let firstRequest=HybridTransfer.ProcessingRequest(kind:.gaussian,iterations:100000,downscale:1)
        let secondRequest=HybridTransfer.ProcessingRequest(kind:.gaussian,iterations:12,downscale:1)
        try JSONEncoder().encode(firstRequest).write(to:first.appendingPathComponent("procesamiento.json"))
        try JSONEncoder().encode(secondRequest).write(to:second.appendingPathComponent("procesamiento.json"))
        let firstHashes=try hashes(first),secondHashes=try hashes(second)
        let oldJobData=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"sourcePath":"authored-legacy", "duration":1,"title":"Legacy","state":"En cola","progress":0,"status":"Conservado"])
        try require(try JSONDecoder().decode(DesktopJob.self,from:oldJobData).processingRequest == nil,"Legacy queue must decode without a request")
        let bases=[firstID,secondID].map{root.appendingPathComponent("Work/Gaussian-"+$0.uuidString)}
        defer { bases.forEach{cleanupWorker($0,helper:helper)} }
        func makeStore()->DesktopStore { DesktopStore(baseURL:root,gaussianHelperURL:helper,gaussianShadersURL:shaders) }
        var store:DesktopStore?=makeStore()
        let received=HybridTransfer.ReceivedJob(id:firstID,directory:first,duration:1)
        store!.enqueue(received,title:"Authored remote Gaussian A")
        store!.enqueue(received,title:"Duplicate handoff must not enqueue")
        store!.enqueue(.init(id:secondID,directory:second,duration:1),title:"Authored remote Gaussian B")
        try await waitUntil("production Store routes first request into native training",timeout:45) {
            store!.remoteStatus(for:firstID).iteration.map{$0>=3} == true && store!.gaussianBusy
        }
        try require(store!.jobs.count==2,"A duplicate handoff must retain exactly two queue rows")
        try require(!fm.fileExists(atPath:bases[1].appendingPathComponent("config.json").path),"Second worker cannot start while the first owns the queue")
        let firstConfig=try dictionary(bases[0].appendingPathComponent("config.json"))
        let workspace=URL(fileURLWithPath:firstConfig["workspacePath"] as! String)
        let statusFile=workspace.appendingPathComponent("status.json")
        try require(firstConfig["targetIterations"] as? Int==100000 && (firstConfig["downscale"] as? NSNumber)?.floatValue==1,"Receiver must use the requested native configuration")
        try require((firstConfig["datasetPath"] as! String).hasPrefix(root.appendingPathComponent("Work/HybridGaussian-").path),"COLMAP preparation must use an owned copy")
        let before=iteration(statusFile)
        weak var released=store
        weak var releasedController=store!.gaussianController(for:store!.jobs.first{$0.id==firstID}!)
        store=nil
        try await waitUntil("Store and controller release without stopping helper",timeout:4){released==nil && releasedController==nil}
        released=nil; releasedController=nil
        try await waitUntil("native helper advances with no app Store"){iteration(statusFile)>=before+10}
        store=makeStore()
        try await waitUntil("new production Store reconnects existing worker"){
            store!.remoteStatus(for:firstID).state=="running" && store!.gaussianBusy
        }
        store!.pause()
        try await waitUntil("manual pause persists in original queue row"){
            store!.remoteStatus(for:firstID).state=="paused" && store!.jobs.first{$0.id==firstID}?.state=="Pausado"
        }
        let paused=iteration(statusFile)
        try await Task.sleep(for:.milliseconds(650))
        try require(iteration(statusFile)==paused,"Manual pause must hold the native checkpoint")
        store=nil
        store=makeStore()
        try await waitUntil("restart preserves paused intent") {store!.remoteStatus(for:firstID).state=="paused"}
        try await Task.sleep(for:.milliseconds(650))
        try require(iteration(statusFile)==paused,"Reconnecting may not undo manual pause")
        store!.resume(firstID)
        try await waitUntil("explicit resume advances actual worker"){iteration(statusFile)>=paused+5}
        store!.gaussianController(for:store!.jobs.first{$0.id==firstID}!).command("export")
        try await waitUntil("both queued jobs publish through actual ScanStore",timeout:60) {
            store!.remoteStatus(for:firstID).resultAvailable && store!.remoteStatus(for:secondID).resultAvailable && !store!.gaussianBusy
        }
        try require(store!.jobs.count==2,"Queued Gaussian results must update original rows, not append derived duplicates")
        try require(store!.library.scans.count==2 && store!.library.scans.allSatisfy{$0.gaussianModelFile != nil},"Both requests must produce Gaussian results rather than LiDAR processing")
        for job in store!.jobs {
            let state=store!.remoteStatus(for:job.id);try state.validate(jobID:job.id)
            try require(state.state=="completed" && state.progress==1 && state.iteration.map{$0>0}==true && state.splats.map{$0>0}==true,"Status must identify a real published model")
            try require(try await store!.library.verify(store!.record(job)!),"Actual ScanStore integrity must validate")
            let encoded=String(data:try JSONEncoder().encode(state),encoding:.utf8)!
            try require(!encoded.contains(root.path) && !encoded.contains("/Users/"),"Remote status may not expose private paths")
        }
        try require(try hashes(first)==firstHashes && hashes(second)==secondHashes,"All incoming source bytes must remain unchanged")
        let savedIDs=Set(store!.library.scans.map(\.id))
        // Exercise the marker-based crash window using only fixture-owned ledgers.
        store=nil
        for base in bases {
            let config=try dictionary(base.appendingPathComponent("config.json"))
            try fm.removeItem(at:URL(fileURLWithPath:config["workspacePath"] as! String).appendingPathComponent("publication.json"))
        }
        store=makeStore()
        try await waitUntil("completed jobs reconcile without duplicate publications") {
            store!.jobs.count==2 && store!.jobs.allSatisfy{$0.resultID != nil} && !store!.gaussianBusy
        }
        try await Task.sleep(for:.milliseconds(1000))
        try require(Set(store!.library.scans.map(\.id))==savedIDs,"Missing publication ledgers must not duplicate completed Gaussian records")
        let invalid=root.appendingPathComponent("Incoming/"+invalidID.uuidString)
        try dataset(invalid)
        try JSONEncoder().encode(HybridTransfer.ProcessingRequest(kind:.gaussian,iterations:0)).write(to:invalid.appendingPathComponent("procesamiento.json"))
        store!.enqueue(.init(id:invalidID,directory:invalid,duration:1),title:"Invalid authored request")
        try require(store!.jobs.count==2 && store!.error != nil,"Invalid native configuration must not fall through to LiDAR")
        let unknown=store!.remoteStatus(for:UUID());try unknown.validate(jobID:unknown.id)
        try await verifyInterruptedCPUPause(root:root.appendingPathComponent("CPU-PauseRecovery"),helper:helper,shaders:shaders)
        let report:[String:Any]=["pendingCPUManualPauseSurvivedRestart":true,"status":"passed","realProductionDesktopStore":true,"realProductionController":true,"realNativeMetalWorker":true,"realScanStore":true,"userAppOpened":false,"userPhotosIncluded":false,"phoneUsed":false,"networkUsed":false,"requests":2,"queueRows":store!.jobs.count,"gaussianRecords":store!.library.scans.count,"requestParametersApplied":true,"originalRowsCompleted":true,"secondWorkerWaitedForFirst":true,"helperContinuedWithoutStore":true,"manualPauseSurvivedStoreRecreation":true,"resumeAdvanced":true,"missingPublicationLedgerDeduplicated":true,"originalSourceBytesUnchanged":true,"privatePathsExcludedFromRemoteStatus":true,"legacyQueueDecoded":true,"invalidRequestRejectedWithoutLiDARRoute":true,"pausedIteration":paused]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("verification.json"),options:.atomic)
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
