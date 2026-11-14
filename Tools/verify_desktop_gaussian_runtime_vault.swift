import Foundation
import CryptoKit
import Darwin

/// Actual controller, processes, locks and library; the helper is a POSIX-only
/// fixture. No native Metal worker or real app/library/job is opened or controlled.
@main struct DesktopGaussianRuntimeVaultVerification {
    typealias F = DesktopGaussianLegacyVerification
    static let fm = FileManager.default
    static func processPath(_ pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress!, UInt32($0.count)) }
        return count > 0 ? String(cString: path) : nil
    }
    static func entry(_ snapshot: DesktopGaussianRuntimeVault.Snapshot) -> URL {
        snapshot.shadersURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func replaceOwned(_ bytes: Data, _ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try bytes.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }
    static func hashes(_ snapshot: DesktopGaussianRuntimeVault.Snapshot) throws -> [String] {
        let resources = snapshot.shadersURL.deletingLastPathComponent()
        return try [snapshot.helperURL, snapshot.shadersURL, resources.appendingPathComponent("worker-artifacts.json"),
                    resources.deletingLastPathComponent().appendingPathComponent("Info.plist"), entry(snapshot).appendingPathComponent("runtime-receipt.json")].map(F.digest)
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw F.Failure(errorDescription: "Expected synthetic worker and fresh owned output") }
        let worker = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try F.require(!fm.fileExists(atPath: root.path), "Use a fresh fixture output")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let firstBundle = try F.bundle(root, name: "SourceVersionA", worker: worker)
        let secondBundle = try F.bundle(root, name: "SourceVersionB", worker: worker)
        // A distinct but self-consistent source artifact, not an arbitrary quota/version ID.
        try Data("SYNTHETIC-NO-METAL-VERSION-B".utf8).write(to: secondBundle.shaders)
        let manifestB = secondBundle.shaders.deletingLastPathComponent().appendingPathComponent("worker-artifacts.json")
        var changedManifest = try F.json(manifestB)
        changedManifest["sha256"] = ["FormaGaussianWorker": try F.digest(secondBundle.helper), "msplat-macos.metallib": try F.digest(secondBundle.shaders)]
        try F.write(changedManifest, manifestB)
        let sourceBHashes = try [secondBundle.helper, secondBundle.shaders, manifestB].map(F.digest)
        let vaultRoot = root.appendingPathComponent("Runtimes/Gaussian"), library = ScanStore(baseURL: root.appendingPathComponent("Library"))
        var vault = DesktopGaussianRuntimeVault(root: vaultRoot)
        let runtimeA = try vault.prepare(helperURL: firstBundle.helper, shadersURL: firstBundle.shaders)
        let firstHashes = try hashes(runtimeA)
        let repeatedA = try vault.prepare(helperURL: firstBundle.helper, shadersURL: firstBundle.shaders)
        try F.require(runtimeA.helperURL == repeatedA.helperURL && (try hashes(runtimeA)) == firstHashes, "Repeated prepare must reuse immutable content")
        try F.require(runtimeA.helperURL != firstBundle.helper && runtimeA.helperURL.path.hasPrefix(vaultRoot.path + "/"), "A new runtime must be detached from its source app")
        let attributes = try fm.attributesOfItem(atPath: runtimeA.helperURL.path)
        try F.require((attributes[.posixPermissions] as! NSNumber).intValue == 0o500, "Snapshot helper must be private and read-only executable")
        try F.require(!((try fm.contentsOfDirectory(atPath: vaultRoot.path)).contains { $0.hasPrefix(".runtime-stage-") }), "Staging must not remain published as a usable runtime")
        print("PASS: verified app artifacts publish once at a content address with private read-only files and authenticated provenance")

        let source = root.appendingPathComponent("authored-source"), dataset = source.appendingPathComponent("dataset")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: []).write(to: dataset)
        let obj = source.appendingPathComponent("modelo.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: obj)
        let originalSourceHashes = try [obj, dataset.appendingPathComponent("dataset.json")].map(F.digest)
        guard let original = await library.save(CaptureResult(mesh: nil, modelURL: obj, mode: .lidar, duration: 1)) else { throw F.Failure(errorDescription: "Authored original save failed") }
        let job = DesktopJob(id: UUID(), sourcePath: source.path, duration: 1, title: "Owned vault lifecycle", resultID: original.id)
        let base = root.appendingPathComponent("Work/Gaussian-" + job.id.uuidString), configURL = base.appendingPathComponent("config.json")
        func controller(_ bundle: (helper: URL, shaders: URL)) -> DesktopGaussian {
            DesktopGaussian(job: job, library: library, root: root, canStart: { true }, setBusy: { _ in }, onSave: { _ in },
                            helperURL: bundle.helper, shadersURL: bundle.shaders)
        }
        var ownedProcesses: [(Int32, URL)] = []
        defer { for (pid, helper) in ownedProcesses { F.killFixture(pid, helper: helper) } }
        var previous: DesktopGaussian? = controller(firstBundle)
        previous!.iterations = "100000"; previous!.start()
        try await F.wait("owned process starts in snapshot A") { previous!.hasLiveWorker && previous!.iteration > 2 }
        let configurationBytes = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(DesktopGaussian.Configuration.self, from: configurationBytes)
        let workspace = URL(fileURLWithPath: config.workspacePath), statusURL = workspace.appendingPathComponent("status.json")
        let workspaceConfig = try Data(contentsOf: workspace.appendingPathComponent("config.json"))
        let firstPID = (try F.json(statusURL)["pid"] as! NSNumber).int32Value
        ownedProcesses.append((firstPID, runtimeA.helperURL))
        try F.require(config.metallibPath == runtimeA.shadersURL.path && processPath(firstPID) == runtimeA.helperURL.path, "Worker/config must pin the exact snapshot")
        weak var released = previous; previous = nil
        try await F.wait("old UI releases") { released == nil }
        // Simulate replacing/deleting only our source app. The pinned runtime survives.
        try fm.removeItem(at: root.appendingPathComponent("SourceVersionA.app"))
        let before = try F.json(statusURL)["iteration"] as! Int
        try await F.wait("helper advances after source app disappears") { ((try? F.json(statusURL)["iteration"] as? Int) ?? -1) > before + 3 }
        let nextUI = controller(secondBundle)
        nextUI.resumeExisting()
        try await F.wait("new UI reconnects same snapshot PID") { nextUI.busy && nextUI.hasLiveWorker && nextUI.iteration > before }
        try F.require((try F.json(statusURL)["pid"] as! NSNumber).int32Value == firstPID && processPath(firstPID) == runtimeA.helperURL.path,
                      "An app update must not replace or relaunch the active worker")
        try F.require(try Data(contentsOf: configURL) == configurationBytes && Data(contentsOf: workspace.appendingPathComponent("config.json")) == workspaceConfig,
                      "Reconnect must not migrate the active configuration")
        nextUI.command("pause")
        try await F.wait("pause adopted snapshot") { nextUI.phase == "paused" }
        let paused = nextUI.iteration
        try await Task.sleep(for: .milliseconds(600))
        try F.require(nextUI.iteration == paused, "Confirmed human pause must stay paused")
        nextUI.command("resume")
        try await F.wait("resume adopted snapshot") { nextUI.phase == "running" && nextUI.iteration > paused + 3 }
        nextUI.command("export")
        try await F.wait("publish snapshot result", timeout: 20) { nextUI.saved != nil && !nextUI.busy && !nextUI.saving }
        try await F.wait("first helper exits") { !nextUI.hasLiveWorker }
        try F.require(nextUI.saved?.sourceScanID == original.id && library.scans.count == 2, "One independent result must link its original")
        print("PASS: removing the old source app leaves the same PID training; new UI reconnects without config changes and pause/resume/export publish once")

        let runtimeB = try vault.prepare(helperURL: secondBundle.helper, shadersURL: secondBundle.shaders)
        try F.require(runtimeA.helperURL != runtimeB.helperURL && (try hashes(runtimeA)) == firstHashes, "New app artifacts need a distinct snapshot without evicting or modifying A")
        nextUI.iterations = "100001"; nextUI.start()
        try await F.wait("next execution uses snapshot B") { nextUI.phase == "running" && nextUI.hasLiveWorker && nextUI.iteration > paused + 3 }
        let nextPID = (try F.json(statusURL)["pid"] as! NSNumber).int32Value
        ownedProcesses.append((nextPID, runtimeB.helperURL))
        try F.require(nextPID != firstPID && processPath(nextPID) == runtimeB.helperURL.path && (try F.json(configURL)["metallibPath"] as? String) == runtimeB.shadersURL.path,
                      "New launches must use the new bundle snapshot rather than the adopted runtime")
        nextUI.command("cancel")
        try await F.wait("cancel only next fixture") { nextUI.phase == "cancelled" && !nextUI.busy }
        try await F.wait("next fixture releases its lock") { !nextUI.hasLiveWorker }
        print("PASS: later execution launches a new PID pinned to B while snapshot A and authored sources remain unchanged")

        // Corrupt only an owned inactive snapshot. prepare must not repair it in place.
        let originalMetal = try Data(contentsOf: runtimeB.shadersURL)
        let tampered = Data(repeating: 88, count: originalMetal.count)
        try replaceOwned(tampered, runtimeB.shadersURL)
        try F.rejected("corrupted snapshot") { _ = try vault.verifiedSnapshot(metallibPath: runtimeB.shadersURL.path) }
        try F.rejected("prepare must not overwrite a damaged published entry") { _ = try vault.prepare(helperURL: secondBundle.helper, shadersURL: secondBundle.shaders) }
        try F.require(try Data(contentsOf: runtimeB.shadersURL) == tampered, "A published damaged runtime must not be replaced behind a worker")
        try replaceOwned(originalMetal, runtimeB.shadersURL)
        let receiptURL = entry(runtimeB).appendingPathComponent("runtime-receipt.json")
        let receiptBytes = try Data(contentsOf: receiptURL)
        var receipt = try F.json(receiptURL); receipt["authenticationCode"] = String(repeating: "0", count: 64)
        try replaceOwned(try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), receiptURL)
        try F.rejected("forged provenance") { _ = try vault.verifiedSnapshot(metallibPath: runtimeB.shadersURL.path, forceHashVerification: true) }
        try replaceOwned(receiptBytes, receiptURL)
        let resources = runtimeB.shadersURL.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resources.path)
        try fm.removeItem(at: runtimeB.shadersURL)
        try fm.createSymbolicLink(at: runtimeB.shadersURL, withDestinationURL: secondBundle.shaders)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: resources.path)
        try F.rejected("snapshot symlink") { _ = try vault.verifiedSnapshot(metallibPath: runtimeB.shadersURL.path, forceHashVerification: true) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resources.path)
        try fm.removeItem(at: runtimeB.shadersURL)
        try originalMetal.write(to: runtimeB.shadersURL)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: runtimeB.shadersURL.path)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: resources.path)
        _ = try vault.verifiedSnapshot(metallibPath: runtimeB.shadersURL.path, forceHashVerification: true)
        print("PASS: corrupted bytes, forged provenance and symlink rejected; a damaged published entry is preserved rather than overwritten")

        // A self-consistent public bundle is insufficient as a snapshot; config
        // paths never select code for launch. Only the app-provided bundle B does.
        let evil = try F.bundle(root, name: "UntrustedConfigChoice", worker: worker)
        try F.rejected("outside vault with consistent manifest") { _ = try vault.verifiedSnapshot(metallibPath: evil.shaders.path, forceHashVerification: true) }
        let otherRoot = root.appendingPathComponent("OtherPrivate/Runtimes/Gaussian")
        var otherVault = DesktopGaussianRuntimeVault(root: otherRoot)
        try F.rejected("another vault has no provenance authority here") { _ = try otherVault.verifiedSnapshot(metallibPath: runtimeB.shadersURL.path) }
        let maliciousJob = DesktopJob(id: UUID(), sourcePath: source.path, duration: 1, title: "Config cannot install code")
        let maliciousBase = root.appendingPathComponent("Work/Gaussian-" + maliciousJob.id.uuidString)
        let maliciousWorkspace = maliciousBase.appendingPathComponent("runs/" + UUID().uuidString)
        try fm.createDirectory(at: maliciousWorkspace, withIntermediateDirectories: true)
        let maliciousConfiguration = DesktopGaussian.Configuration(jobID: maliciousJob.id.uuidString, datasetPath: dataset.path,
            workspacePath: maliciousWorkspace.path, metallibPath: evil.shaders.path, targetIterations: 100000, downscale: 1,
            datasetIndexSHA256: try F.digest(dataset.appendingPathComponent("dataset.json")), executionID: UUID(), executionStartedAt: Date().timeIntervalSince1970)
        let maliciousBytes = try JSONEncoder().encode(maliciousConfiguration)
        try maliciousBytes.write(to: maliciousBase.appendingPathComponent("config.json"))
        try maliciousBytes.write(to: maliciousWorkspace.appendingPathComponent("config.json"))
        let recovery = DesktopGaussian(job: maliciousJob, library: library, root: root, canStart: { true }, setBusy: { _ in }, onSave: { _ in },
                                       helperURL: secondBundle.helper, shadersURL: secondBundle.shaders)
        recovery.resumeExisting()
        try await F.wait("recovery launches selected bundle B") { recovery.hasLiveWorker && recovery.iteration > 2 }
        let recoveryStatus = maliciousWorkspace.appendingPathComponent("status.json")
        let recoveryPID = (try F.json(recoveryStatus)["pid"] as! NSNumber).int32Value
        ownedProcesses.append((recoveryPID, runtimeB.helperURL))
        try F.require(processPath(recoveryPID) == runtimeB.helperURL.path && (try F.json(maliciousBase.appendingPathComponent("config.json"))["metallibPath"] as? String) == runtimeB.shadersURL.path,
                      "Config-provided runtime must never select executable code")
        recovery.command("cancel")
        try await F.wait("stop recovery fixture") { recovery.phase == "cancelled" && !recovery.busy }
        try F.require(try [obj, dataset.appendingPathComponent("dataset.json")].map(F.digest) == originalSourceHashes &&
                      [secondBundle.helper, secondBundle.shaders, manifestB].map(F.digest) == sourceBHashes,
                      "Authored sources and current app bundle must stay unchanged")
        print("PASS: a consistent manifest outside the private vault cannot install a runtime; config recovery launches only the app-selected snapshot")
        let report: [String: Any] = ["passed": true, "gpuUsed": false, "syntheticPOSIXHelper": true, "realController": true, "realScanStore": true,
            "samePIDAfterSourceAppRemoval": true, "activeConfigurationUnchanged": true, "pauseResumeExport": true,
            "nextLaunchUsesNewSnapshot": true, "immutableReuse": true, "noAutomaticEviction": true,
            "corruptSnapshotRejectedWithoutOverwrite": true, "provenanceForgeryRejected": true, "symlinkRejected": true,
            "consistentOutsideManifestRejected": true, "configCannotChooseExecutable": true, "sourcesUnchanged": true,
            "realAppOrWorkerAccessed": false, "runtimeA": entry(runtimeA).lastPathComponent, "runtimeB": entry(runtimeB).lastPathComponent]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("verification.json"), options: .atomic)
    }
}
