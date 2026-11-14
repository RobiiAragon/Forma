import XCTest
import Network
@testable import Forma

/// The phone controller uses the production paired transport against isolated localhost providers.
final class HybridRemoteClientTests: XCTestCase {
    private final class AcknowledgementGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false
        private var receivedIDs: Set<UUID> = []
        func acknowledge() -> Bool {
            condition.lock(); defer { condition.unlock() }
            entered = true
            let deadline = Date().addingTimeInterval(35)
            while !released { if !condition.wait(until: deadline) { return false } }
            return true
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var waiting: Bool { condition.lock(); defer { condition.unlock() }; return entered && !released }
        func didReceive(_ id: UUID) { condition.lock(); receivedIDs.insert(id); condition.unlock() }
        var received: Set<UUID> { condition.lock(); defer { condition.unlock() }; return receivedIDs }
    }
    private struct Ledger: Codable {
        struct Entry: Codable { var command: HybridTransfer.RemoteJobCommand; var reply: HybridTransfer.RemoteCommandReply }
        var status: HybridTransfer.RemoteJobStatus
        var effects: Int = 0
        var entries: [Entry] = []
    }
    private actor Remote {
        private let ledgerURL: URL
        private var ledger: Ledger
        private var holdCommands = false
        private var holdQueries = false
        private var queryCount = 0
        private var resultCount = 0
        private var commands: [UUID: (HybridTransfer.RemoteCommandReply, CheckedContinuation<HybridTransfer.RemoteCommandReply, Never>)] = [:]
        private var queries: [Int: (HybridTransfer.RemoteJobStatus, CheckedContinuation<HybridTransfer.RemoteJobStatus, Never>)] = [:]
        init(jobID: UUID, ledgerURL: URL) throws {
            self.ledgerURL = ledgerURL
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))
            } else {
                ledger = Ledger(status: .init(id: jobID, state: "running", progress: 0.4, iteration: 400, targetIterations: 1000,
                    splats: 12345, resultAvailable: false, controlRevision: UUID(), supportedCommands: [.pause, .resume, .cancel, .export]))
            }
        }
        func currentStatus() -> HybridTransfer.RemoteJobStatus { ledger.status }
        func effectCount() -> Int { ledger.effects }
        func queryCalls() -> Int { queryCount }
        func resultCalls() -> Int { resultCount }
        func pendingCommands() -> [UUID] { Array(commands.keys) }
        func pendingQueries() -> [Int] { queries.keys.sorted() }
        func setHoldingCommands(_ value: Bool) { holdCommands = value }
        func setHoldingQueries(_ value: Bool) { holdQueries = value }
        func query(_ id: UUID) async throws -> HybridTransfer.RemoteJobStatus {
            guard id == ledger.status.id else { throw HybridTransfer.TransferError.failed("Unknown fixture job") }
            queryCount += 1
            let index = queryCount, value = ledger.status
            if holdQueries { return await withCheckedContinuation { queries[index] = (value, $0) } }
            return value
        }
        func command(_ command: HybridTransfer.RemoteJobCommand) async throws -> HybridTransfer.RemoteCommandReply {
            if let entry = ledger.entries.first(where: { $0.command.id == command.id }) {
                guard entry.command == command else { throw HybridTransfer.TransferError.failed("Fixture command ID collision") }
                return entry.reply
            }
            guard command.jobID == ledger.status.id, command.expectedRevision == ledger.status.controlRevision else {
                throw HybridTransfer.TransferError.failed("Fixture stale revision")
            }
            ledger.effects += 1
            ledger.status.state = command.action == .pause ? "paused" : "running"
            ledger.status.controlRevision = UUID()
            let reply = HybridTransfer.RemoteCommandReply(commandID: command.id, jobID: command.jobID, state: "accepted", status: ledger.status)
            ledger.entries.append(.init(command: command, reply: reply))
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
            if holdCommands { return await withCheckedContinuation { commands[command.id] = (reply, $0) } }
            return reply
        }
        func releaseCommand(_ id: UUID) {
            if let (reply, continuation) = commands.removeValue(forKey: id) { continuation.resume(returning: reply) }
        }
        func releaseQuery(_ index: Int) {
            if let (status, continuation) = queries.removeValue(forKey: index) { continuation.resume(returning: status) }
        }
        func releaseAll() {
            let heldCommands = commands, heldQueries = queries
            commands.removeAll(); queries.removeAll()
            for (_, (reply, continuation)) in heldCommands { continuation.resume(returning: reply) }
            for (_, (status, continuation)) in heldQueries { continuation.resume(returning: status) }
        }
        func result(_ source: HybridTransfer.ResultSource, id: UUID) throws -> HybridTransfer.ResultSource {
            guard id == source.descriptor.jobID else { throw HybridTransfer.TransferError.failed("Unknown result fixture") }
            resultCount += 1
            return source
        }
    }
    @MainActor private final class Fixture {
        let root: URL
        let capture: URL
        let receipts: URL
        let incoming: URL
        let jobID = UUID()
        let scan: ScanRecord
        let request = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 5000, downscale: 1)
        let sourceHashes: [URL: String]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridRemoteClientTests-" + UUID().uuidString)
            capture = root.appendingPathComponent("capture")
            receipts = root.appendingPathComponent("receipts")
            incoming = root.appendingPathComponent("incoming")
            let dataset = capture.appendingPathComponent("fuentes")
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
            try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
            try Data("Only isolated capture data".utf8).write(to: dataset.appendingPathComponent("source.bin"))
            let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
            try JSONEncoder().encode(mesh).write(to: capture.appendingPathComponent("malla.json"))
            scan = ScanRecord(id: UUID(), name: "Isolated remote source", mode: .lidar, createdAt: Date(timeIntervalSince1970: 100),
                vertexCount: 3, faceCount: 1, duration: 12, isDemo: false, note: "Fixture", modelFile: nil,
                exports: ["malla.json"], datasetDirectory: "fuentes")
            let files = [capture.appendingPathComponent("malla.json"), dataset.appendingPathComponent("dataset.json"), dataset.appendingPathComponent("source.bin")]
            sourceHashes = try Dictionary(uniqueKeysWithValues: files.map { ($0, try HybridTransfer.digest($0)) })
        }
        var ledgerURL: URL { root.appendingPathComponent("remote-ledger.json") }
        func seed(status: HybridTransfer.RemoteJobStatus? = nil) throws {
            try HybridDeliveryReceipt(scanID: scan.id, processingRequest: request, jobID: jobID,
                acknowledgedAt: Date(timeIntervalSince1970: 100), lastStatus: status, statusObservedAt: status == nil ? nil : Date(timeIntervalSince1970: 150)).save(in: receipts)
        }
        func controller(_ destination: HybridCaptureDestination? = nil) -> HybridDeliveryController {
            HybridDeliveryController(scan: scan, directory: capture, destination: destination, processingRequest: request, receiptDirectory: receipts)
        }
        func assertSourcesUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            for (url, sha) in sourceHashes { XCTAssertEqual(try HybridTransfer.digest(url), sha, file: file, line: line) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private struct Timeout: LocalizedError {
        var action: String
        var errorDescription: String? { "Remote controller fixture timed out: " + action }
    }
    @MainActor private func wait(_ action: String, until predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Timeout(action: action) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor private func destination(_ receiver: HybridTransferReceiver,
        transport: HybridCaptureDestination.Transport = .wifi) async throws -> HybridCaptureDestination {
        try await wait("listener") { receiver.listeningPort != nil }
        let raw = try XCTUnwrap(receiver.listeningPort), port = try XCTUnwrap(NWEndpoint.Port(rawValue: raw))
        return .init(peer: .init(id: "remote-fixture-" + UUID().uuidString, displayName: "Isolated paired receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: port), includePeerToPeer: transport == .nearby),
            pairingCode: receiver.pairingCode, transport: transport)
    }
    @MainActor private func start(_ receiver: HybridTransferReceiver, fixture: Fixture, remote: Remote,
                                  result: HybridTransfer.ResultSource? = nil) throws {
        let resultProvider: HybridTransfer.ResultProvider?
        if let result { resultProvider = { id in try await remote.result(result, id: id) } }
        else { resultProvider = nil }
        try receiver.start(directory: fixture.incoming, name: "Forma isolated remote client",
            onStatus: { try await remote.query($0) }, onCommand: { try await remote.command($0) },
            onResult: resultProvider) { _ in
                XCTFail("Remote control/result request must not publish an incoming capture")
            }
    }

    @MainActor
    func testLostReplyPersistsCommandAndColdControllerReplaysSameIDWithoutAnotherEffect() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver()
        let remote = try Remote(jobID: fixture.jobID, ledgerURL: fixture.ledgerURL)
        defer { receiver.stop(); Task { await remote.releaseAll() }; fixture.remove() }
        try fixture.seed(); try start(receiver, fixture: fixture, remote: remote)
        let target = try await destination(receiver), controller = fixture.controller(target)
        controller.refreshRemoteStatus()
        try await wait("initial capabilities") { !controller.checkingStatus && controller.availableRemoteCommands.contains(.pause) }
        await remote.setHoldingCommands(true)
        controller.sendRemoteCommand(.pause)
        try await wait("effect durably applied, reply withheld") { await remote.pendingCommands().count == 1 && controller.commanding }
        let pending = try XCTUnwrap(controller.pendingCommand)
        XCTAssertEqual(pending.jobID, fixture.jobID)
        XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts)?.pendingCommand, pending)
        receiver.stop()
        try await wait("lost reply observed") { !controller.commanding && controller.commandNotice?.contains("No se recibió confirmación") == true }
        XCTAssertEqual(controller.pendingCommand, pending)
        await remote.releaseAll()
        let committedEffects = await remote.effectCount()
        XCTAssertEqual(committedEffects, 1)

        // Both sides are reconstructed from their durable files; no live controller/ledger is reused.
        let restarted = try Remote(jobID: fixture.jobID, ledgerURL: fixture.ledgerURL)
        defer { Task { await restarted.releaseAll() } }
        try start(receiver, fixture: fixture, remote: restarted)
        let cold = fixture.controller(try await destination(receiver))
        XCTAssertEqual(cold.pendingCommand, pending)
        cold.retryRemoteCommand()
        try await wait("same UUID receipt recovered") { !cold.commanding && cold.pendingCommand == nil && cold.remoteStatus?.state == "paused" }
        let finalEffects = await restarted.effectCount()
        XCTAssertEqual(finalEffects, 1)
        let recoveredStatus = await restarted.currentStatus()
        XCTAssertEqual(cold.remoteStatus?.controlRevision, recoveredStatus.controlRevision)
        XCTAssertEqual(cold.remoteStatusLabel, "Pausado en tu Mac", "A confirmed paused backend state must not be described as an outstanding pause request")
        XCTAssertNil(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts)?.pendingCommand)
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testLateMonitorCannotOverwriteNewCommandReplyOrStartDuringCommand() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver()
        let remote = try Remote(jobID: fixture.jobID, ledgerURL: fixture.ledgerURL)
        defer { receiver.stop(); Task { await remote.releaseAll() }; fixture.remove() }
        try fixture.seed(); try start(receiver, fixture: fixture, remote: remote)
        let controller = fixture.controller(try await destination(receiver, transport: .nearby))
        controller.refreshRemoteStatus()
        try await wait("fresh initial status") { !controller.checkingStatus && controller.availableRemoteCommands.contains(.pause) }
        let oldRevision = controller.remoteStatus?.controlRevision
        await remote.setHoldingQueries(true)
        controller.refreshRemoteStatus()
        try await wait("old monitor held") { await remote.pendingQueries() == [2] }
        await remote.setHoldingCommands(true)
        controller.sendRemoteCommand(.pause)
        try await wait("command reply held") { await remote.pendingCommands().count == 1 && controller.commanding }
        let pending = try XCTUnwrap(controller.pendingCommand)
        controller.refreshRemoteStatus()
        try await Task.sleep(for: .milliseconds(100))
        let queryCount = await remote.queryCalls()
        XCTAssertEqual(queryCount, 2, "A query started while commanding can carry an old control revision beyond the new reply")
        await remote.releaseCommand(pending.id)
        try await wait("new command reply applied") { !controller.commanding && controller.pendingCommand == nil && controller.remoteStatus?.state == "paused" }
        let newRevision = try XCTUnwrap(controller.remoteStatus?.controlRevision)
        XCTAssertNotEqual(newRevision, oldRevision)
        await remote.releaseQuery(2)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(controller.remoteStatus?.state, "paused")
        XCTAssertEqual(controller.remoteStatus?.controlRevision, newRevision)
        let saved = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        XCTAssertEqual(saved.lastStatus?.controlRevision, newRevision)
        controller.stopRemoteMonitoring()
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testDownloadedResultPublishesWithSourceAndColdOfflineRecoveryDoesNotDuplicate() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver()
        let remote = try Remote(jobID: fixture.jobID, ledgerURL: fixture.ledgerURL)
        defer { receiver.stop(); Task { await remote.releaseAll() }; fixture.remove() }
        let published = fixture.root.appendingPathComponent("published"), package = published.appendingPathComponent("modelo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let model = package.appendingPathComponent("modelo.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: model)
        try FileManager.default.copyItem(at: fixture.capture.appendingPathComponent("malla.json"), to: published.appendingPathComponent("malla.json"))
        let descriptor = HybridTransfer.ResultDescriptor(jobID: fixture.jobID, resultID: UUID(), name: "Derived isolated room", mode: "lidar", duration: 12,
            note: "Verified derivative", statistics: ["faces": 1], modelRelativePath: "modelo/modelo.obj", packageRelativePath: "modelo", meshRelativePath: "malla.json")
        let result = HybridTransfer.ResultSource(descriptor: descriptor, directory: published)
        try fixture.seed(); try start(receiver, fixture: fixture, remote: remote, result: result)
        let library = ScanStore(baseURL: fixture.root.appendingPathComponent("library"))
        let controller = fixture.controller(try await destination(receiver, transport: .nearby))
        controller.downloadResult(library: library)
        try await wait("download and publication") { !controller.receivingResult && !controller.savingResult && controller.savedResult != nil }
        let saved = try XCTUnwrap(controller.savedResult), bundle = try XCTUnwrap(controller.downloadedResult)
        XCTAssertEqual(library.scans.count, 1)
        XCTAssertEqual(saved.sourceScanID, fixture.scan.id)
        XCTAssertNil(saved.datasetDirectory)
        XCTAssertEqual(saved.hybridResultProvenance?.jobID, fixture.jobID)
        XCTAssertEqual(saved.hybridResultProvenance?.resultID, descriptor.resultID)
        XCTAssertEqual(saved.hybridResultProvenance?.manifestSHA256, bundle.manifestSHA256)
        XCTAssertEqual(try HybridTransfer.digest(try XCTUnwrap(library.modelURL(for: saved))), try HybridTransfer.digest(model))
        let receipt = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        XCTAssertTrue(try XCTUnwrap(receipt.downloadedResultDirectory).hasPrefix("results/"))
        receiver.stop()

        let cold = fixture.controller()
        cold.startIfNeeded()
        try await wait("complete bundle recovered without a connection") { cold.downloadedResult != nil }
        await cold.saveDownloadedResult(in: library)
        XCTAssertEqual(cold.savedResult?.id, saved.id)
        XCTAssertEqual(library.scans.count, 1)
        let reopenedLibrary = ScanStore(baseURL: library.baseURL)
        let reopened = fixture.controller()
        reopened.startIfNeeded()
        try await wait("second cold bundle recovery") { reopened.downloadedResult != nil }
        await reopened.saveDownloadedResult(in: reopenedLibrary)
        XCTAssertEqual(reopened.savedResult?.id, saved.id)
        XCTAssertEqual(reopenedLibrary.scans.count, 1)
        let resultCalls = await remote.resultCalls()
        XCTAssertEqual(resultCalls, 1, "Offline recovery must not download a second copy")
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testAcknowledgementFromFirstMacDoesNotConfirmEmptySecondMacBeforeItsOwnTransferACK() async throws {
        let fixture = try Fixture(), first = HybridTransferReceiver(), second = HybridTransferReceiver()
        let firstACK = AcknowledgementGate(), secondACK = AcknowledgementGate()
        let firstIncoming = fixture.root.appendingPathComponent("first-mac"), secondIncoming = fixture.root.appendingPathComponent("second-mac")
        defer {
            firstACK.release(); secondACK.release(); first.stop(); second.stop(); fixture.remove()
        }
        firstACK.release()
        try first.start(directory: firstIncoming, name: "First isolated Mac",
            acknowledgementPolicy: { _ in firstACK.acknowledge() }, onStatus: { id in
                .init(id: id, state: "queued", progress: 0, resultAvailable: false)
            }) { firstACK.didReceive($0.id) }
        try second.start(directory: secondIncoming, name: "Empty second isolated Mac",
            acknowledgementPolicy: { _ in secondACK.acknowledge() }, onStatus: { id in
                .init(id: id, state: "unknown", progress: 0, resultAvailable: false)
            }) { secondACK.didReceive($0.id) }
        let firstTarget = try await destination(first), secondTarget = try await destination(second)
        let controller = fixture.controller(firstTarget)
        defer { controller.stopRemoteMonitoring(); controller.cancel() }
        controller.send()
        try await wait("first Mac confirms source delivery") {
            !controller.transferring && controller.remoteJobID != nil && controller.destinationAcknowledgedAt != nil
        }
        let jobID = try XCTUnwrap(controller.remoteJobID), firstDate = try XCTUnwrap(controller.destinationAcknowledgedAt)
        try await wait("first receiver published one capture") { firstACK.received == [jobID] }
        controller.refreshRemoteStatus()
        try await wait("first Mac query is current") { !controller.checkingStatus && controller.remoteStatus?.state == "queued" }
        XCTAssertTrue(controller.remoteStatusIsCurrentDestination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: secondIncoming.path).count, 0)

        controller.selectDestination(secondTarget)
        XCTAssertNil(controller.destinationAcknowledgedAt, "A valid ACK from A is not an ACK from the newly selected B")
        XCTAssertNil(controller.remoteStatus)
        XCTAssertFalse(controller.remoteStatusIsCurrentDestination)
        XCTAssertFalse(controller.status.contains("confirmó todos"))
        XCTAssertTrue(controller.status.contains("Entrega anterior"))
        let history = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        XCTAssertEqual(history.acknowledgedAt, firstDate, "Changing a connection must preserve historical evidence")
        controller.refreshRemoteStatus()
        try await wait("second Mac honestly reports unknown") { !controller.checkingStatus && controller.remoteStatus?.state == "unknown" }
        XCTAssertNil(controller.destinationAcknowledgedAt, "An authenticated status query does not verify every source file")
        XCTAssertFalse(controller.status.contains("confirmó todos"))

        controller.send(verifyingDelivery: true)
        try await wait("second Mac committed files but has not sent its ACK") { secondACK.waiting && controller.transferring }
        XCTAssertNil(controller.destinationAcknowledgedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondIncoming.appendingPathComponent(jobID.uuidString + "/.transfer.json").path))
        XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts)?.acknowledgedAt, firstDate)
        secondACK.release()
        try await wait("second Mac ACK confirms this selected connection") {
            !controller.transferring && controller.destinationAcknowledgedAt != nil
        }
        try await wait("second receiver published capture") { secondACK.received == [jobID] }
        let secondDate = try XCTUnwrap(controller.destinationAcknowledgedAt)
        XCTAssertGreaterThan(secondDate, firstDate)
        XCTAssertEqual(controller.remoteJobID, jobID)
        XCTAssertNil(controller.error)
        let final = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        XCTAssertEqual(final.acknowledgedAt, secondDate, "Each successful resend records its actual ACK time")
        XCTAssertEqual(final.firstAcknowledgedAt, firstDate, "The original ACK remains historical evidence")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: firstIncoming.path), [jobID.uuidString])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: secondIncoming.path), [jobID.uuidString])
        let cold = fixture.controller(secondTarget)
        XCTAssertNil(cold.destinationAcknowledgedAt, "Loading an old receipt cannot authenticate a new pairing session")
        XCTAssertFalse(cold.status.contains("confirmó todos"))
        XCTAssertTrue(cold.status.contains("Entrega anterior"))
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testReceiptRejectsPendingCommandForAnotherJobBeforeColdRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed()
        let validURL = fixture.receipts.appendingPathComponent(try HybridDeliveryReceipt.key(scanID: fixture.scan.id, request: fixture.request) + ".json")
        let valid = try Data(contentsOf: validURL)
        var malformed = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        malformed.pendingCommand = .init(id: UUID(), jobID: UUID(), action: .resume, expectedRevision: UUID())
        XCTAssertThrowsError(try malformed.save(in: fixture.receipts))
        XCTAssertEqual(try Data(contentsOf: validURL), valid)
        try JSONEncoder().encode(malformed).write(to: validURL, options: .atomic)
        let cold = fixture.controller()
        XCTAssertNotNil(cold.error)
        XCTAssertNil(cold.pendingCommand)
        XCTAssertNil(cold.remoteJobID)
    }
}
