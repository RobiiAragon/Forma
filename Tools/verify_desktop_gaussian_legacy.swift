import Foundation
import CryptoKit
import Darwin

// Only the production controller and persistence are compiled; no Metal engine.
struct DesktopJob: Identifiable, Codable {
    var id: UUID; var sourcePath: String; var duration: TimeInterval; var title: String
    var state = "En cola"; var progress = 0.0; var status = "Fuentes originales conservadas"
    var resultID: UUID?
}

#if !FORMA_RUNTIME_VAULT_HARNESS
@main
#endif
struct DesktopGaussianLegacyVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static let fm = FileManager.default
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(errorDescription: message) }
    }
    static func rejected(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(errorDescription: "Expected rejection: " + name)
    }
    static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    static func write(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func bundle(_ root: URL, name: String, worker: URL) throws -> (helper: URL, shaders: URL) {
        let app = root.appendingPathComponent(name + ".app"), contents = app.appendingPathComponent("Contents")
        let helper = contents.appendingPathComponent("Helpers/FormaGaussianWorker")
        let shaders = contents.appendingPathComponent("Resources/msplat-macos.metallib")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: shaders.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: worker, to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try Data("SYNTHETIC-NO-METAL-".utf8).write(to: shaders)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.robii.forma.desktop"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try write(["schemaVersion": 1, "platform": "macOS", "runtimeABI": 2,
            "syntheticFixture": true, "gpuUsed": false,
            "sha256": ["FormaGaussianWorker": try digest(helper), "msplat-macos.metallib": try digest(shaders)]],
            shaders.deletingLastPathComponent().appendingPathComponent("worker-artifacts.json"))
        return (helper, shaders)
    }
    @MainActor static func wait(_ reason: String, timeout: Double = 10, _ predicate: () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        try require(predicate(), "Timeout: " + reason)
    }
    static func killFixture(_ pid: Int32, helper: URL) {
        guard pid > 0 else { return }
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress!, UInt32($0.count)) }
        guard count > 0, URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL == helper.standardizedFileURL else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<100 { if kill(pid, 0) != 0 { return }; usleep(10_000) }
        _ = kill(pid, SIGKILL)
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure(errorDescription: "Usage: verify-desktop-gaussian-legacy SYNTHETIC_WORKER FRESH_OWNED_OUTPUT") }
        let worker = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try require(!fm.fileExists(atPath: root.path), "Output must be fresh and fixture-owned")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try bundle(root, name: "LegacyFixture", worker: worker), new = try bundle(root, name: "NewUIFixture", worker: worker)
        var verifier = DesktopGaussianLegacyRuntime()
        try require(try verifier.verifiedHelper(metallibPath: old.shaders.path, forceHashVerification: true) == old.helper, "Valid ABI2 bundle must verify")
        let manifestURL = old.shaders.deletingLastPathComponent().appendingPathComponent("worker-artifacts.json")
        let manifestBytes = try Data(contentsOf: manifestURL), originalMetal = try Data(contentsOf: old.shaders)
        var altered = try json(manifestURL); altered["runtimeABI"] = 999
        try write(altered, manifestURL)
        try rejected("wrong ABI") { _ = try verifier.verifiedHelper(metallibPath: old.shaders.path) }
        try manifestBytes.write(to: manifestURL, options: .atomic)
        altered = try json(manifestURL); altered["sha256"] = ["FormaGaussianWorker": String(repeating: "0", count: 64), "msplat-macos.metallib": try digest(old.shaders)]
        try write(altered, manifestURL)
        try rejected("wrong helper hash") { _ = try verifier.verifiedHelper(metallibPath: old.shaders.path, forceHashVerification: true) }
        try manifestBytes.write(to: manifestURL, options: .atomic)
        _ = try verifier.verifiedHelper(metallibPath: old.shaders.path)
        try Data(repeating: 70, count: originalMetal.count).write(to: old.shaders)
        try rejected("cached same-size file mutation") { _ = try verifier.verifiedHelper(metallibPath: old.shaders.path) }
        try originalMetal.write(to: old.shaders, options: .atomic)
        let realShader = old.shaders.deletingLastPathComponent().appendingPathComponent("synthetic-actual-library")
        try fm.moveItem(at: old.shaders, to: realShader)
        try fm.createSymbolicLink(at: old.shaders, withDestinationURL: realShader)
        try rejected("symlink library") { _ = try verifier.verifiedHelper(metallibPath: old.shaders.path, forceHashVerification: true) }
        try fm.removeItem(at: old.shaders); try fm.moveItem(at: realShader, to: old.shaders)
        try require(try verifier.verifiedHelper(metallibPath: old.shaders.path, forceHashVerification: true) == old.helper, "Restored owned bundle verifies")
        print("PASS: own synthetic ABI2 bundle, wrong ABI/hash, same-size cache mutation and symlink rejection")

        let source = root.appendingPathComponent("authored-source"), dataset = source.appendingPathComponent("dataset")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: []).write(to: dataset)
        let obj = source.appendingPathComponent("modelo.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: obj)
        let sourceHashes = [try digest(obj), try digest(dataset.appendingPathComponent("dataset.json"))]
        let library = ScanStore(baseURL: root.appendingPathComponent("Library"))
        guard let original = await library.save(CaptureResult(mesh: nil, modelURL: obj, mode: .lidar, duration: 1)) else { throw Failure(errorDescription: "Fixture source save failed") }
        let job = DesktopJob(id: UUID(), sourcePath: source.path, duration: 1, title: "Synthetic legacy lifecycle", resultID: original.id)
        let base = root.appendingPathComponent("Work/Gaussian-" + job.id.uuidString), configURL = base.appendingPathComponent("config.json")
        func controller(_ helper: URL, _ shaders: URL) -> DesktopGaussian {
            DesktopGaussian(job: job, library: library, root: root, canStart: { true }, setBusy: { _ in }, onSave: { _ in }, helperURL: helper, shadersURL: shaders)
        }
        // Launch an actual pre-vault configuration directly. Using today's
        // controller.start() here would test a vault run instead of legacy adoption.
        let legacyWork = base.appendingPathComponent("runs/" + UUID().uuidString)
        try fm.createDirectory(at: legacyWork, withIntermediateDirectories: true)
        let legacyConfig = DesktopGaussian.Configuration(jobID: job.id.uuidString, datasetPath: dataset.path,
            workspacePath: legacyWork.path, metallibPath: old.shaders.path, targetIterations: 100000, downscale: 1,
            datasetIndexSHA256: try digest(dataset.appendingPathComponent("dataset.json")), executionID: UUID(),
            executionStartedAt: Date().timeIntervalSince1970)
        let legacyBytes = try JSONEncoder().encode(legacyConfig)
        try legacyBytes.write(to: configURL, options: .atomic)
        try legacyBytes.write(to: legacyWork.appendingPathComponent("config.json"), options: .atomic)
        let legacyProcess = Process(); legacyProcess.executableURL = old.helper
        legacyProcess.arguments = ["--config", configURL.path]
        legacyProcess.standardOutput = FileHandle.nullDevice; legacyProcess.standardError = FileHandle.nullDevice
        try legacyProcess.run()
        defer { killFixture(legacyProcess.processIdentifier, helper: old.helper) }
        try await wait("pre-vault synthetic helper emits status") { fm.fileExists(atPath: legacyWork.appendingPathComponent("status.json").path) }
        var previous: DesktopGaussian? = controller(old.helper, old.shaders)
        previous!.resumeExisting()
        try await wait("synthetic old helper starts") { previous!.hasLiveWorker && previous!.iteration >= 3 }
        let config = try json(configURL), workspace = URL(fileURLWithPath: config["workspacePath"] as! String)
        let statusURL = workspace.appendingPathComponent("status.json"), controlsURL = workspace.appendingPathComponent("control.ndjson")
        let pid = (try json(statusURL)["pid"] as! NSNumber).int32Value
        defer { killFixture(pid, helper: old.helper) }
        let configBytes = try Data(contentsOf: configURL)
        let workspaceConfigURL = workspace.appendingPathComponent("config.json")
        let workspaceConfigBytes = try Data(contentsOf: workspaceConfigURL)
        weak var released = previous; previous = nil
        try await wait("old UI controller deallocates", timeout: 3) { released == nil }
        let before = try json(statusURL)["iteration"] as! Int
        try await wait("owned helper runs without UI") { ((try? json(statusURL)["iteration"] as? Int) ?? -1) >= before + 5 }
        let adopted = controller(new.helper, new.shaders)
        adopted.resumeExisting()
        try await wait("new UI adopts old helper PID") { adopted.hasLiveWorker && adopted.busy && adopted.iteration >= before + 5 }
        try require((try json(statusURL)["pid"] as! NSNumber).int32Value == pid, "Adoption must preserve exact PID")
        try require(try Data(contentsOf: configURL) == configBytes && Data(contentsOf: workspaceConfigURL) == workspaceConfigBytes && (try json(configURL)["metallibPath"] as! String) == old.shaders.path, "Adoption must not rewrite runtime/config")
        print("PASS: old controller released, helper continues, new UI helper path differs but adopts same PID/config")

        // Corrupt only the fixture's manifest while its fixture process holds its
        // lock. Every entry point must refuse a replacement or control write.
        altered = try json(manifestURL)
        altered["sha256"] = ["FormaGaussianWorker": String(repeating: "0", count: 64), "msplat-macos.metallib": try digest(old.shaders)]
        try write(altered, manifestURL)
        let unknown = controller(new.helper, new.shaders)
        let controlsBefore = (try? Data(contentsOf: controlsURL)) ?? Data()
        try require(!unknown.hasLiveWorker, "Unverifiable legacy worker must not be adopted")
        unknown.resumeExisting(); unknown.start(); unknown.command("pause")
        try require(try Data(contentsOf: configURL) == configBytes, "Locked invalid runtime must preserve config")
        try require(try Data(contentsOf: workspaceConfigURL) == workspaceConfigBytes, "Locked invalid runtime must preserve workspace config")
        try require(((try? Data(contentsOf: controlsURL)) ?? Data()) == controlsBefore, "Locked invalid runtime must not receive commands")
        try require(kill(pid, 0) == 0 && !unknown.notice.isEmpty, "Invalid runtime must preserve active fixture and show reason")
        try manifestBytes.write(to: manifestURL, options: .atomic)
        adopted.command("pause")
        try await wait("manual pause reaches old helper") { adopted.phase == "paused" }
        let paused = try json(statusURL)["iteration"] as! Int
        try await Task.sleep(for: .milliseconds(650))
        try require((try json(statusURL)["iteration"] as! Int) == paused, "Manual pause must hold fixture iteration")
        adopted.command("resume")
        try await wait("manual resume old helper") { adopted.phase == "running" && adopted.iteration > paused + 3 }
        adopted.command("export")
        try await wait("synthetic export saved by real ScanStore", timeout: 20) { adopted.saved != nil && !adopted.busy && !adopted.saving }
        try require(adopted.saved?.sourceScanID == original.id && library.scans.count == 2, "Synthetic publication must link source exactly once")
        print("PASS: invalid occupied workspace preserved; pause/resume/export reach adopted helper and real library saves one derivative")
        try await wait("completed old fixture exits") { !adopted.hasLiveWorker }
        var newVault = DesktopGaussianRuntimeVault(root: root.appendingPathComponent("Runtimes/Gaussian"))
        let newRuntime = try newVault.prepare(helperURL: new.helper, shadersURL: new.shaders)
        adopted.iterations = "100001"; adopted.start()
        try await wait("subsequent execution uses new default helper") { adopted.hasLiveWorker && adopted.phase == "running" && adopted.iteration >= 2 }
        let newPID = (try json(statusURL)["pid"] as! NSNumber).int32Value
        defer { killFixture(newPID, helper: newRuntime.helperURL) }
        var newProcessPath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathCount = newProcessPath.withUnsafeMutableBytes { proc_pidpath(newPID, $0.baseAddress!, UInt32($0.count)) }
        try require(pathCount > 0 && newPID != pid && String(cString: newProcessPath) == newRuntime.helperURL.path, "Next run must launch a verified snapshot of the new helper, not the adopted legacy helper")
        try require((try json(configURL)["metallibPath"] as? String) == newRuntime.shadersURL.path, "Next run must pin the new shader snapshot path")
        adopted.command("cancel")
        try await wait("cancel only subsequent synthetic fixture") { adopted.phase == "cancelled" && !adopted.busy }
        print("PASS: subsequent run launches a new PID at the new default helper/shader path; fixture cancelled")

        // A true fixture process without a workspace lock is insufficient for
        // adoption, even with the exact verified legacy path and matching PID.
        let unlockedJob = DesktopJob(id: UUID(), sourcePath: source.path, duration: 1, title: "Unlocked synthetic fixture", resultID: original.id)
        let unlockedBase = root.appendingPathComponent("Work/Gaussian-" + unlockedJob.id.uuidString)
        let unlockedWorkspace = unlockedBase.appendingPathComponent("runs/owned-unlocked")
        try fm.createDirectory(at: unlockedWorkspace, withIntermediateDirectories: true)
        var unlockedConfig = config; unlockedConfig["jobID"] = unlockedJob.id.uuidString; unlockedConfig["workspacePath"] = unlockedWorkspace.path
        unlockedConfig["executionStartedAt"] = Date().timeIntervalSince1970
        let unlockedConfigURL = unlockedBase.appendingPathComponent("config.json")
        try write(unlockedConfig, unlockedConfigURL)
        let unlockedProcess = Process(); unlockedProcess.executableURL = old.helper
        unlockedProcess.arguments = ["--config", unlockedConfigURL.path, "--no-lock"]
        unlockedProcess.standardOutput = FileHandle.nullDevice; unlockedProcess.standardError = FileHandle.nullDevice
        try unlockedProcess.run()
        defer { killFixture(unlockedProcess.processIdentifier, helper: old.helper) }
        try await wait("unlocked fixture emits status") { fm.fileExists(atPath: unlockedWorkspace.appendingPathComponent("status.json").path) }
        let unlockedController = DesktopGaussian(job: unlockedJob, library: library, root: root, canStart: { true }, setBusy: { _ in }, onSave: { _ in }, helperURL: new.helper, shadersURL: new.shaders)
        try require(!unlockedController.hasLiveWorker, "Matching helper PID without held workspace lock must be rejected")
        var staleStatus = try json(unlockedWorkspace.appendingPathComponent("status.json"))
        killFixture(unlockedProcess.processIdentifier, helper: old.helper)
        staleStatus["pid"] = Int32.max; staleStatus["updatedAt"] = Date().timeIntervalSince1970
        try write(staleStatus, unlockedWorkspace.appendingPathComponent("status.json"))
        let staleLock = open(unlockedWorkspace.appendingPathComponent("worker.lock").path, O_RDONLY | O_NOFOLLOW)
        try require(staleLock >= 0 && flock(staleLock, LOCK_EX | LOCK_NB) == 0, "Fixture must hold stale workspace lock")
        defer { flock(staleLock, LOCK_UN); close(staleLock) }
        let staleController = DesktopGaussian(job: unlockedJob, library: library, root: root, canStart: { true }, setBusy: { _ in }, onSave: { _ in }, helperURL: new.helper, shadersURL: new.shaders)
        try require(!staleController.hasLiveWorker, "Stale/nonexistent PID must be rejected even with a held lock")
        print("PASS: matching synthetic PID without flock and nonexistent stale PID are not adopted")

        // Only this static verifier reads the installed app. It does not load a
        // job/controller, inspect its worker PID, or start/control any process.
        let installedMetal = URL(fileURLWithPath: "/Applications/FormaDesktop.app/Contents/Resources/msplat-macos.metallib")
        let installedManifestURL = installedMetal.deletingLastPathComponent().appendingPathComponent("worker-artifacts.json")
        var installedVerifier = DesktopGaussianLegacyRuntime()
        let installedHelper = try installedVerifier.verifiedHelper(metallibPath: installedMetal.path, forceHashVerification: true)
        let installedManifest = try json(installedManifestURL)
        let installed: [String: Any] = ["runtimeABI": installedManifest["runtimeABI"]!, "helperSHA256": try digest(installedHelper),
            "metallibSHA256": try digest(installedMetal), "manifestSHA256": try digest(installedManifestURL), "readOnly": true,
            "controllerCreated": false, "workerAccessed": false]
        try require(sourceHashes == [try digest(obj), try digest(dataset.appendingPathComponent("dataset.json"))], "Authored source hashes must remain unchanged")
        let report: [String: Any] = ["passed": true, "realProductionController": true, "realScanStore": true,
            "syntheticPOSIXHelper": true, "syntheticABI": 2, "gpuUsed": false, "realWorkerControlled": false,
            "samePIDAdopted": true, "legacyConfigPreserved": true, "invalidRuntimePreserved": true,
            "futureLaunchUsesNewDefaultRuntime": true,
            "negativeCases": ["wrong ABI", "wrong hash", "cached same-size mutation", "symlink", "unlocked PID", "stale PID"],
            "pauseResumeExport": true, "sourceSHA256Unchanged": true, "installedBundleReadOnly": installed]
        try write(report, root.appendingPathComponent("harness-report.json"))
        print("PASS: installed legacy bundle SHA/ABI verified read-only; no phone, GPU, real controller/job/worker access")
    }
}
