import Foundation
import Network
import CryptoKit
import Security
import Combine

/// Local, paired transfers. Captures stay on the phone; only complete, verified jobs are published.
enum HybridTransfer {
    static let serviceType = "_forma-rgbd._tcp"
    static let chunkBytes = 1024 * 1024

    enum TransferStage: Sendable, Equatable {
        case connecting
        case authenticating
        case hashing(completedBytes: Double, totalBytes: Double)
        case negotiating
        case verifying
    }

    struct Peer: Identifiable, @unchecked Sendable {
        var id: String
        var displayName: String
        var endpoint: NWEndpoint
        var includePeerToPeer: Bool = false
    }

    /// Direct discovery and every later operation must use the same peer-to-peer policy.
    static func networkParameters(for peer: Peer) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peer.includePeerToPeer
        return parameters
    }
    struct ReceivedJob: Sendable, Identifiable {
        var id: UUID
        var directory: URL
        var datasetDirectory: URL { directory.appendingPathComponent("dataset", isDirectory: true) }
        var meshURL: URL { directory.appendingPathComponent("malla-original.json") }
        var duration: TimeInterval
    }
    struct ProcessingRequest: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable { case lidar, gaussian }
        var kind: Kind
        var iterations: Int? = nil
        var downscale: Float? = nil

        /// Optional values use the receiver's defaults; bounds reflect the native ABI, not quotas.
        func validate() throws {
            if let iterations, iterations <= 0 || iterations > Int(Int32.max) {
                throw TransferError.failed("Las iteraciones deben ser positivas y representables por el motor Gaussian.")
            }
            if let downscale, !downscale.isFinite || downscale < 1 {
                throw TransferError.failed("El factor de resolución debe ser finito e igual o superior a 1.")
            }
        }
    }
    struct RemoteJobStatus: Codable, Equatable, Sendable {
        var id: UUID
        var state: String
        var progress: Double
        var iteration: Int? = nil
        var targetIterations: Int? = nil
        var splats: Int? = nil
        var resultAvailable: Bool
        var error: String? = nil
        var controlRevision: UUID? = nil
        var supportedCommands: [RemoteJobCommand.Action]? = nil

        func validate(jobID: UUID) throws {
            guard id == jobID, !state.isEmpty, progress.isFinite, progress >= 0, progress <= 1,
                  iteration.map({ $0 >= 0 }) ?? true, targetIterations.map({ $0 > 0 }) ?? true,
                  splats.map({ $0 >= 0 }) ?? true else {
                throw TransferError.failed("La respuesta de estado del Mac no es válida.")
            }
        }
    }
    struct RemoteJobCommand: Codable, Equatable, Sendable {
        enum Action: String, Codable, Equatable, Sendable { case pause, resume, cancel, export }
        var id: UUID
        var jobID: UUID
        var action: Action
        var expectedRevision: UUID? = nil
    }
    struct RemoteCommandReply: Codable, Equatable, Sendable {
        var commandID: UUID
        var jobID: UUID
        var state: String
        var status: RemoteJobStatus
        var error: String? = nil
        func validate(command: RemoteJobCommand) throws {
            guard commandID == command.id, jobID == command.jobID, !state.isEmpty else {
                throw TransferError.failed("El Mac respondió a otro comando.")
            }
            try status.validate(jobID: command.jobID)
        }
    }
    struct ResultDescriptor: Codable, Equatable, Sendable {
        var jobID: UUID
        var resultID: UUID
        var name: String
        var mode: String
        var duration: Double
        var note: String = ""
        var statistics: [String: Double]? = nil
        var modelRelativePath: String? = nil
        var packageRelativePath: String? = nil
        var meshRelativePath: String? = nil
        /// Relative to packageRelativePath, matching ScanStore's Gaussian package convention.
        var gaussianModelRelativePath: String? = nil

        func validate() throws {
            guard !name.isEmpty, ScanMode(rawValue: mode) != nil, duration.isFinite, duration >= 0,
                  statistics?.values.allSatisfy({ $0.isFinite }) ?? true,
                  modelRelativePath != nil || meshRelativePath != nil else {
                throw TransferError.failed("El descriptor del resultado no es válido.")
            }
            for path in [modelRelativePath, packageRelativePath, meshRelativePath, gaussianModelRelativePath].compactMap({ $0 }) {
                guard resultPath(path) else { throw TransferError.failed("Ruta del resultado no válida.") }
            }
            if let package = packageRelativePath, let model = modelRelativePath {
                guard model.hasPrefix(package + "/") else { throw TransferError.failed("El modelo debe estar dentro de su paquete.") }
            }
            if gaussianModelRelativePath != nil, packageRelativePath == nil {
                throw TransferError.failed("Falta el paquete del resultado Gaussian.")
            }
        }
    }
    struct ResultSource: Sendable { var descriptor: ResultDescriptor; var directory: URL }
    struct DownloadedResult: Sendable {
        var descriptor: ResultDescriptor
        var directory: URL
        var manifestSHA256: String
    }
    typealias StatusProvider = @Sendable (UUID) async throws -> RemoteJobStatus
    typealias CommandProvider = @Sendable (RemoteJobCommand) async throws -> RemoteCommandReply
    typealias ResultProvider = @Sendable (UUID) async throws -> ResultSource
    struct Header: Codable {
        var kind: String
        var jobID: UUID? = nil
        var duration: Double? = nil
        var path: String? = nil
        var bytes: Int64? = nil
        var sha256: String? = nil
        var version: Int? = nil
        var manifestSHA256: String? = nil
        var status: RemoteJobStatus? = nil
        var command: RemoteJobCommand? = nil
        var commandReply: RemoteCommandReply? = nil
        var message: String? = nil
    }
    struct TransferMetrics: Sendable {
        var transmittedPayloadBytes: Int64 = 0
        var resumedPayloadBytes: Int64 = 0
        var alreadyCommitted = false
        var connectionUsesWiFi: Bool? = nil
    }
    struct FileDescriptor: Codable, Equatable {
        var path: String
        var bytes: Int64
        var sha256: String
    }
    struct Manifest: Codable, Equatable {
        var version = 2
        var duration: Double
        var files: [FileDescriptor]
        var encoded: Data {
            get throws { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(self) }
        }
        var sha256: String { get throws { hex(SHA256.hash(data: try encoded)) } }
        var id: UUID {
            get throws {
                var bytes = Array(SHA256.hash(data: try encoded).prefix(16))
                bytes[6] = (bytes[6] & 0x0f) | 0x80
                bytes[8] = (bytes[8] & 0x3f) | 0x80
                return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                                   bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            }
        }
    }
    struct TransferReceipt: Codable, Equatable {
        var jobID: UUID
        var manifestSHA256: String
        var manifest: Manifest
    }
    /// One writer per capture, including simultaneous Wi-Fi and USB connections.
    final class ReceivingLease {
        private static let lock = NSLock()
        private static var active: Set<String> = []
        private let key: String
        private init(key: String) { self.key = key }
        static func acquire(directory: URL, id: UUID) throws -> ReceivingLease {
            let key = directory.resolvingSymlinksInPath().path + "/" + id.uuidString
            lock.lock(); defer { lock.unlock() }
            guard active.insert(key).inserted else { throw TransferError.failed("Esta captura ya se está transfiriendo. Espera a que termine la conexión anterior y vuelve a intentar.") }
            return ReceivingLease(key: key)
        }
        deinit { Self.lock.lock(); Self.active.remove(key); Self.lock.unlock() }
    }
    enum TransferError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let reason) = self { return reason }; return nil }
    }

    static func pairingKey(_ code: String) throws -> SymmetricKey {
        let clean = code.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 32, clean.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw TransferError.failed("Pega la clave de sesión de 32 caracteres que muestra Forma Desktop.")
        }
        var bytes = Data()
        for offset in stride(from: 0, to: 32, by: 2) {
            let a = clean.index(clean.startIndex, offsetBy: offset), b = clean.index(a, offsetBy: 2)
            guard let byte = UInt8(clean[a..<b], radix: 16) else { throw TransferError.failed("Clave de sesión no válida.") }
            bytes.append(byte)
        }
        return SymmetricKey(data: bytes)
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw TransferError.failed("No se pudo crear una clave segura para esta sesión.")
        }
        return Data(bytes)
    }

    /// Streams one file at a time with TCP backpressure; no archive or multi-gigabyte Data is made.
    @discardableResult
    static func send(datasetDirectory: URL, mesh: MeshSnapshot, duration: TimeInterval,
                     to peer: Peer, pairingCode: String,
                     processingRequest: ProcessingRequest? = nil,
                     stage: @escaping @Sendable (TransferStage) -> Void = { _ in },
                     metrics: @escaping @Sendable (TransferMetrics) -> Void = { _ in },
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> UUID {
        try Task.checkCancellation()
        try processingRequest?.validate()
        let key = try pairingKey(pairingCode)
        let channel = Channel(NWConnection(to: peer.endpoint, using: networkParameters(for: peer)))
        return try await sendStream(datasetDirectory: datasetDirectory, mesh: mesh, duration: duration,
                                    channel: channel, key: key, processingRequest: processingRequest, stage: stage, metrics: metrics, progress: progress)
    }

    /// The Mac forwards localhost:49232 to this iPhone port through usbmux/iproxy.
    @discardableResult
    static func sendOverUSBWaitingForMac(datasetDirectory: URL, mesh: MeshSnapshot, duration: TimeInterval,
                                        pairingCode: String, port: UInt16 = 49231,
                                        processingRequest: ProcessingRequest? = nil,
                                        stage: @escaping @Sendable (TransferStage) -> Void = { _ in },
                                        metrics: @escaping @Sendable (TransferMetrics) -> Void = { _ in },
                                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> UUID {
        try Task.checkCancellation()
        try processingRequest?.validate()
        let key = try pairingKey(pairingCode)
        return try await withUSBChannel(port: port) { channel in
            try await sendStream(datasetDirectory: datasetDirectory, mesh: mesh, duration: duration,
                channel: channel, key: key, processingRequest: processingRequest, stage: stage, metrics: metrics, progress: progress)
        }
    }

    private static func withUSBChannel<Value>(port: UInt16, operation: (Channel) async throws -> Value) async throws -> Value {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw TransferError.failed("Puerto USB no válido.") }
        let listener = try NWListener(using: .tcp, on: port)
        let gate = ConnectionGate()
        let connection: NWConnection = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                listener.newConnectionHandler = { connection in
                    if gate.take() { continuation.resume(returning: connection) } else { connection.cancel() }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error): if gate.take() { continuation.resume(throwing: error) }
                    case .cancelled: if gate.take() { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue(label: "com.forma.usb-wait"))
            }
        }, onCancel: { listener.cancel() })
        defer { listener.cancel() }
        return try await operation(Channel(connection))
    }

    private final class ConnectionGate: @unchecked Sendable {
        let lock = NSLock(); var used = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; guard !used else { return false }; used = true; return true }
    }

    /// A fresh paired, encrypted query. No job sources or result files are sent.
    static func status(jobID: UUID, to peer: Peer, pairingCode: String) async throws -> RemoteJobStatus {
        try Task.checkCancellation()
        return try await statusStream(jobID: jobID, channel: Channel(NWConnection(to: peer.endpoint, using: networkParameters(for: peer))),
            key: pairingKey(pairingCode))
    }

    /// Same reverse USB connection as source delivery. The Mac connects with connectUSB and its status provider.
    static func statusOverUSBWaitingForMac(jobID: UUID, pairingCode: String, port: UInt16 = 49231) async throws -> RemoteJobStatus {
        try Task.checkCancellation()
        let key = try pairingKey(pairingCode)
        return try await withUSBChannel(port: port) { channel in
            try await statusStream(jobID: jobID, channel: channel, key: key)
        }
    }

    private static func clientCipher(channel: Channel, key: SymmetricKey,
                                     stage: @Sendable (TransferStage) -> Void = { _ in }) async throws -> Cipher {
        try Task.checkCancellation()
        stage(.connecting)
        try await channel.start()
        stage(.authenticating)
        let challenge = try await channel.readExactly(32)
        try await channel.write(Data(HMAC<SHA256>.authenticationCode(for: challenge + Data("client".utf8), using: key)))
        let response: Data
        do { response = try await channel.readExactly(32) }
        catch {
            try Task.checkCancellation()
            throw TransferError.failed("No se completó la autenticación con la Mac. Comprueba su clave de sesión y vuelve a conectar. \(error.localizedDescription)")
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(response, authenticating: challenge + Data("server".utf8), using: key) else {
            throw TransferError.failed("La clave de sesión del Mac no coincide.")
        }
        return Cipher(channel: channel, pairingKey: key, challenge: challenge, sending: "client", receiving: "server")
    }

    private static func statusStream(jobID: UUID, channel: Channel, key: SymmetricKey) async throws -> RemoteJobStatus {
        try await withTaskCancellationHandler(operation: {
            defer { channel.cancel() }
            let cipher = try await clientCipher(channel: channel, key: key)
            try await cipher.send(JSONEncoder().encode(Header(kind: "status-query", jobID: jobID, version: 1)))
            let response = try JSONDecoder().decode(Header.self, from: await cipher.receive())
            guard response.kind == "status-response", response.version == 1, response.jobID == jobID else {
                throw TransferError.failed("El Mac no confirmó el trabajo consultado. Actualiza ambas apps si no admiten consultas de estado.")
            }
            if let message = response.message { throw TransferError.failed(message) }
            guard let status = response.status else { throw TransferError.failed("El Mac no envió el estado del trabajo.") }
            try status.validate(jobID: jobID)
            return status
        }, onCancel: { channel.cancel() })
    }

    private static func sendStream(datasetDirectory: URL, mesh: MeshSnapshot, duration: TimeInterval,
                                   channel: Channel, key: SymmetricKey,
                                   processingRequest: ProcessingRequest?,
                                   stage: @escaping @Sendable (TransferStage) -> Void,
                                   metrics: @escaping @Sendable (TransferMetrics) -> Void,
                                   progress: @escaping @Sendable (Double) -> Void) async throws -> UUID {
        return try await withTaskCancellationHandler(operation: {
            defer { channel.cancel() }
            try Task.checkCancellation()
            try processingRequest?.validate()
            guard duration.isFinite, duration >= 0 else { throw TransferError.failed("Duración de captura no válida.") }
            let cipher = try await clientCipher(channel: channel, key: key, stage: stage)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FormaHybridSend-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let rawMesh = temporary.appendingPathComponent("malla-original.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(mesh).write(to: rawMesh, options: .atomic)
            var sources: [String: URL] = ["malla-original.json": rawMesh]
            if let processingRequest {
                let request = temporary.appendingPathComponent("procesamiento.json")
                try encoder.encode(processingRequest).write(to: request, options: .atomic)
                sources["procesamiento.json"] = request
            }
            guard let enumerator = FileManager.default.enumerator(atPath: datasetDirectory.path) else {
                throw TransferError.failed("No se pudieron enumerar las fuentes de la captura.")
            }
            while let relative = enumerator.nextObject() as? String {
                try Task.checkCancellation()
                guard ScanStore.safeRelativePath(relative) else { throw TransferError.failed("Ruta de fuentes no válida.") }
                let url = datasetDirectory.appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw TransferError.failed("Las fuentes contienen un enlace que no se puede transferir.") }
                if values.isRegularFile == true { sources["dataset/" + relative] = url }
            }
            let paths = sources.keys.sorted()
            let sizes = try paths.map { try size(sources[$0]!) }
            let totalBytes = sizes.reduce(0.0) { $0 + Double($1) }
            var hashedBytes = 0.0
            stage(.hashing(completedBytes: 0, totalBytes: totalBytes))
            let files = try paths.enumerated().map { index, path -> FileDescriptor in
                try Task.checkCancellation()
                let url = sources[path]!
                let base = hashedBytes
                let sha = try digest(url) { bytes in
                    stage(.hashing(completedBytes: base + Double(bytes), totalBytes: totalBytes))
                }
                hashedBytes += Double(sizes[index])
                return FileDescriptor(path: path, bytes: sizes[index], sha256: sha)
            }
            guard sources["dataset/dataset.json"] != nil else { throw TransferError.failed("Falta la calibración de la captura.") }
            let manifest = Manifest(duration: duration, files: files)
            let job = try manifest.id, manifestSHA = try manifest.sha256
            stage(.negotiating)
            try await cipher.send(encoder.encode(Header(kind: "job-v2", jobID: job, duration: duration, version: 2, manifestSHA256: manifestSHA)))
            for file in files {
                try await cipher.send(encoder.encode(Header(kind: "manifest-file", path: file.path, bytes: file.bytes, sha256: file.sha256)))
            }
            try await cipher.send(encoder.encode(Header(kind: "manifest-done")))
            let acceptance: Header
            do { acceptance = try JSONDecoder().decode(Header.self, from: await cipher.receive()) }
            catch { throw TransferError.failed("El Mac no pudo negociar la transferencia reanudable. Actualiza ambas apps y vuelve a conectar. \(error.localizedDescription)") }
            guard acceptance.jobID == job, acceptance.manifestSHA256 == manifestSHA else {
                throw TransferError.failed("El Mac confirmó otra captura.")
            }
            let total = files.reduce(0.0) { $0 + Double($1.bytes) }
            var statistics = TransferMetrics(), accounted = 0.0
            statistics.connectionUsesWiFi = channel.connection.currentPath?.usesInterfaceType(.wifi)
            if acceptance.kind == "committed" {
                statistics.alreadyCommitted = true
                statistics.resumedPayloadBytes = files.reduce(0) { $0 + $1.bytes }
                metrics(statistics); progress(1); return job
            }
            guard acceptance.kind == "ready" else { throw TransferError.failed("El Mac no aceptó las fuentes.") }
            for file in files {
                try Task.checkCancellation()
                let url = sources[file.path]!
                guard try size(url) == file.bytes else { throw TransferError.failed("Una fuente cambió durante la transferencia.") }
                try await cipher.send(encoder.encode(Header(kind: "file", path: file.path, bytes: file.bytes, sha256: file.sha256)))
                let request = try JSONDecoder().decode(Header.self, from: await cipher.receive())
                guard request.kind == "resume-file", request.path == file.path, let offset = request.bytes,
                      offset >= 0, offset <= file.bytes, let prefixSHA = request.sha256, validSHA(prefixSHA) else {
                    throw TransferError.failed("El punto de reanudación del Mac no es válido.")
                }
                let localPrefix = offset == file.bytes ? file.sha256 : try digest(url, prefixBytes: offset)
                let resumed = localPrefix == prefixSHA ? offset : 0
                try await cipher.send(encoder.encode(Header(kind: resumed == offset ? "append-file" : "restart-file", path: file.path)))
                statistics.resumedPayloadBytes += resumed; accounted += Double(resumed)
                progress(total > 0 ? min(1, accounted / total) : 1)
                let handle = try FileHandle(forReadingFrom: url)
                do {
                    try handle.seek(toOffset: UInt64(resumed))
                    var actual = resumed
                    while let data = try autoreleasepool(invoking: { try handle.read(upToCount: chunkBytes) }), !data.isEmpty {
                        try Task.checkCancellation()
                        guard Int64(data.count) <= file.bytes - actual else { throw TransferError.failed("Una fuente cambió durante la transferencia.") }
                        try await cipher.send(data)
                        actual += Int64(data.count); statistics.transmittedPayloadBytes += Int64(data.count); accounted += Double(data.count)
                        progress(total > 0 ? min(1, accounted / total) : 1)
                    }
                    try handle.close()
                    guard actual == file.bytes else { throw TransferError.failed("Una fuente cambió durante la transferencia.") }
                } catch { try? handle.close(); throw error }
                let verified = try JSONDecoder().decode(Header.self, from: await cipher.receive())
                guard verified.kind == "file-verified", verified.path == file.path else {
                    throw TransferError.failed("El Mac no verificó una fuente.")
                }
            }
            stage(.verifying)
            try await cipher.send(encoder.encode(Header(kind: "done")))
            let acknowledged = try JSONDecoder().decode(Header.self, from: await cipher.receive())
            guard acknowledged.kind == "committed", acknowledged.jobID == job, acknowledged.manifestSHA256 == manifestSHA else {
                throw TransferError.failed("El Mac no confirmó los archivos.")
            }
            metrics(statistics); progress(1)
            return job
        }, onCancel: { channel.cancel() })
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && (("0"..."9").contains($0) || ("a"..."f").contains($0)) }
    }
    static func validPath(_ path: String) -> Bool {
        ScanStore.safeRelativePath(path) && (path == "malla-original.json" || path == "procesamiento.json" || path.hasPrefix("dataset/"))
    }
    static func digest(_ url: URL, prefixBytes: Int64) throws -> String {
        guard let hash = try prefixHash(url, bytes: prefixBytes) else { throw TransferError.failed("Una fuente cambió durante la verificación.") }
        return hex(hash.finalize())
    }
    static func prefixHash(_ url: URL, bytes: Int64) throws -> SHA256? {
        guard bytes >= 0 else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try autoreleasepool(invoking: { try handle.read(upToCount: Int(min(Int64(chunkBytes), remaining))) }), !data.isEmpty else { return nil }
            hash.update(data: data); remaining -= Int64(data.count)
        }
        return hash
    }

    static func size(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func digest(_ url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try autoreleasepool(invoking: { try handle.read(upToCount: chunkBytes) }), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
            bytes += Int64(data.count); progress(bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    final class Channel: @unchecked Sendable {
        private final class StartGate: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            func take() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return false }; finished = true; return true
            }
        }
        let connection: NWConnection
        let queue = DispatchQueue(label: "com.forma.local-transfer")
        init(_ connection: NWConnection) { self.connection = connection }
        func cancel() { connection.cancel() }
        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = StartGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if gate.take() { continuation.resume() }
                    case .failed(let error): if gate.take() { continuation.resume(throwing: error) }
                    case .waiting(let error): if gate.take() { continuation.resume(throwing: error) }; self.connection.cancel()
                    case .cancelled: if gate.take() { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
        func readExactly(_ count: Int) async throws -> Data {
            var data = Data()
            while data.count < count {
                try Task.checkCancellation()
                let needed = count - data.count
                let part: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { bytes, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                        else { continuation.resume(throwing: TransferError.failed(complete ? "La conexión local se cerró." : "No se recibieron datos.")) }
                    }
                }
                data.append(part)
            }
            return data
        }
        func write(_ data: Data) async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }

    final class Cipher {
        let channel: Channel
        let key: SymmetricKey
        let sending: String, receiving: String
        var sent: UInt64 = 0, received: UInt64 = 0
        init(channel: Channel, pairingKey: SymmetricKey, challenge: Data, sending: String, receiving: String) {
            self.channel = channel; self.sending = sending; self.receiving = receiving
            key = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairingKey, salt: challenge, info: Data("Forma LAN v1".utf8), outputByteCount: 32)
        }
        private func aad(_ direction: String, _ number: UInt64) -> Data {
            var value = number.bigEndian
            return Data(direction.utf8) + withUnsafeBytes(of: &value) { Data($0) }
        }
        func send(_ plaintext: Data) async throws {
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad(sending, sent))
            guard let bytes = sealed.combined, bytes.count <= HybridTransfer.chunkBytes + 4096 else { throw TransferError.failed("Bloque local demasiado grande.") }
            var length = UInt32(bytes.count).bigEndian
            try await channel.write(withUnsafeBytes(of: &length) { Data($0) })
            try await channel.write(bytes); sent += 1
        }
        func receive() async throws -> Data {
            let header = try await channel.readExactly(4)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 28, length <= HybridTransfer.chunkBytes + 4096 else { throw TransferError.failed("El bloque local no es válido.") }
            let bytes = try await channel.readExactly(Int(length))
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad(receiving, received))
            received += 1; return data
        }
    }
}

