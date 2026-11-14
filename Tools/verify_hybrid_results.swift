import Foundation
import Network

private final class ResultLocked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult func update<T>(_ operation: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation(&value) }
    var snapshot: Value { update { $0 } }
}

private actor CommandFixture {
    var revision = UUID(), effects = 0
    var ledger: [UUID: (HybridTransfer.RemoteJobCommand, HybridTransfer.RemoteCommandReply)] = [:]
    let jobID: UUID
    init(_ jobID: UUID) { self.jobID = jobID }
    func status() -> HybridTransfer.RemoteJobStatus {
        .init(id: jobID, state: "running", progress: 0.4, iteration: 400, targetIterations: 1000, splats: 12345,
              resultAvailable: true, controlRevision: revision, supportedCommands: [.pause, .resume, .cancel, .export])
    }
    func execute(_ command: HybridTransfer.RemoteJobCommand) throws -> HybridTransfer.RemoteCommandReply {
        if let (original, reply) = ledger[command.id] {
            guard original == command else { throw HybridTransfer.TransferError.failed("Command ID collision") }
            return reply
        }
        guard command.jobID == jobID, command.expectedRevision == revision else { throw HybridTransfer.TransferError.failed("Stale control revision") }
        effects += 1; revision = UUID()
        let reply = HybridTransfer.RemoteCommandReply(commandID: command.id, jobID: jobID, state: "accepted", status: status())
        ledger[command.id] = (command, reply)
        return reply
    }
}

