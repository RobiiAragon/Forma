import Foundation

struct GaussianRecoverySession: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    /// Relative to Documents when possible, so restored app containers retain valid source paths.
    var datasetPath: String
    var targetIterations: Int
    var downscale: Float
    var createdAt: Date
    var step: Int = 0
    var updatedAt: Date
    var state: String = "created"

    var datasetURL: URL {
        if datasetPath.hasPrefix("/") { return URL(fileURLWithPath: datasetPath, isDirectory: true) }
        return GaussianRecovery.documentsDirectory.appendingPathComponent(datasetPath, isDirectory: true)
    }
    var workspaceURL: URL { GaussianRecovery.sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    var checkpointURL: URL { workspaceURL.appendingPathComponent("entrenamiento.ckpt") }
}

/// Metadata and checkpoints live in Documents; sources remain owned by their original library scan.
enum GaussianRecovery {
    enum RecoveryError: LocalizedError {
        case invalidConfiguration, missingDataset, invalidWorkspace, invalidStep
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "La sesión necesita iteraciones positivas y un factor de resolución finito igual o superior a 1."
            case .missingDataset: return "No se encuentra el directorio de fotografías y cámaras calibradas."
            case .invalidWorkspace: return "La carpeta de recuperación no corresponde a esta sesión."
            case .invalidStep: return "El número de pasos guardados no puede ser negativo."
            }
        }
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var sessionsDirectory: URL { documentsDirectory.appendingPathComponent("FormaTraining", isDirectory: true) }

    static func create(datasetURL: URL, iterations: Int, downscale: Float) throws
        -> (session: GaussianRecoverySession, workspaceURL: URL) {
        guard iterations > 0, downscale.isFinite, downscale >= 1 else { throw RecoveryError.invalidConfiguration }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: datasetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecoveryError.missingDataset
        }
        let source = datasetURL.standardizedFileURL.resolvingSymlinksInPath()
        let documents = documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let documentPrefix = documents.path + "/"
        let path = source.path.hasPrefix(documentPrefix) ? String(source.path.dropFirst(documentPrefix.count)) : source.path
        let now = Date()
        let session = GaussianRecoverySession(id: UUID(), datasetPath: path, targetIterations: iterations,
                                              downscale: downscale, createdAt: now, updatedAt: now)
        let workspace = session.workspaceURL
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        do { try write(session, to: workspace) }
        catch { try? FileManager.default.removeItem(at: workspace); throw error }
        return (session, workspace)
    }

    /// Call after a successful atomic checkpoint commit. Returns the metadata written to disk.
    @discardableResult
    static func update(session: GaussianRecoverySession, workspaceURL: URL, step: Int,
                       state: String = "checkpointed") throws -> GaussianRecoverySession {
        guard step >= 0 else { throw RecoveryError.invalidStep }
        guard sameWorkspace(workspaceURL, session.workspaceURL),
              FileManager.default.fileExists(atPath: workspaceURL.path) else { throw RecoveryError.invalidWorkspace }
        var updated = session
        updated.step = step
        updated.updatedAt = Date()
        updated.state = state
        try write(updated, to: workspaceURL)
        return updated
    }

    /// Initial sessions without a checkpoint are omitted; incomplete/corrupt metadata is never deleted here.
    static func sessions(requireCheckpoint: Bool = true) -> [GaussianRecoverySession] {
        guard !Task.isCancelled else { return [] }
        let folders = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> GaussianRecoverySession? in
            guard !Task.isCancelled else { return nil }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let session = try? JSONDecoder().decode(GaussianRecoverySession.self, from: data),
                  folder.lastPathComponent == session.id.uuidString,
                  sameWorkspace(folder, session.workspaceURL) else { return nil }
            if requireCheckpoint {
                guard let properties = try? session.checkpointURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      properties.isRegularFile == true, (properties.fileSize ?? 0) > 0 else { return nil }
            }
            return session
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The caller must obtain explicit discard confirmation or a successful library commit first.
    /// Only this session workspace is removed; the source dataset is never removed by this API.
    static func remove(_ record: GaussianRecoverySession) throws {
        let workspace = record.workspaceURL
        guard sameWorkspace(workspace, sessionsDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)) else {
            throw RecoveryError.invalidWorkspace
        }
        if FileManager.default.fileExists(atPath: workspace.path) { try FileManager.default.removeItem(at: workspace) }
    }

    private static func sameWorkspace(_ lhs: URL, _ rhs: URL) -> Bool {
        let base = sessionsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        return left == right && left.deletingLastPathComponent() == base && UUID(uuidString: left.lastPathComponent) != nil
    }

    private static func write(_ session: GaussianRecoverySession, to workspace: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: workspace.appendingPathComponent("session.json"), options: .atomic)
    }
}
