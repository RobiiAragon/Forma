import Foundation
import CryptoKit

/// Acknowledgement survives app relaunch; session pairing secrets stay in memory.
struct HybridDeliveryReceipt: Codable {
    var scanID: UUID
    var processingRequest: HybridTransfer.ProcessingRequest?
    var jobID: UUID
    var acknowledgedAt: Date
    var lastStatus: HybridTransfer.RemoteJobStatus?
    var statusObservedAt: Date? = nil
    var pendingCommand: HybridTransfer.RemoteJobCommand? = nil
    var downloadedResultDirectory: String? = nil
    /// Observed on the channel carrying the source payload, not a separate probe.
    var sourceConnectionUsesWiFi: Bool? = nil
    /// Existing receipts store one historical ACK. Later successful verification
    /// updates acknowledgedAt while preserving the first observed confirmation.
    var firstAcknowledgedAt: Date? = nil

    mutating func recordAcknowledgement(at date: Date) {
        firstAcknowledgedAt = firstAcknowledgedAt ?? acknowledgedAt
        acknowledgedAt = date
    }

    static func key(scanID: UUID, request: HybridTransfer.ProcessingRequest?) throws -> String {
        if let request { try request.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let configuration = try encoder.encode(request)
        let digest = SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined()
        return scanID.uuidString + "-" + digest
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FormaHybridDelivery", isDirectory: true)
    }

    static func load(scanID: UUID, request: HybridTransfer.ProcessingRequest?,
                     in directory: URL = HybridDeliveryReceipt.directory) throws -> Self? {
        let url = directory.appendingPathComponent(try key(scanID: scanID, request: request) + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.scanID == scanID, value.processingRequest == request else {
            throw HybridTransfer.TransferError.failed("El recibo no corresponde a esta captura y configuración.")
        }
        try value.validate()
        return value
    }

    func save(in directory: URL = HybridDeliveryReceipt.directory) throws {
        try validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(try Self.key(scanID: scanID, request: processingRequest) + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private func validate() throws {
        try lastStatus?.validate(jobID: jobID)
        if let pendingCommand, pendingCommand.jobID != jobID {
            throw HybridTransfer.TransferError.failed("La orden guardada pertenece a otro trabajo.")
        }
        if let relative = downloadedResultDirectory,
           !ScanStore.safeRelativePath(relative) || !relative.hasPrefix("results/") {
            throw HybridTransfer.TransferError.failed("La carpeta del resultado guardado no es válida.")
        }
    }
}