@main
struct HybridResultVerification {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw HybridTransfer.TransferError.failed(message) }
    }
    static func rejected(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw HybridTransfer.TransferError.failed("Expected rejection: " + label)
    }
    static func rejectedSync(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw HybridTransfer.TransferError.failed("Expected rejection: " + label)
    }
    @MainActor static func peer(_ receiver: HybridTransferReceiver) async throws -> HybridTransfer.Peer {
        for _ in 0..<300 {
            if let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) {
                return .init(id: "results-loopback", displayName: "Results loopback", endpoint: .hostPort(host: "127.0.0.1", port: port))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HybridTransfer.TransferError.failed("Listener timeout")
    }
    @MainActor static func interrupt(jobID: UUID, peer: HybridTransfer.Peer, code: String, directory: URL) async throws -> (URL, Int64) {
        let handle = ResultLocked<Task<HybridTransfer.DownloadedResult, Error>?>(nil)
        let latest = ResultLocked(HybridTransfer.TransferMetrics())
        let task = Task {
            try await HybridTransfer.downloadResult(jobID: jobID, to: peer, pairingCode: code, directory: directory, metrics: { metrics in
                latest.update { $0 = metrics }
                if metrics.transmittedPayloadBytes >= 3 * 1024 * 1024 { handle.snapshot?.cancel() }
            })
        }
        handle.update { $0 = task }
        try await rejected("interrupted result stream") { _ = try await task.value }
        let partial = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".result-resume-") }
        guard let partial else { throw HybridTransfer.TransferError.failed("Result prefix was discarded") }
        let model = partial.appendingPathComponent("modelo/modelo.ply")
        try require(try HybridTransfer.size(model) >= 3 * 1024 * 1024, "No useful result prefix retained")
        return (partial, latest.snapshot.transmittedPayloadBytes)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FormaHybridResults-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("published"), package = source.appendingPathComponent("modelo")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let model = package.appendingPathComponent("modelo.ply"), texture = package.appendingPathComponent("textura.bin")
        let mesh = source.appendingPathComponent("malla.json")
        var modelBytes = [UInt8](repeating: 0, count: 12_582_949)
        for index in modelBytes.indices { modelBytes[index] = UInt8((index * 19) % 251) }
        try Data(modelBytes).write(to: model)
        try Data((0..<79_031).map { UInt8($0 % 239) }).write(to: texture)
        try JSONEncoder().encode(MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])).write(to: mesh)
        let original = source.appendingPathComponent("originales/foto.jpg")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("private original never part of the derived bundle".utf8).write(to: original)
        let sourceHashes = try [model, texture, mesh, original].map { try HybridTransfer.digest($0) }
        let sourceNames = fm.subpaths(atPath: source.path)!.sorted()
        let jobID = UUID(), resultID = UUID(), commands = CommandFixture(jobID)
        let descriptor = HybridTransfer.ResultDescriptor(jobID: jobID, resultID: resultID, name: "Sala fixture", mode: "lidar", duration: 123.5,
            note: "Derived Gaussian and mesh", statistics: ["splats": 12345], modelRelativePath: "modelo/modelo.ply", packageRelativePath: "modelo",
            meshRelativePath: "malla.json", gaussianModelRelativePath: "modelo.ply")
        let sourceValue = HybridTransfer.ResultSource(descriptor: descriptor, directory: source)
        let resultProviderCalls = ResultLocked(0), commandProviderCalls = ResultLocked(0), jobs = ResultLocked(0)
        let dropCommandID = ResultLocked<UUID?>(nil)
        let dropCommandTask = ResultLocked<Task<HybridTransfer.RemoteCommandReply, Error>?>(nil)
        let resultProvider: HybridTransfer.ResultProvider = { id in
            resultProviderCalls.update { $0 += 1 }
            guard id == jobID else { throw HybridTransfer.TransferError.failed("Unknown result job") }
            return sourceValue
        }
        let commandProvider: HybridTransfer.CommandProvider = { command in
            commandProviderCalls.update { $0 += 1 }
            let reply = try await commands.execute(command)
            if dropCommandID.snapshot == command.id {
                dropCommandTask.snapshot?.cancel()
                try? await Task.sleep(for: .milliseconds(40))
            }
            return reply
        }
        let receiver = HybridTransferReceiver(), incoming = root.appendingPathComponent("incoming")
        try receiver.start(directory: incoming, name: "Forma results verification", onStatus: { _ in await commands.status() }, onCommand: commandProvider,
            onResult: resultProvider) { _ in jobs.update { $0 += 1 } }
        defer { receiver.stop() }
        let endpoint = try await peer(receiver), code = receiver.pairingCode
        let initial = try await HybridTransfer.status(jobID: jobID, to: endpoint, pairingCode: code)
        try require(initial.supportedCommands?.count == 4 && initial.controlRevision != nil, "Capabilities/revision lost")
        let firstCommand = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: jobID, action: .pause, expectedRevision: initial.controlRevision)
        let firstReply = try await HybridTransfer.command(firstCommand, to: endpoint, pairingCode: code)
        let replay = try await HybridTransfer.command(firstCommand, to: endpoint, pairingCode: code)
        let effectCount = await commands.effects
        try require(firstReply == replay && effectCount == 1, "Replay duplicated command effect")
        var collision = firstCommand; collision.action = .resume
        try await rejected("same UUID changed action") { _ = try await HybridTransfer.command(collision, to: endpoint, pairingCode: code) }
        var stale = firstCommand; stale.id = UUID()
        try await rejected("stale revision") { _ = try await HybridTransfer.command(stale, to: endpoint, pairingCode: code) }
        for action in [HybridTransfer.RemoteJobCommand.Action.resume, .export, .cancel] {
            let revision = await commands.revision
            let reply = try await HybridTransfer.command(.init(id: UUID(), jobID: jobID, action: action, expectedRevision: revision), to: endpoint, pairingCode: code)
            try require(reply.state == "accepted" && reply.status.controlRevision != revision, "Action/revision did not round trip")
        }
        let lostReplyCommand = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: jobID, action: .pause, expectedRevision: await commands.revision)
        dropCommandID.update { $0 = lostReplyCommand.id }
        let droppedTask = Task { try await HybridTransfer.command(lostReplyCommand, to: endpoint, pairingCode: code) }
        dropCommandTask.update { $0 = droppedTask }
        try await rejected("effect committed but command reply lost") { _ = try await droppedTask.value }
        dropCommandID.update { $0 = nil }
        let effectsAfterLostReply = await commands.effects
        let recoveredReply = try await HybridTransfer.command(lostReplyCommand, to: endpoint, pairingCode: code)
        let effectsAfterRetry = await commands.effects
        try require(recoveredReply.commandID == lostReplyCommand.id && effectsAfterLostReply == effectsAfterRetry, "Lost ACK retry repeated a command effect")
        let callsBeforeAuth = commandProviderCalls.snapshot
        try await rejected("unpaired command") { _ = try await HybridTransfer.command(firstCommand, to: endpoint, pairingCode: "00000000000000000000000000000000") }
        try require(commandProviderCalls.snapshot == callsBeforeAuth, "Unauthenticated command reached provider")
        print("PASS: real encrypted TCP pause/resume/cancel/export, capabilities/revision, exact UUID replay/lost-reply recovery, collision/stale rejection and pairing isolation")

        let destination = root.appendingPathComponent("downloads")
        let (partial, interruptedBytes) = try await interrupt(jobID: jobID, peer: endpoint, code: code, directory: destination)
        try require(fm.fileExists(atPath: partial.appendingPathComponent(".result-transfer.json").path), "Partial inventory missing")
        let resumedMetrics = ResultLocked(HybridTransfer.TransferMetrics())
        let completed = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: destination,
            metrics: { value in resumedMetrics.update { $0 = value } })
        try HybridTransfer.verifyDownloadedResult(completed)
        let recovered = try HybridTransfer.loadDownloadedResult(from: completed.directory)
        try require(recovered.descriptor == descriptor && recovered.manifestSHA256 == completed.manifestSHA256, "Offline recovery identity mismatch")
        try require(resumedMetrics.snapshot.resumedPayloadBytes >= interruptedBytes && resumedMetrics.snapshot.transmittedPayloadBytes < (try HybridTransfer.size(model)), "Resumed full file instead of prefix")
        try require(!fm.fileExists(atPath: completed.directory.appendingPathComponent("originales").path), "Original photographs leaked into result")
        let repeatMetrics = ResultLocked(HybridTransfer.TransferMetrics())
        let repeated = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: destination,
            metrics: { value in repeatMetrics.update { $0 = value } })
        try require(repeated.directory.standardizedFileURL.path == completed.directory.standardizedFileURL.path && repeatMetrics.snapshot.alreadyCommitted && repeatMetrics.snapshot.transmittedPayloadBytes == 0, "Committed retry repeated payload or result")
        print("PASS: interrupted result retains verified prefix; resumed download streams only remainder; atomic verified bundle recovers offline and repeated receipt sends zero payload")

        let corruptDestination = root.appendingPathComponent("corrupt-prefix")
        let (corruptPartial, _) = try await interrupt(jobID: jobID, peer: endpoint, code: code, directory: corruptDestination)
        let damaged = try FileHandle(forWritingTo: corruptPartial.appendingPathComponent("modelo/modelo.ply"))
        try damaged.write(contentsOf: Data([255])); try damaged.close()
        let restartMetrics = ResultLocked(HybridTransfer.TransferMetrics())
        let repaired = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: corruptDestination,
            metrics: { value in restartMetrics.update { $0 = value } })
        try HybridTransfer.verifyDownloadedResult(repaired)
        try require(restartMetrics.snapshot.transmittedPayloadBytes >= (try HybridTransfer.size(model)), "Corrupt prefix was accepted")
        try await rejected("changed pinned manifest") {
            _ = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: root.appendingPathComponent("changed-manifest"), expectedManifestSHA256: String(repeating: "a", count: 64))
        }
        print("PASS: corrupt prefix restarts only damaged file; expected manifest changes rejected before payload")

        let mismatchDestination = root.appendingPathComponent("mismatch-inventory")
        let (mismatchPartial, _) = try await interrupt(jobID: jobID, peer: endpoint, code: code, directory: mismatchDestination)
        let metadata = mismatchPartial.appendingPathComponent(".result-transfer.json")
        let metadataBytes = try Data(contentsOf: metadata)
        var wrong = try JSONDecoder().decode(HybridTransfer.TransferReceipt.self, from: metadataBytes)
        wrong.manifest.duration += 1
        try JSONEncoder().encode(wrong).write(to: metadata, options: .atomic)
        let changedBytes = try Data(contentsOf: metadata)
        try await rejected("partial inventory replacement") { _ = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: mismatchDestination) }
        try require(try Data(contentsOf: metadata) == changedBytes, "Mismatched partial was overwritten")
        let linkDestination = root.appendingPathComponent("linked-prefix")
        let (linkPartial, _) = try await interrupt(jobID: jobID, peer: endpoint, code: code, directory: linkDestination)
        let linkFile = linkPartial.appendingPathComponent("modelo/modelo.ply")
        try fm.removeItem(at: linkFile); try fm.createSymbolicLink(at: linkFile, withDestinationURL: original)
        try await rejected("partial symlink") { _ = try await HybridTransfer.downloadResult(jobID: jobID, to: endpoint, pairingCode: code, directory: linkDestination) }
        try rejectedSync("offline symlink") { _ = try HybridTransfer.loadDownloadedResult(from: linkPartial) }
        var traversal = descriptor; traversal.modelRelativePath = "../private-original"
        try rejectedSync("descriptor traversal") { try traversal.validate() }
        var absolute = descriptor; absolute.meshRelativePath = original.path
        try rejectedSync("descriptor absolute path") { try absolute.validate() }
        var nul = descriptor; nul.modelRelativePath = "modelo/modelo.ply\0/truncated"
        try rejectedSync("descriptor NUL") { try nul.validate() }
        try require(try HybridTransfer.digest(original) == sourceHashes[3], "Symlink victim changed")
        print("PASS: changed partial inventory, traversal, absolute paths and symlinks rejected without modifying source or partial metadata")

        let usbCode = code, usbPort = UInt16.random(in: 52000...59000)
        let usbTask = Task { try await HybridTransfer.downloadResultOverUSBWaitingForMac(jobID: jobID, pairingCode: usbCode, directory: root.appendingPathComponent("usb-download"), port: usbPort) }
        try await Task.sleep(for: .milliseconds(100))
        try receiver.connectUSB(directory: incoming, port: usbPort, pairingCode: usbCode, onCommand: commandProvider, onResult: resultProvider) { _ in jobs.update { $0 += 1 } }
        let usbResult = try await usbTask.value
        try HybridTransfer.verifyDownloadedResult(usbResult)
        try require(usbResult.manifestSHA256 == completed.manifestSHA256, "Reverse USB changed result identity")
        let usbCommandPort = UInt16.random(in: 52000...59000)
        let usbCommandTask = Task { try await HybridTransfer.commandOverUSBWaitingForMac(firstCommand, pairingCode: usbCode, port: usbCommandPort) }
        try await Task.sleep(for: .milliseconds(100))
        try receiver.connectUSB(directory: incoming, port: usbCommandPort, pairingCode: usbCode, onCommand: commandProvider, onResult: resultProvider) { _ in jobs.update { $0 += 1 } }
        let usbReply = try await usbCommandTask.value
        try require(usbReply == firstReply, "Reverse USB command replay mismatch")
        print("PASS: reverse USB-style connection downloads identical bundle and supports the same authenticated idempotent command")

        let tampered = completed.directory.appendingPathComponent("modelo/textura.bin")
        try Data("tampered".utf8).write(to: tampered)
        try rejectedSync("post-download tamper") { try HybridTransfer.verifyDownloadedResult(completed) }
        try require(jobs.snapshot == 0, "Command/result request published a source job")
        try require(try [model, texture, mesh, original].map { try HybridTransfer.digest($0) } == sourceHashes && fm.subpaths(atPath: source.path)!.sorted() == sourceNames, "Server sources changed")
        print("PASS: post-download SHA tamper detected; originals and complete server file list unchanged; no source jobs, user library, phone or GPU accessed")
        let report: [String: Any] = ["passed": true, "resultID": resultID.uuidString, "manifestSHA256": completed.manifestSHA256,
            "interruptedBytes": interruptedBytes, "resumedBytes": resumedMetrics.snapshot.resumedPayloadBytes,
            "remainingPayloadBytes": resumedMetrics.snapshot.transmittedPayloadBytes, "committedRetryPayloadBytes": repeatMetrics.snapshot.transmittedPayloadBytes,
            "resultProviderCalls": resultProviderCalls.snapshot, "commandProviderCalls": commandProviderCalls.snapshot, "sourceHashesUnchanged": true]
        if let output = CommandLine.arguments.dropFirst().first {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
