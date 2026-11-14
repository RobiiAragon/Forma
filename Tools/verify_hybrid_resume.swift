import Foundation
import Network
import CryptoKit

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update<T>(_ operation: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation(&value) }
    var snapshot: Value { update { $0 } }
}

/// Exercises the production encrypted protocol over real loopback TCP connections.
@main
struct HybridResumeVerification {
    @MainActor static func wait(_ message: String, until predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw HybridTransfer.TransferError.failed("Timed out: " + message)
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HybridTransfer.TransferError.failed(message) }
    }
    @MainActor static func peer(_ receiver: HybridTransferReceiver) async throws -> HybridTransfer.Peer {
        try await wait("listener ready") { receiver.listeningPort != nil }
        guard let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) else { fatalError("missing port") }
        return .init(id: "loopback", displayName: "Loopback", endpoint: .hostPort(host: "127.0.0.1", port: port))
    }
    static func legacySend(dataset: URL, mesh: MeshSnapshot, peer: HybridTransfer.Peer, code: String) async throws -> UUID {
        let key = try HybridTransfer.pairingKey(code)
        let channel = HybridTransfer.Channel(NWConnection(to: peer.endpoint, using: .tcp))
        defer { channel.cancel() }
        try await channel.start()
        let challenge = try await channel.readExactly(32)
        try await channel.write(Data(HMAC<SHA256>.authenticationCode(for: challenge + Data("client".utf8), using: key)))
        let answer = try await channel.readExactly(32)
        try require(HMAC<SHA256>.isValidAuthenticationCode(answer, authenticating: challenge + Data("server".utf8), using: key), "Legacy authentication failed")
        let cipher = HybridTransfer.Cipher(channel: channel, pairingKey: key, challenge: challenge, sending: "client", receiving: "server")
        let encoder = JSONEncoder(), id = UUID()
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "job", jobID: id, duration: 7)))
        let meshData = try encoder.encode(mesh)
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "file", path: "malla-original.json", bytes: Int64(meshData.count), sha256: HybridTransfer.hex(SHA256.hash(data: meshData)))))
        try await cipher.send(meshData)
        for name in ["dataset.json", "empty.bin", "native-source.bin"] {
            let url = dataset.appendingPathComponent(name)
            try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "file", path: "dataset/" + name, bytes: HybridTransfer.size(url), sha256: HybridTransfer.digest(url))))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: HybridTransfer.chunkBytes), !bytes.isEmpty { try await cipher.send(bytes) }
        }
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "done")))
        let acknowledgement = try await cipher.receive()
        try require(acknowledgement == Data("verified".utf8), "Legacy commit was not acknowledged")
        return id
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FormaHybridResume-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let dataset = root.appendingPathComponent("sources")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: false)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
        let fixture = dataset.appendingPathComponent("native-source.bin")
        try Data((0..<(8*1024*1024+33)).map { UInt8($0 % 251) }).write(to: fixture)
        try Data().write(to: dataset.appendingPathComponent("empty.bin"))
        let originalSHA = try HybridTransfer.digest(fixture)
        let originalManifestSHA = try HybridTransfer.digest(dataset.appendingPathComponent("dataset.json"))
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
        let incoming = root.appendingPathComponent("incoming")
        var received: [UUID: HybridTransfer.ReceivedJob] = [:], receiveEvents = 0
        var receiver = HybridTransferReceiver()
        try receiver.start(directory: incoming, name: "Forma resume verification") { job in
            Task { @MainActor in received[job.id] = job; receiveEvents += 1 }
        }
        var target = try await peer(receiver), code = receiver.pairingCode
        let interrupted = Task.detached { [target, code] in
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code) { progress in
                if progress > 0.3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await interrupted.value; throw HybridTransfer.TransferError.failed("Expected interruption") }
        catch { if error.localizedDescription == "Expected interruption" { throw error } }
        try await wait("receiver noticed disconnect") { receiver.status.contains("interrumpida") }
        var entries = try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)
        try require(entries.count == 1 && entries[0].lastPathComponent.hasPrefix(".resume-"), "Interrupted transfer must retain one private partial and publish nothing")
        let retained = entries[0], partial = retained.appendingPathComponent("dataset/native-source.bin")
        let retainedBytes = try HybridTransfer.size(partial)
        try require(retainedBytes > 0 && retainedBytes < HybridTransfer.size(fixture), "A real partial payload was not retained")
        try require(received.isEmpty, "An incomplete capture was published")
        // Recreate the receiver: offsets must come from disk, not a live connection object.
        receiver.stop(); receiver = HybridTransferReceiver()
        try receiver.start(directory: incoming, name: "Forma restarted receiver") { job in
            Task { @MainActor in received[job.id] = job; receiveEvents += 1 }
        }
        target = try await peer(receiver); code = receiver.pairingCode
        let resumedMetrics = Locked(HybridTransfer.TransferMetrics())
        let resumedID = try await Task.detached { [target, code] in
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                metrics: { value in resumedMetrics.update { $0 = value } })
        }.value
        try await wait("resumed capture queued") { received[resumedID] != nil }
        guard let saved = received[resumedID] else { fatalError("missing capture") }
        try require(HybridTransfer.digest(saved.datasetDirectory.appendingPathComponent("native-source.bin")) == originalSHA, "Resumed file hash differs")
        try require(resumedMetrics.snapshot.resumedPayloadBytes >= retainedBytes, "Verified partial prefix was retransmitted")
        try require(resumedMetrics.snapshot.transmittedPayloadBytes < HybridTransfer.size(fixture), "Resume retransmitted the entire large file")
        try require(!fm.fileExists(atPath: retained.path), "Committed staging was not atomically moved")
        print("PASS: real disconnect retained \(retainedBytes) bytes; new receiver resumed by offset+prefix SHA and sent only \(resumedMetrics.snapshot.transmittedPayloadBytes) payload bytes")
        let duplicateMetrics = Locked(HybridTransfer.TransferMetrics())
        let duplicateID = try await Task.detached { [target, code] in
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                metrics: { value in duplicateMetrics.update { $0 = value } })
        }.value
        try await wait("duplicate receipt delivered") { receiveEvents >= 2 }
        try require(duplicateID == resumedID && duplicateMetrics.snapshot.alreadyCommitted && duplicateMetrics.snapshot.transmittedPayloadBytes == 0, "Committed retry must keep identity and send zero source payload")
        try require(received.count == 1, "A retried receipt created a duplicate queue identity")
        print("PASS: committed retry reverified all SHA-256 files, transferred zero payload, and reused one queue identity")
        receiver.stop()

        // Switch connection direction, using the same durable capture identity.
        let usbReceiver = HybridTransferReceiver(), usbMetrics = Locked(HybridTransfer.TransferMetrics())
        let usbPort = UInt16.random(in: 50000...55000), usbCode = "00112233445566778899aabbccddeeff"
        let usbSender = Task.detached {
            try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: dataset, mesh: mesh, duration: 9,
                pairingCode: usbCode, port: usbPort, metrics: { value in usbMetrics.update { $0 = value } })
        }
        try await Task.sleep(for: .milliseconds(200))
        var usbJob: UUID?
        try usbReceiver.connectUSB(directory: incoming, port: usbPort, pairingCode: usbCode) { job in
            Task { @MainActor in usbJob = job.id }
        }
        let usbID = try await usbSender.value
        try await wait("USB direction callback") { usbJob != nil }
        try require(usbID == resumedID && usbJob == resumedID && usbMetrics.snapshot.alreadyCommitted && usbMetrics.snapshot.transmittedPayloadBytes == 0,
                    "Switching connection direction lost the committed identity")
        usbReceiver.stop()
        print("PASS: reverse USB-style loopback connection reused the Wi-Fi-style transfer identity with zero payload")

        let legacyIncoming = root.appendingPathComponent("legacy"), legacyReceiver = HybridTransferReceiver()
        var legacyJob: HybridTransfer.ReceivedJob?
        try legacyReceiver.start(directory: legacyIncoming, name: "Forma v1 compatibility") { job in Task { @MainActor in legacyJob = job } }
        let legacyPeer = try await peer(legacyReceiver), legacyCode = legacyReceiver.pairingCode
        let legacyID = try await Task.detached { try await legacySend(dataset: dataset, mesh: mesh, peer: legacyPeer, code: legacyCode) }.value
        try await wait("legacy source callback") { legacyJob != nil }
        try require(legacyJob?.id == legacyID && HybridTransfer.digest(legacyIncoming.appendingPathComponent(legacyID.uuidString + "/dataset/native-source.bin")) == originalSHA, "Updated receiver rejected a valid v1 sender")
        legacyReceiver.stop()
        print("PASS: updated receiver accepts an authenticated encrypted v1 client and preserves its source bytes")

        // Corrupt an owned partial prefix. Receiver and sender must negotiate a restart of that file.
        let corruptIncoming = root.appendingPathComponent("corrupt-incoming")
        let corruptReceiver = HybridTransferReceiver()
        try corruptReceiver.start(directory: corruptIncoming, name: "Forma prefix repair") { _ in }
        let corruptTarget = try await peer(corruptReceiver), corruptCode = corruptReceiver.pairingCode
        let corruptAttempt = Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 10, to: corruptTarget, pairingCode: corruptCode) { progress in
                if progress > 0.3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await corruptAttempt.value; throw HybridTransfer.TransferError.failed("Expected interruption") }
        catch { if error.localizedDescription == "Expected interruption" { throw error } }
        try await wait("corrupt test disconnected") { corruptReceiver.status.contains("interrumpida") }
        let corruptStaging = try fm.contentsOfDirectory(at: corruptIncoming, includingPropertiesForKeys: nil)[0]
        let corruptFile = corruptStaging.appendingPathComponent("dataset/native-source.bin")
        let corruptHandle = try FileHandle(forWritingTo: corruptFile)
        try corruptHandle.write(contentsOf: Data([255])); try corruptHandle.close()
        let repairMetrics = Locked(HybridTransfer.TransferMetrics())
        let repairID = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 10, to: corruptTarget, pairingCode: corruptCode,
                metrics: { value in repairMetrics.update { $0 = value } })
        }.value
        try require(HybridTransfer.digest(corruptIncoming.appendingPathComponent(repairID.uuidString + "/dataset/native-source.bin")) == originalSHA, "Corrupt prefix was trusted")
        try require(repairMetrics.snapshot.transmittedPayloadBytes >= HybridTransfer.size(fixture), "Corrupt file was not restarted")
        corruptReceiver.stop()
        print("PASS: modified partial prefix failed SHA negotiation; only that file restarted, final SHA exact")

        // Force the real receiver to close after durable commit but before its encrypted ACK.
        let lostIncoming = root.appendingPathComponent("lost-ack")
        let lostReceiver = HybridTransferReceiver(), acknowledgements = Locked(0)
        var lostEvents = 0, lostJobs: Set<UUID> = []
        try lostReceiver.start(directory: lostIncoming, name: "Forma lost ACK", acknowledgementPolicy: { _ in
            acknowledgements.update { count in count += 1; return count > 1 }
        }) { job in Task { @MainActor in lostEvents += 1; lostJobs.insert(job.id) } }
        let lostTarget = try await peer(lostReceiver), lostCode = lostReceiver.pairingCode
        do {
            _ = try await Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 11, to: lostTarget, pairingCode: lostCode) }.value
            throw HybridTransfer.TransferError.failed("Expected lost acknowledgement")
        } catch { if error.localizedDescription == "Expected lost acknowledgement" { throw error } }
        try await wait("first committed receipt") { lostEvents == 1 }
        let ackMetrics = Locked(HybridTransfer.TransferMetrics())
        let ackID = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 11, to: lostTarget, pairingCode: lostCode,
                metrics: { value in ackMetrics.update { $0 = value } })
        }.value
        try await wait("retried committed receipt") { lostEvents == 2 }
        entries = try fm.contentsOfDirectory(at: lostIncoming, includingPropertiesForKeys: nil)
        try require(entries.count == 1 && entries[0].lastPathComponent == ackID.uuidString && lostJobs.count == 1, "Lost ACK retry duplicated a committed job")
        try require(ackMetrics.snapshot.alreadyCommitted && ackMetrics.snapshot.transmittedPayloadBytes == 0, "Lost ACK retry resent committed payload")
        // A completed destination is rehashed, rather than trusting a stale receipt alone.
        let tampered = entries[0].appendingPathComponent("dataset/native-source.bin")
        let tamperHandle = try FileHandle(forWritingTo: tampered); try tamperHandle.write(contentsOf: Data([255])); try tamperHandle.close()
        do {
            _ = try await Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 11, to: lostTarget, pairingCode: lostCode) }.value
            throw HybridTransfer.TransferError.failed("Expected committed hash rejection")
        } catch { if error.localizedDescription == "Expected committed hash rejection" { throw error } }
        lostReceiver.stop()
        print("PASS: actual commit/ACK disconnect retried with zero payload and one UUID; later completed-file tampering was rejected")

        // Authentication still precedes inventory publication.
        let rejected = root.appendingPathComponent("wrong-key"), wrongReceiver = HybridTransferReceiver()
        try wrongReceiver.start(directory: rejected, name: "Forma wrong key") { _ in }
        let wrongTarget = try await peer(wrongReceiver)
        do {
            _ = try await Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: wrongTarget, pairingCode: "00112233445566778899aabbccddeeff") }.value
            throw HybridTransfer.TransferError.failed("Expected wrong key rejection")
        } catch { if error.localizedDescription == "Expected wrong key rejection" { throw error } }
        try await wait("wrong key rejected") { wrongReceiver.status.contains("interrumpida") }
        try require(fm.contentsOfDirectory(atPath: rejected.path).isEmpty, "Unauthenticated peer created partial sources")
        wrongReceiver.stop()
        try require(HybridTransfer.digest(fixture) == originalSHA && HybridTransfer.digest(dataset.appendingPathComponent("dataset.json")) == originalManifestSHA, "Source capture was modified")
        print("PASS: wrong key rejected before files; original sender source and calibration SHA-256 unchanged")
        let report: [String: Any] = ["result": "PASS", "transport": "real loopback TCP / paired AES-GCM", "physicalWiFiOrUSB": false,
            "retainedPayloadBytes": retainedBytes, "resumedPayloadBytes": resumedMetrics.snapshot.resumedPayloadBytes,
            "transmittedOnResume": resumedMetrics.snapshot.transmittedPayloadBytes, "committedRetryPayload": duplicateMetrics.snapshot.transmittedPayloadBytes,
            "lostAckRetryPayload": ackMetrics.snapshot.transmittedPayloadBytes, "sourceSHA256": originalSHA]
        let reportURL = URL(fileURLWithPath: "build/Research/HybridResume/harness-report.json")
        try fm.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
    }
}
