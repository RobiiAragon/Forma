import XCTest
import CryptoKit
import UIKit
import Network
@testable import Forma

/// Explicit hardware QA only. The ordinary suite never contacts a Mac or camera.
final class HybridPhysicalTransportTests: XCTestCase {
    private struct Configuration: Decodable, Sendable {
        let schemaVersion: Int
        let sessionID: String
        let serviceName: String
        let pairingCode: String
        let fixtureBytes: Int
        let fixtureSHA256: String
        let canonicalMeshSHA256: String
        let usbDevicePort: UInt16
        let discoveryTimeoutSeconds: Double
        let transferTimeoutSeconds: Double
    }
    private struct Deadline: LocalizedError {
        let operation: String
        var errorDescription: String? { "Hardware QA timeout: " + operation }
    }
    private final class PayloadMetrics: @unchecked Sendable {
        private let lock = NSLock()
        private var current: HybridTransfer.TransferMetrics?
        func update(_ value: HybridTransfer.TransferMetrics) { lock.lock(); current = value; lock.unlock() }
        var value: HybridTransfer.TransferMetrics? { lock.lock(); defer { lock.unlock() }; return current }
    }

    @MainActor
    func testOptInPhysicalWiFiThenUSBWithLocalFixture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly selected physical iPhone and local Mac harness.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["FORMA_HYBRID_HARDWARE_OPT_IN"] == "1",
              let encoded = environment["FORMA_HYBRID_HARDWARE_CONFIG"],
              let bytes = Data(base64Encoded: encoded) else {
            throw XCTSkip("Hardware transport QA is opt-in; no harness configuration supplied.")
        }
        let config = try JSONDecoder().decode(Configuration.self, from: bytes)
        guard config.schemaVersion == 1, UUID(uuidString: config.sessionID) != nil,
              config.serviceName.hasPrefix("Forma Hardware QA "), config.fixtureBytes == 8*1024*1024+33,
              config.discoveryTimeoutSeconds > 0, config.discoveryTimeoutSeconds <= 30,
              config.transferTimeoutSeconds > 0, config.transferTimeoutSeconds <= 90 else {
            throw RGBDDatasetError.invalid("Invalid hardware fixture configuration.")
        }
        _ = try HybridTransfer.pairingKey(config.pairingCode)
        let browser = HybridTransferBrowser()
        browser.start()
        defer { browser.stop() }
        let until = Date().addingTimeInterval(config.discoveryTimeoutSeconds)
        var selected: HybridTransfer.Peer?
        while Date() < until, selected == nil {
            try Task.checkCancellation()
            selected = browser.peers.first { $0.displayName == config.serviceName }
            if selected == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let selected else {
            throw XCTSkip("No matching Wi-Fi-scoped Bonjour hardware harness within 30 seconds; no fixture sent. " + browser.status)
        }
        let peer = selected
        guard case .service(_, _, _, let endpointInterface) = peer.endpoint,
              let wifiInterface = endpointInterface, wifiInterface.type == .wifi else {
            throw RGBDDatasetError.invalid("Production discovery returned an unscoped or non-Wi-Fi endpoint.")
        }
        let interfaceName = wifiInterface.name
        // Mirror the real selector's onDisappear: the copied peer must remain usable.
        browser.stop()
        let probe = HybridTransfer.Channel(NWConnection(to:peer.endpoint,using:.tcp))
        defer { probe.cancel() }
        try await Self.withDeadline(seconds:10,operation:"Wi-Fi endpoint path probe") {
            try await withTaskCancellationHandler(operation:{ try await probe.start() },onCancel:{ probe.cancel() })
        }
        let probeUsesWiFi = probe.connection.currentPath?.usesInterfaceType(.wifi) == true
        guard probeUsesWiFi else { throw RGBDDatasetError.invalid("The scoped Bonjour endpoint probe did not use a Wi-Fi interface; radio Wi-Fi is unverified.") }
        probe.cancel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FormaHardwareFixture-\(config.sessionID)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1_700_000_000), frames: []).write(to: dataset)
        let routeEvidence: [String:Any] = ["endpointInterfaceType":"wifi","endpointInterfaceName":interfaceName,
            "payloadEndpointScopedToWiFi":true,"probeUsesWiFi":probeUsesWiFi,"pathObservationIsProbeOnly":true,
            "note":"NWPath is observed on a separate connection to the same Wi-Fi-scoped endpoint; HybridTransfer.send owns the payload connection internally."]
        try JSONSerialization.data(withJSONObject:routeEvidence,options:[.sortedKeys]).write(to:dataset.appendingPathComponent("route-evidence.json"))
        let fixture = dataset.appendingPathComponent("fixture.bin")
        try Self.writeFixture(fixture, count: config.fixtureBytes)
        let mesh = MeshSnapshot(vertices: [.init(0,0,0),.init(1,0,0),.init(0,1,0)], triangles: [0,1,2])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let meshData = try encoder.encode(mesh), meshFile = dataset.appendingPathComponent("mesh-source.json")
        try meshData.write(to: meshFile)
        XCTAssertEqual(try HybridTransfer.digest(fixture), config.fixtureSHA256)
        XCTAssertEqual(try HybridTransfer.digest(meshFile), config.canonicalMeshSHA256)
        let manifestBefore = try HybridTransfer.digest(dataset.appendingPathComponent("dataset.json"))
        print("FORMA_HARDWARE_QA_START session=\(config.sessionID) device=\(UIDevice.current.model) os=\(UIDevice.current.systemVersion) bytes=\(config.fixtureBytes) Bonjour=\(config.serviceName)")
        print("FORMA_HARDWARE_ROUTE interface=\(interfaceName) type=wifi payloadEndpointScoped=true probePathUsesWiFi=\(probeUsesWiFi) pathObservationIsProbeOnly=true")
        let wifiMetrics = PayloadMetrics()
        let wifi = try await Self.withDeadline(seconds: config.transferTimeoutSeconds, operation: "physical Wi-Fi fixture") {
            try await HybridTransfer.send(datasetDirectory: dataset, mesh: mesh, duration: 1,
                                          to: peer, pairingCode: config.pairingCode, metrics: { wifiMetrics.update($0) })
        }
        XCTAssertEqual(wifiMetrics.value?.connectionUsesWiFi, true, "Verify the actual source payload connection, not only the diagnostic probe")
        print("FORMA_HARDWARE_PAYLOAD_ROUTE productionBrowser=true payloadConnectionUsesWiFi=\(wifiMetrics.value?.connectionUsesWiFi == true)")
        print("FORMA_HARDWARE_WIFI_ACK session=\(config.sessionID) job=\(wifi.uuidString)")
        let usb = try await Self.withDeadline(seconds: config.transferTimeoutSeconds, operation: "physical USB fixture") {
            try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: dataset, mesh: mesh, duration: 2,
                                                             pairingCode: config.pairingCode, port: config.usbDevicePort)
        }
        print("FORMA_HARDWARE_USB_ACK session=\(config.sessionID) job=\(usb.uuidString)")
        XCTAssertEqual(try HybridTransfer.digest(fixture), config.fixtureSHA256)
        XCTAssertEqual(try HybridTransfer.digest(meshFile), config.canonicalMeshSHA256)
        XCTAssertEqual(try HybridTransfer.digest(dataset.appendingPathComponent("dataset.json")), manifestBefore)
        print("FORMA_HARDWARE_ORIGINALS_UNCHANGED session=\(config.sessionID)")
        #endif
    }

    private static func writeFixture(_ url: URL, count: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var position = 0
        while position < count {
            try Task.checkCancellation()
            let length = min(1_048_576, count-position)
            let data = Data((0..<length).map { UInt8((position+$0)%251) })
            try handle.write(contentsOf: data); position += length
        }
    }
    private static func withDeadline<T: Sendable>(seconds: Double, operation name: String,
                          body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw Deadline(operation: name) }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
