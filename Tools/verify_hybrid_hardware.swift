import Foundation
import CryptoKit
import Network
import Darwin

/// Mac-side fixture receiver. Never launches Xcode, installs an app, or opens a camera.
@main struct HybridHardwareVerification {
    struct Configuration: Codable {
        var schemaVersion = 1
        var sessionID: String
        var serviceName: String
        var pairingCode: String
        var fixtureBytes = 8*1024*1024+33
        var fixtureSHA256: String
        var canonicalMeshSHA256: String
        var usbDevicePort: UInt16 = 49431
        var discoveryTimeoutSeconds = 30.0
        var transferTimeoutSeconds = 90.0
    }
    struct Failure: LocalizedError { var errorDescription: String?; init(_ text: String) { errorDescription = text } }
    @MainActor final class Inbox { var jobs: [HybridTransfer.ReceivedJob] = [] }
    static let testMethod = "HybridPhysicalTransportTests/testOptInPhysicalWiFiThenUSBWithLocalFixture"

    @MainActor static func main() async throws {
        umask(0o077)
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("Usage: verify_hybrid_hardware --device UDID --xctestrun BASE [--output DIRECTORY] [--usb-local-port PORT] [--usb-device-port PORT]")
            print("Starts a local fixture harness and writes a private opt-in xctestrun. Run the printed xcodebuild command separately. Does not build/install/launch device apps itself.")
            return
        }
        var options: [String:String] = [:], index = 0
        while index < args.count {
            guard ["--device","--xctestrun","--output","--usb-local-port","--usb-device-port"].contains(args[index]),
                  index+1 < args.count else { throw Failure("Unknown or incomplete argument; use --help.") }
            options[args[index]] = args[index+1]; index += 2
        }
        guard let device = options["--device"], !device.isEmpty,
              device.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }),
              let runPath = options["--xctestrun"] else { throw Failure("An explicit device UDID and base xctestrun are required.") }
        let base = URL(fileURLWithPath: runPath).standardizedFileURL
        let session = UUID().uuidString
        let output = URL(fileURLWithPath: options["--output"] ?? "build/Validation/HybridHardware-\(session)").standardizedFileURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure("Choose a new output directory to avoid overwriting evidence.") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let localPort = try port(options["--usb-local-port"] ?? "49432")
        let phonePort = try port(options["--usb-device-port"] ?? "49431")
        let serviceName = "Forma Hardware QA " + session.prefix(8)
        let receiver = HybridTransferReceiver(), inbox = Inbox()
        var proxy: Process?
        defer { receiver.stop(); if proxy?.isRunning == true { proxy?.terminate() } }
        try receiver.start(directory: output.appendingPathComponent("received"), name: serviceName) { job in
            Task { @MainActor in inbox.jobs.append(job) }
        }
        let readyDeadline = Date().addingTimeInterval(10)
        while !receiver.isListening && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(100)) }
        guard receiver.isListening else { throw Failure("Mac listener failed: " + receiver.status) }
        let fixture = output.appendingPathComponent("expected-fixture.bin")
        try writeFixture(fixture, count: 8*1024*1024+33)
        let mesh = MeshSnapshot(vertices: [.init(0,0,0),.init(1,0,0),.init(0,1,0)], triangles: [0,1,2])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let meshData = try encoder.encode(mesh)
        let meshHash = SHA256.hash(data: meshData).map { String(format:"%02x",$0) }.joined()
        let config = Configuration(sessionID:session, serviceName:String(serviceName), pairingCode:receiver.pairingCode,
                                   fixtureSHA256:try HybridTransfer.digest(fixture), canonicalMeshSHA256:meshHash,
                                   usbDevicePort:phonePort)
        let configData = try encoder.encode(config)
        let privateConfig = output.appendingPathComponent("session-private.json")
        try configData.write(to:privateConfig, options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:privateConfig.path)
        let run = output.appendingPathComponent("HardwareFixture.xctestrun")
        try writeRun(base:base, output:run, config:configData)
        print("HARDWARE_QA_READY session=\(session) Bonjour=\(serviceName) fixtureBytes=\(config.fixtureBytes)")
        print("PRIVATE_CONFIG \(privateConfig.path) (ephemeral pairing key; do not publish)")
        print("Run separately after the physical test bundle is rebuilt:")
        print(["xcodebuild","test-without-building","-xctestrun",run.path,"-destination","id="+device,
               "-parallel-testing-enabled","NO","-collect-test-diagnostics","never","-resultBundlePath",output.appendingPathComponent("HardwareFixture.xcresult").path].map(quote).joined(separator:" "))
        fflush(stdout)
        var report: [[String:Any]] = []
        do {
            let wifi = try await awaitJob(duration:1, inbox:inbox, timeout:240, receiver:receiver)
            report.append(try verify(wifi, label:"physical-WiFi-Bonjour", config:config, mesh:mesh))
            print("PASS Bonjour fixture: Wi-Fi-scoped payload endpoint + separate NWPath probe evidence; source/mesh hashes exact")
            let candidates = ["/opt/homebrew/bin/iproxy","/usr/local/bin/iproxy"]
            guard let executable = candidates.first(where:{fm.isExecutableFile(atPath:$0)}) else { throw Failure("iproxy missing; install the free libusbmuxd helper before USB QA.") }
            let process = Process(); process.executableURL = URL(fileURLWithPath:executable)
            process.arguments = ["-l","-s","127.0.0.1","-u",device,"\(localPort):\(phonePort)"]
            let proxyLog = output.appendingPathComponent("iproxy.log")
            fm.createFile(atPath:proxyLog.path,contents:nil)
            let log = try FileHandle(forWritingTo:proxyLog)
            process.standardOutput=log; process.standardError=log
            try process.run(); proxy=process
            defer { try? log.close() }
            try await Task.sleep(for:.milliseconds(500))
            guard process.isRunning else { throw Failure("iproxy exited; inspect its log (port may already be occupied).") }
            let usbDeadline = Date().addingTimeInterval(90)
            var lastAttempt = Date.distantPast
            while !inbox.jobs.contains(where:{$0.duration == 2}) && Date() < usbDeadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw Failure("iproxy stopped during USB transfer.") }
                if lastAttempt == .distantPast || (receiver.status.hasPrefix("USB-C interrumpido:") && Date().timeIntervalSince(lastAttempt) > 1) {
                    try receiver.connectUSB(directory:output.appendingPathComponent("received"),host:"127.0.0.1",port:localPort,pairingCode:config.pairingCode) { job in
                        Task { @MainActor in inbox.jobs.append(job) }
                    }
                    lastAttempt=Date()
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            guard let usb=inbox.jobs.first(where:{$0.duration == 2}) else { throw Failure("USB fixture timed out after 90 seconds: "+receiver.status) }
            report.append(try verify(usb,label:"physical-USB-usbmux",config:config,mesh:mesh))
            print("PASS physical USB-C/iproxy: native fixture SHA-256, canonical/source mesh exact, committed and acknowledged")
            try saveReport(output:output,session:session,config:config,report:report,error:nil)
            print("HARDWARE_QA_PASS Mac received both fixture transports. Confirm XCTest also reports ORIGINALS_UNCHANGED and success.")
        } catch {
            try? saveReport(output:output,session:session,config:config,report:report,error:error.localizedDescription)
            throw error
        }
    }
    static func port(_ text:String)throws->UInt16 {
        guard let value=UInt16(text),value>1024 else { throw Failure("Use a TCP port between 1025 and 65535.") }; return value
    }
    static func quote(_ text:String)->String { "'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'" }
    @MainActor static func awaitJob(duration:Double,inbox:Inbox,timeout:Double,receiver:HybridTransferReceiver)async throws->HybridTransfer.ReceivedJob {
        let deadline=Date().addingTimeInterval(timeout)
        while Date()<deadline {
            try Task.checkCancellation()
            if let job=inbox.jobs.first(where:{$0.duration == duration}) { return job }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw Failure("No physical fixture arrived within harness timeout: "+receiver.status)
    }
    static func verify(_ job:HybridTransfer.ReceivedJob,label:String,config:Configuration,mesh:MeshSnapshot)throws->[String:Any] {
        let source=job.datasetDirectory.appendingPathComponent("fixture.bin")
        let sourceMesh=job.datasetDirectory.appendingPathComponent("mesh-source.json")
        guard try HybridTransfer.size(source)==Int64(config.fixtureBytes),
              try HybridTransfer.digest(source)==config.fixtureSHA256,
              try HybridTransfer.digest(sourceMesh)==config.canonicalMeshSHA256 else { throw Failure(label+" file hashes/bytes differ") }
        let received=try JSONDecoder().decode(MeshSnapshot.self,from:Data(contentsOf:job.meshURL))
        guard received.vertices==mesh.vertices,received.triangles==mesh.triangles else { throw Failure(label+" native mesh geometry differs") }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let canonical=SHA256.hash(data:try encoder.encode(received)).map{String(format:"%02x",$0)}.joined()
        guard canonical==config.canonicalMeshSHA256 else { throw Failure(label+" canonical native mesh differs") }
        guard let route=try JSONSerialization.jsonObject(with:Data(contentsOf:job.datasetDirectory.appendingPathComponent("route-evidence.json"))) as? [String:Any],
              route["endpointInterfaceType"] as? String == "wifi",route["payloadEndpointScopedToWiFi"] as? Bool == true,
              route["probeUsesWiFi"] as? Bool == true,route["pathObservationIsProbeOnly"] as? Bool == true else { throw Failure("Missing or unverified Wi-Fi route evidence") }
        return ["transport":label,"jobID":job.id.uuidString,"sourceBytes":config.fixtureBytes,"sourceSHA256":config.fixtureSHA256,
                "sourceMeshSHA256":config.canonicalMeshSHA256,"nativeMeshCanonicalSHA256":canonical,
                "nativeMeshWireSHA256":try HybridTransfer.digest(job.meshURL),"committed":true,
                "wifiRouteEvidence":route,"usbForwardingUsesLocalUSBOnlyFlag":label.contains("USB")]
    }
    static func writeFixture(_ url:URL,count:Int)throws {
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()}
        var position=0
        while position<count { try Task.checkCancellation();let length=min(1_048_576,count-position)
            try handle.write(contentsOf:Data((0..<length).map{UInt8((position+$0)%251)}));position+=length }
    }
    static func writeRun(base:URL,output:URL,config:Data)throws {
        guard let root=try PropertyListSerialization.propertyList(from:Data(contentsOf:base),format:nil) as? [String:Any],
              var target=root["FormaTests"] as? [String:Any] else { throw Failure("Expected the project's FormatVersion1 xctestrun with FormaTests.") }
        var environment=target["EnvironmentVariables"] as? [String:String] ?? [:]
        environment["FORMA_HYBRID_HARDWARE_OPT_IN"]="1"
        environment["FORMA_HYBRID_HARDWARE_CONFIG"]=config.base64EncodedString()
        target["EnvironmentVariables"]=environment
        target["OnlyTestIdentifiers"]=[testMethod]
        target["TestTimeoutsEnabled"]=true
        target["DefaultTestExecutionTimeAllowance"]=240
        target["MaximumTestExecutionTimeAllowance"]=300
        let derived:[String:Any]=["__xctestrun_metadata__":root["__xctestrun_metadata__"] ?? [:],"FormaTests":target]
        func absolute(_ object:Any)->Any {
            if let text=object as? String { return text.replacingOccurrences(of:"__TESTROOT__",with:base.deletingLastPathComponent().path) }
            if let array=object as? [Any] { return array.map(absolute) }
            if let dictionary=object as? [String:Any] { return dictionary.mapValues(absolute) }
            return object
        }
        let data=try PropertyListSerialization.data(fromPropertyList:absolute(derived),format:.xml,options:0)
        try data.write(to:output,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
    }
    static func saveReport(output:URL,session:String,config:Configuration,report:[[String:Any]],error:String?)throws {
        var result:[String:Any]=["sessionID":session,"schemaVersion":1,"fixtureOnly":true,"cloudUsed":false,
                                "fixtureBytes":config.fixtureBytes,"results":report,"macReceivedBoth":report.count==2,
                                "phoneXCTestResultMustBeCheckedSeparately":true]
        if let error { result["error"]=error }
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("hardware-report.json"),options:.atomic)
    }
}