@MainActor
final class HybridTransferBrowser: ObservableObject {
    @Published private(set) var peers: [HybridTransfer.Peer] = []
    @Published private(set) var status = "Buscando Forma Desktop en tu red local"
    private var browser: NWBrowser?
    private var generation = UUID()
    nonisolated static func networkParameters(peerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
        if !peerToPeer { parameters.requiredInterfaceType = .wifi }
        return parameters
    }

    nonisolated static func peer(endpoint: NWEndpoint, interfaces: [NWInterface],
                                 peerToPeer: Bool) -> HybridTransfer.Peer? {
        guard case .service(let name, let type, let domain, let endpointInterface) = endpoint else { return nil }
        if peerToPeer {
            // A required interface prevents Network from selecting an Apple peer-to-peer path.
            return .init(id: name + type + domain, displayName: name,
                endpoint: .service(name: name, type: type, domain: domain, interface: nil), includePeerToPeer: true)
        }
        guard let wifi = ([endpointInterface].compactMap { $0 } + interfaces).first(where: { $0.type == .wifi }) else { return nil }
        return .init(id: name + type + domain, displayName: name,
            endpoint: .service(name: name, type: type, domain: domain, interface: wifi))
    }

    func start(peerToPeer: Bool = false) {
        stop()
        let generation = self.generation
        status = peerToPeer ? "Buscando un Mac cercano con Forma Desktop" : "Buscando Forma Desktop en tu red local"
        let browser = NWBrowser(for: .bonjour(type: HybridTransfer.serviceType, domain: nil),
                                using: Self.networkParameters(peerToPeer: peerToPeer))
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { Self.peer(endpoint: $0.endpoint, interfaces: $0.interfaces, peerToPeer: peerToPeer) }
                .sorted { $0.displayName < $1.displayName }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.peers = peers
                self?.status = peers.isEmpty ? (peerToPeer ? "No hay un Mac cercano recibiendo" : "No hay un Mac recibiendo en esta red Wi-Fi") : "Elige tu Mac"
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.status = error.localizedDescription
            } }
        }
        browser.start(queue: DispatchQueue(label: "com.forma.discovery"))
    }
    func stop() { generation = UUID(); browser?.cancel(); browser = nil; peers = [] }
}

