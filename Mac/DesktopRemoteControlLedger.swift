import Foundation
import Darwin

/// At-most-once dispatch, not an acknowledgement from the training engine.
/// A receipt is synced before effects; an interrupted receipt stays uncertain forever
/// and a retry never dispatches it again. Revisions also reject stale new commands.
final class DesktopRemoteControlLedger {
    struct Outcome: Codable { var state: String; var error: String? }
    enum Claim { case dispatch; case recorded(Outcome) }
    private struct Entry: Codable {
        var command: HybridTransfer.RemoteJobCommand
        var createdAt: Date
        var outcome: Outcome?
    }
    private struct Document: Codable {
        var schemaVersion = 1
        var jobID: UUID
        var revision: UUID
        var entries: [String: Entry] = [:]
    }
    let root: URL
    init(root: URL) { self.root = root }

    func revision(for id: UUID) throws -> UUID { try document(id).revision }

    func noteHumanIntent(for id: UUID) throws {
        var value = try document(id)
        value.revision = UUID()
        try save(value)
    }

    func claim(_ command: HybridTransfer.RemoteJobCommand, rejection: String?) throws -> Claim {
        var value = try document(command.jobID)
        if let entry = value.entries[command.id.uuidString] {
            guard entry.command.jobID == command.jobID, entry.command.action == command.action,
                  entry.command.expectedRevision == command.expectedRevision else {
                return .recorded(.init(state: "rejected", error: "El identificador del comando ya pertenece a otra solicitud."))
            }
            return .recorded(entry.outcome ?? .init(state: "uncertain", error:
                "La Mac se interrumpió durante este comando. No se volverá a ejecutar; consulta el estado y envía una nueva acción si todavía la necesitas."))
        }
        let reason = rejection ?? (command.expectedRevision == value.revision ? nil :
            "El estado de control cambió. Actualiza el trabajo antes de enviar otra acción.")
        let outcome = reason.map { Outcome(state: "rejected", error: $0) }
        value.entries[command.id.uuidString] = Entry(command: command, createdAt: Date(), outcome: outcome)
        if outcome == nil { value.revision = UUID() }
        try save(value)
        return outcome.map(Claim.recorded) ?? .dispatch
    }

    func finish(_ command: HybridTransfer.RemoteJobCommand, outcome: Outcome) throws {
        var value = try document(command.jobID)
        guard var entry = value.entries[command.id.uuidString], entry.outcome == nil,
              entry.command.action == command.action, entry.command.expectedRevision == command.expectedRevision else {
            throw failure("No se pudo confirmar el registro del comando; no se repetirá automáticamente.")
        }
        entry.outcome = outcome; value.entries[command.id.uuidString] = entry
        try save(value)
    }

    func hasUncertainCommand(for id: UUID) throws -> Bool {
        try document(id).entries.values.contains { $0.outcome == nil || $0.outcome?.state == "uncertain" }
    }

    private func document(_ id: UUID) throws -> Document {
        try ensureDirectory()
        let file = root.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            let value = Document(jobID: id, revision: UUID())
            try save(value); return value
        }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw failure("El registro de controles no es un archivo regular; se conservó para revisión.")
        }
        let value = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard value.schemaVersion == 1, value.jobID == id else {
            throw failure("El registro de controles necesita revisión; no se ejecutó la acción.")
        }
        return value
    }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attributes = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
              root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw failure("La carpeta de controles debe ser una carpeta local sin enlaces simbólicos.")
        }
    }
    private func save(_ value: Document) throws {
        try ensureDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try Self.writeDurably(encoder.encode(value), to: root.appendingPathComponent(value.jobID.uuidString + ".json"))
    }

    static func writeDurably(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        // Atomic replacement must survive a process crash with its directory entry.
        let descriptor = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw failure("No se pudo sincronizar la carpeta de controles.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure("No se pudo confirmar el registro durable del control.") }
    }
    private static func failure(_ message: String) -> HybridTransfer.TransferError { .failed(message) }
    private func failure(_ message: String) -> HybridTransfer.TransferError { Self.failure(message) }
}
