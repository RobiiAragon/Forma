import Foundation
import Network
import CryptoKit
import Combine

/// Real authenticated TCP -> production Store -> native Metal helper -> published
/// ScanStore -> authenticated result download. Only authored files in a fresh root.
@main struct DesktopHybridRemoteVerification {
    typealias Fixture = DesktopHybridGaussianVerification
    static func require(_ value: Bool, _ message: String) throws { try Fixture.require(value, message) }
    @MainActor static func peer(_ store: DesktopStore) async throws -> HybridTransfer.Peer {
        try await Fixture.waitUntil("production listener ready") { store.receiver.listeningPort != nil }
        return .init(id: "owned-loopback", displayName: "Owned loopback", endpoint:
            .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: store.receiver.listeningPort!)!))
    }
    static func status(_ id: UUID, peer: HybridTransfer.Peer, code: String) async throws -> HybridTransfer.RemoteJobStatus {
        try await HybridTransfer.status(jobID: id, to: peer, pairingCode: code)
    }
    static func command(_ action: HybridTransfer.RemoteJobCommand.Action, id: UUID,
                        peer: HybridTransfer.Peer, code: String) async throws -> (HybridTransfer.RemoteJobCommand, HybridTransfer.RemoteCommandReply) {
        let current = try await status(id, peer: peer, code: code)
        let command = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: action, expectedRevision: current.controlRevision)
        return (command, try await HybridTransfer.command(command, to: peer, pairingCode: code))
    }
    static func workspace(_ base: URL) throws -> URL {
        URL(fileURLWithPath: try Fixture.dictionary(base.appendingPathComponent("config.json"))["workspacePath"] as! String)
    }
    static func controlLines(_ work: URL) -> Int {
        ((try? String(contentsOf: work.appendingPathComponent("control.ndjson"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    @MainActor static func verifyManualCPUHandoff(root: URL, helper: URL, shaders: URL) async throws {
        let source = root.appendingPathComponent("Incoming/" + UUID().uuidString)
        try Fixture.dataset(source)
        let request = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 100000, downscale: 1)
        try JSONEncoder().encode(request).write(to: source.appendingPathComponent("procesamiento.json"))
        let original = try Fixture.hashes(source), id = UUID()
        let store = DesktopStore(baseURL: root, gaussianHelperURL: helper, gaussianShadersURL: shaders)
        let base = root.appendingPathComponent("Work/Gaussian-" + id.uuidString)
        defer { store.cancel(); Fixture.cleanupWorker(base, helper: helper) }
        // Same main-actor turn: pause is requested before the asynchronous copy can
        // finish. Both CPU preparation and the following native handoff are real.
        store.enqueue(.init(id: id, directory: source, duration: 1), title: "Authored CPU handoff")
        store.pause()
        try await Fixture.waitUntil("CPU preparation confirms human pause") { store.remoteStatus(for: id).state == "paused" }
        try await Task.sleep(for: .milliseconds(150))
        try require(!FileManager.default.fileExists(atPath: base.appendingPathComponent("config.json").path), "CPU manual pause must not launch a native worker")
        store.resume(id)
        try await Fixture.waitUntil("explicit CPU continuation reaches native worker", timeout: 60) { (store.remoteStatus(for: id).iteration ?? 0) > 2 }
        store.cancel()
        try await Fixture.waitUntil("actual native worker cancellation", timeout: 30) { store.remoteStatus(for: id).state == "cancelled" }
        try require(try Fixture.hashes(source) == original, "CPU pause/resume/handoff must preserve incoming source bytes")
    }

    @MainActor static func expectNoResult(_ store: DesktopStore, id: UUID, reason: String) async throws {
        var rejected = false
        do { _ = try await store.remoteResult(for: id) } catch { rejected = true }
        try require(rejected, reason)
    }

    @MainActor static func verifyManualExecutionHistory(store: DesktopStore, original: ScanRecord,
                                                       source: URL, root: URL, helper: URL, shaders: URL,
                                                       peer: HybridTransfer.Peer, code: String) async throws {
        let fm = FileManager.default, id = UUID()
        let historical = store.library.directory(for: original)
        let historicalHashes = try Fixture.hashes(historical)
        let job = DesktopJob(id: id, sourcePath: source.path, duration: 3, title: "Authored manual history",
                             state: "Completado", progress: 1, status: "Historical result", resultID: original.id)
        store.jobs.append(job)
        let beforeStart = try await status(id, peer: peer, code: code)
        try require(beforeStart.resultAvailable && beforeStart.iteration == original.statistics?["steps"].flatMap(Int.init(exactly:)), "Without a new workspace the historical publication remains available")
        let controller = store.gaussianController(for: job)
        controller.iterations = "100000"; controller.downscale = "1"
        let base = store.root.appendingPathComponent("Work/Gaussian-" + id.uuidString)
        defer { controller.command("cancel"); Fixture.cleanupWorker(base, helper: helper) }
        controller.start()
        let firstExecution = controller.currentExecutionID
        let justStarted = store.remoteStatus(for: id)
        try require(!justStarted.resultAvailable && justStarted.state != "completed" && justStarted.targetIterations == 100000,
                    "Manual start must hide the historical result immediately, before a new native snapshot exists")
        try require(justStarted.controlRevision != beforeStart.controlRevision, "Manual start must rotate the durable control revision")
        try await expectNoResult(store, id: id, reason: "A running new manual execution may not return the historical model")
        try await Fixture.waitUntil("manual native worker runs", timeout: 60) { store.remoteStatus(for: id).state == "running" && (store.remoteStatus(for: id).iteration ?? 0) > 4 }
        let stale = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: .resume, expectedRevision: beforeStart.controlRevision)
        let staleReply = try await HybridTransfer.command(stale, to: peer, pairingCode: code)
        try require(staleReply.state == "rejected", "A pre-start command revision must not control a new manual execution")
        let (_, pause) = try await command(.pause, id: id, peer: peer, code: code)
        try require(pause.state == "accepted", "Manual execution must expose remote controls despite historical resultID and no processingRequest")
        try await Fixture.waitUntil("manual native pause") { store.remoteStatus(for: id).state == "paused" }
        try require(!store.remoteStatus(for: id).resultAvailable, "A paused new execution must not masquerade as its historical completion")
        try await expectNoResult(store, id: id, reason: "Paused current run must not return old model")

        // A persisted exporting snapshot is tested in its own metadata directory;
        // no running worker's status file is edited, including this fixture's worker.
        let phaseRoot = root.appendingPathComponent("Exporting-Metadata")
        let phaseBase = phaseRoot.appendingPathComponent("Work/Gaussian-" + id.uuidString)
        let phaseWork = phaseBase.appendingPathComponent("runs/" + UUID().uuidString)
        try fm.createDirectory(at: phaseWork, withIntermediateDirectories: true)
        var phaseConfig = try Fixture.dictionary(base.appendingPathComponent("config.json"))
        phaseConfig["workspacePath"] = phaseWork.path
        var phaseStatus = try Fixture.dictionary(try workspace(base).appendingPathComponent("status.json"))
        phaseStatus["phase"] = "exporting"; phaseStatus["pid"] = 0; phaseStatus["resultPath"] = NSNull()
        phaseStatus["updatedAt"] = Date().timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: phaseConfig).write(to: phaseBase.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: phaseStatus).write(to: phaseWork.appendingPathComponent("status.json"))
        let phaseController = DesktopGaussian(job: job, library: store.library, root: phaseRoot,
            canStart: { false }, setBusy: { _ in }, onSave: { _ in }, helperURL: helper, shadersURL: shaders)
        phaseController.inspectCurrentExecution()
        try require(phaseController.phase == "exporting" && phaseController.publishedCurrentResult == nil,
                    "An exporting snapshot must not resolve a historical publication")

        let (resumeFirst, resumed) = try await command(.resume, id: id, peer: peer, code: code)
        try require(resumed.state == "accepted", "Current manual execution can resume remotely")
        try await Fixture.waitUntil("manual resume advances") { store.remoteStatus(for: id).state == "running" }
        let (_, exported) = try await command(.export, id: id, peer: peer, code: code)
        try require(exported.state == "accepted", "Current manual execution can export remotely")
        try await Fixture.waitUntil("new manual publication becomes available", timeout: 60) {
            store.remoteStatus(for: id).resultAvailable && controller.publishedCurrentResult != nil
        }
        let publication = controller.publishedCurrentResult!
        try require(publication.id != original.id && store.record(job)?.id == original.id,
                    "New publication must have a new identity while the historical row retains its old resultID")
        let newPackage = try await store.remoteResult(for: id)
        try require(newPackage.descriptor.resultID == publication.id,
                    "Remote result must return the current published identity, not source job.resultID")
        try require(try Fixture.hashes(historical) == historicalHashes, "Manual completion must preserve every historical export byte")
        // A new attempt may export the same checkpoint step in the same workspace.
        // Equal runID/iteration is insufficient proof that an earlier publication
        // belongs to this attempt; its execution identity and exact export differ.
        let collisionRoot = root.appendingPathComponent("Same-Step-New-Execution")
        let realWork = try workspace(base)
        let collisionBase = collisionRoot.appendingPathComponent("Work/Gaussian-" + id.uuidString)
        let collisionWork = collisionBase.appendingPathComponent("runs/" + realWork.lastPathComponent)
        try fm.createDirectory(at: collisionWork, withIntermediateDirectories: true)
        var collisionConfig = try Fixture.dictionary(base.appendingPathComponent("config.json"))
        let collisionStarted = Date().timeIntervalSince1970
        collisionConfig["workspacePath"] = collisionWork.path
        collisionConfig["executionID"] = UUID().uuidString
        collisionConfig["executionStartedAt"] = collisionStarted
        var collisionStatus = try Fixture.dictionary(realWork.appendingPathComponent("status.json"))
        collisionStatus["phase"] = "completed"; collisionStatus["pid"] = 0
        collisionStatus["updatedAt"] = collisionStarted + 0.01
        collisionStatus["resultPath"] = collisionWork.appendingPathComponent("exports/new-unpublished-result").path
        try JSONSerialization.data(withJSONObject: collisionConfig).write(to: collisionBase.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: collisionStatus).write(to: collisionWork.appendingPathComponent("status.json"))
        let collision = DesktopGaussian(job: job, library: store.library, root: collisionRoot,
            canStart: { false }, setBusy: { _ in }, onSave: { _ in }, helperURL: helper, shadersURL: shaders)
        collision.inspectCurrentExecution()
        try require(collision.phase == "completed" && collision.iteration == controller.iteration && collision.publishedCurrentResult == nil,
                    "A same-step new attempt cannot reuse an earlier publication before publishing its own identity")
        let completedRevision = store.remoteStatus(for: id).controlRevision
        try await Fixture.waitUntil("first manual worker exits") { !controller.hasLiveWorker }
        let completedSteps = controller.iteration
        controller.iterations = String(completedSteps + 50000)
        controller.start()
        try require(controller.currentExecutionID != firstExecution, "Resuming a completed workspace creates a new attempt identity")
        let second = store.remoteStatus(for: id)
        try require(!second.resultAvailable && second.state != "completed" && second.controlRevision != completedRevision,
                    "The prior completed status.json may not describe the newly started attempt in the same workspace")
        let cold = DesktopGaussian(job: job, library: store.library, root: store.root,
            canStart: { false }, setBusy: { _ in }, onSave: { _ in }, helperURL: helper, shadersURL: shaders)
        cold.inspectCurrentExecution()
        try require(cold.currentExecutionID == controller.currentExecutionID && cold.publishedCurrentResult == nil && cold.phase != "completed",
                    "A cold metadata read must reject the old terminal snapshot after a new start")
        try await expectNoResult(store, id: id, reason: "A subsequent active attempt may not return either older publication")
        try await Fixture.waitUntil("second manual attempt runs", timeout: 60) { store.remoteStatus(for: id).state == "running" }
        let secondWork = try workspace(base), lines = controlLines(secondWork)
        let replay = try await HybridTransfer.command(resumeFirst, to: peer, pairingCode: code)
        try require(replay.state == "accepted" && !replay.status.resultAvailable && controlLines(secondWork) == lines,
                    "A recorded resume from the preceding attempt may not dispatch into the new attempt")
        let staleSecond = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: .pause, expectedRevision: completedRevision)
        try require(try await HybridTransfer.command(staleSecond, to: peer, pairingCode: code).state == "rejected",
                    "New IDs with old execution revisions must be rejected")
        let (_, cancelled) = try await command(.cancel, id: id, peer: peer, code: code)
        try require(cancelled.state == "accepted", "Current manual attempt can cancel remotely")
        try await Fixture.waitUntil("current cancellation", timeout: 30) { store.remoteStatus(for: id).state == "cancelled" }
        try require(!store.remoteStatus(for: id).resultAvailable, "Cancellation must not fall back to an old success")
        try await expectNoResult(store, id: id, reason: "Cancelled current attempt may not return an older result")
        try require(store.library.scans.contains { $0.id == publication.id } && (try Fixture.hashes(historical)) == historicalHashes,
                    "Cancellation must preserve both the earlier derived publication and original history")

        // A genuine controller launch failure with an unavailable helper, isolated
        // from the live training and backed by an actual copied ScanStore record.
        let failedRoot = root.appendingPathComponent("Failed-Manual")
        try fm.createDirectory(at: failedRoot.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try CooperativeFileIO.copyDirectory(historical, to: failedRoot.appendingPathComponent("Library/" + original.id.uuidString))
        let failedID = UUID()
        let failedJob = DesktopJob(id: failedID, sourcePath: source.path, duration: 3, title: "Authored failed manual start",
                                  state: "Completado", progress: 1, resultID: original.id)
        try JSONEncoder().encode([failedJob]).write(to: failedRoot.appendingPathComponent("jobs.json"))
        let failedStore = DesktopStore(baseURL: failedRoot, gaussianHelperURL: failedRoot.appendingPathComponent("absent-helper"), gaussianShadersURL: shaders)
        let failedController = failedStore.gaussianController(for: failedJob)
        failedController.iterations = "100000"; failedController.start()
        try require(failedStore.remoteStatus(for: failedID).state == "failed" && !failedStore.remoteStatus(for: failedID).resultAvailable,
                    "A failed current launch must not report the historical model as current success")
        try await expectNoResult(failedStore, id: failedID, reason: "Failed current launch must not serve old model")
        try require(failedStore.record(failedJob)?.id == original.id, "Launch failure must preserve historical local viewing")
    }

    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw HybridTransfer.TransferError.failed("Usage: WORKER METALLIB NEW_OWNED_OUTPUT") }
        let helper = URL(fileURLWithPath: args[0]).standardizedFileURL
        let shaders = URL(fileURLWithPath: args[1]).standardizedFileURL
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "Use a fresh owned output directory")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try await verifyManualCPUHandoff(root: root.appendingPathComponent("CPU-Handoff"), helper: helper, shaders: shaders)
        let original = root.appendingPathComponent("AuthoredSource")
        try Fixture.dataset(original)
        let before = try Fixture.hashes(original)
        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: original.appendingPathComponent("malla-original.json")))
        let desktopRoot = root.appendingPathComponent("Desktop")
        var store: DesktopStore? = DesktopStore(baseURL: desktopRoot, gaussianHelperURL: helper, gaussianShadersURL: shaders)
        var ids: [UUID] = []
        defer {
            store?.stopReception(); store?.cancel()
            for id in ids { Fixture.cleanupWorker(desktopRoot.appendingPathComponent("Work/Gaussian-" + id.uuidString), helper: helper) }
        }
        store!.receive()
        var destination = try await peer(store!)
        var code = store!.receiver.pairingCode
        let id = try await HybridTransfer.send(datasetDirectory: original.appendingPathComponent("dataset"), mesh: mesh, duration: 3,
            to: destination, pairingCode: code, processingRequest: .init(kind: .gaussian, iterations: 100000, downscale: 1))
        ids.append(id)
        let base = desktopRoot.appendingPathComponent("Work/Gaussian-" + id.uuidString)
        try await Fixture.waitUntil("native worker starts", timeout: 60) {
            fm.fileExists(atPath: base.appendingPathComponent("config.json").path) && (store?.remoteStatus(for: id).iteration ?? 0) > 2
        }
        let work = try workspace(base), workerStatus = work.appendingPathComponent("status.json")
        // An actual append failure is observable as uncertain, never accepted.
        // The fixture directory stands in for an unwritable control file without
        // changing system permissions or disturbing another process's files.
        let control = work.appendingPathComponent("control.ndjson")
        let preservedControl = work.appendingPathComponent("control-fixture-preserved.ndjson")
        // The helper intentionally holds an open FD for its append-only queue.
        // Move and restore its inode; replacing that inode would test an unrelated
        // unsupported truncation/replacement instead of a writer-open failure.
        try fm.moveItem(at: control, to: preservedControl)
        try fm.createDirectory(at: control, withIntermediateDirectories: false)
        let (failedDispatch, failedReply) = try await command(.pause, id: id, peer: destination, code: code)
        try require(failedReply.state == "uncertain", "A failed actual control-file append may not be reported accepted")
        try fm.removeItem(at: control)
        try fm.moveItem(at: preservedControl, to: control)
        let failedRetry = try await HybridTransfer.command(failedDispatch, to: destination, pairingCode: code)
        try require(failedRetry.state == "uncertain" && controlLines(work) == 0, "A failed submission receipt is never retried as a new effect")
        let incoming = desktopRoot.appendingPathComponent("Incoming/" + id.uuidString)
        let incomingBefore = try Fixture.hashes(incoming)
        let second = try await HybridTransfer.send(datasetDirectory: original.appendingPathComponent("dataset"), mesh: mesh, duration: 3,
            to: destination, pairingCode: code, processingRequest: .init(kind: .gaussian, iterations: 12, downscale: 1))
        ids.append(second)
        try await Fixture.waitUntil("second request enqueued") { store?.jobs.contains(where: { $0.id == second }) == true }
        try require(store!.remoteStatus(for: second).state == "queued" && !store!.remoteStatus(for: second).resultAvailable,
                    "A queued job must remain queued without an advertised result")
        let previousStep = Fixture.iteration(workerStatus)
        let (_, pauseSecond) = try await command(.pause, id: second, peer: destination, code: code)
        try require(pauseSecond.state == "accepted", "Queued target pause must be accepted")
        try await Fixture.waitUntil("first worker keeps advancing while second is paused") { Fixture.iteration(workerStatus) > previousStep + 2 }
        try require(store!.remoteStatus(for: second).state == "paused", "Pause must affect only the indicated queued job")
        try require(!fm.fileExists(atPath: desktopRoot.appendingPathComponent("Work/Gaussian-" + second.uuidString + "/config.json").path), "Pausing a queued job must not start its worker")

        let (_, pausedReply) = try await command(.pause, id: id, peer: destination, code: code)
        try require(pausedReply.state == "accepted", "Remote pause dispatch must be accepted")
        try await Fixture.waitUntil("actual native checkpoint pause", timeout: 30) { store?.remoteStatus(for: id).state == "paused" }
        let paused = Fixture.iteration(workerStatus)
        try await Task.sleep(for: .milliseconds(200))
        try require(Fixture.iteration(workerStatus) == paused, "Actual native step must stop after confirmed pause")
        let (resumeCommand, resumeReply) = try await command(.resume, id: id, peer: destination, code: code)
        try require(resumeReply.state == "accepted", "Remote resume dispatch must be accepted")
        try await Fixture.waitUntil("native steps resume") { Fixture.iteration(workerStatus) > paused + 3 }

        // The exact same public action as the Gaussian Mac window, bypassing Store.pause().
        let job = store!.jobs.first { $0.id == id }!
        store!.gaussianController(for: job).command("pause")
        try await Fixture.waitUntil("local Mac pause acknowledged") { store?.remoteStatus(for: id).state == "paused" }
        let humanPaused = Fixture.iteration(workerStatus), lines = controlLines(work)
        let replay = try await HybridTransfer.command(resumeCommand, to: destination, pairingCode: code)
        try require(replay.state == "accepted" && replay.status.state == "paused", "Receipt replay returns current paused status, not a new effect")
        let stale = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: .resume, expectedRevision: resumeCommand.expectedRevision)
        let staleReply = try await HybridTransfer.command(stale, to: destination, pairingCode: code)
        try require(staleReply.state == "rejected", "A different resume with stale revision must be rejected after the direct Mac pause")
        try await Task.sleep(for: .milliseconds(250))
        try require(Fixture.iteration(workerStatus) == humanPaused && controlLines(work) == lines, "Old or stale resumes must not append controls or advance the manually paused worker")

        // Model a process death immediately after the durable claim and before effect/finish.
        let current = try await status(id, peer: destination, code: code)
        let interrupted = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: .resume, expectedRevision: current.controlRevision)
        let ledger = DesktopRemoteControlLedger(root: desktopRoot.appendingPathComponent("RemoteControl"))
        guard case .dispatch = try ledger.claim(interrupted, rejection: nil) else { throw HybridTransfer.TransferError.failed("Crash-window claim unexpectedly reused") }
        store!.stopReception(); store = nil
        try await Task.sleep(for: .milliseconds(100))
        store = DesktopStore(baseURL: desktopRoot, gaussianHelperURL: helper, gaussianShadersURL: shaders)
        store!.receive(); destination = try await peer(store!); code = store!.receiver.pairingCode
        try await Fixture.waitUntil("restored controller sees manual pause") { store?.remoteStatus(for: id).state == "paused" }
        let uncertain = try await HybridTransfer.command(interrupted, to: destination, pairingCode: code)
        try require(uncertain.state == "uncertain" && uncertain.status.error != nil, "A durable pending receipt survives Store recreation as visible uncertainty")
        let replayAfterRestart = try await HybridTransfer.command(resumeCommand, to: destination, pairingCode: code)
        try require(replayAfterRestart.state == "accepted", "Completed receipt must survive Store recreation")
        try await Task.sleep(for: .milliseconds(250))
        try require(Fixture.iteration(workerStatus) == humanPaused && controlLines(work) == lines, "Neither pending nor completed resume may redispatch after restart")
        let (_, cancelSecond) = try await command(.cancel, id: second, peer: destination, code: code)
        try require(cancelSecond.state == "accepted" && store!.remoteStatus(for: second).state == "cancelled", "Remote cancel targets only the queued second job")
        let (_, resumedAgain) = try await command(.resume, id: id, peer: destination, code: code)
        try require(resumedAgain.state == "accepted", "Fresh explicit intent may resume after reviewing uncertainty")
        try await Fixture.waitUntil("fresh explicit intent advances") { Fixture.iteration(workerStatus) > humanPaused + 3 }
        var saveRevisionBeforeDirectPause: UUID?
        let savePauseObservation = store!.library.$isSaving.sink { [weak fixtureStore = store!] saving in
            guard saving else { return }
            Task { @MainActor [weak fixtureStore] in
                guard let fixtureStore, fixtureStore.library.isSaving else { return }
                saveRevisionBeforeDirectPause = fixtureStore.remoteStatus(for: id).controlRevision
                // Same API as DesktopSavingPanel: intentionally bypass Store control.
                fixtureStore.library.pauseSaving()
            }
        }
        defer { savePauseObservation.cancel() }
        let (_, exportReply) = try await command(.export, id: id, peer: destination, code: code)
        try require(exportReply.state == "accepted", "Targeted remote export dispatch must be accepted")
        try await Fixture.waitUntil("actual published Gaussian save reaches direct-library human pause", timeout: 60) {
            store!.library.isSaving && store!.library.savingState.isPauseActive && saveRevisionBeforeDirectPause != nil
        }
        savePauseObservation.cancel()
        let staleSaveResume = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: id, action: .resume, expectedRevision: saveRevisionBeforeDirectPause)
        let staleSaveReply = try await HybridTransfer.command(staleSaveResume, to: destination, pairingCode: code)
        try require(staleSaveReply.state == "rejected" && store!.library.savingState.isPauseActive,
                    "A direct library saving pause must synchronously invalidate an old remote resume")
        let (_, resumedSave) = try await command(.resume, id: id, peer: destination, code: code)
        try require(resumedSave.state == "accepted", "Fresh explicit remote resume continues the indicated real save")
        try await Fixture.waitUntil("real Gaussian result published in actual ScanStore", timeout: 60) { store?.record(store!.jobs.first { $0.id == id }!) != nil }
        let completed = try await status(id, peer: destination, code: code)
        try require(completed.resultAvailable && completed.state == "completed", "Only a complete published derivative is downloadable")
        let resultRecord = store!.record(store!.jobs.first { $0.id == id }!)!
        let libraryDirectory = store!.library.directory(for: resultRecord)
        let publishedModel = libraryDirectory.appendingPathComponent(resultRecord.modelFile!)

        // A malicious link inside a published fixture package must not expose another file.
        let outside = root.appendingPathComponent("outside.png")
        try Data("private-owned-fixture".utf8).write(to: outside)
        let malicious = publishedModel.deletingLastPathComponent().appendingPathComponent("escaped.png")
        try fm.createSymbolicLink(at: malicious, withDestinationURL: outside)
        var rejectedLink = false
        do { _ = try await store!.remoteResult(for: id) } catch { rejectedLink = true }
        try require(rejectedLink, "Result provider must reject a package with a symbolic link")
        try fm.removeItem(at: malicious)
        let downloaded = try await HybridTransfer.downloadResult(jobID: id, to: destination, pairingCode: code, directory: root.appendingPathComponent("PhoneDownload"))
        try HybridTransfer.verifyDownloadedResult(downloaded)
        let descriptor = downloaded.descriptor
        try require(descriptor.jobID == id && descriptor.resultID == resultRecord.id && descriptor.packageRelativePath == "modelo", "Returned descriptor must identify the requested published result")
        let receivedModel = downloaded.directory.appendingPathComponent(descriptor.modelRelativePath!)
        try require(try HybridTransfer.digest(receivedModel) == HybridTransfer.digest(publishedModel), "Downloaded native PLY bytes must match the actual published Gaussian model")
        let resultNames = try Fixture.hashes(downloaded.directory).keys.sorted()
        try require(!resultNames.contains(where: { $0.contains("fuentes/") || $0.contains("dataset/") || $0.hasSuffix("captura.json") || $0.hasSuffix("integridad.json") || $0.hasSuffix("informe.json") }), "Download must not repeat photos or old library metadata")
        for file in ["entrenamiento.ckpt", "gaussianas.json"] {
            let local = publishedModel.deletingLastPathComponent().appendingPathComponent(file)
            let remote = downloaded.directory.appendingPathComponent("modelo/" + file)
            try require(try HybridTransfer.digest(local) == HybridTransfer.digest(remote), "Full optimizer checkpoint and native metadata must survive the download byte for byte")
        }
        let serialized = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8)!
        try require(!serialized.contains(root.path) && !serialized.contains("/Users/"), "Wire result descriptor must not contain private local paths")
        let repeated = try await HybridTransfer.downloadResult(jobID: id, to: destination, pairingCode: code, directory: root.appendingPathComponent("PhoneDownload"))
        try require(repeated.descriptor == descriptor && repeated.manifestSHA256 == downloaded.manifestSHA256, "Retry must identify the same published result and manifest")
        try require(store!.library.scans.count == 1 && store!.jobs.count == 2, "Control, receipt replay, and download retry must not duplicate records or jobs")
        try require(try Fixture.hashes(original) == before && Fixture.hashes(incoming) == incomingBefore, "Authored source bytes and committed incoming dataset must remain unchanged")
        try await verifyManualExecutionHistory(store: store!, original: resultRecord,
            source: desktopRoot.appendingPathComponent("Work/HybridGaussian-" + id.uuidString + "/source"),
            root: root, helper: helper, shaders: shaders, peer: destination, code: code)
        let report: [String: Any] = ["status": "passed", "realTCP": true, "pairedEncryption": true,
            "realProductionStore": true, "realNativeMetalWorker": true, "realScanStore": true,
            "phoneUsed": false, "userLibraryUsed": false, "targetedQueuedPauseAndCancel": true,
            "remotePauseResumeExport": true, "manualCPUPreparationPausePreventedGPUHandoff": true,
            "directMacPauseInvalidatedOldResume": true, "directLibrarySavePauseInvalidatedOldResume": true,
            "durableReceiptReplayDidNotResume": true, "pendingCrashWindowUncertain": true, "failedControlAppendUncertainWithoutReplay": true,
            "resultDownloadedAndSHAEqual": true, "manualNewRunSupersededHistoricalStatusAndResult": true,
            "manualRunColdMetadataDidNotResurrectOldCompletion": true, "sameStepNewExecutionDidNotReuseOldPublication": true, "manualRunCommandsAndRevisionSafe": true,
            "manualFailedAndCancelledDidNotReturnOldSuccess": true, "exportingMetadataDidNotResolveOldPublication": true, "resultRetryStable": true, "symlinkRejected": true,
            "datasetAndOldMetadataExcluded": true, "completeOptimizerCheckpointAndEngineMetadataPreserved": true, "sourcesUnchanged": true,
            "resultFiles": resultNames, "jobID": id.uuidString, "resultID": resultRecord.id.uuidString,
            "manifestSHA256": downloaded.manifestSHA256, "pausedIteration": humanPaused]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("verification.json"))
        print("FORMA_HYBRID_REMOTE_STORE_PASS " + root.appendingPathComponent("verification.json").path)
    }
}