@MainActor
final class HybridTransferReceiver: ObservableObject {
    @Published private(set) var pairingCode = ""
    @Published private(set) var status = "Recepción desactivada"
    @Published private(set) var isListening = false
    @Published private(set) var listeningPort: UInt16?
    private var listener: NWListener?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    @Published private(set) var isUSBContinuousEnabled = false
    @Published private(set) var usbConnectionActive = false
    @Published private(set) var usbStatus = "USB-C desactivado"
    private var usbGeneration = UUID()
    private var usbLoopTask: Task<Void, Never>?
    private var usbConnection: NWConnection?
    private var usbLastIssue: String?

    deinit {
        usbLoopTask?.cancel(); usbConnection?.cancel(); listener?.cancel()
        for task in tasks.values { task.cancel() }
    }

    /// Opt-in reconnecting receiver for the phone's reverse USB operation listener.
    /// Each channel still carries exactly one authenticated operation. This loop
    /// never resubmits a command or calls a processing worker on its own.
    func startContinuousUSB(directory: URL, host: String = "127.0.0.1", port: UInt16 = 49232, pairingCode: String,
                    acknowledgementPolicy: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Bool = { _ in true },
                    onStatus: HybridTransfer.StatusProvider? = nil,
                    onCommand: HybridTransfer.CommandProvider? = nil,
                    onResult: HybridTransfer.ResultProvider? = nil,
                    onReceive: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Void) throws {
        guard !isUSBContinuousEnabled else { return }
        let key = try HybridTransfer.pairingKey(pairingCode)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw HybridTransfer.TransferError.failed("Puerto USB no válido.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        usbGeneration = UUID()
        let scope = usbGeneration, reception = generation
        isUSBContinuousEnabled = true; usbConnectionActive = false; usbLastIssue = nil
        usbStatus = "USB-C activo · esperando una operación del iPhone"
        usbLoopTask = Task.detached(priority: .utility) { [weak self] in
            var backoff = 0.25
            while !Task.isCancelled {
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
                guard await self?.registerUSB(connection, scope: scope, reception: reception) == true else { connection.cancel(); break }
                var succeeded = false
                do {
                    let job = try await Self.receive(connection, key: key, directory: directory,
                        acknowledgementPolicy: acknowledgementPolicy, onStatus: onStatus, onCommand: onCommand, onResult: onResult,
                        onAuthenticated: { [weak self] in await self?.authenticatedUSB(scope: scope, reception: reception) })
                    // A ReceivedJob has already committed atomically (and may have
                    // sent its ACK). Publish it even if Stop races that final return;
                    // cancellation only prevents additional channels, not a durable
                    // capture from reaching the queue's UUID deduplication.
                    if let job { onReceive(job) }
                    try Task.checkCancellation()
                    await self?.settledUSB(scope: scope, reception: reception, error: nil)
                    succeeded = true
                } catch {
                    guard !Task.isCancelled else { break }
                    await self?.settledUSB(scope: scope, reception: reception, error: error)
                }
                // No retry budget or terminal failure count: only the connection
                // cadence backs off while the phone has no operation listening.
                do { try await Task.sleep(for: .seconds(succeeded ? 0.1 : backoff)) }
                catch { break }
                backoff = succeeded ? 0.25 : min(3, backoff * 2)
            }
            await self?.endedUSB(scope: scope, reception: reception)
        }
    }

    func stopContinuousUSB() {
        usbGeneration = UUID()
        usbLoopTask?.cancel(); usbLoopTask = nil
        usbConnection?.cancel(); usbConnection = nil
        isUSBContinuousEnabled = false; usbConnectionActive = false; usbLastIssue = nil
        usbStatus = "USB-C desactivado"
    }
    private func currentUSB(_ scope: UUID, reception: UUID) -> Bool {
        isUSBContinuousEnabled && usbGeneration == scope && generation == reception
    }
    private func registerUSB(_ connection: NWConnection, scope: UUID, reception: UUID) -> Bool {
        guard currentUSB(scope, reception: reception) else { return false }
        usbConnection = connection; return true
    }
    private func authenticatedUSB(scope: UUID, reception: UUID) {
        guard currentUSB(scope, reception: reception) else { return }
        usbConnectionActive = true; usbLastIssue = nil
        if usbStatus != "USB-C conectado · atendiendo la operación" { usbStatus = "USB-C conectado · atendiendo la operación" }
    }
    private func settledUSB(scope: UUID, reception: UUID, error: Error?) {
        guard currentUSB(scope, reception: reception) else { return }
        let hadConnection = usbConnectionActive
        usbConnectionActive = false; usbConnection = nil
        if let error {
            if !Self.isWaitingUSBError(error) { usbLastIssue = error.localizedDescription }
            else if hadConnection { usbLastIssue = "La conexión se interrumpió; los parciales se conservan para reintentar." }
        } else { usbLastIssue = nil }
        let message = "USB-C activo · esperando una operación del iPhone" + (usbLastIssue.map { " · " + $0 } ?? "")
        if usbStatus != message { usbStatus = message }
    }
    private func endedUSB(scope: UUID, reception: UUID) {
        guard currentUSB(scope, reception: reception) else { return }
        usbLoopTask = nil; usbConnection?.cancel(); usbConnection = nil
        isUSBContinuousEnabled = false; usbConnectionActive = false
        usbStatus = "USB-C desactivado"
    }
    nonisolated private static func isWaitingUSBError(_ error: Error) -> Bool {
        if let network = error as? NWError, case .posix(let code) = network {
            return [.ECONNREFUSED, .ECONNRESET, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT, .EPIPE, .ENOTCONN].contains(code)
        }
        return error is CancellationError
    }

    func connectUSB(directory: URL, host: String = "127.0.0.1", port: UInt16 = 49232, pairingCode: String,
                    acknowledgementPolicy: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Bool = { _ in true },
                    onStatus: HybridTransfer.StatusProvider? = nil,
                    onCommand: HybridTransfer.CommandProvider? = nil,
                    onResult: HybridTransfer.ResultProvider? = nil,
                    onReceive: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Void) throws {
        guard !isUSBContinuousEnabled else { throw HybridTransfer.TransferError.failed("USB-C continuo ya está activo. No hace falta conectar otra vez.") }
        let key = try HybridTransfer.pairingKey(pairingCode)
        guard let port = NWEndpoint.Port(rawValue: port) else { throw HybridTransfer.TransferError.failed("Puerto USB no válido.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let id = UUID(), receiver = self
        status = "Conectando al iPhone por USB-C"
        tasks[id] = Task.detached(priority: .userInitiated) {
            do {
                if let job = try await Self.receive(connection, key: key, directory: directory, acknowledgementPolicy: acknowledgementPolicy, onStatus: onStatus, onCommand: onCommand, onResult: onResult) {
                    onReceive(job)
                    await receiver.finished(id, status: "Captura USB-C recibida y verificada")
                } else { await receiver.finished(id, status: "Consulta USB-C atendida con cifrado local") }
            } catch { await receiver.finished(id, status: "USB-C interrumpido: \(error.localizedDescription)") }
        }
    }

    func start(directory: URL, name: String = "Forma Desktop",
               acknowledgementPolicy: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Bool = { _ in true },
               onStatus: HybridTransfer.StatusProvider? = nil,
               onCommand: HybridTransfer.CommandProvider? = nil,
               onResult: HybridTransfer.ResultProvider? = nil,
               onReceive: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Void) throws {
        stop()
        let generation = self.generation
        status = "Abriendo recepción local"
        pairingCode = try HybridTransfer.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let key = try HybridTransfer.pairingKey(pairingCode)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.service = NWListener.Service(name: name, type: HybridTransfer.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard self?.generation == generation else { return }
                switch state {
                case .ready: self?.isListening = true; self?.listeningPort = listener.port?.rawValue; self?.status = "Listo para recibir fuentes cifradas del iPhone"
                case .failed(let error): self?.isListening = false; self?.status = error.localizedDescription
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let id = UUID()
            Task { @MainActor in
                guard let self, self.listener != nil, self.generation == generation else { connection.cancel(); return }
                let receiver = self
                self.tasks[id] = Task.detached(priority: .userInitiated) {
                    do {
                        if let job = try await Self.receive(connection, key: key, directory: directory, acknowledgementPolicy: acknowledgementPolicy, onStatus: onStatus, onCommand: onCommand, onResult: onResult) {
                            onReceive(job)
                            await receiver.finished(id, status: "Captura recibida y verificada")
                        } else { await receiver.finished(id, status: "Consulta atendida con cifrado local") }
                    } catch {
                        await receiver.finished(id, status: "Transferencia interrumpida: \(error.localizedDescription)")
                    }
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "com.forma.receiver"))
    }
    func stop() {
        generation = UUID()
        stopContinuousUSB()
        listener?.cancel(); listener = nil
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        isListening = false; listeningPort = nil; status = "Recepción desactivada"; pairingCode = ""
    }
    private func finished(_ id: UUID, status: String) {
        // stop() removes every old task. Its later cancellation must not replace
        // the status of a newly opened receiver with a stale network error.
        guard tasks.removeValue(forKey: id) != nil else { return }
        self.status = status
    }

    /// Reject links at every component before touching an owned staging file.
    nonisolated private static func checkedURL(root: URL, path: String) throws -> URL {
        guard ScanStore.safeRelativePath(path) else { throw HybridTransfer.TransferError.failed("Ruta recibida no válida.") }
        var cursor = root
        for component in [String?](arrayLiteral: nil) + path.split(separator: "/").map({ Optional(String($0)) }) {
            if let component { cursor.appendPathComponent(component) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw HybridTransfer.TransferError.failed("El destino contiene un enlace; se conservó sin modificar.")
            }
        }
        return cursor
    }

    nonisolated private static func verifyFiles(_ manifest: HybridTransfer.Manifest, root: URL) throws {
        for file in manifest.files {
            try Task.checkCancellation()
            let url = try checkedURL(root: root, path: file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try HybridTransfer.size(url) == file.bytes, try HybridTransfer.digest(url) == file.sha256 else {
                throw HybridTransfer.TransferError.failed("Una fuente recibida no supera la verificación SHA-256. Se conservó la captura para revisarla.")
            }
        }
        _ = try RGBDDatasetManifest.load(from: root.appendingPathComponent("dataset"))
        try validateProcessingRequest(root: root)
    }

    nonisolated private static func validateProcessingRequest(root: URL) throws {
        let url = try checkedURL(root: root, path: "procesamiento.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try JSONDecoder().decode(HybridTransfer.ProcessingRequest.self, from: Data(contentsOf: url)).validate()
        }
    }

    nonisolated private static func receiveResumable(first: HybridTransfer.Header, cipher: HybridTransfer.Cipher, directory: URL,
        acknowledgementPolicy: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Bool) async throws -> HybridTransfer.ReceivedJob {
        guard first.version == 2, let id = first.jobID, let duration = first.duration, duration.isFinite, duration >= 0,
              let manifestSHA = first.manifestSHA256, HybridTransfer.validSHA(manifestSHA) else {
            throw HybridTransfer.TransferError.failed("Cabecera reanudable no válida.")
        }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var files: [HybridTransfer.FileDescriptor] = [], paths: Set<String> = []
        while true {
            try Task.checkCancellation()
            let header = try decoder.decode(HybridTransfer.Header.self, from: await cipher.receive())
            if header.kind == "manifest-done" { break }
            guard header.kind == "manifest-file", let path = header.path, HybridTransfer.validPath(path),
                  paths.insert(path).inserted, let count = header.bytes, count >= 0,
                  let sha = header.sha256, HybridTransfer.validSHA(sha) else {
                throw HybridTransfer.TransferError.failed("Inventario de fuentes no válido.")
            }
            files.append(.init(path: path, bytes: count, sha256: sha))
        }
        guard paths.contains("dataset/dataset.json"), paths.contains("malla-original.json") else {
            throw HybridTransfer.TransferError.failed("Falta la calibración o la malla original.")
        }
        let manifest = HybridTransfer.Manifest(duration: duration, files: files.sorted { $0.path < $1.path })
        guard try manifest.sha256 == manifestSHA, try manifest.id == id else {
            throw HybridTransfer.TransferError.failed("La identidad SHA-256 de la captura no coincide.")
        }
        let lease = try HybridTransfer.ReceivingLease.acquire(directory: directory, id: id)
        defer { withExtendedLifetime(lease) {} }
        let receipt = HybridTransfer.TransferReceipt(jobID: id, manifestSHA256: manifestSHA, manifest: manifest)
        let final = try checkedURL(root: directory, path: id.uuidString)
        let job = HybridTransfer.ReceivedJob(id: id, directory: final, duration: duration)
        let committed = HybridTransfer.Header(kind: "committed", jobID: id, manifestSHA256: manifestSHA)
        if FileManager.default.fileExists(atPath: final.path) {
            let metadata = try checkedURL(root: final, path: ".transfer.json")
            guard try decoder.decode(HybridTransfer.TransferReceipt.self, from: Data(contentsOf: metadata)) == receipt else {
                throw HybridTransfer.TransferError.failed("Ya existe otro trabajo con esta identidad; no se sobrescribió.")
            }
            try verifyFiles(manifest, root: final)
            if acknowledgementPolicy(job) { try? await cipher.send(encoder.encode(committed)) }
            return job
        }
        let staging = try checkedURL(root: directory, path: ".resume-" + id.uuidString)
        if !FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        }
        let metadata = try checkedURL(root: staging, path: ".transfer.json")
        if FileManager.default.fileExists(atPath: metadata.path) {
            guard try decoder.decode(HybridTransfer.TransferReceipt.self, from: Data(contentsOf: metadata)) == receipt else {
                throw HybridTransfer.TransferError.failed("Los archivos parciales pertenecen a otra captura; se conservaron.")
            }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty else {
                throw HybridTransfer.TransferError.failed("El destino parcial no tiene un inventario verificable; se conservó.")
            }
            try encoder.encode(receipt).write(to: metadata, options: .atomic)
        }
        // Staging deliberately survives cancellation, connection loss, and app relaunch.
        try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "ready", jobID: id, manifestSHA256: manifestSHA)))
        for descriptor in files {
            try Task.checkCancellation()
            let header = try decoder.decode(HybridTransfer.Header.self, from: await cipher.receive())
            guard header.kind == "file", header.path == descriptor.path, header.bytes == descriptor.bytes,
                  header.sha256 == descriptor.sha256 else {
                throw HybridTransfer.TransferError.failed("La fuente no coincide con el inventario acordado.")
            }
            let file = try checkedURL(root: staging, path: descriptor.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var offset: Int64 = 0, hash = SHA256()
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HybridTransfer.TransferError.failed("El destino parcial no es un archivo.") }
                offset = try HybridTransfer.size(file)
                if offset <= descriptor.bytes, let prefix = try HybridTransfer.prefixHash(file, bytes: offset) {
                    hash = prefix
                    if offset == descriptor.bytes, HybridTransfer.hex(hash.finalize()) != descriptor.sha256 { offset = 0; hash = SHA256() }
                } else { offset = 0 }
            } else {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw HybridTransfer.TransferError.failed("No se pudo crear una fuente parcial.") }
            }
            try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "resume-file", path: descriptor.path, bytes: offset, sha256: HybridTransfer.hex(hash.finalize()))))
            let decision = try decoder.decode(HybridTransfer.Header.self, from: await cipher.receive())
            guard decision.path == descriptor.path, decision.kind == "append-file" || decision.kind == "restart-file" else {
                throw HybridTransfer.TransferError.failed("Respuesta de reanudación no válida.")
            }
            if decision.kind == "restart-file" { offset = 0; hash = SHA256() }
            let handle = try FileHandle(forWritingTo: file)
            do {
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                var received = offset
                while received < descriptor.bytes {
                    try Task.checkCancellation()
                    let bytes = try await cipher.receive()
                    guard !bytes.isEmpty, Int64(bytes.count) <= descriptor.bytes - received else {
                        throw HybridTransfer.TransferError.failed("Tamaño de fuente recibida no válido.")
                    }
                    try autoreleasepool { try handle.write(contentsOf: bytes); hash.update(data: bytes) }
                    received += Int64(bytes.count)
                }
                try handle.synchronize(); try handle.close()
                guard HybridTransfer.hex(hash.finalize()) == descriptor.sha256 else {
                    throw HybridTransfer.TransferError.failed("La huella SHA-256 de una fuente no coincide; se conserva el parcial para reintentar.")
                }
            } catch { try? handle.close(); throw error }
            try await cipher.send(encoder.encode(HybridTransfer.Header(kind: "file-verified", path: descriptor.path)))
        }
        let done = try decoder.decode(HybridTransfer.Header.self, from: await cipher.receive())
        guard done.kind == "done" else { throw HybridTransfer.TransferError.failed("La captura no terminó correctamente.") }
        _ = try RGBDDatasetManifest.load(from: staging.appendingPathComponent("dataset"))
        try validateProcessingRequest(root: staging)
        try Task.checkCancellation()
        try encoder.encode(first).write(to: staging.appendingPathComponent("job.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: final)
        // Returning the same identity also lets the queue recover a commit whose ACK was lost.
        if acknowledgementPolicy(job) { try? await cipher.send(encoder.encode(committed)) }
        return job
    }

    nonisolated private static func receive(_ connection: NWConnection, key: SymmetricKey, directory: URL,
        acknowledgementPolicy: @escaping @Sendable (HybridTransfer.ReceivedJob) -> Bool,
        onStatus: HybridTransfer.StatusProvider?, onCommand: HybridTransfer.CommandProvider?,
        onResult: HybridTransfer.ResultProvider?,
        onAuthenticated: (@Sendable () async -> Void)? = nil) async throws -> HybridTransfer.ReceivedJob? {
        let channel = HybridTransfer.Channel(connection)
        return try await withTaskCancellationHandler(operation: {
            defer { channel.cancel() }
            try await channel.start()
            let challenge = try HybridTransfer.randomBytes(32)
            try await channel.write(challenge)
            let timeout = Task { try await Task.sleep(for: .seconds(20)); channel.cancel() }
            let answer: Data
            do { answer = try await channel.readExactly(32); timeout.cancel() }
            catch { timeout.cancel(); throw error }
            guard HMAC<SHA256>.isValidAuthenticationCode(answer, authenticating: challenge + Data("client".utf8), using: key) else {
                throw HybridTransfer.TransferError.failed("Clave de sesión incorrecta.")
            }
            try await channel.write(Data(HMAC<SHA256>.authenticationCode(for: challenge + Data("server".utf8), using: key)))
            await onAuthenticated?()
            try Task.checkCancellation()
            let cipher = HybridTransfer.Cipher(channel: channel, pairingKey: key, challenge: challenge, sending: "server", receiving: "client")
            let first = try JSONDecoder().decode(HybridTransfer.Header.self, from: await cipher.receive())
            if first.kind == "command-query" {
                guard first.version == 1, let command = first.command, first.jobID == command.jobID else {
                    throw HybridTransfer.TransferError.failed("Comando remoto no válido.")
                }
                var response = HybridTransfer.Header(kind: "command-response", jobID: command.jobID, version: 1)
                do {
                    guard let onCommand else { throw HybridTransfer.TransferError.failed("Esta recepción no admite comandos remotos. Actualiza Forma Desktop.") }
                    try Task.checkCancellation()
                    let reply = try await onCommand(command)
                    try reply.validate(command: command)
                    response.commandReply = reply
                } catch { response.message = error.localizedDescription }
                try await cipher.send(JSONEncoder().encode(response))
                return nil
            }
            if first.kind == "result-query" {
                guard first.version == 2, let id = first.jobID else {
                    throw HybridTransfer.TransferError.failed("Consulta de resultado no válida.")
                }
                do {
                    guard let onResult else { throw HybridTransfer.TransferError.failed("Esta recepción no ofrece descargas de resultados. Actualiza Forma Desktop.") }
                    try Task.checkCancellation()
                    let source = try await onResult(id)
                    guard source.descriptor.jobID == id else { throw HybridTransfer.TransferError.failed("El resultado pertenece a otro trabajo.") }
                    try await HybridTransfer.serveResult(source, cipher: cipher, expectedManifestSHA256: first.manifestSHA256)
                } catch {
                    try? await cipher.send(JSONEncoder().encode(HybridTransfer.Header(kind: "result-error", jobID: id, message: error.localizedDescription)))
                    throw error
                }
                return nil
            }
            if first.kind == "status-query" {
                guard first.version == 1, let id = first.jobID else { throw HybridTransfer.TransferError.failed("Consulta de trabajo no válida.") }
                var response = HybridTransfer.Header(kind: "status-response", jobID: id, version: 1)
                do {
                    guard let onStatus else { throw HybridTransfer.TransferError.failed("Esta recepción no ofrece consultas de estado. Actualiza Forma Desktop o revisa el trabajo en la Mac.") }
                    try Task.checkCancellation()
                    let result = try await onStatus(id)
                    try result.validate(jobID: id)
                    response.status = result
                } catch { response.message = error.localizedDescription }
                try await cipher.send(JSONEncoder().encode(response))
                return nil
            }
            if first.kind == "job-v2" {
                return try await receiveResumable(first: first, cipher: cipher, directory: directory, acknowledgementPolicy: acknowledgementPolicy)
            }
            guard first.kind == "job", let id = first.jobID, let duration = first.duration, duration.isFinite, duration >= 0 else {
                throw HybridTransfer.TransferError.failed("Cabecera de captura no válida.")
            }
            let staging = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
            let final = directory.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            var paths: Set<String> = []
            while true {
                try Task.checkCancellation()
                let header = try JSONDecoder().decode(HybridTransfer.Header.self, from: await cipher.receive())
                if header.kind == "done" { break }
                guard header.kind == "file", let path = header.path, ScanStore.safeRelativePath(path),
                      path == "malla-original.json" || path.hasPrefix("dataset/"), paths.insert(path).inserted,
                      let count = header.bytes, count >= 0, let expected = header.sha256, expected.count == 64 else {
                    throw HybridTransfer.TransferError.failed("Archivo de transferencia no válido.")
                }
                let file = staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw HybridTransfer.TransferError.failed("No se pudo crear el archivo recibido.") }
                let handle = try FileHandle(forWritingTo: file)
                do {
                    var received: Int64 = 0, hash = SHA256()
                    while received < count {
                        let bytes = try await cipher.receive()
                        guard !bytes.isEmpty, Int64(bytes.count) <= count - received else { throw HybridTransfer.TransferError.failed("Tamaño de archivo recibido no válido.") }
                        try autoreleasepool { try handle.write(contentsOf: bytes); hash.update(data: bytes) }
                        received += Int64(bytes.count)
                    }
                    try handle.close()
                    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw HybridTransfer.TransferError.failed("La huella SHA-256 de una fuente no coincide.") }
                } catch { try? handle.close(); throw error }
            }
            guard paths.contains("dataset/dataset.json"), paths.contains("malla-original.json") else { throw HybridTransfer.TransferError.failed("Falta la calibración o la malla original.") }
            _ = try RGBDDatasetManifest.load(from: staging.appendingPathComponent("dataset"))
            try Task.checkCancellation()
            try JSONEncoder().encode(first).write(to: staging.appendingPathComponent("job.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: final)
            // A lost acknowledgement must not hide an already committed job from the Mac queue.
            try? await cipher.send(Data("verified".utf8))
            return HybridTransfer.ReceivedJob(id: id, directory: final, duration: duration)
        }, onCancel: { channel.cancel() })
    }
}

