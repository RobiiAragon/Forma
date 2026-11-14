import XCTest
import Network
import UIKit
@testable import Forma

/// Production controller and receiver, using only temporary captures and localhost TCP.
final class HybridDeliveryControllerTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL
        let sourceDirectory: URL
        let dataset: URL
        let receipts: URL
        let incoming: URL
        let scan: ScanRecord
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
        let request = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 5000, downscale: 1)
        let sourceHashes: [String: String]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridControllerTests-\(UUID().uuidString)")
            sourceDirectory = root.appendingPathComponent("capture")
            dataset = sourceDirectory.appendingPathComponent("fuentes")
            receipts = root.appendingPathComponent("receipts")
            incoming = root.appendingPathComponent("incoming")
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
            try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
            try Data((0..<(2*1024*1024+19)).map { UInt8($0 % 251) }).write(to: dataset.appendingPathComponent("source.bin"))
            try JSONEncoder().encode(mesh).write(to: sourceDirectory.appendingPathComponent("malla.json"))
            scan = ScanRecord(id: UUID(), name: "Isolated hybrid fixture", mode: .lidar, createdAt: Date(timeIntervalSince1970: 100),
                vertexCount: 3, faceCount: 1, duration: 9, isDemo: false, note: "Test only", modelFile: nil,
                exports: ["malla.json"], datasetDirectory: "fuentes")
            sourceHashes = try Dictionary(uniqueKeysWithValues: [dataset.appendingPathComponent("source.bin"),
                dataset.appendingPathComponent("dataset.json"), sourceDirectory.appendingPathComponent("malla.json")].map { ($0.path, try HybridTransfer.digest($0)) })
        }
        func assertSourcesUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            for (path, expected) in sourceHashes { XCTAssertEqual(try HybridTransfer.digest(URL(fileURLWithPath: path)), expected, file: file, line: line) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dataset.path).sorted(), ["dataset.json", "source.bin"], file: file, line: line)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func controller(destination: HybridCaptureDestination?) -> HybridDeliveryController {
            HybridDeliveryController(scan: scan, directory: sourceDirectory, destination: destination,
                processingRequest: request, receiptDirectory: receipts)
        }
        func seedReceipt(jobID: UUID, status: HybridTransfer.RemoteJobStatus? = nil, observedAt: Date? = nil) throws {
            try HybridDeliveryReceipt(scanID: scan.id, processingRequest: request, jobID: jobID,
                acknowledgedAt: Date(timeIntervalSince1970: 100), lastStatus: status, statusObservedAt: observedAt).save(in: receipts)
        }
    }
    private final class AckGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var armed = false
        private var entered = false
        private var released = false
        private var receiveCount = 0
        func arm() { condition.lock(); armed = true; entered = false; released = false; condition.unlock() }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return entered && !released }
        var received: Int { condition.lock(); defer { condition.unlock() }; return receiveCount }
        func didReceive() { condition.lock(); receiveCount += 1; condition.unlock() }
        func acknowledge() -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard armed else { return true }
            entered = true
            let deadline = Date().addingTimeInterval(30)
            while !released { if !condition.wait(until: deadline) { return false } }
            return true
        }
    }
    private actor StatusGate {
        private var call = 0
        private var hold = false
        private var pending: [Int: (UUID, CheckedContinuation<HybridTransfer.RemoteJobStatus, Never>)] = [:]
        private var value: HybridTransfer.RemoteJobStatus
        init(jobID: UUID) { value = .init(id: jobID, state: "completed", progress: 1, iteration: 5000, targetIterations: 5000, splats: 430000, resultAvailable: true) }
        func setHolding(_ hold: Bool) { self.hold = hold }
        func count() -> Int { call }
        func pendingCalls() -> [Int] { pending.keys.sorted() }
        func query(_ id: UUID) async throws -> HybridTransfer.RemoteJobStatus {
            call += 1; let sequence = call
            if hold {
                return await withCheckedContinuation { continuation in pending[sequence] = (id, continuation) }
            }
            var result = value; result.id = id; return result
        }
        func release(_ sequence: Int, state: String, progress: Double, resultAvailable: Bool) {
            guard let (id, continuation) = pending.removeValue(forKey: sequence) else { return }
            continuation.resume(returning: .init(id: id, state: state, progress: progress,
                iteration: Int(progress * 5000), targetIterations: 5000, splats: 425928, resultAvailable: resultAvailable))
        }
        func releaseAll() {
            let current = pending; pending.removeAll()
            for (_, (id, continuation)) in current { var result = value; result.id = id; continuation.resume(returning: result) }
        }
    }
    private struct Deadline: LocalizedError {
        var operation: String
        var errorDescription: String? { "Controller test timed out: " + operation }
    }
    @MainActor private func wait(_ operation: String, seconds: TimeInterval = 35,
                                until condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Deadline(operation: operation) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor private func destination(_ receiver: HybridTransferReceiver) async throws -> HybridCaptureDestination {
        try await wait("localhost listener") { receiver.listeningPort != nil }
        let port = try XCTUnwrap(receiver.listeningPort)
        let endpoint = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let peer = HybridTransfer.Peer(id: "fixture-\(UUID().uuidString)", displayName: "Isolated local receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: endpoint))
        return .init(peer: peer, pairingCode: receiver.pairingCode, transport: .wifi)
    }

    @MainActor
    func testAcknowledgedVerificationCanPauseResumeCancelAndRetryThroughRealReceiver() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver(), ack = AckGate()
        defer { ack.release(); receiver.stop(); fixture.remove() }
        try receiver.start(directory: fixture.incoming, name: "Forma isolated controller ACK",
            acknowledgementPolicy: { _ in ack.acknowledge() }) { _ in ack.didReceive() }
        let target = try await destination(receiver), peer = try XCTUnwrap(target.peer)
        let dataset = fixture.dataset, mesh = fixture.mesh, request = fixture.request, code = target.pairingCode
        let seed = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: peer, pairingCode: code, processingRequest: request)
        }.value
        try await wait("seed capture acknowledged") { ack.received == 1 }
        try fixture.seedReceipt(jobID: seed)
        let controller = fixture.controller(destination: target)
        defer { controller.stopRemoteMonitoring(); controller.cancel() }
        XCTAssertEqual(controller.remoteJobID, seed)
        ack.arm(); controller.send(verifyingDelivery: true)
        try await wait("verification waiting at real receiver ACK") { ack.isWaiting && controller.transferring }
        var wrongTarget = target; wrongTarget.pairingCode = "00112233445566778899aabbccddeeff"
        controller.selectDestination(wrongTarget)
        XCTAssertEqual(controller.destination?.pairingCode, target.pairingCode, "An active transfer must keep its selected destination")
        controller.pause()
        try await wait("verification manually paused") { !controller.transferring && controller.pausedByUser }
        XCTAssertEqual(controller.remoteJobID, seed)
        XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: request, in: fixture.receipts)?.jobID, seed)
        ack.release(); try await wait("cancelled connection released receiver lease") { ack.received == 2 }
        // The normal resume entry point must retain verification mode despite an existing receipt.
        controller.send()
        try await wait("verification resumed with original job identity") { !controller.transferring && controller.progress == 1 && !controller.pausedByUser }
        XCTAssertNil(controller.error); XCTAssertEqual(controller.remoteJobID, seed)
        XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: request, in: fixture.receipts)?.sourceConnectionUsesWiFi, false, "The controller must persist the actual loopback payload route")
        try await wait("resumed receipt callback") { ack.received == 3 }

        ack.arm(); controller.send(verifyingDelivery: true)
        try await wait("second verification held") { ack.isWaiting && controller.transferring }
        controller.cancel()
        try await wait("explicit cancellation") { !controller.transferring && !controller.pausedByUser }
        ack.release(); try await wait("explicit cancellation released receiver lease") { ack.received == 4 }
        controller.send()
        XCTAssertFalse(controller.transferring, "An explicit cancellation must not implicitly start a second delivery from an existing receipt")
        controller.send(verifyingDelivery: true)
        try await wait("explicitly requested retry completed") { !controller.transferring && controller.progress == 1 && controller.error == nil }
        try await wait("retry callback") { ack.received == 5 }
        XCTAssertEqual(controller.remoteJobID, seed)
        let finalDirectories = try FileManager.default.contentsOfDirectory(at: fixture.incoming, includingPropertiesForKeys: nil)
        XCTAssertEqual(finalDirectories.map(\.lastPathComponent), [seed.uuidString])
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testClosingAndReopeningMonitorRejectsOldGenerationAndPersistsFreshStatus() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver(), jobID = UUID()
        let observed = Date(timeIntervalSince1970: 150)
        let cached = HybridTransfer.RemoteJobStatus(id: jobID, state: "running", progress: 0.25,
            iteration: 1250, targetIterations: 5000, splats: 425928, resultAvailable: false)
        try fixture.seedReceipt(jobID: jobID, status: cached, observedAt: observed)
        let gate = StatusGate(jobID: jobID)
        defer { Task { await gate.releaseAll() }; receiver.stop(); fixture.remove() }
        try receiver.start(directory: fixture.incoming, name: "Forma isolated status generations",
            onStatus: { id in try await gate.query(id) }) { _ in XCTFail("Status query published a source job") }
        let target = try await destination(receiver), controller = fixture.controller(destination: target)
        defer { controller.stopRemoteMonitoring(); controller.cancel() }
        XCTAssertEqual(controller.remoteStatus, cached); XCTAssertEqual(controller.statusObservedAt, observed)
        await gate.setHolding(true)
        controller.startRemoteMonitoring()
        try await wait("first status provider pending") { await gate.pendingCalls() == [1] && controller.checkingStatus }
        controller.stopRemoteMonitoring()
        XCTAssertFalse(controller.checkingStatus)
        controller.startRemoteMonitoring()
        try await wait("reopened monitor uses a second connection") { await gate.pendingCalls() == [1, 2] && controller.checkingStatus }
        await gate.release(1, state: "running", progress: 0.9, resultAvailable: false)
        await Task.yield(); await Task.yield()
        XCTAssertTrue(controller.checkingStatus, "Old query cleanup must not clear the new generation's in-flight state")
        XCTAssertEqual(controller.remoteStatus, cached, "A late response from a closed monitor must not replace cached status")
        XCTAssertEqual(controller.statusObservedAt, observed)
        await gate.release(2, state: "completed", progress: 1, resultAvailable: true)
        try await wait("new generation completed") { !controller.checkingStatus && controller.remoteStatus?.resultAvailable == true }
        XCTAssertNil(controller.statusError)
        let freshDate = try XCTUnwrap(controller.statusObservedAt)
        XCTAssertGreaterThan(freshDate, observed)
        let saved = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts))
        XCTAssertEqual(saved.lastStatus, controller.remoteStatus); XCTAssertEqual(saved.statusObservedAt, freshDate)
        controller.stopRemoteMonitoring()
        let calls = await gate.count()
        try await Task.sleep(for: .milliseconds(100))
        let callsAfterClose = await gate.count()
        XCTAssertEqual(callsAfterClose, calls)
        let cold = fixture.controller(destination: nil)
        cold.startIfNeeded()
        XCTAssertFalse(cold.transferring); XCTAssertFalse(cold.checkingStatus)
        XCTAssertEqual(cold.remoteJobID, jobID); XCTAssertEqual(cold.remoteStatus, saved.lastStatus)
        XCTAssertEqual(cold.statusObservedAt, freshDate, "A cold load must preserve the historical observation time, rather than inventing a new query")
        try fixture.assertSourcesUnchanged()
    }

    @MainActor
    func testTransientAuthenticationFailureRetainsHistoricalReceiptAndCanReconnect() async throws {
        let fixture = try Fixture(), receiver = HybridTransferReceiver(), jobID = UUID()
        let observed = Date(timeIntervalSince1970: 150)
        let cached = HybridTransfer.RemoteJobStatus(id: jobID, state: "running", progress: 0.25,
            iteration: 1250, targetIterations: 5000, splats: 425928, resultAvailable: false)
        try fixture.seedReceipt(jobID: jobID, status: cached, observedAt: observed)
        let gate = StatusGate(jobID: jobID)
        defer { Task { await gate.releaseAll() }; receiver.stop(); fixture.remove() }
        try receiver.start(directory: fixture.incoming, name: "Forma isolated reconnect",
            onStatus: { id in try await gate.query(id) }) { _ in XCTFail("Status query published a source job") }
        let correct = try await destination(receiver)
        var incorrect = correct; incorrect.pairingCode = "00112233445566778899aabbccddeeff"
        let controller = fixture.controller(destination: incorrect)
        defer { controller.stopRemoteMonitoring(); controller.cancel() }
        controller.refreshRemoteStatus()
        try await wait("wrong key reported") { !controller.checkingStatus && controller.statusError != nil }
        let unauthenticatedCalls = await gate.count()
        XCTAssertEqual(unauthenticatedCalls, 0, "Incorrect pairing must not reach the status provider")
        XCTAssertEqual(controller.remoteStatus, cached); XCTAssertEqual(controller.statusObservedAt, observed)
        XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: fixture.scan.id, request: fixture.request, in: fixture.receipts)?.lastStatus, cached)
        controller.selectDestination(correct)
        XCTAssertNil(controller.remoteStatus); XCTAssertNil(controller.statusObservedAt)
        controller.refreshRemoteStatus()
        try await wait("authenticated reconnect completed") { !controller.checkingStatus && controller.remoteStatus?.resultAvailable == true }
        XCTAssertNil(controller.statusError)
        XCTAssertEqual(controller.remoteJobID, jobID)
        XCTAssertGreaterThan(try XCTUnwrap(controller.statusObservedAt), observed)
        let authenticatedCalls = await gate.count()
        XCTAssertEqual(authenticatedCalls, 1)
        try fixture.assertSourcesUnchanged()
    }
}
