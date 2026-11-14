import Foundation
import Network

private final class PeerLocked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    @discardableResult func update<T>(_ operation: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation(&stored) }
    var value: Value { update { $0 } }
}
private actor PeerProviders {
    let jobID: UUID
    var revision = UUID(), commandEffects = 0, calls = 0
    var commands: [UUID: HybridTransfer.RemoteCommandReply] = [:]
    init(_ jobID: UUID) { self.jobID = jobID }
    func status(_ id: UUID) throws -> HybridTransfer.RemoteJobStatus {
        guard id == jobID else { throw HybridTransfer.TransferError.failed("Unknown isolated P2P job") }
        calls += 1
        return .init(id: id, state: "running", progress: 0.5, iteration: 50, targetIterations: 100, splats: 1000,
            resultAvailable: true, controlRevision: revision, supportedCommands: [.pause, .resume])
    }
    func command(_ request: HybridTransfer.RemoteJobCommand) throws -> HybridTransfer.RemoteCommandReply {
        if let reply = commands[request.id] { return reply }
        guard request.jobID == jobID, request.expectedRevision == revision else { throw HybridTransfer.TransferError.failed("Stale isolated revision") }
        commandEffects += 1; revision = UUID()
        let reply = HybridTransfer.RemoteCommandReply(commandID: request.id, jobID: request.jobID, state: "accepted", status: try status(request.jobID))
        commands[request.id] = reply; return reply
    }
}
@main
struct HybridPeerVerification {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw HybridTransfer.TransferError.failed(message) }
    }
    static func rejected(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw HybridTransfer.TransferError.failed("Expected rejection: " + label)
    }
    @MainActor static func main() async throws {
        let wifiPolicy = HybridTransferBrowser.networkParameters(peerToPeer: false)
        let p2pPolicy = HybridTransferBrowser.networkParameters(peerToPeer: true)
        try require(!wifiPolicy.includePeerToPeer && wifiPolicy.requiredInterfaceType == .wifi, "Wi-Fi default changed")
        try require(p2pPolicy.includePeerToPeer && p2pPolicy.requiredInterface == nil && p2pPolicy.requiredInterfaceType == .other, "P2P discovery remains interface constrained")
        let service = NWEndpoint.service(name: "Isolated nearby Mac", type: HybridTransfer.serviceType, domain: "local.", interface: nil)
        guard let nearby = HybridTransferBrowser.peer(endpoint: service, interfaces: [], peerToPeer: true) else { throw HybridTransfer.TransferError.failed("P2P service rejected") }
        guard case .service(_, _, _, let selectedInterface) = nearby.endpoint else { throw HybridTransfer.TransferError.failed("P2P peer lost service") }
        try require(nearby.includePeerToPeer && selectedInterface == nil, "P2P peer retained fixed interface")
        try require(HybridTransfer.networkParameters(for: nearby).includePeerToPeer, "P2P client policy lost")
        let legacy = HybridTransfer.Peer(id: "legacy", displayName: "Legacy", endpoint: service)
        try require(!legacy.includePeerToPeer && !HybridTransfer.networkParameters(for: legacy).includePeerToPeer, "Existing Peer initializer changed")
        print("PASS: pure Wi-Fi/default and explicit nearby policies, unconstrained Bonjour peer, legacy initializer compatibility")

        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("FormaPeerTransport-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let dataset = root.appendingPathComponent("source"), published = root.appendingPathComponent("derived")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: true)
        try fm.createDirectory(at: published.appendingPathComponent("modelo"), withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
        let original = dataset.appendingPathComponent("source.bin"), model = published.appendingPathComponent("modelo/modelo.obj")
        try Data(repeating: 123, count: 65539).write(to: original)
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: model)
        let sourceHash = try HybridTransfer.digest(original), modelHash = try HybridTransfer.digest(model)
        let calibrationHash = try HybridTransfer.digest(dataset.appendingPathComponent("dataset.json"))
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
        let providerJob = UUID(), providers = PeerProviders(providerJob), receiver = HybridTransferReceiver()
        let source = HybridTransfer.ResultSource(descriptor: .init(jobID: providerJob, resultID: UUID(), name: "Derived peer fixture", mode: "lidar", duration: 10,
            modelRelativePath: "modelo/modelo.obj", packageRelativePath: "modelo"), directory: published)
        let delivered = PeerLocked<[UUID: HybridTransfer.ReceivedJob]>([:]), results = PeerLocked(0)
        try receiver.start(directory: root.appendingPathComponent("received"), name: "Forma isolated peer transport",
            onStatus: { try await providers.status($0) }, onCommand: { try await providers.command($0) }, onResult: { id in
                guard id == providerJob else { throw HybridTransfer.TransferError.failed("Unknown derived result") }
                results.update { $0 += 1 }; return source
            }) { job in delivered.update { $0[job.id] = job } }
        defer { receiver.stop() }
        for _ in 0..<500 { if receiver.listeningPort != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) else { throw HybridTransfer.TransferError.failed("Loopback receiver timeout") }
        let peer = HybridTransfer.Peer(id: "nearby-policy-loopback", displayName: "Explicit P2P loopback", endpoint: .hostPort(host: "127.0.0.1", port: port), includePeerToPeer: true)
        let code = receiver.pairingCode
        let uploadID = try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 10, to: peer, pairingCode: code,
            processingRequest: .init(kind: .gaussian, iterations: 100, downscale: 1))
        for _ in 0..<100 { if delivered.value[uploadID] != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        try require(delivered.value.count == 1, "P2P-enabled source delivery not published")
        let status = try await HybridTransfer.status(jobID: providerJob, to: peer, pairingCode: code)
        let command = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: providerJob, action: .pause, expectedRevision: status.controlRevision)
        let reply = try await HybridTransfer.command(command, to: peer, pairingCode: code)
        let replay = try await HybridTransfer.command(command, to: peer, pairingCode: code)
        let effects = await providers.commandEffects
        try require(reply == replay && effects == 1, "P2P-enabled command replay repeated effects")
        let downloaded = try await HybridTransfer.downloadResult(jobID: providerJob, to: peer, pairingCode: code, directory: root.appendingPathComponent("downloaded"))
        try HybridTransfer.verifyDownloadedResult(downloaded)
        try require(downloaded.descriptor == source.descriptor && results.value == 1, "P2P-enabled result identity changed")
        print("PASS: production send/status/command/download all succeed over paired TCP loopback with includePeerToPeer=true; command replay has one effect")
        let calls = await providers.calls, resultsBefore = results.value
        try await rejected("P2P pairing mismatch") { _ = try await HybridTransfer.status(jobID: providerJob, to: peer, pairingCode: "00000000000000000000000000000000") }
        let afterCalls = await providers.calls
        try require(calls == afterCalls && results.value == resultsBefore && delivered.value.count == 1, "Wrong key reached operation provider")
        try require(try HybridTransfer.digest(original) == sourceHash && HybridTransfer.digest(model) == modelHash && HybridTransfer.digest(dataset.appendingPathComponent("dataset.json")) == calibrationHash, "Private fixture sources changed")
        print("PASS: wrong key rejected before provider; original calibration/source/model unchanged; no AWDL physical connectivity claim, phone, user library or GPU")
        let report: [String: Any] = ["passed": true, "transport": "TCP localhost", "includePeerToPeer": true, "physicalAWDLValidated": false,
            "operations": ["send", "status", "command", "downloadResult"], "commandEffects": effects, "sourceUnchanged": true,
            "uploadID": uploadID.uuidString, "resultManifestSHA256": downloaded.manifestSHA256]
        let path = CommandLine.arguments.dropFirst().first ?? "build/Research/HybridPeerTransport/harness-report.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
