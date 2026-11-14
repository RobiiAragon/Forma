import Foundation

/// Publishes a verified remote derivative once, including after an app crash at commit.
@MainActor
final class HybridResultImport {
    private var pending: [String: CaptureResult] = [:]
    private let metadataDirectory: URL

    init(metadataDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FormaHybridImports", isDirectory: true)) {
        self.metadataDirectory = metadataDirectory
    }

    func save(_ bundle: HybridTransfer.DownloadedResult, sourceScanID: UUID?,
              library: ScanStore) async throws -> ScanRecord {
        let marker = HybridResultProvenance(jobID: bundle.descriptor.jobID, resultID: bundle.descriptor.resultID,
            manifestSHA256: bundle.manifestSHA256, sourceScanID: sourceScanID)
        if let saved = try existing(marker, library: library) {
            guard try await library.verify(saved) else { throw failure("El modelo ya guardado no coincide con su manifiesto de integridad.") }
            return saved
        }
        let key = marker.jobID.uuidString + "/" + marker.resultID.uuidString + "/" + marker.manifestSHA256
        if pending[key] == nil {
            let metadataDirectory = metadataDirectory
            pending[key] = try await Task.detached(priority: .utility) {
                try Self.prepare(bundle, provenance: marker, metadataDirectory: metadataDirectory)
            }.value
        }
        guard let result = pending[key] else { throw failure("No se pudo preparar el resultado descargado.") }
        guard !library.isSaving else { throw failure("La biblioteca está guardando otro resultado. El modelo descargado se conserva para reintentar.") }
        guard library.pendingCapture == nil || library.pendingCapture?.id == result.id else {
            throw failure("Resuelve el guardado pendiente en la biblioteca y vuelve a guardar este resultado. La descarga se conserva.")
        }
        guard let saved = await library.save(result) else {
            throw failure(library.error ?? "No se pudo guardar el resultado. La descarga se conserva para reintentar.")
        }
        if let sidecar = result.auxiliaryURLs.first {
            let folder = sidecar.deletingLastPathComponent()
            if folder.deletingLastPathComponent().standardizedFileURL == metadataDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        pending.removeValue(forKey: key)
        return saved
    }

    func existing(_ marker: HybridResultProvenance, library: ScanStore) throws -> ScanRecord? {
        for record in library.scans {
            if let saved = record.hybridResultProvenance {
                guard saved.schemaVersion == 1, saved.jobID == marker.jobID, saved.resultID == marker.resultID,
                      saved.manifestSHA256 == marker.manifestSHA256 else { continue }
                // An old marker cannot claim that a deleted payload is still available.
                guard let model = library.modelURL(for: record), FileManager.default.fileExists(atPath: model.path) else {
                    throw failure("Existe un recibo del resultado, pero falta su modelo guardado. Revisa esa captura antes de importar otra copia.")
                }
                return record
            }
        }
        return nil
    }

    nonisolated private static func prepare(_ bundle: HybridTransfer.DownloadedResult,
                                            provenance: HybridResultProvenance, metadataDirectory: URL) throws -> CaptureResult {
        try Task.checkCancellation()
        try HybridTransfer.verifyDownloadedResult(bundle)
        let descriptor = bundle.descriptor
        guard let mode = ScanMode(rawValue: descriptor.mode) else { throw failure("Modalidad de resultado no compatible.") }
        func resolved(_ relative: String) throws -> URL {
            guard ScanStore.safeRelativePath(relative) else { throw failure("El resultado contiene una ruta no válida.") }
            let url = bundle.directory.appendingPathComponent(relative)
            let root = bundle.directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
                throw failure("Un archivo del resultado sale de su carpeta verificada.")
            }
            return url
        }
        let model = try descriptor.modelRelativePath.map(resolved)
        let package = try descriptor.packageRelativePath.map(resolved)
        var mesh: MeshSnapshot?
        if let relative = descriptor.meshRelativePath {
            mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: resolved(relative)))
            try MeshExporter.validate(mesh!)
        }
        guard model != nil || mesh != nil else { throw failure("El resultado no contiene un modelo utilizable.") }
        let metadata = metadataDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var returned = false
        defer { if !returned { try? FileManager.default.removeItem(at: metadata) } }
        let sidecar = metadata.appendingPathComponent("hybrid-result.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance).write(to: sidecar, options: .atomic)
        var result = CaptureResult(mesh: mesh, modelURL: model, auxiliaryURLs: [sidecar], mode: mode,
            duration: descriptor.duration, note: descriptor.note)
        result.modelPackageURL = package
        result.gaussianModelRelativePath = descriptor.gaussianModelRelativePath
        result.statistics = descriptor.statistics
        result.sourceScanID = provenance.sourceScanID
        result.hybridResultProvenance = provenance
        // Keep the verified download for retry/recovery; no original photographs are copied.
        returned = true
        return result
    }

    nonisolated private func failure(_ text: String) -> Error { Self.failure(text) }
    nonisolated private static func failure(_ text: String) -> Error {
        RGBDDatasetError.invalid(text)
    }
}
