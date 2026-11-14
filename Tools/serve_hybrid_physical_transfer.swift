import Foundation
import Darwin

/// Physical QA destination, deliberately separate from every app/library/worker.
/// All transport, pairing, encryption, staging and commit logic is production.
private actor PhysicalTransferReports {
    let root: URL
    let expectedFiles: Int?
    let expectedBytes: Int64?
    private var reports: [UUID: URL] = [:]
    private var pending = 0
    init(root: URL, expectedFiles: Int?, expectedBytes: Int64?) {
        self.root = root; self.expectedFiles = expectedFiles; self.expectedBytes = expectedBytes
    }
    func received(_ job: HybridTransfer.ReceivedJob) async {
        pending += 1; defer { pending -= 1 }
        let reportURL = root.appendingPathComponent("received-" + job.id.uuidString + ".json")
        do {
            let receiptURL = job.directory.appendingPathComponent(".transfer.json")
            let receipt = try JSONDecoder().decode(HybridTransfer.TransferReceipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.jobID == job.id, try receipt.manifest.id == job.id,
                  try receipt.manifest.sha256 == receipt.manifestSHA256 else {
                throw HybridTransfer.TransferError.failed("QA receipt identity mismatch")
            }
            var files: [[String: Any]] = [], total: Int64 = 0
            for descriptor in receipt.manifest.files {
                guard ScanStore.safeRelativePath(descriptor.path) else { throw HybridTransfer.TransferError.failed("QA unsafe path") }
                var file = job.directory
                for component in descriptor.path.split(separator: "/") {
                    file.appendPathComponent(String(component))
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else { throw HybridTransfer.TransferError.failed("QA symlink rejected") }
                }
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else { throw HybridTransfer.TransferError.failed("QA non-file rejected") }
                let bytes = try HybridTransfer.size(file), sha = try HybridTransfer.digest(file)
                guard bytes == descriptor.bytes, sha == descriptor.sha256 else { throw HybridTransfer.TransferError.failed("QA streaming SHA verification failed") }
                let sum = total.addingReportingOverflow(bytes)
                guard !sum.overflow else { throw HybridTransfer.TransferError.failed("QA byte count overflow") }
                total = sum.partialValue
                files.append(["path": descriptor.path, "bytes": bytes, "sha256": sha])
            }
            var report: [String: Any] = ["verified": true, "jobID": job.id.uuidString,
                "directory": job.directory.path, "duration": job.duration,
                "manifestSHA256": receipt.manifestSHA256, "receiptSHA256": try HybridTransfer.digest(receiptURL),
                "fileCount": files.count, "payloadBytes": total, "files": files,
                "verification": "Independent streaming SHA-256 of every committed production-manifest entry",
                "freshIncomingAtStart": true, "datasetCopiedBeforeTransfer": false,
                "processingStarted": false, "libraryUsed": false, "verifiedAt": Date().timeIntervalSince1970]
            if let expectedFiles { report["expectedFileCount"] = expectedFiles; report["fileCountMatchesExpected"] = files.count == expectedFiles }
            if let expectedBytes { report["expectedPayloadBytes"] = expectedBytes; report["payloadBytesMatchExpected"] = total == expectedBytes }
            try Self.write(report, to: reportURL); reports[job.id] = reportURL
            try Self.write(["committedJobs": reports.map { ["jobID": $0.key.uuidString, "report": $0.value.path] },
                "count": reports.count, "processingStarted": false], to: root.appendingPathComponent("received-index.json"))
            print("QA committed and independently verified: " + job.id.uuidString + " · " + String(files.count) + " files · " + String(total) + " payload bytes")
            fflush(stdout)
        } catch {
            try? Self.write(["verified": false, "jobID": job.id.uuidString, "error": error.localizedDescription,
                "sourcesPreserved": true], to: reportURL)
            fputs("QA verification failed; received sources preserved. See owned report.\n", stderr)
        }
    }
    func hasPendingVerification() -> Bool { pending > 0 }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

@main struct PhysicalHybridTransferServer {
    struct Options {
        let root: URL
        let name: String
        let expectedFiles: Int?
        let expectedBytes: Int64?
        init() throws {
            let args = Array(CommandLine.arguments.dropFirst()); var values: [String: String] = [:]; var i = 0
            while i < args.count {
                guard ["--root", "--name", "--expected-files", "--expected-bytes"].contains(args[i]), i + 1 < args.count else {
                    throw HybridTransfer.TransferError.failed("Usage: serve_hybrid_physical_transfer.sh --root FRESH_OWNED_DIRECTORY [--name NAME] [--expected-files COUNT] [--expected-bytes BYTES]")
                }
                values[args[i]] = args[i + 1]; i += 2
            }
            guard let path = values["--root"], !path.isEmpty else { throw HybridTransfer.TransferError.failed("A fresh owned --root is required") }
            root = URL(fileURLWithPath: path).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: root.path) else { throw HybridTransfer.TransferError.failed("QA root must not already exist; no source dataset may be staged beforehand") }
            name = values["--name"] ?? "Forma prueba Wi-Fi"
            expectedFiles = values["--expected-files"].flatMap(Int.init)
            expectedBytes = values["--expected-bytes"].flatMap(Int64.init)
            if values["--expected-files"] != nil, expectedFiles == nil || expectedFiles! < 0 { throw HybridTransfer.TransferError.failed("Invalid expected count") }
            if values["--expected-bytes"] != nil, expectedBytes == nil || expectedBytes! < 0 { throw HybridTransfer.TransferError.failed("Invalid expected byte count") }
        }
    }
    static func writePrivate(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HybridTransfer.TransferError.failed("Could not create private QA key file") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard fchmod(fd, 0o600) == 0 else { throw HybridTransfer.TransferError.failed("Could not protect QA key file") }
        try file.write(contentsOf: Data((text + "\n").utf8)); try file.synchronize()
    }
    @MainActor static func main() async {
        do {
            let options = try Options(), fm = FileManager.default
            try fm.createDirectory(at: options.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let incoming = options.root.appendingPathComponent("incoming"), stop = options.root.appendingPathComponent("STOP")
            try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
            guard try fm.contentsOfDirectory(atPath: incoming.path).isEmpty else { throw HybridTransfer.TransferError.failed("QA incoming must be empty") }
            let reports = PhysicalTransferReports(root: options.root, expectedFiles: options.expectedFiles, expectedBytes: options.expectedBytes)
            let receiver = HybridTransferReceiver()
            try receiver.start(directory: incoming, name: options.name, onStatus: { id in
                .init(id: id, state: "unknown", progress: 0, resultAvailable: false,
                    error: "Receptor QA: fuentes conservadas; no hay motor ni cola de procesamiento.")
            }) { job in Task { await reports.received(job) } }
            let keyURL = options.root.appendingPathComponent("pairing-key.private")
            try writePrivate(receiver.pairingCode, to: keyURL)
            while receiver.listeningPort == nil {
                if receiver.status.hasPrefix("Transferencia interrumpida") { throw HybridTransfer.TransferError.failed("QA listener failed") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let readiness: [String: Any] = ["ready": true, "name": options.name, "port": receiver.listeningPort!,
                "serviceType": HybridTransfer.serviceType, "keyFile": keyURL.path, "incoming": incoming.path,
                "root": options.root.path, "stopFile": stop.path, "pid": getpid(), "includePeerToPeer": true,
                "freshIncomingAtStart": true, "processingStarted": false, "libraryUsed": false,
                "startedAt": Date().timeIntervalSince1970]
            try PhysicalTransferReports.write(readiness, to: options.root.appendingPathComponent("ready.json"))
            print(String(data: try JSONSerialization.data(withJSONObject: readiness, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
            var previous = ""
            while !fm.fileExists(atPath: stop.path) {
                if receiver.status != previous {
                    previous = receiver.status
                    try PhysicalTransferReports.write(["status": previous, "isListening": receiver.isListening,
                        "updatedAt": Date().timeIntervalSince1970], to: options.root.appendingPathComponent("receiver-status.json"))
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            receiver.stop()
            while await reports.hasPendingVerification() { try await Task.sleep(for: .milliseconds(100)) }
            try PhysicalTransferReports.write(["stopped": true, "receivedSourcesPreserved": true,
                "stoppedAt": Date().timeIntervalSince1970], to: options.root.appendingPathComponent("stopped.json"))
        } catch {
            fputs(("Physical QA receiver failed: " + error.localizedDescription + "\n"), stderr)
            exit(1)
        }
    }
}