// Commands and result delivery use the same paired HMAC handshake and AES-GCM sequence as capture upload.
extension HybridTransfer {
    static func command(_ command: RemoteJobCommand, to peer: Peer, pairingCode: String) async throws -> RemoteCommandReply {
        try await commandStream(command, channel: Channel(NWConnection(to: peer.endpoint, using: networkParameters(for: peer))), key: pairingKey(pairingCode))
    }

    static func commandOverUSBWaitingForMac(_ command: RemoteJobCommand, pairingCode: String, port: UInt16 = 49231) async throws -> RemoteCommandReply {
        let key = try pairingKey(pairingCode)
        return try await withUSBChannel(port: port) { try await commandStream(command, channel: $0, key: key) }
    }

    private static func commandStream(_ command: RemoteJobCommand, channel: Channel, key: SymmetricKey) async throws -> RemoteCommandReply {
        try await withTaskCancellationHandler(operation: {
            defer { channel.cancel() }
            let cipher = try await clientCipher(channel: channel, key: key)
            try await cipher.send(JSONEncoder().encode(Header(kind: "command-query", jobID: command.jobID, version: 1, command: command)))
            let response = try JSONDecoder().decode(Header.self, from: await cipher.receive())
            guard response.kind == "command-response", response.version == 1, response.jobID == command.jobID else {
                throw TransferError.failed("El Mac no confirmó el comando. Actualiza ambas apps.")
            }
            if let message = response.message { throw TransferError.failed(message) }
            guard let reply = response.commandReply else { throw TransferError.failed("El Mac no envió el recibo del comando.") }
            try reply.validate(command: command)
            return reply
        }, onCancel: { channel.cancel() })
    }

