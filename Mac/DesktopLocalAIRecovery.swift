import Foundation

/// Small durable controller ledger. Atlas checkpoints remain owned/validated by
/// LocalAITextureEnhancer; this file never rewrites their cursor or payload.
enum DesktopLocalAIRecovery {
    enum State: String, Codable { case running, manualPaused, stopped, saving, savePending, failed, completed }
    struct Job: Codable, Identifiable {
        var schema = 1
        var id: UUID
        var sourceID: UUID
        var strength: Double
        var state: State = .running
        var progress = 0.0
        var resultID: UUID?
        var error: String?
        var updatedAt = Date()
        var shouldResumeAutomatically: Bool { state == .running || state == .saving || state == .savePending }
    }
    struct File: Codable, Equatable { var name: String; var bytes: Int64; var sha256: String }
    private struct Inputs: Codable, Equatable { var source: [File]; var model: [File] }
    struct Discovery { var jobs: [Job] = []; var failures: [String] = [] }
    static let metadataName = "trabajo-ia.json"

    static func workspace(root: URL, sourceID: UUID) -> URL {
        root.appendingPathComponent("Work/LocalAI-" + sourceID.uuidString, isDirectory: true)
    }

    static func load(root: URL, sourceID: UUID) throws -> Job? {
        let parent = root.appendingPathComponent("Work", isDirectory: true)
        if FileManager.default.fileExists(atPath: parent.path) { try requireDirectory(parent) }
        let work = workspace(root: root, sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: work.path) else { return nil }
        try requireDirectory(work)
        let metadata = work.appendingPathComponent(metadataName)
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw invalid("Hay una carpeta IA sin índice válido. Se conserva para revisión: " + work.lastPathComponent)
        }
        try requireFile(metadata)
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: metadata))
        guard job.schema == 1, job.sourceID == sourceID, job.strength.isFinite,
              (0...1).contains(job.strength), job.progress.isFinite, (0...1).contains(job.progress) else {
            throw invalid("El índice del trabajo IA no corresponde a esta captura o configuración.")
        }
        return job
    }

    static func save(_ job: Job, root: URL) throws {
        let work = workspace(root: root, sourceID: job.sourceID)
        let parent = work.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { try requireDirectory(parent) }
        if FileManager.default.fileExists(atPath: work.path) { try requireDirectory(work) }
        else { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
        let url = work.appendingPathComponent(metadataName)
        if FileManager.default.fileExists(atPath: url.path) { try requireFile(url) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: url, options: .atomic)
    }

    static func discover(root: URL) -> Discovery {
        let parent = root.appendingPathComponent("Work", isDirectory: true)
        var result = Discovery()
        let directories = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for directory in directories where directory.lastPathComponent.hasPrefix("LocalAI-") {
            guard let sourceID = UUID(uuidString: String(directory.lastPathComponent.dropFirst("LocalAI-".count))) else { continue }
            do { if let job = try load(root: root, sourceID: sourceID) { result.jobs.append(job) } }
            catch { result.failures.append(directory.lastPathComponent + ": " + error.localizedDescription) }
        }
        return result
    }

    /// Fingerprints bind resumed and already-completed work to the same source
    /// and installed weights. Paths are local; names are relative and validated.
    static func bindInputs(work: URL, source: URL, model: URL) throws {
        let actual = try Inputs(source: files(in: source), model: files(in: model))
        let url = work.appendingPathComponent("inputs.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try requireFile(url)
            guard try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: url)) == actual else {
                throw invalid("Cambiaron las fuentes o los pesos del trabajo IA. Se conserva el avance; no se mezclará con otra configuración.")
            }
        } else {
            try JSONEncoder().encode(actual).write(to: url, options: .atomic)
        }
    }

    static func commitResult(work: URL, package: URL) throws {
        let records = try files(in: package)
        guard records.contains(where: { ["modelo.obj", "modelo.usdz"].contains($0.name) }), records.contains(where: { $0.name == "ia-local.json" }) else {
            throw invalid("Falta el modelo o el informe del resultado IA.")
        }
        try JSONEncoder().encode(records).write(to: work.appendingPathComponent("result-integrity.json"), options: .atomic)
    }

    static func restoredReport(work: URL, package: URL, sourceModel: URL) throws -> LocalAITextureEnhancer.Report? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: package.path) else { return nil }
        let manifest = work.appendingPathComponent("result-integrity.json")
        guard fm.fileExists(atPath: manifest.path) else {
            // An interruption between engine publication and integrity commit
            // cannot authenticate that output. Keep it, then rebuild safely.
            try requireDirectory(package)
            try fm.moveItem(at: package, to: work.appendingPathComponent("unverified-output-" + UUID().uuidString))
            return nil
        }
        try requireFile(manifest)
        let expected = try JSONDecoder().decode([File].self, from: Data(contentsOf: manifest))
        guard !expected.isEmpty, try files(in: package) == expected else {
            throw invalid("La copia IA pendiente no pasa su verificación de integridad. Se conserva sin publicar.")
        }
        return try LocalAIModelRestoration.restoredReport(package: package, sourceModel: sourceModel)
    }

    static func publishedJob(in directory: URL, record: ScanRecord) -> Job? {
        guard let name = record.exports.first(where: { $0.hasSuffix("-" + metadataName) }), ScanStore.safeRelativePath(name) else { return nil }
        let url = directory.appendingPathComponent(name)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(Job.self, from: data), job.schema == 1,
              job.sourceID == record.sourceScanID else { return nil }
        return job
    }

    static func removeCompleted(_ job: Job, root: URL) throws {
        guard job.state == .completed, job.resultID != nil,
              let saved = try load(root: root, sourceID: job.sourceID), saved.id == job.id,
              saved.state == .completed, saved.resultID == job.resultID else { return }
        try FileManager.default.removeItem(at: workspace(root: root, sourceID: job.sourceID))
    }

    private static func files(in directory: URL) throws -> [File] {
        try requireDirectory(directory)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw invalid("No se pudo enumerar el paquete IA.")
        }
        var result: [File] = []
        for case let url as URL in enumerator {
            try ProcessingControl.checkpoint()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw invalid("El paquete IA contiene un enlace simbólico.") }
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root) else { throw invalid("Un archivo IA está fuera de su paquete.") }
            let name = String(path.dropFirst(root.count))
            guard ScanStore.safeRelativePath(name) else { throw invalid("Ruta IA no válida.") }
            result.append(.init(name: name, bytes: try HybridTransfer.size(url), sha256: try IntegrityManifest.digest(url)))
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid("La carpeta IA no es un directorio propio válido.") }
    }
    private static func requireFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid("El índice IA no es un archivo regular.") }
    }
    private static func invalid(_ text: String) -> Error { RGBDDatasetError.invalid(text) }
}
