import XCTest
import Network
@testable import Forma

/// Production TCP protocol with authored local files; never contacts an iPhone or GPU.
final class HybridTransferPreparationTests: XCTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        @discardableResult func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
        var snapshot: Value { update { $0 } }
    }
    private enum Event {
        case stage(HybridTransfer.TransferStage)
        case progress(Double)
        case metrics(HybridTransfer.TransferMetrics)
    }
    private struct Fixture {
        let root: URL
        let dataset: URL
        let mesh: MeshSnapshot
        let request: HybridTransfer.ProcessingRequest
        let sourceHashes: [String: String]
        let totalBytes: Int64
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridPreparationTests-\(UUID().uuidString)")
        let dataset = root.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
        try Data((0..<(2 * HybridTransfer.chunkBytes + 19)).map { UInt8($0 % 251) }).write(to: dataset.appendingPathComponent("payload.bin"))
        try Data().write(to: dataset.appendingPathComponent("empty.bin"))
        let mesh = MeshSnapshot(vertices: [.init(0,0,0), .init(1,0,0), .init(0,1,0)], triangles: [0,1,2])
        let request = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 5000, downscale: 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let files = try FileManager.default.contentsOfDirectory(at: dataset, includingPropertiesForKeys: nil)
        let hashes = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try HybridTransfer.digest($0)) })
        let total = try files.reduce(Int64(0)) { try $0 + HybridTransfer.size($1) } + Int64(encoder.encode(mesh).count + encoder.encode(request).count)
        return Fixture(root: root, dataset: dataset, mesh: mesh, request: request, sourceHashes: hashes, totalBytes: total)
    }
    @MainActor private func peer(_ receiver: HybridTransferReceiver) async throws -> HybridTransfer.Peer {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) {
                return .init(id: "preparation-loopback", displayName: "Preparation loopback", endpoint: .hostPort(host: "127.0.0.1", port: port))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HybridTransfer.TransferError.failed("Fixture listener did not become ready")
    }
    private func assertSourcesUnchanged(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try FileManager.default.contentsOfDirectory(at: fixture.dataset, includingPropertiesForKeys: nil)
        let actual = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try HybridTransfer.digest($0)) })
        XCTAssertEqual(actual, fixture.sourceHashes, file: file, line: line)
    }
    private func assertPreparation(_ events: [Event], expectedTotal: Int64, verified: Bool,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let stages = events.compactMap { event -> HybridTransfer.TransferStage? in if case .stage(let value) = event { return value }; return nil }
        XCTAssertEqual(stages.first, .connecting, file: file, line: line)
        XCTAssertEqual(stages.dropFirst().first, .authenticating, file: file, line: line)
        XCTAssertEqual(stages.filter { $0 == .connecting }.count, 1, file: file, line: line)
        XCTAssertEqual(stages.filter { $0 == .authenticating }.count, 1, file: file, line: line)
        XCTAssertEqual(stages.filter { $0 == .negotiating }.count, 1, file: file, line: line)
        XCTAssertEqual(stages.filter { $0 == .verifying }.count, verified ? 1 : 0, file: file, line: line)
        let hashing = stages.compactMap { stage -> (Double, Double)? in
            if case .hashing(let completed, let total) = stage { return (completed, total) }; return nil
        }
        XCTAssertGreaterThan(hashing.count, 3, "The multi-chunk fixture must report preparation progress", file: file, line: line)
        XCTAssertEqual(hashing.first?.0, 0, file: file, line: line)
        XCTAssertEqual(hashing.last?.0, Double(expectedTotal), file: file, line: line)
        for (index, value) in hashing.enumerated() {
            XCTAssertEqual(value.1, Double(expectedTotal), file: file, line: line)
            XCTAssertGreaterThanOrEqual(value.0, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(value.0, value.1, file: file, line: line)
            if index > 0 { XCTAssertGreaterThanOrEqual(value.0, hashing[index - 1].0, file: file, line: line) }
        }
        let negotiation = try XCTUnwrap(events.firstIndex { if case .stage(.negotiating) = $0 { return true }; return false }, file: file, line: line)
        let firstPayload = try XCTUnwrap(events.firstIndex { if case .progress = $0 { return true }; return false }, file: file, line: line)
        XCTAssertLessThan(negotiation, firstPayload, file: file, line: line)
        for (index, event) in events.enumerated() {
            if case .stage(.hashing) = event { XCTAssertLessThan(index, negotiation, file: file, line: line) }
        }
        let progress = events.compactMap { event -> Double? in if case .progress(let value) = event { return value }; return nil }
        XCTAssertEqual(progress.last, 1, file: file, line: line)
        XCTAssertTrue(progress.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, file: file, line: line)
    }

    @MainActor
    func testRealTCPPreparationStagesCountEveryByteBeforePayloadAndReportActualLoopbackRoute() async throws {
        let fixture = try fixture(), receiver = HybridTransferReceiver()
        let jobs = Locked<[HybridTransfer.ReceivedJob]>([]), events = Locked<[Event]>([])
        try receiver.start(directory: fixture.root.appendingPathComponent("incoming"), name: "Preparation fixture " + UUID().uuidString) { job in jobs.update { $0.append(job) } }
        defer { receiver.stop() }
        let endpoint = try await peer(receiver)
        let job = try await HybridTransfer.send(datasetDirectory: fixture.dataset, mesh: fixture.mesh, duration: 7, to: endpoint,
            pairingCode: receiver.pairingCode, processingRequest: fixture.request,
            stage: { value in events.update { $0.append(.stage(value)) } },
            metrics: { value in events.update { $0.append(.metrics(value)) } },
            progress: { value in events.update { $0.append(.progress(value)) } })
        try assertPreparation(events.snapshot, expectedTotal: fixture.totalBytes, verified: true)
        let metrics = try XCTUnwrap(events.snapshot.compactMap { event -> HybridTransfer.TransferMetrics? in if case .metrics(let value) = event { return value }; return nil }.last)
        XCTAssertEqual(metrics.connectionUsesWiFi, false, "Observe the actual source payload channel, not a separate probe")
        XCTAssertEqual(metrics.transmittedPayloadBytes, fixture.totalBytes)
        XCTAssertEqual(metrics.resumedPayloadBytes, 0); XCTAssertFalse(metrics.alreadyCommitted)
        let received = fixture.root.appendingPathComponent("incoming/" + job.uuidString)
        for name in fixture.sourceHashes.keys {
            XCTAssertEqual(try HybridTransfer.digest(received.appendingPathComponent("dataset/" + name)), fixture.sourceHashes[name])
        }
        let savedMesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: received.appendingPathComponent("malla-original.json")))
        XCTAssertEqual(savedMesh.vertices, fixture.mesh.vertices); XCTAssertEqual(savedMesh.triangles, fixture.mesh.triangles)
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testCommittedRetryPreparesAndAuthenticatesAgainButSendsNoPayloadAndPreservesRoute() async throws {
        let fixture = try fixture(), receiver = HybridTransferReceiver(), events = Locked<[Event]>([])
        let incoming = fixture.root.appendingPathComponent("incoming")
        try receiver.start(directory: incoming, name: "Committed fixture " + UUID().uuidString) { _ in }
        defer { receiver.stop() }
        let endpoint = try await peer(receiver), code = receiver.pairingCode
        let first = try await HybridTransfer.send(datasetDirectory: fixture.dataset, mesh: fixture.mesh, duration: 7,
            to: endpoint, pairingCode: code, processingRequest: fixture.request)
        let second = try await HybridTransfer.send(datasetDirectory: fixture.dataset, mesh: fixture.mesh, duration: 7,
            to: endpoint, pairingCode: code, processingRequest: fixture.request,
            stage: { value in events.update { $0.append(.stage(value)) } },
            metrics: { value in events.update { $0.append(.metrics(value)) } },
            progress: { value in events.update { $0.append(.progress(value)) } })
        XCTAssertEqual(second, first)
        try assertPreparation(events.snapshot, expectedTotal: fixture.totalBytes, verified: false)
        let metrics = try XCTUnwrap(events.snapshot.compactMap { event -> HybridTransfer.TransferMetrics? in if case .metrics(let value) = event { return value }; return nil }.last)
        XCTAssertTrue(metrics.alreadyCommitted); XCTAssertEqual(metrics.transmittedPayloadBytes, 0)
        XCTAssertEqual(metrics.resumedPayloadBytes, fixture.totalBytes)
        XCTAssertEqual(metrics.connectionUsesWiFi, false)
        let folders = try FileManager.default.contentsOfDirectory(atPath: incoming.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(folders, [first.uuidString])
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testCancellationDuringHashingDoesNotAdvanceToNegotiationOrPublishPayloadProgress() async throws {
        let fixture = try fixture(), receiver = HybridTransferReceiver(), events = Locked<[Event]>([])
        let taskHandle = Locked<Task<UUID, Error>?>(nil), received = Locked(0)
        let incoming = fixture.root.appendingPathComponent("incoming")
        try receiver.start(directory: incoming, name: "Hash cancellation fixture " + UUID().uuidString) { _ in received.update { $0 += 1 } }
        defer { receiver.stop() }
        let endpoint = try await peer(receiver), code = receiver.pairingCode
        let task = Task {
            try await HybridTransfer.send(datasetDirectory: fixture.dataset, mesh: fixture.mesh, duration: 7,
                to: endpoint, pairingCode: code, processingRequest: fixture.request,
                stage: { value in
                    events.update { $0.append(.stage(value)) }
                    if case .hashing(let completed, let total) = value, completed >= Double(HybridTransfer.chunkBytes), completed < total {
                        taskHandle.snapshot?.cancel()
                    }
                }, progress: { value in events.update { $0.append(.progress(value)) } })
        }
        taskHandle.update { $0 = task }
        do { _ = try await task.value; XCTFail("A manually cancelled hash pass must stop before negotiation") }
        catch is CancellationError { }
        XCTAssertFalse(events.snapshot.contains { if case .stage(.negotiating) = $0 { return true }; return false })
        XCTAssertFalse(events.snapshot.contains { if case .progress = $0 { return true }; return false })
        XCTAssertEqual(received.snapshot, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty)
        try assertSourcesUnchanged(fixture)
    }

    func testReceiptPreservesTrueFalseAndLegacyUnknownPayloadRouteWithoutSessionSecrets() throws {
        let fixture = try fixture(), receipts = fixture.root.appendingPathComponent("receipts"), scan = UUID()
        var receipt = HybridDeliveryReceipt(scanID: scan, processingRequest: fixture.request, jobID: UUID(), acknowledgedAt: Date(timeIntervalSince1970: 100))
        for observed in [false, true] {
            receipt.sourceConnectionUsesWiFi = observed
            try receipt.save(in: receipts)
            XCTAssertEqual(try HybridDeliveryReceipt.load(scanID: scan, request: fixture.request, in: receipts)?.sourceConnectionUsesWiFi, observed)
        }
        let file = receipts.appendingPathComponent(try HybridDeliveryReceipt.key(scanID: scan, request: fixture.request) + ".json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "sourceConnectionUsesWiFi")
        try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys).write(to: file, options: .atomic)
        let decoded = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: scan, request: fixture.request, in: receipts))
        XCTAssertNil(decoded.sourceConnectionUsesWiFi, "An old receipt must not invent that its payload used Wi-Fi")
        XCTAssertEqual(decoded.jobID, receipt.jobID)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("pairingCode")); XCTAssertFalse(text.contains("sessionKey"))
    }
}