    /// directory is an owned cache root; complete bundles and interrupted prefixes remain available offline.
    static func downloadResult(jobID: UUID, to peer: Peer, pairingCode: String, directory: URL,
                               expectedManifestSHA256: String? = nil,
                               metrics: @escaping @Sendable (TransferMetrics) -> Void = { _ in },
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> DownloadedResult {
        try await downloadResultStream(jobID: jobID, channel: Channel(NWConnection(to: peer.endpoint, using: networkParameters(for: peer))),
            key: pairingKey(pairingCode), directory: directory, expectedManifestSHA256: expectedManifestSHA256, metrics: metrics, progress: progress)
    }

    static func downloadResultOverUSBWaitingForMac(jobID: UUID, pairingCode: String, directory: URL, port: UInt16 = 49231,
                               expectedManifestSHA256: String? = nil,
                               metrics: @escaping @Sendable (TransferMetrics) -> Void = { _ in },
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> DownloadedResult {
        let key = try pairingKey(pairingCode)
        return try await withUSBChannel(port: port) { channel in
            try await downloadResultStream(jobID: jobID, channel: channel, key: key, directory: directory,
                expectedManifestSHA256: expectedManifestSHA256, metrics: metrics, progress: progress)
        }
    }

    /// Reserved protocol metadata cannot be supplied as a model/package path.
    static func resultPath(_ path: String) -> Bool {
        !path.contains("\0") && ScanStore.safeRelativePath(path) && !path.split(separator: "/").contains(where: {
            $0 == "resultado.json" || $0 == ".result-transfer.json" || $0 == "dataset" || $0 == "dataset.json"
        })
    }

    private static func resultURL(root: URL, path: String) throws -> URL {
        guard !path.contains("\0"), ScanStore.safeRelativePath(path) else { throw TransferError.failed("Ruta del resultado no válida.") }
        var cursor = root
        for component in [String?](arrayLiteral: nil) + path.split(separator: "/").map({ Optional(String($0)) }) {
            if let component { cursor.appendPathComponent(component) }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cursor.path) {
                guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw TransferError.failed("El resultado contiene un enlace. Se conservó sin seguirlo.")
                }
            }
        }
        return cursor
    }

