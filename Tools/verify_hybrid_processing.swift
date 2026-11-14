import Foundation
import Network
import CryptoKit

private final class HybridLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult func update<T>(_ operation: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation(&value) }
    var snapshot: Value { update { $0 } }
}

/// Production paired AES-GCM protocol over real TCP, without touching the user's library or GPU.
@main
struct HybridProcessingVerification {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HybridTransfer.TransferError.failed(message) }
    }
    @MainActor static func wait(_ message: String, until predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw HybridTransfer.TransferError.failed("Timed out: " + message)
    }
    @MainActor static func peer(_ receiver: HybridTransferReceiver) async throws -> HybridTransfer.Peer {
        try await wait("listener ready") { receiver.listeningPort != nil }
        guard let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) else { fatalError("missing port") }
        return .init(id: "loopback", displayName: "Loopback", endpoint: .hostPort(host: "127.0.0.1", port: port))
    }
    static func expectFailure(_ message: String, operation: () async throws -> Void) async throws -> String {
        do { try await operation(); throw HybridTransfer.TransferError.failed("Expected rejection: " + message) }
        catch {
            if error.localizedDescription == "Expected rejection: " + message { throw error }
            return error.localizedDescription
        }
    }

    /// Deliberately bypass sender-side validation to exercise the real receiver's precommit validation.
    static func sendInvalidRequest(dataset: URL, mesh: MeshSnapshot, peer: HybridTransfer.Peer, code: String) async throws -> UUID {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var files: [(String, Data)] = [("malla-original.json", try encoder.encode(mesh)),
            ("procesamiento.json", Data("{\"kind\":\"gaussian\",\"iterations\":0,\"downscale\":1}".utf8))]
        for name in try FileManager.default.contentsOfDirectory(atPath: dataset.path).sorted() {
            files.append(("dataset/" + name, try Data(contentsOf: dataset.appendingPathComponent(name))))
        }
        files.sort { $0.0 < $1.0 }
        let manifest = HybridTransfer.Manifest(duration: 90, files: files.map {
            .init(path: $0.0, bytes: Int64($0.1.count), sha256: HybridTransfer.hex(SHA256.hash(data: $0.1)))
        })
        let id = try manifest.id
        let key = try HybridTransfer.pairingKey(code)
        let channel = HybridTransfer.Channel(NWConnection(to: peer.endpoint, using: .tcp)); defer { channel.cancel() }
        try await channel.start()
        let challenge = try await channel.readExactly(32)
        try await channel.write(Data(HMAC<SHA256>.authenticationCode(for: challenge + Data("client".utf8), using: key)))
        let response = try await channel.readExactly(32)
        try require(HMAC<SHA256>.isValidAuthenticationCode(response, authenticating: challenge + Data("server".utf8), using: key), "Invalid-request test authentication failed")
        let cipher = HybridTransfer.Cipher(channel: channel, pairingKey: key, challenge: challenge, sending: "client", receiving: "server")
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "job-v2", jobID: id, duration: 90, version: 2, manifestSHA256: manifest.sha256)))
        for file in manifest.files { try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "manifest-file", path: file.path, bytes: file.bytes, sha256: file.sha256))) }
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "manifest-done")))
        let ready = try JSONDecoder().decode(HybridTransfer.Header.self, from: await cipher.receive())
        try require(ready.kind == "ready", "Invalid-request test never reached staging")
        for file in files {
            let descriptor = manifest.files.first { $0.path == file.0 }!
            try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "file", path: file.0, bytes: descriptor.bytes, sha256: descriptor.sha256)))
            let resume = try JSONDecoder().decode(HybridTransfer.Header.self, from: await cipher.receive())
            try require(resume.kind == "resume-file" && resume.bytes == 0, "Unexpected existing invalid-request partial")
            try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "append-file", path: file.0)))
            var offset = 0
            while offset < file.1.count {
                let end = min(offset + HybridTransfer.chunkBytes, file.1.count)
                try await cipher.send(file.1.subdata(in: offset..<end)); offset = end
            }
            let verified = try JSONDecoder().decode(HybridTransfer.Header.self, from: await cipher.receive())
            try require(verified.kind == "file-verified", "Invalid-request test source SHA failed")
        }
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "done")))
        _ = try await expectFailure("receiver validation") { _ = try await cipher.receive() }
        return id
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FormaHybridProcessing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let dataset = root.appendingPathComponent("sources")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: false)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
        let fixture = dataset.appendingPathComponent("source.bin")
        try Data((0..<(2*1024*1024+19)).map { UInt8($0 % 251) }).write(to: fixture)
        let sourceSHA = try HybridTransfer.digest(fixture), calibrationSHA = try HybridTransfer.digest(dataset.appendingPathComponent("dataset.json"))
        let sourceNames = try fm.contentsOfDirectory(atPath: dataset.path).sorted()
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
        let incoming = root.appendingPathComponent("received")
        let receiver = HybridTransferReceiver()
        let jobs = HybridLocked<[UUID: HybridTransfer.ReceivedJob]>([:])
        let requests = HybridLocked<[UUID: HybridTransfer.ProcessingRequest]>([:])
        let statuses = HybridLocked<[UUID: HybridTransfer.RemoteJobStatus]>([:])
        let events = HybridLocked(0), providerCalls = HybridLocked(0), receiverErrors = HybridLocked<[String]>([])
        let provider: HybridTransfer.StatusProvider = { id in
            providerCalls.update { $0 += 1 }
            guard let status = statuses.snapshot[id] else { throw HybridTransfer.TransferError.failed("Unknown local job") }
            return status
        }
        try receiver.start(directory: incoming, name: "Forma hybrid processing", onStatus: provider) { job in
            do {
                let requestURL = job.directory.appendingPathComponent("procesamiento.json")
                let request = FileManager.default.fileExists(atPath: requestURL.path) ? try JSONDecoder().decode(HybridTransfer.ProcessingRequest.self, from: Data(contentsOf: requestURL)) : nil
                try request?.validate()
                jobs.update { $0[job.id] = job }; events.update { $0 += 1 }
                if let request { requests.update { $0[job.id] = request } }
                statuses.update { $0[job.id] = .init(id: job.id, state: "running", progress: 0.25,
                    iteration: request?.kind == .gaussian ? 750 : nil, targetIterations: request?.kind == .gaussian ? request?.iterations ?? 3000 : nil,
                    splats: request?.kind == .gaussian ? 425928 : nil, resultAvailable: false) }
            } catch { receiverErrors.update { $0.append(error.localizedDescription) } }
        }
        let target = try await peer(receiver), code = receiver.pairingCode
        let baseline = try await Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code) }.value
        let request = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 5000, downscale: 1)
        let gaussian = try await Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code, processingRequest: request) }.value
        try await wait("processing requests queued") { jobs.snapshot.count == 2 }
        try require(baseline != gaussian && requests.snapshot[gaussian] == request, "Processing request was omitted or did not affect content identity")
        let savedRequest = try JSONDecoder().decode(HybridTransfer.ProcessingRequest.self, from: Data(contentsOf: incoming.appendingPathComponent(gaussian.uuidString + "/procesamiento.json")))
        try require(savedRequest == request && !fm.fileExists(atPath: incoming.appendingPathComponent(baseline.uuidString + "/procesamiento.json").path), "Optional processing configuration compatibility failed")
        let duplicateMetrics = HybridLocked(HybridTransfer.TransferMetrics())
        let duplicate = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                processingRequest: request, metrics: { value in duplicateMetrics.update { $0 = value } })
        }.value
        try require(duplicate == gaussian && duplicateMetrics.snapshot.alreadyCommitted && duplicateMetrics.snapshot.transmittedPayloadBytes == 0, "Matching configuration did not deduplicate")
        let changedIterations = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                processingRequest: .init(kind: .gaussian, iterations: 6000, downscale: 1))
        }.value
        let changedResolution = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                processingRequest: .init(kind: .gaussian, iterations: 5000, downscale: 2))
        }.value
        try require(Set([baseline, gaussian, changedIterations, changedResolution]).count == 4, "Different Gaussian configurations reused a job identity")
        let lidar = try await Task.detached {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code,
                processingRequest: .init(kind: .lidar))
        }.value
        try await wait("all configured captures queued") { jobs.snapshot.count == 5 }
        try require(requests.snapshot[lidar] == .init(kind: .lidar), "Explicit LiDAR request did not round-trip")
        try HybridTransfer.ProcessingRequest(kind: .gaussian).validate()
        try HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: Int(Int32.max), downscale: 1).validate()
        print("PASS: authenticated procesamiento.json preserved exactly; nil remains compatible, iteration/resolution changes have distinct UUIDs, exact retry sends zero payload")

        let eventCount = events.snapshot
        let queried = try await Task.detached { try await HybridTransfer.status(jobID: gaussian, to: target, pairingCode: code) }.value
        try require(queried == statuses.snapshot[gaussian] && queried.iteration == 750 && queried.splats == 425928 && !queried.resultAvailable, "Paired status changed fields")
        statuses.update { $0[gaussian] = .init(id: gaussian, state: "completed", progress: 1, iteration: 5000, targetIterations: 5000, splats: 430000, resultAvailable: true) }
        let completed = try await Task.detached { try await HybridTransfer.status(jobID: gaussian, to: target, pairingCode: code) }.value
        try require(completed.state == "completed" && completed.resultAvailable && completed.progress == 1, "Completion status did not round-trip")
        try require(events.snapshot == eventCount, "A status query emitted a received source job")
        let unknownError = try await expectFailure("unknown job") { _ = try await HybridTransfer.status(jobID: UUID(), to: target, pairingCode: code) }
        try require(unknownError == "Unknown local job", "Provider error did not remain inside the authenticated response")
        let beforeWrongKey = providerCalls.snapshot
        _ = try await expectFailure("wrong status pairing key") {
            _ = try await HybridTransfer.status(jobID: gaussian, to: target, pairingCode: "00112233445566778899aabbccddeeff")
        }
        try require(providerCalls.snapshot == beforeWrongKey, "Unauthenticated client accessed the status provider")
        statuses.update { $0[gaussian]?.progress = .nan }
        _ = try await expectFailure("nonfinite status") { _ = try await HybridTransfer.status(jobID: gaussian, to: target, pairingCode: code) }
        statuses.update { $0[gaussian] = completed }
        print("PASS: running/completed status and provider errors round-trip through AES-GCM; wrong key never reaches provider; nonfinite response rejected; queries never publish source jobs")

        let usbReceiver = HybridTransferReceiver(), usbPort = UInt16.random(in: 50000...55000)
        let usbCode = "11223344556677889900aabbccddeeff"
        let usbQuery = Task.detached { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: gaussian, pairingCode: usbCode, port: usbPort) }
        try await Task.sleep(for: .milliseconds(200))
        let usbUnexpected = HybridLocked(false)
        try usbReceiver.connectUSB(directory: incoming, port: usbPort, pairingCode: usbCode, onStatus: provider) { _ in usbUnexpected.update { $0 = true } }
        let usbStatus = try await usbQuery.value
        try require(usbStatus == completed && !usbUnexpected.snapshot, "Reverse USB-style status route failed")
        usbReceiver.stop()
        print("PASS: reverse USB-style TCP query uses the same pairing/cipher/provider and does not create a dataset")

        let beforeInvalid = jobs.snapshot.count
        for invalid in [HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 0),
                        .init(kind: .gaussian, iterations: Int(Int32.max) + 1),
                        .init(kind: .gaussian, downscale: .nan), .init(kind: .gaussian, downscale: 0.5)] {
            _ = try await expectFailure("invalid request") {
                _ = try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: target, pairingCode: code, processingRequest: invalid)
            }
        }
        try require(jobs.snapshot.count == beforeInvalid, "Invalid sender configuration published a job")
        let invalidID = try await Task.detached { try await sendInvalidRequest(dataset: dataset, mesh: mesh, peer: target, code: code) }.value
        try await wait("receiver rejected invalid configuration") { receiver.status.contains("interrumpida") }
        try require(receiver.status.contains("iteraciones"), "Receiver disconnected for a reason other than configuration validation")
        try require(!fm.fileExists(atPath: incoming.appendingPathComponent(invalidID.uuidString).path) && jobs.snapshot[invalidID] == nil,
                    "Receiver committed an invalid but SHA-valid processing request")
        try require(fm.fileExists(atPath: incoming.appendingPathComponent(".resume-" + invalidID.uuidString).path), "Receiver destroyed resumable sources on invalid configuration")
        print("PASS: native ABI validation rejects invalid configurations before sending and before committing a hand-crafted authenticated SHA-valid request; private sources retained")
        receiver.stop()
        try require(receiverErrors.snapshot.isEmpty, "Received configuration decode failed: \(receiverErrors.snapshot)")
        try require(fm.contentsOfDirectory(atPath: dataset.path).sorted() == sourceNames && HybridTransfer.digest(fixture) == sourceSHA &&
                    HybridTransfer.digest(dataset.appendingPathComponent("dataset.json")) == calibrationSHA, "Sender originals changed")
        print("PASS: original sender dataset/calibration hashes and file list unchanged; no cloud, user library, device or GPU access")
        let report: [String: Any] = ["result": "PASS", "transport": "real loopback TCP / paired HMAC + AES-GCM", "physicalWiFiOrUSB": false,
            "baselineID": baseline.uuidString, "gaussianID": gaussian.uuidString, "changedIterationsID": changedIterations.uuidString,
            "changedResolutionID": changedResolution.uuidString, "lidarID": lidar.uuidString, "duplicatePayloadBytes": duplicateMetrics.snapshot.transmittedPayloadBytes,
            "statusProviderCalls": providerCalls.snapshot, "receivedJobCount": jobs.snapshot.count, "sourceSHA256": sourceSHA,
            "sourceFilesUnchanged": true, "receivedProcessingRequest": ["kind": "gaussian", "iterations": 5000, "downscale": 1]]
        let reportURL = URL(fileURLWithPath: "build/Research/HybridProcessing/harness-report.json")
        try fm.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
    }
}
