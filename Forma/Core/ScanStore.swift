import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []
    @Published private(set) var isSaving = false
    @Published private(set) var isRecoveringPending = false
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var savingState = ProcessingControl.Snapshot(phase: .running, revision: 0)
    @Published private(set) var savingStage = "Preparando archivos"
    @Published private(set) var savingCompletedBytes: Int64 = 0
    @Published private(set) var savingTotalBytes: Int64 = 0
    @Published private(set) var pendingCapture: CaptureResult?
    @Published var error: String?
    let baseURL: URL
    private var savingControl: ProcessingControl?
    private var savingTask: Task<ScanRecord, Error>?
    private var recoveryTask: Task<PendingScanRecovery.Report, Error>?
    private var savingGeneration = UUID()
    private var scheduledPendingRecovery = false
#if os(iOS)
    private var previousSavingIdleTimer: Bool?
#endif

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma", isDirectory: true)
        reload()
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            scans = folders.compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("captura.json")) else { return nil }
                return try? JSONDecoder().decode(ScanRecord.self, from: data)
            }.sorted { $0.createdAt > $1.createdAt }
        } catch { self.error = "No se pudo abrir la biblioteca: \(error.localizedDescription)" }
        pendingSaveCount = ((try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? [])
            .filter { PendingScanRecovery.isStagingDirectoryName($0) }.count
        if !scheduledPendingRecovery {
            scheduledPendingRecovery = true
            if pendingSaveCount > 0 { Task { [weak self] in await self?.recoverPendingSaves() } }
        }
    }

    func recoverPendingSaves() async {
        guard !isSaving else { return }
        isSaving = true; isRecoveringPending = true
        savingStage = "Validando guardados pendientes"
        savingCompletedBytes = 0; savingTotalBytes = 0
        let generation = UUID(); savingGeneration = generation
        savingState = .init(phase: .running, revision: 0)
        let control = ProcessingControl { [weak self] state in
            Task { @MainActor [weak self] in self?.applySavingState(state, generation: generation) }
        }
        savingControl = control
        updateSavingIdleTimer(working: true)
        defer {
            isSaving = false; isRecoveringPending = false
            savingControl = nil; recoveryTask = nil
            updateSavingIdleTimer(working: false)
        }
        let base = baseURL
        let owner = self
        let throttle = SaveProgressThrottle()
        let worker = Task.detached(priority: .utility) { [owner, throttle] in
            try PendingScanRecovery.recover(in: base, control: control) { title, fraction in
                guard throttle.shouldReport(finished: fraction >= 1) else { return }
                Task { @MainActor [weak owner] in
                    guard let owner, owner.isSaving, owner.savingGeneration == generation else { return }
                    owner.savingStage = title
                }
            }
        }
        recoveryTask = worker
        do {
            let report = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
                control.cancel(); worker.cancel()
            })
            pendingSaveCount = report.remainingCount
            if !report.failures.isEmpty { error = "Quedan guardados pendientes sin completar. Sus archivos se conservan. " + report.failures.prefix(2).joined(separator: " ") }
            reload()
        } catch {
            self.error = error is CancellationError ? "Recuperación cancelada. Los archivos pendientes se conservan." : error.localizedDescription
        }
    }

    func toggleSavingPause() {
        guard isSaving, let savingControl else { return }
        let next = savingControl.snapshot.isPauseActive ? savingControl.resume() : savingControl.requestPause()
        applySavingState(next, generation: savingGeneration)
    }

    func pauseSaving() {
        guard isSaving, let savingControl else { return }
        applySavingState(savingControl.requestPause(), generation: savingGeneration)
    }

    func cancelSaving() {
        guard isSaving else { return }
        if let savingControl { applySavingState(savingControl.cancel(), generation: savingGeneration) }
        savingTask?.cancel()
        recoveryTask?.cancel()
    }

    private func applySavingState(_ state: ProcessingControl.Snapshot, generation: UUID) {
        guard isSaving, generation == savingGeneration, state.revision >= savingState.revision else { return }
        savingState = state
        updateSavingIdleTimer(working: state.phase == .running || state.phase == .pauseRequested)
    }

    private func updateSavingIdleTimer(working: Bool) {
#if os(iOS)
        if working {
            if previousSavingIdleTimer == nil { previousSavingIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousSavingIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousSavingIdleTimer
            self.previousSavingIdleTimer = nil
        }
#endif
    }

    func directory(for scan: ScanRecord) -> URL { baseURL.appendingPathComponent(scan.id.uuidString, isDirectory: true) }
    func modelURL(for scan: ScanRecord) -> URL? { scan.modelFile.map { directory(for: scan).appendingPathComponent($0) } }
    /// Derived models can reuse their original capture without duplicating its photographs.
    func datasetSource(for scan: ScanRecord) -> ScanRecord? {
        var current = scan
        var visited: Set<UUID> = []
        while visited.insert(current.id).inserted {
            if let relative = current.datasetDirectory {
                return Self.safeRelativePath(relative) ? current : nil
            }
            guard let sourceID = current.sourceScanID,
                  let source = scans.first(where: { $0.id == sourceID }) else { return nil }
            current = source
        }
        return nil
    }
    func datasetURL(for scan: ScanRecord) -> URL? {
        guard let source = datasetSource(for: scan), let relative = source.datasetDirectory else { return nil }
        return directory(for: source).appendingPathComponent(relative)
    }
    func gaussianURL(for scan: ScanRecord) -> URL? { scan.gaussianModelFile.map { directory(for: scan).appendingPathComponent($0) } }
    func files(for scan: ScanRecord) -> [URL] { scan.exports.map { directory(for: scan).appendingPathComponent($0) } }

    func save(_ result: CaptureResult, pacing: (@Sendable () throws -> Void)? = nil,
              initiallyPaused: Bool = false,
              controlObserver: (@Sendable (ProcessingControl.Snapshot) -> Void)? = nil) async -> ScanRecord? {
        guard !isSaving else { return nil }
        guard pendingCapture == nil || pendingCapture?.id == result.id else {
            error = "Hay una captura pendiente. Guárdala o descártala antes de iniciar otra."
            return nil
        }
        error = nil
        pendingCapture = result
        isSaving = true
        defer { isSaving = false }
        let base = baseURL
        let generation = UUID()
        savingGeneration = generation
        savingState = .init(phase: .running, revision: 0)
        savingCompletedBytes = 0; savingTotalBytes = 0
        let control = ProcessingControl { [weak self] state in
            controlObserver?(state)
            Task { @MainActor [weak self] in self?.applySavingState(state, generation: generation) }
        }
        if initiallyPaused { control.requestPause() }
        savingControl = control
        updateSavingIdleTimer(working: true)
        defer {
            updateSavingIdleTimer(working: false)
            savingTask = nil
            savingControl = nil
        }
        do {
            let worker = Task.detached(priority: .utility) { [weak self] in
              try ProcessingControl.$workPacing.withValue(pacing) {
                try ProcessingControl.withControl(control) {
                    var lastReport = -Double.infinity
                    return try Self.persist(result, at: base) { title, value in
                        let now = ProcessInfo.processInfo.systemUptime
                        guard now - lastReport >= 0.1 || value.completedBytes == value.totalBytes else { return }
                        lastReport = now
                        Task { @MainActor [weak self] in
                            guard let self, self.isSaving, self.savingGeneration == generation else { return }
                            self.savingStage = title
                            self.savingCompletedBytes = value.completedBytes
                            self.savingTotalBytes = value.totalBytes
                        }
                    }
                }
              }
            }
            savingTask = worker
            let record = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
                control.cancel(); worker.cancel()
            })
            scans.insert(record, at: 0)
            pendingCapture = nil
            return record
        } catch {
            self.error = error is CancellationError
                ? "Guardado cancelado. La captura y sus fuentes siguen pendientes; puedes reintentar."
                : "No se pudo guardar: \(error.localizedDescription)"
            return nil
        }
    }

    nonisolated private static func persist(_ result: CaptureResult, at base: URL,
                                           progress: (String, CooperativeFileIO.Progress) -> Void) throws -> ScanRecord {
        try ProcessingControl.checkpoint()
        progress("Preparando geometría", .init(completedBytes: 0, totalBytes: 0))
        let id = UUID()
        let pending = base.appendingPathComponent(".pending-\(id.uuidString)", isDirectory: true)
        let destination = base.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: pending) } }
        var exports: [String] = []
        var modelFile: String?
        var gaussianFile: String?
        var datasetFolder: String?
        if let mesh = result.mesh {
            exports += try MeshExporter.write(mesh, to: pending)
            modelFile = "modelo.obj"
            try JSONEncoder().encode(mesh).write(to: pending.appendingPathComponent("malla.json"), options: .atomic)
            exports.append("malla.json")
        }
        if let package = result.modelPackageURL {
            let copied = pending.appendingPathComponent("modelo", isDirectory: true)
            try CooperativeFileIO.copyDirectory(package, to: copied) { progress("Copiando modelo y texturas", $0) }
            if let model = result.modelURL {
                let rootPath = package.standardizedFileURL.path + "/"
                guard model.standardizedFileURL.path.hasPrefix(rootPath) else {
                    throw RGBDDatasetError.invalid("El modelo principal no pertenece a su paquete de archivos.")
                }
                let relative = String(model.standardizedFileURL.path.dropFirst(rootPath.count))
                guard Self.safeRelativePath(relative) else { throw RGBDDatasetError.invalid("Ruta del modelo no válida.") }
                modelFile = "modelo/" + relative
            }
            if let relative = result.gaussianModelRelativePath {
                guard Self.safeRelativePath(relative) else { throw RGBDDatasetError.invalid("Ruta Gaussian no válida.") }
                gaussianFile = "modelo/" + relative
                guard FileManager.default.fileExists(atPath: pending.appendingPathComponent(gaussianFile!).path) else {
                    throw RGBDDatasetError.invalid("El paquete no contiene el modelo Gaussian anunciado.")
                }
                modelFile = modelFile ?? gaussianFile
            }
            let archiveName = gaussianFile == nil ? "modelo-texturizado.zip" : "modelo-gaussian.zip"
            try CooperativeFileIO.archiveDirectory(copied, to: pending.appendingPathComponent(archiveName)) { progress("Empaquetando modelo sin recomprimir fotografías", $0) }
            exports.append(archiveName)
            // Gaussian interchange files are independently usable. OBJ+MTL textures travel together as ZIP.
            for file in try FileManager.default.contentsOfDirectory(at: copied, includingPropertiesForKeys: nil)
                where ["splat", "ply", "spz"].contains(file.pathExtension.lowercased()) {
                exports.append("modelo/" + file.lastPathComponent)
            }
        } else if let model = result.modelURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: model.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw MeshExportError.empty }
            let name = "modelo.\(model.pathExtension.lowercased())"
            try CooperativeFileIO.copyFile(model, to: pending.appendingPathComponent(name)) { progress("Copiando modelo", $0) }
            exports.append(name)
            modelFile = name
        }
        guard modelFile != nil else { throw MeshExportError.empty }
        if let modelFile {
            let attributes = try FileManager.default.attributesOfItem(atPath: pending.appendingPathComponent(modelFile).path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw MeshExportError.empty }
        }
        if let dataset = result.captureDatasetURL {
            let destination = pending.appendingPathComponent("fuentes", isDirectory: true)
            try CooperativeFileIO.copyDirectory(dataset, to: destination) { progress("Conservando fotografías y calibración", $0) }
            _ = try RGBDDatasetManifest.load(from: destination)
            datasetFolder = "fuentes"
        }
        for (index, source) in result.auxiliaryURLs.enumerated() {
            let isDirectory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            let name = "datos-\(index + 1)-\(source.lastPathComponent)\(isDirectory ? ".zip" : "")"
            if isDirectory {
                try CooperativeFileIO.archiveDirectory(source, to: pending.appendingPathComponent(name)) { progress("Empaquetando archivos auxiliares", $0) }
            } else {
                try CooperativeFileIO.copyFile(source, to: pending.appendingPathComponent(name)) { progress("Copiando archivos auxiliares", $0) }
            }
            exports.append(name)
        }
        let date = Date()
        let refinement = result.sourceScanID == nil ? "" : " · Refinada"
        let title = result.isDemo ? "Estudio de forma · Ejemplo" : "\(gaussianFile == nil ? result.mode.title : "Gaussian 3D")\(refinement) · \(date.formatted(date: .abbreviated, time: .shortened))"
        var record = ScanRecord(id: id, name: title, mode: result.mode, createdAt: date,
            vertexCount: result.mesh?.vertexCount ?? result.modelGeometryCounts?.vertexCount ?? 0,
            faceCount: result.mesh?.faceCount ?? result.modelGeometryCounts?.faceCount ?? 0,
            duration: result.duration, isDemo: result.isDemo, note: result.note,
            modelFile: modelFile, exports: [])
        record.datasetDirectory = datasetFolder
        record.gaussianModelFile = gaussianFile
        record.statistics = result.statistics
        record.sourceScanID = result.sourceScanID
        record.hybridResultProvenance = result.hybridResultProvenance
        let report: [String: Any] = [
            "schema": 1, "app": "Forma", "mode": result.mode.rawValue,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "createdAt": ISO8601DateFormatter().string(from: date), "units": "meters", "upAxis": "Y",
            "isDemo": result.isDemo, "vertices": record.vertexCount, "triangles": record.faceCount,
            "sourceScanID": result.sourceScanID?.uuidString as Any? ?? NSNull(),
            "durationSeconds": result.duration, "note": result.note,
            "boundsMeters": result.mesh.map { [$0.bounds.x, $0.bounds.y, $0.bounds.z] } ?? [],
            "meshSurfaceAreaSquareMeters": result.mesh?.surfaceArea as Any? ?? NSNull(),
            "accuracy": "No certificada; validar contra medidas de referencia.",
            "stlUnits": "STL no codifica unidades; las coordenadas están en metros. Convertir a mm antes de imprimir.",
            "meshTopology": "No se garantiza una malla cerrada ni apta para impresión sin reparar.",
            "statistics": result.statistics ?? [:],
            "representation": gaussianFile != nil ? "trained3DGaussianSplatting" :
                (result.statistics?["texturedFaces"] ?? 0) > 0 ? "photographicallyTexturedMesh" :
                result.mode == .object && result.modelURL != nil ? "photogrammetricMesh" : "geometry"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: pending.appendingPathComponent("informe.json"))
        exports += ["informe.json", "captura.json", "integridad.json"]
        record.exports = exports
        try JSONEncoder().encode(record).write(to: pending.appendingPathComponent("captura.json"), options: .atomic)
        var entries: [IntegrityManifest.Entry] = []
        // URL enumeration may resolve /var or a library alias into a longer canonical
        // path. Enumerate relative names rather than slicing two different roots.
        guard let containedFiles = FileManager.default.enumerator(atPath: pending.path) else {
            throw RGBDDatasetError.invalid("No se pudieron enumerar los archivos guardados para comprobar su integridad.")
        }
        var filesToHash: [(String, URL, Int)] = []
        while let name = containedFiles.nextObject() as? String {
            try ProcessingControl.checkpoint()
            guard Self.safeRelativePath(name) else { throw RGBDDatasetError.invalid("Ruta de integridad no válida.") }
            let file = pending.appendingPathComponent(name)
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            filesToHash.append((name, file, bytes))
        }
        let hashTotal = filesToHash.reduce(Int64(0)) { $0 + Int64($1.2) }
        var hashed: Int64 = 0
        for (name, file, bytes) in filesToHash {
            let digest = try IntegrityManifest.digest(file) { count in
                progress("Verificando integridad", .init(completedBytes: hashed + count, totalBytes: hashTotal))
            }
            entries.append(.init(name: name, sha256: digest, bytes: bytes))
            hashed += Int64(bytes)
        }
        let manifest = IntegrityManifest(createdAt: date, files: entries)
        try JSONEncoder().encode(manifest).write(to: pending.appendingPathComponent("integridad.json"), options: .atomic)
        try ProcessingControl.checkpoint()
        try FileManager.default.moveItem(at: pending, to: destination)
        committed = true
        Self.cleanTemporaryWorkspace(result)
        return record
    }

    nonisolated static func safeRelativePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\0") &&
        name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    nonisolated private static func archiveDirectory(_ source: URL, to destination: URL) throws {
        try CooperativeFileIO.archiveDirectory(source, to: destination)
    }

    func exportDataset(_ scan: ScanRecord) async throws -> URL {
        guard let source = datasetURL(for: scan) else { throw RGBDDatasetError.invalid("Esta captura no contiene datos RGB-D guardados.") }
        let id = scan.id
        return try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FormaExports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("Fuentes-\(id.uuidString).zip")
            if FileManager.default.fileExists(atPath: output.path) { return output }
            try Self.archiveDirectory(source, to: output)
            return output
        }.value
    }

    nonisolated private static func cleanTemporaryWorkspace(_ result: CaptureResult?) {
        if let result, let cleanup = result.cleanupDirectory {
            let fm = FileManager.default
            let requested = cleanup.standardizedFileURL
            let candidate = requested.resolvingSymlinksInPath()
            let aiRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FormaAIWork", isDirectory: true).standardizedFileURL
            let resolvedAIRoot = aiRoot.resolvingSymlinksInPath()
            let requestedAIWork = requested.path == aiRoot.path || requested.path.hasPrefix(aiRoot.path + "/")
            let resolvedAIWork = candidate.path == resolvedAIRoot.path || candidate.path.hasPrefix(resolvedAIRoot.path + "/")
            if requestedAIWork || resolvedAIWork {
                // Persistent IA work is not disposable merely because its name resembles
                // a temporary folder. Bind cleanup to this exact derived result and owner.
                guard let sourceID = result.sourceScanID,
                      UUID(uuidString: requested.lastPathComponent) == sourceID,
                      candidate.deletingLastPathComponent().path == resolvedAIRoot.path,
                      let rootValues = try? aiRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                      let workValues = try? requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      workValues.isDirectory == true, workValues.isSymbolicLink != true,
                      let package = result.modelPackageURL,
                      package.standardizedFileURL.resolvingSymlinksInPath().path == candidate.appendingPathComponent("modelo").path,
                      let packageValues = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      packageValues.isDirectory == true, packageValues.isSymbolicLink != true else { return }
                let metadata = requested.appendingPathComponent("trabajo.json")
                guard let values = try? metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      metadata.resolvingSymlinksInPath().deletingLastPathComponent().path == candidate.path,
                      let data = try? Data(contentsOf: metadata),
                      let owner = try? JSONDecoder().decode(AIWorkspaceOwner.self, from: data),
                      owner.sourceID == sourceID else { return }
                try? fm.removeItem(at: requested)
                return
            }
            // Only feature-owned workspaces below the system temporary directory are eligible.
            let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let trainingRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FormaTraining", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let ownedTemporary = candidate.path.hasPrefix(temporary) && candidate.lastPathComponent.hasPrefix("Forma")
            let ownedTraining = candidate.path.hasPrefix(trainingRoot) && UUID(uuidString: candidate.lastPathComponent) != nil
            if ownedTemporary || ownedTraining {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
    }

    private struct AIWorkspaceOwner: Decodable { var sourceID: UUID }

    func discardPendingCapture() {
        guard !isSaving else { return }
        Self.cleanTemporaryWorkspace(pendingCapture)
        pendingCapture = nil
        error = nil
    }

    func verify(_ scan: ScanRecord) async throws -> Bool {
        let folder = directory(for: scan)
        return try await Task.detached {
            let data = try Data(contentsOf: folder.appendingPathComponent("integridad.json"))
            return try JSONDecoder().decode(IntegrityManifest.self, from: data).verify(in: folder)
        }.value
    }

    func delete(_ scan: ScanRecord) {
        do {
            try FileManager.default.removeItem(at: directory(for: scan))
            scans.removeAll { $0.id == scan.id }
        } catch { self.error = "No se pudo eliminar: \(error.localizedDescription)" }
    }
}

private final class SaveProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.infinity
    func shouldReport(finished: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard finished || now - last >= 0.1 else { return false }
        last = now
        return true
    }
}
