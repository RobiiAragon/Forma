import Foundation
import Network
import Darwin

private final class USBLocked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    @discardableResult func update<T>(_ operation: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation(&stored) }
    var value: Value { update { $0 } }
}
private actor USBProviders {
    let jobID: UUID
    var revision = UUID(), effects = 0, queries = 0, resultCalls = 0, commandCalls = 0
    var holdingQueries = false
    private var held: [Int: (HybridTransfer.RemoteJobStatus, CheckedContinuation<HybridTransfer.RemoteJobStatus, Never>)] = [:]
    private var ledger: [UUID: (HybridTransfer.RemoteJobCommand, HybridTransfer.RemoteCommandReply)] = [:]
    init(_ jobID: UUID) { self.jobID = jobID }
    func snapshot() -> HybridTransfer.RemoteJobStatus {
        .init(id: jobID, state: "running", progress: 0.5, iteration: 500, targetIterations: 1000, splats: 12345,
              resultAvailable: true, controlRevision: revision, supportedCommands: [.pause, .resume, .cancel, .export])
    }
    func query(_ id: UUID) async throws -> HybridTransfer.RemoteJobStatus {
        guard id == jobID else { throw HybridTransfer.TransferError.failed("Unknown isolated USB job") }
        queries += 1; let sequence = queries, value = snapshot()
        if holdingQueries { return await withCheckedContinuation { held[sequence] = (value, $0) } }
        return value
    }
    func command(_ request: HybridTransfer.RemoteJobCommand) throws -> HybridTransfer.RemoteCommandReply {
        commandCalls += 1
        if let (previous, reply) = ledger[request.id] {
            guard previous == request else { throw HybridTransfer.TransferError.failed("USB command UUID collision") }
            return reply
        }
        guard request.jobID == jobID, request.expectedRevision == revision else { throw HybridTransfer.TransferError.failed("Stale USB control revision") }
        effects += 1; revision = UUID()
        let reply = HybridTransfer.RemoteCommandReply(commandID: request.id, jobID: jobID, state: "accepted", status: snapshot())
        ledger[request.id] = (request, reply); return reply
    }
    func result(_ source: HybridTransfer.ResultSource, id: UUID) throws -> HybridTransfer.ResultSource {
        guard id == jobID else { throw HybridTransfer.TransferError.failed("Unknown isolated USB result") }
        resultCalls += 1; return source
    }
    func setHolding(_ value: Bool) { holdingQueries = value }
    func pending() -> [Int] { held.keys.sorted() }
    func counters() -> (Int, Int, Int, Int) { (queries, effects, resultCalls, commandCalls) }
    func release(_ sequence: Int) { if let (value, continuation) = held.removeValue(forKey: sequence) { continuation.resume(returning: value) } }
    func releaseAll() { let old = held; held.removeAll(); for (_, (value, continuation)) in old { continuation.resume(returning: value) } }
}