    private static func resultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder
    }

    private static func resultSources(_ source: ResultSource) throws -> [String: URL] {
        try source.descriptor.validate()
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: source.directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw TransferError.failed("No existe el paquete publicado del resultado.")
        }
        var paths = Set<String>()
        if let package = source.descriptor.packageRelativePath {
            let packageURL = try resultURL(root: source.directory, path: package)
            guard try fm.attributesOfItem(atPath: packageURL.path)[.type] as? FileAttributeType == .typeDirectory,
                  let enumerator = fm.enumerator(atPath: packageURL.path) else { throw TransferError.failed("El paquete del modelo no es una carpeta.") }
            while let relative = enumerator.nextObject() as? String {
                try Task.checkCancellation()
                let path = package + "/" + relative
                guard resultPath(path) else { throw TransferError.failed("El paquete contiene una ruta de fuentes o metadatos ajenos al resultado.") }
                let file = try resultURL(root: source.directory, path: path)
                let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else { throw TransferError.failed("El paquete contiene un archivo especial.") }
                if type == .typeRegular { paths.insert(path) }
            }
        }
        for path in [source.descriptor.modelRelativePath, source.descriptor.meshRelativePath].compactMap({ $0 }) { paths.insert(path) }
        if let gaussian = source.descriptor.gaussianModelRelativePath, let package = source.descriptor.packageRelativePath {
            paths.insert(package + "/" + gaussian)
        }
        var files: [String: URL] = [:]
        for path in paths {
            let url = try resultURL(root: source.directory, path: path)
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw TransferError.failed("Falta un archivo publicado del resultado.")
            }
            files[path] = url
        }
        return files
    }

    /// Offline recovery rehashes every file and the canonical descriptor before returning a usable bundle.
    static func loadDownloadedResult(from directory: URL) throws -> DownloadedResult {
        let receiptURL = try resultURL(root: directory, path: ".result-transfer.json")
        guard try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.type] as? FileAttributeType == .typeRegular else {
            throw TransferError.failed("Falta el recibo del resultado.")
        }
        let receipt = try JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.manifest.version == 2, receipt.manifest.duration.isFinite, receipt.manifest.duration >= 0,
              try receipt.manifest.id == receipt.jobID, try receipt.manifest.sha256 == receipt.manifestSHA256 else {
            throw TransferError.failed("El inventario del resultado cambió.")
        }
        var paths = Set<String>()
        for file in receipt.manifest.files {
            try Task.checkCancellation()
            guard (file.path == "resultado.json" || resultPath(file.path)), paths.insert(file.path).inserted,
                  file.bytes >= 0, validSHA(file.sha256) else { throw TransferError.failed("Inventario del resultado no válido.") }
            let url = try resultURL(root: directory, path: file.path)
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
                  try size(url) == file.bytes, try digest(url) == file.sha256 else {
                throw TransferError.failed("Un archivo del resultado no coincide con su SHA-256.")
            }
        }
        guard paths.contains("resultado.json") else { throw TransferError.failed("Falta el descriptor del resultado.") }
        let descriptorURL = try resultURL(root: directory, path: "resultado.json")
        let data = try Data(contentsOf: descriptorURL)
        let descriptor = try JSONDecoder().decode(ResultDescriptor.self, from: data)
        try descriptor.validate()
        guard try resultEncoder().encode(descriptor) == data, descriptor.duration == receipt.manifest.duration else {
            throw TransferError.failed("El descriptor no coincide con el inventario canónico.")
        }
        let derived = try resultSources(ResultSource(descriptor: descriptor, directory: directory))
        guard Set(derived.keys).union(["resultado.json"]) == paths else {
            throw TransferError.failed("El inventario incluye archivos ajenos al modelo publicado.")
        }
        // Reject extra files/links, including unlisted links inside otherwise valid package directories.
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { throw TransferError.failed("No se pudo revisar el resultado.") }
        while let path = enumerator.nextObject() as? String {
            let url = try resultURL(root: directory, path: path)
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory || (type == .typeRegular && (paths.contains(path) || path == ".result-transfer.json")) else {
                throw TransferError.failed("El resultado contiene archivos que no figuran en el inventario.")
            }
        }
        return DownloadedResult(descriptor: descriptor, directory: directory, manifestSHA256: receipt.manifestSHA256)
    }

    static func verifyDownloadedResult(_ result: DownloadedResult) throws {
        let verified = try loadDownloadedResult(from: result.directory)
        guard verified.descriptor == result.descriptor, verified.manifestSHA256 == result.manifestSHA256 else {
            throw TransferError.failed("La identidad del resultado cambió antes de importarlo.")
        }
    }

    static func serveResult(_ source: ResultSource, cipher: Cipher, expectedManifestSHA256: String?) async throws {
        let fm = FileManager.default, encoder = resultEncoder(), decoder = JSONDecoder()
        var sources = try resultSources(source)
        let temporary = fm.temporaryDirectory.appendingPathComponent("FormaResultDescriptor-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let descriptorURL = temporary.appendingPathComponent("resultado.json")
        try encoder.encode(source.descriptor).write(to: descriptorURL, options: .atomic)
        sources["resultado.json"] = descriptorURL
        let files = try sources.keys.sorted().map { path in FileDescriptor(path: path, bytes: try size(sources[path]!), sha256: try digest(sources[path]!)) }
        let manifest = Manifest(duration: source.descriptor.duration, files: files)
        let id = try manifest.id, sha = try manifest.sha256
        if let expectedManifestSHA256, expectedManifestSHA256 != sha { throw TransferError.failed("El resultado publicado cambió respecto de la descarga solicitada.") }
        try await cipher.send(encoder.encode(Header(kind: "result-manifest", jobID: id, duration: manifest.duration, version: 2, manifestSHA256: sha)))
        for file in files { try await cipher.send(encoder.encode(Header(kind: "manifest-file", path: file.path, bytes: file.bytes, sha256: file.sha256))) }
        try await cipher.send(encoder.encode(Header(kind: "manifest-done")))
        let ready = try decoder.decode(Header.self, from: await cipher.receive())
        guard ready.jobID == id, ready.manifestSHA256 == sha else { throw TransferError.failed("El cliente confirmó otro resultado.") }
        if ready.kind == "committed" { return }
        guard ready.kind == "ready" else { throw TransferError.failed("El cliente no aceptó el resultado.") }
        for file in files {
            try Task.checkCancellation()
            let url = sources[file.path]!
            if file.path != "resultado.json" { _ = try resultURL(root: source.directory, path: file.path) }
            guard try size(url) == file.bytes else { throw TransferError.failed("El resultado cambió durante la descarga.") }
            try await cipher.send(encoder.encode(Header(kind: "file", path: file.path, bytes: file.bytes, sha256: file.sha256)))
            let request = try decoder.decode(Header.self, from: await cipher.receive())
            guard request.kind == "resume-file", request.path == file.path, let offset = request.bytes,
                  offset >= 0, offset <= file.bytes, let prefix = request.sha256, validSHA(prefix) else {
                throw TransferError.failed("El punto de reanudación del resultado no es válido.")
            }
            let localPrefix = try digest(url, prefixBytes: offset)
            let resumed = localPrefix == prefix ? offset : 0
            try await cipher.send(encoder.encode(Header(kind: resumed == offset ? "append-file" : "restart-file", path: file.path)))
            let handle = try FileHandle(forReadingFrom: url)
            do {
                try handle.seek(toOffset: UInt64(resumed))
                var sent = resumed
                while sent < file.bytes {
                    try Task.checkCancellation()
                    guard let data = try autoreleasepool(invoking: { try handle.read(upToCount: Int(min(Int64(chunkBytes), file.bytes - sent))) }), !data.isEmpty else {
                        throw TransferError.failed("El resultado cambió durante la descarga.")
                    }
                    try await cipher.send(data); sent += Int64(data.count)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let verified = try decoder.decode(Header.self, from: await cipher.receive())
            guard verified.kind == "file-verified", verified.path == file.path else { throw TransferError.failed("El cliente no verificó un archivo del resultado.") }
        }
        try await cipher.send(encoder.encode(Header(kind: "done")))
        let committed = try decoder.decode(Header.self, from: await cipher.receive())
        guard committed.kind == "committed", committed.jobID == id, committed.manifestSHA256 == sha else { throw TransferError.failed("El cliente no confirmó el resultado.") }
    }

    private static func downloadResultStream(jobID: UUID, channel: Channel, key: SymmetricKey, directory: URL,
                         expectedManifestSHA256: String?, metrics: @escaping @Sendable (TransferMetrics) -> Void,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> DownloadedResult {
        try await withTaskCancellationHandler(operation: {
            defer { channel.cancel() }
            try Task.checkCancellation()
            if let expectedManifestSHA256, !validSHA(expectedManifestSHA256) { throw TransferError.failed("Identidad del resultado no válida.") }
            let cipher = try await clientCipher(channel: channel, key: key)
            let encoder = resultEncoder(), decoder = JSONDecoder(), fm = FileManager.default
            try await cipher.send(encoder.encode(Header(kind: "result-query", jobID: jobID, version: 2, manifestSHA256: expectedManifestSHA256)))
            let first = try decoder.decode(Header.self, from: await cipher.receive())
            if first.kind == "result-error" { throw TransferError.failed(first.message ?? "El resultado todavía no está disponible.") }
            guard first.kind == "result-manifest", first.version == 2, let id = first.jobID,
                  let duration = first.duration, duration.isFinite, duration >= 0,
                  let sha = first.manifestSHA256, validSHA(sha), expectedManifestSHA256.map({ $0 == sha }) ?? true else {
                throw TransferError.failed("El inventario del resultado no es válido.")
            }
            var files: [FileDescriptor] = [], paths = Set<String>()
            while true {
                let header = try decoder.decode(Header.self, from: await cipher.receive())
                if header.kind == "manifest-done" { break }
                guard header.kind == "manifest-file", let path = header.path,
                      path == "resultado.json" || resultPath(path), paths.insert(path).inserted,
                      let bytes = header.bytes, bytes >= 0, let hash = header.sha256, validSHA(hash) else {
                    throw TransferError.failed("Una ruta del resultado no es válida.")
                }
                files.append(FileDescriptor(path: path, bytes: bytes, sha256: hash))
            }
            let manifest = Manifest(duration: duration, files: files.sorted { $0.path < $1.path })
            guard paths.contains("resultado.json"), try manifest.id == id, try manifest.sha256 == sha else {
                throw TransferError.failed("La identidad SHA-256 del resultado no coincide.")
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let lease = try ReceivingLease.acquire(directory: directory, id: id)
            defer { withExtendedLifetime(lease) {} }
            let final = try resultURL(root: directory, path: "Result-" + id.uuidString)
            let committed = Header(kind: "committed", jobID: id, manifestSHA256: sha)
            var stats = TransferMetrics()
            if fm.fileExists(atPath: final.path) {
                let result = try loadDownloadedResult(from: final)
                guard result.descriptor.jobID == jobID, result.manifestSHA256 == sha else { throw TransferError.failed("Existe otro resultado con esta identidad.") }
                stats.alreadyCommitted = true; stats.resumedPayloadBytes = files.reduce(0) { $0 + $1.bytes }
                metrics(stats); progress(1)
                try? await cipher.send(encoder.encode(committed))
                return result
            }
            let staging = try resultURL(root: directory, path: ".result-resume-" + id.uuidString)
            if !fm.fileExists(atPath: staging.path) { try fm.createDirectory(at: staging, withIntermediateDirectories: false) }
            let receipt = TransferReceipt(jobID: id, manifestSHA256: sha, manifest: manifest)
            let metadata = try resultURL(root: staging, path: ".result-transfer.json")
            if fm.fileExists(atPath: metadata.path) {
                guard try decoder.decode(TransferReceipt.self, from: Data(contentsOf: metadata)) == receipt else { throw TransferError.failed("El inventario del parcial cambió; se conservó sin modificar.") }
            } else {
                guard try fm.contentsOfDirectory(atPath: staging.path).isEmpty else { throw TransferError.failed("El parcial no tiene un inventario verificable.") }
                try encoder.encode(receipt).write(to: metadata, options: .atomic)
            }
            try await cipher.send(encoder.encode(Header(kind: "ready", jobID: id, manifestSHA256: sha)))
            let total = files.reduce(0.0) { $0 + Double($1.bytes) }
            var accounted = 0.0
            for file in manifest.files {
                let header = try decoder.decode(Header.self, from: await cipher.receive())
                guard header.kind == "file", header.path == file.path, header.bytes == file.bytes, header.sha256 == file.sha256 else {
                    throw TransferError.failed("Un archivo no coincide con el inventario del resultado.")
                }
                let url = try resultURL(root: staging, path: file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var offset: Int64 = 0, hash = SHA256()
                if fm.fileExists(atPath: url.path) {
                    guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw TransferError.failed("El parcial del resultado no es un archivo.") }
                    offset = try size(url)
                    if offset <= file.bytes, let prefix = try prefixHash(url, bytes: offset) {
                        hash = prefix
                        if offset == file.bytes, hex(hash.finalize()) != file.sha256 { offset = 0; hash = SHA256() }
                    } else { offset = 0 }
                } else if !fm.createFile(atPath: url.path, contents: nil) { throw TransferError.failed("No se pudo crear el resultado parcial.") }
                try await cipher.send(encoder.encode(Header(kind: "resume-file", path: file.path, bytes: offset, sha256: hex(hash.finalize()))))
                let decision = try decoder.decode(Header.self, from: await cipher.receive())
                guard decision.path == file.path, decision.kind == "append-file" || decision.kind == "restart-file" else { throw TransferError.failed("Respuesta de reanudación del resultado no válida.") }
                if decision.kind == "restart-file" { offset = 0; hash = SHA256() }
                stats.resumedPayloadBytes += offset; accounted += Double(offset)
                metrics(stats); progress(total > 0 ? accounted / total : 1)
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.truncate(atOffset: UInt64(offset)); try handle.seek(toOffset: UInt64(offset))
                    var received = offset
                    while received < file.bytes {
                        try Task.checkCancellation()
                        let data = try await cipher.receive()
                        guard !data.isEmpty, Int64(data.count) <= file.bytes - received else { throw TransferError.failed("Tamaño de archivo del resultado no válido.") }
                        try autoreleasepool { try handle.write(contentsOf: data); hash.update(data: data) }
                        received += Int64(data.count); stats.transmittedPayloadBytes += Int64(data.count); accounted += Double(data.count)
                        metrics(stats); progress(total > 0 ? accounted / total : 1)
                    }
                    try handle.synchronize(); try handle.close()
                    guard hex(hash.finalize()) == file.sha256 else { throw TransferError.failed("SHA-256 del resultado incorrecto; se conserva el parcial.") }
                } catch { try? handle.close(); throw error }
                try await cipher.send(encoder.encode(Header(kind: "file-verified", path: file.path)))
            }
            let done = try decoder.decode(Header.self, from: await cipher.receive())
            guard done.kind == "done" else { throw TransferError.failed("La descarga no terminó correctamente.") }
            let candidate = try loadDownloadedResult(from: staging)
            guard candidate.descriptor.jobID == jobID else { throw TransferError.failed("El modelo pertenece a otro trabajo.") }
            try Task.checkCancellation()
            try fm.moveItem(at: staging, to: final)
            let result = DownloadedResult(descriptor: candidate.descriptor, directory: final, manifestSHA256: sha)
            // The atomic local commit survives a lost acknowledgement; the retry sends no model payload.
            try? await cipher.send(encoder.encode(committed))
            metrics(stats); progress(1)
            return result
        }, onCancel: { channel.cancel() })
    }
}
