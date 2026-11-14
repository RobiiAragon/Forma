import Foundation
import Network
import Darwin

/// Read-only paired query. The session secret is read from a private file, never from argv or logs.
@main
struct HybridStatusQuery {
    private struct QueryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Options {
        var host: String
        var port: UInt16
        var jobID: UUID
        var keyFile: URL
        var output: URL?
        var timeout: Double = 15
        init() throws {
            let args = Array(CommandLine.arguments.dropFirst())
            var values: [String: String] = [:], index = 0
            let usage = "Usage: query_hybrid_status.sh --host HOST --port PORT --job-id UUID --key-file PRIVATE_0600_FILE [--out JSON_FILE] [--timeout SECONDS]"
            while index < args.count {
                let name = args[index]
                guard ["--host", "--port", "--job-id", "--jobID", "--key-file", "--out", "--timeout"].contains(name),
                      index + 1 < args.count else { throw QueryError(message: usage) }
                values[name] = args[index + 1]; index += 2
            }
            guard let host = values["--host"], !host.isEmpty,
                  let portValue = values["--port"], let port = UInt16(portValue), port > 0,
                  let jobValue = values["--job-id"] ?? values["--jobID"], let job = UUID(uuidString: jobValue),
                  let keyPath = values["--key-file"], !keyPath.isEmpty else { throw QueryError(message: usage) }
            self.host = host; self.port = port; jobID = job
            keyFile = URL(fileURLWithPath: keyPath).standardizedFileURL
            output = values["--out"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            if let text = values["--timeout"] {
                guard let value = Double(text), value.isFinite, value > 0 else { throw QueryError(message: "Timeout must be positive and finite.") }
                timeout = value
            }
            if let output, output.resolvingSymlinksInPath() == keyFile.resolvingSymlinksInPath() {
                throw QueryError(message: "The status JSON output must be separate from the key file.")
            }
        }
        func pairingCode() throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw QueryError(message: "Key file must be a regular file owned by this user with permissions 0600.")
            }
            guard let value = String(data: try Data(contentsOf: keyFile), encoding: .utf8) else {
                throw QueryError(message: "Key file must contain a UTF-8 pairing code.")
            }
            _ = try HybridTransfer.pairingKey(value)
            return value
        }
    }
    static func main() async {
        do {
            let options = try Options(), code = try options.pairingCode()
            guard let port = NWEndpoint.Port(rawValue: options.port) else { throw QueryError(message: "Invalid local receiver port.") }
            let peer = HybridTransfer.Peer(id: "explicit-local-status-query", displayName: "Forma status receiver",
                endpoint: .hostPort(host: NWEndpoint.Host(options.host), port: port))
            let status = try await withThrowingTaskGroup(of: HybridTransfer.RemoteJobStatus.self) { group in
                group.addTask { try await HybridTransfer.status(jobID: options.jobID, to: peer, pairingCode: code) }
                group.addTask {
                    try await Task.sleep(for: .seconds(options.timeout))
                    throw QueryError(message: "Local status query timed out.")
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw QueryError(message: "No status response received.") }
                return value
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var bytes = try encoder.encode(status); bytes.append(0x0a)
            if let output = options.output {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: output, options: .atomic)
            } else { FileHandle.standardOutput.write(bytes) }
        } catch {
            FileHandle.standardError.write(Data(("Hybrid status query failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
