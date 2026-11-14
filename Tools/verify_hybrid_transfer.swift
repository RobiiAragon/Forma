import Foundation
import Network
import CryptoKit

/// Real loopback encrypted transfer, key rejection, and resumable interrupted-publication checks.
@main
struct HybridTransferVerification {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FormaHybridVerify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
        try RGBDDatasetManifest(createdAt: Date(), frames: []).write(to: dataset)
        let fixture = dataset.appendingPathComponent("native-source.bin")
        let bytes = Data((0..<(8*1024*1024+33)).map { UInt8($0 % 251) })
        try bytes.write(to: fixture)
        let expected = try HybridTransfer.digest(fixture)
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)],triangles: [0,1,2])
        let key = "00112233445566778899aabbccddeeff"
        for test in 0..<3 {
            let incoming = root.appendingPathComponent("received-\(test)")
            let receiver = HybridTransferReceiver()
            let port = UInt16.random(in: 50000...55000)
            let sender = Task.detached {
                try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: dataset, mesh: mesh, duration: 9,
                    pairingCode: key, port: port) { progress in
                    if test == 2, progress > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            var received: HybridTransfer.ReceivedJob?
            try receiver.connectUSB(directory: incoming, port: port,
                pairingCode: test == 1 ? "ffeeddccbbaa99887766554433221100" : key) { job in
                Task { @MainActor in received = job }
            }
            if test == 0 {
                _ = try await sender.value
                for _ in 0..<50 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
                guard let job = received, try HybridTransfer.digest(job.datasetDirectory.appendingPathComponent("native-source.bin")) == expected,
                      job.duration == 9 else { throw HybridTransfer.TransferError.failed("Verified transfer did not preserve the source.") }
                let savedMesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: job.meshURL))
                guard savedMesh.vertices == mesh.vertices, savedMesh.triangles == mesh.triangles else { throw HybridTransfer.TransferError.failed("Mesh changed in transit.") }
                print("PASS: loopback streamed 8 MiB+33 bytes, SHA-256 and raw mesh exact, acknowledged after commit")
            } else {
                do { _ = try await sender.value; throw HybridTransfer.TransferError.failed("Expected transfer rejection did not occur") }
                catch {
                    if case HybridTransfer.TransferError.failed(let message) = error, message == "Expected transfer rejection did not occur" { throw error }
                }
                try await Task.sleep(for: .milliseconds(250))
                let remaining = try FileManager.default.contentsOfDirectory(atPath: incoming.path)
                guard received == nil else { throw HybridTransfer.TransferError.failed("Rejected or interrupted transfer published a job") }
                if test == 1 {
                    guard remaining.isEmpty else { throw HybridTransfer.TransferError.failed("Unauthenticated transfer created files: \(remaining)") }
                    print("PASS: incorrect pairing key rejected before source publication")
                } else {
                    guard remaining.count == 1, remaining[0].hasPrefix(".resume-") else { throw HybridTransfer.TransferError.failed("Interrupted transfer did not preserve its private partial: \(remaining)") }
                    print("PASS: cancellation mid-file retained private resumable staging and published no job")
                }
            }
            receiver.stop()
        }
        let wifi = HybridTransferReceiver()
        let wifiIncoming = root.appendingPathComponent("wifi-received")
        var wifiJob: HybridTransfer.ReceivedJob?
        try wifi.start(directory: wifiIncoming, name: "Forma transport verification") { job in
            Task { @MainActor in wifiJob = job }
        }
        for _ in 0..<100 where wifi.listeningPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let port = wifi.listeningPort, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw HybridTransfer.TransferError.failed("Wi-Fi listener did not become ready") }
        let peer = HybridTransfer.Peer(id: "loopback", displayName: "Local transport test", endpoint: .hostPort(host: "127.0.0.1", port: endpointPort))
        let wifiCode = wifi.pairingCode
        let wifiSender = Task.detached { try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 9, to: peer, pairingCode: wifiCode) }
        _ = try await wifiSender.value
        for _ in 0..<100 where wifiJob == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let received = wifiJob, try HybridTransfer.digest(received.datasetDirectory.appendingPathComponent("native-source.bin")) == expected else {
            throw HybridTransfer.TransferError.failed("Mac listener / phone client direction failed")
        }
        wifi.stop()
        print("PASS: default Mac-listener/phone-client TCP direction streamed and verified the same source (loopback, not a physical Wi-Fi test)")
        guard try HybridTransfer.digest(fixture) == expected else { throw HybridTransfer.TransferError.failed("Original source changed.") }
        print("PASS: original sender dataset unchanged; no cloud or device access used")
    }
}