@main
struct HybridUSBContinuousVerification {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw HybridTransfer.TransferError.failed(message) }
    }
    static func rejected(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw HybridTransfer.TransferError.failed("Expected rejection: " + label)
    }
    static func bounded<T: Sendable>(_ label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        FileHandle.standardError.write(Data(("START: " + label + "\n").utf8))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw HybridTransfer.TransferError.failed("USB harness deadline: " + label) }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
    @MainActor static func wait(_ label: String, until condition: () async -> Bool) async throws {
        for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw HybridTransfer.TransferError.failed("USB harness timeout: " + label)
    }
    @MainActor static func wifiPeer(_ receiver: HybridTransferReceiver) async throws -> HybridTransfer.Peer {
        try await wait("Wi-Fi listener") { receiver.listeningPort != nil }
        return .init(id: "continuous-fixture-wifi", displayName: "Isolated Wi-Fi receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: receiver.listeningPort!)!))
    }
    @MainActor static func unusedPort() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp)
        let port = USBLocked<UInt16?>(nil)
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { port.update { $0 = listener.port?.rawValue } } }
        listener.start(queue: DispatchQueue(label: "forma.usb-port-fixture"))
        try await wait("fixture ephemeral port") { port.value != nil }
        let result = port.value!; listener.cancel()
        try await Task.sleep(for: .milliseconds(150))
        return result
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FormaContinuousUSB-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let dataset = root.appendingPathComponent("capture"), published = root.appendingPathComponent("published")
        try fm.createDirectory(at: dataset, withIntermediateDirectories: true)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: []).write(to: dataset)
        let original = dataset.appendingPathComponent("source.bin")
        var bytes = [UInt8](repeating: 0, count: 8_388_645)
        for index in bytes.indices { bytes[index] = UInt8((index * 13) % 251) }
        try Data(bytes).write(to: original)
        let package = published.appendingPathComponent("modelo")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let model = package.appendingPathComponent("modelo.ply")
        try Data(bytes).write(to: model)
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
        try JSONEncoder().encode(mesh).write(to: published.appendingPathComponent("malla.json"))
        let sourceURLs = [original, dataset.appendingPathComponent("dataset.json"), model, published.appendingPathComponent("malla.json")]
        let originalHashes = try sourceURLs.map { try HybridTransfer.digest($0) }
        let sourceNames = fm.subpaths(atPath: root.path)!.filter { $0.hasPrefix("capture/") || $0.hasPrefix("published/") }.sorted()
        let jobID = UUID(), providers = USBProviders(jobID)
        let source = HybridTransfer.ResultSource(descriptor: .init(jobID: jobID, resultID: UUID(), name: "USB derived fixture", mode: "lidar", duration: 15,
            note: "Isolated protocol fixture", modelRelativePath: "modelo/modelo.ply", packageRelativePath: "modelo", meshRelativePath: "malla.json", gaussianModelRelativePath: "modelo.ply"), directory: published)
        let onStatus: HybridTransfer.StatusProvider = { try await providers.query($0) }
        let onCommand: HybridTransfer.CommandProvider = { try await providers.command($0) }
        let onResult: HybridTransfer.ResultProvider = { try await providers.result(source, id: $0) }
        let jobs = USBLocked<[UUID: HybridTransfer.ReceivedJob]>([:]), deliveries = USBLocked(0)
        let onReceive: @Sendable (HybridTransfer.ReceivedJob) -> Void = { job in jobs.update { $0[job.id] = job }; deliveries.update { $0 += 1 } }
        let incoming = root.appendingPathComponent("incoming"), receiver = HybridTransferReceiver()
        defer { receiver.stop(); Task { await providers.releaseAll() } }
        try receiver.start(directory: incoming, name: "Forma isolated continuous USB", onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        let wifi = try await wifiPeer(receiver), wifiPort = receiver.listeningPort, code = receiver.pairingCode
        let port = try await unusedPort()
        try receiver.startContinuousUSB(directory: incoming, port: port, pairingCode: code, onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        try require(receiver.isUSBContinuousEnabled, "Continuous USB did not enable")
        do {
            try receiver.connectUSB(directory: incoming, port: port, pairingCode: code, onReceive: onReceive)
            throw HybridTransfer.TransferError.failed("One-shot USB competed with the loop")
        } catch { if error.localizedDescription == "One-shot USB competed with the loop" { throw error } }
        let first = try await bounded("first reverse status") { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        let command = HybridTransfer.RemoteJobCommand(id: UUID(), jobID: jobID, action: .pause, expectedRevision: first.controlRevision)
        let reply = try await bounded("reverse command") { try await HybridTransfer.commandOverUSBWaitingForMac(command, pairingCode: code, port: port) }
        let replay = try await bounded("reverse command replay") { try await HybridTransfer.commandOverUSBWaitingForMac(command, pairingCode: code, port: port) }
        let commandEffects = await providers.effects
        try require(reply == replay && commandEffects == 1, "Command replay changed identity or duplicated effect")
        print("PASS: one opt-in starts serial reverse status→command→same-UUID replay without additional Mac connect calls; one-shot cannot compete")

        let downloads = root.appendingPathComponent("downloads")
        let taskHandle = USBLocked<Task<HybridTransfer.DownloadedResult, Error>?>(nil)
        let firstMetrics = USBLocked(HybridTransfer.TransferMetrics())
        let partialTask = Task {
            try await HybridTransfer.downloadResultOverUSBWaitingForMac(jobID: jobID, pairingCode: code, directory: downloads, port: port, metrics: { metrics in
                firstMetrics.update { $0 = metrics }
                if metrics.transmittedPayloadBytes >= 2 * 1024 * 1024 { taskHandle.value?.cancel() }
            })
        }
        taskHandle.update { $0 = partialTask }
        defer { partialTask.cancel() }
        try await rejected("interrupted reverse download") { _ = try await bounded("interrupted download") { try await partialTask.value } }
        let partials = try fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".result-resume-") }
        try require(partials.count == 1 && firstMetrics.value.transmittedPayloadBytes >= 2 * 1024 * 1024, "Interrupted result prefix discarded")
        let resumedMetrics = USBLocked(HybridTransfer.TransferMetrics())
        let completed = try await bounded("resumed reverse download") {
            try await HybridTransfer.downloadResultOverUSBWaitingForMac(jobID: jobID, pairingCode: code, directory: downloads, port: port,
                metrics: { value in resumedMetrics.update { $0 = value } })
        }
        try HybridTransfer.verifyDownloadedResult(completed)
        try require(resumedMetrics.value.resumedPayloadBytes >= firstMetrics.value.transmittedPayloadBytes && resumedMetrics.value.transmittedPayloadBytes < (try HybridTransfer.size(model)), "USB resumed a complete file instead of its prefix")
        let afterResult = try await bounded("post-result reverse status") { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        try require(afterResult.id == jobID && receiver.pairingCode == code && receiver.isUSBContinuousEnabled, "Continuous operation lost pairing key or stopped")
        print("PASS: same-port reverse result interruption preserves SHA prefix, reconnect loop serves resume and a later status with original pairing")

        let beforeWrongKey = await providers.counters()
        try await rejected("wrong key on continuous listener") {
            _ = try await bounded("wrong-key status") { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: "00000000000000000000000000000000", port: port) }
        }
        let afterWrongKey = await providers.counters()
        try require(beforeWrongKey.0 == afterWrongKey.0 && beforeWrongKey.1 == afterWrongKey.1 && beforeWrongKey.3 == afterWrongKey.3, "Unauthenticated operation reached providers")
        _ = try await bounded("correct pairing after rejection") { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        let idleBefore = await providers.counters()
        try await Task.sleep(for: .milliseconds(400))
        let idleAfter = await providers.counters()
        try require(idleBefore.0 == idleAfter.0 && idleBefore.1 == idleAfter.1 && idleBefore.2 == idleAfter.2 && idleBefore.3 == idleAfter.3, "Idle reconnect loop resubmitted an operation")
        try require(!receiver.usbStatus.lowercased().contains("refused"), "Idle connection refusal spammed USB status")
        receiver.stopContinuousUSB()
        try require(!receiver.isUSBContinuousEnabled && !receiver.usbConnectionActive && receiver.isListening && receiver.listeningPort == wifiPort && receiver.pairingCode == code, "StopUSB damaged Wi-Fi reception")
        _ = try await HybridTransfer.status(jobID: jobID, to: wifi, pairingCode: code)
        let stoppedCalls = await providers.counters()
        let unusedClient = Task { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        try await Task.sleep(for: .milliseconds(400)); unusedClient.cancel()
        try await rejected("stopped loop stays stopped") { _ = try await unusedClient.value }
        let afterStopCalls = await providers.counters()
        try require(stoppedCalls.0 == afterStopCalls.0 && !receiver.isUSBContinuousEnabled, "Stopped loop reconnected to a later phone listener")
        print("PASS: wrong key never invokes providers; idle loop submits no commands; StopUSB cancels waiting and preserves authenticated Wi-Fi")

        await providers.setHolding(true)
        try receiver.startContinuousUSB(directory: incoming, port: port, pairingCode: code, onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        let oldQuery = Task { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        defer { oldQuery.cancel() }
        try await wait("old USB generation held") { await providers.pending().count == 1 && receiver.usbConnectionActive }
        let oldSequence = await providers.pending().first!
        receiver.stopContinuousUSB()
        try await rejected("old generation client cancelled") { _ = try await bounded("old generation cancellation") { try await oldQuery.value } }
        try receiver.startContinuousUSB(directory: incoming, port: port, pairingCode: code, onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        let newQuery = Task { try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: code, port: port) }
        defer { newQuery.cancel() }
        try await wait("new USB generation held") { await providers.pending().count == 2 && receiver.usbConnectionActive }
        let newSequence = await providers.pending().last!
        await providers.release(oldSequence)
        try await Task.sleep(for: .milliseconds(100))
        try require(receiver.isUSBContinuousEnabled && receiver.usbConnectionActive && receiver.usbStatus.contains("conectado"), "Old completion overwrote restarted USB state")
        await providers.release(newSequence)
        let newStatus = try await bounded("new generation response") { try await newQuery.value }
        try require(newStatus.id == jobID, "New generation failed after old completion")
        await providers.setHolding(false)
        receiver.stopContinuousUSB()
        print("PASS: stop/restart invalidates old completion without clearing the new authenticated connection or reconnecting the old loop")

        let dropACKOnce = USBLocked(true)
        let acknowledgement: @Sendable (HybridTransfer.ReceivedJob) -> Bool = { _ in
            let shouldStop = dropACKOnce.update { value in let old = value; value = false; return old }
            guard shouldStop else { return true }
            let stopped = DispatchSemaphore(value: 0)
            Task { @MainActor in receiver.stopContinuousUSB(); stopped.signal() }
            guard stopped.wait(timeout: .now() + 5) == .success else { return false }
            return false
        }
        try receiver.startContinuousUSB(directory: incoming, port: port, pairingCode: code, acknowledgementPolicy: acknowledgement,
            onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        try await rejected("commit confirmed locally but Stop drops ACK") {
            _ = try await bounded("upload ACK interrupted") {
                try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: dataset, mesh: mesh, duration: 15, pairingCode: code, port: port)
            }
        }
        try await wait("committed capture published despite stop race") { jobs.value.count == 1 && deliveries.value == 1 && !receiver.isUSBContinuousEnabled }
        let committedID = jobs.value.keys.first!
        let retryMetrics = USBLocked(HybridTransfer.TransferMetrics())
        try receiver.startContinuousUSB(directory: incoming, port: port, pairingCode: code, acknowledgementPolicy: acknowledgement,
            onStatus: onStatus, onCommand: onCommand, onResult: onResult, onReceive: onReceive)
        let retriedID = try await bounded("ACK-lost upload retry") {
            try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: dataset, mesh: mesh, duration: 15, pairingCode: code, port: port,
                metrics: { value in retryMetrics.update { $0 = value } })
        }
        try await wait("idempotent retry callback") { deliveries.value == 2 }
        try require(retriedID == committedID && jobs.value.count == 1 && retryMetrics.value.alreadyCommitted && retryMetrics.value.transmittedPayloadBytes == 0, "ACK-lost retry hid or duplicated durable capture")
        receiver.stop()
        try require(!receiver.isUSBContinuousEnabled && !receiver.isListening, "Global stop did not stop both transports")
        try require(try sourceURLs.map { try HybridTransfer.digest($0) } == originalHashes, "Private sender/model bytes changed")
        let finalNames = fm.subpaths(atPath: root.path)!.filter { $0.hasPrefix("capture/") || $0.hasPrefix("published/") }.sorted()
        try require(finalNames == sourceNames, "Private sender/model file list changed")
        print("PASS: Stop after atomic upload commit still publishes its UUID; restart/retry acknowledges same capture with zero payload, then global stop closes both routes")
        print("PASS: source and model hashes/file lists unchanged; all tests use temporary localhost TCP, no iPhone, GPU, worker or library")
        let report: [String: Any] = ["passed": true, "reversePort": port, "sequence": "status-command-replay-result-interrupt-resume-status",
            "commandEffects": commandEffects, "interruptedPayloadBytes": firstMetrics.value.transmittedPayloadBytes,
            "resumedPayloadBytes": resumedMetrics.value.resumedPayloadBytes, "remainingPayloadBytes": resumedMetrics.value.transmittedPayloadBytes,
            "ackLostCommittedID": committedID.uuidString, "ackLostRetryPayloadBytes": retryMetrics.value.transmittedPayloadBytes,
            "deduplicatedJobs": jobs.value.count, "commitCallbacks": deliveries.value, "sourcesUnchanged": true]
        let output = CommandLine.arguments.dropFirst().first ?? "build/Research/HybridUSBContinuous/harness-report.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
